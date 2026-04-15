// ─── CustomerOrderLineService ────────────────────────────────────────────────
/**
 * Single service class for Customer Order Line (COL) sync.
 *
 * Merges the handler, service, and repository into one class.
 * The trigger calls run() and everything else is handled internally.
 *
 * METHOD SUMMARY
 * ──────────────
 * run(op, newMap, oldMap, oldList)
 *     → Entry point called by the OrderItem trigger. Routes each operation
 *       (insert, update, delete) to the correct internal handler.
 *
 * buildCOL(orderItem)
 *     → Maps every relevant OrderItem field onto a new COL record. Public
 *       so the nightly batch can call it without duplicating logic.
 *
 * applyChanges(col, oldOI, newOI)
 *     → Diffs old vs new OrderItem onto an existing COL. Returns true when
 *       at least one field changed. Public so the batch can reuse it.
 *
 * buildPseudoOld(col)
 *     → Reconstructs a fake "before" OrderItem from the COL's stored values.
 *       Uses JSON.deserialize for read-only fields. Public so the batch
 *       can reuse it.
 *
 * getColsByOrderItemIds(ids)
 *     → Returns a Map keyed by OrderItem Id for quick lookup. Null Ids
 *       are silently removed. Public so the batch can look up existing COLs.
 *
 * getOrphanedCols()
 *     → Returns COLs with no linked OrderItem that haven't been tagged
 *       [DEL] yet. Public so the nightly batch can call it.
 *
 * ── Internal (private) ──
 *
 * createCOLsAsync(ids)
 *     → @future — re-queries OrderItems and inserts new COLs. Skips any
 *       OrderItem that already has a COL (idempotent safety net).
 *
 * updateCOLsAsync(ids)
 *     → @future — re-queries OrderItems, diffs them against the COL's stored
 *       values, and updates only the fields that changed.
 *
 * handleDeletedOrderItems(deletedList)
 *     → Synchronous — tags COLs with [DEL] prefix. Must be sync because
 *       OrderItem Ids become unqueryable after the transaction commits.
 *
 * queryOrderItems(ids)
 *     → Shared SOQL query used by both async methods so the field list is
 *       maintained in one place.
 *
 * without sharing — COLs are an internal sync object; sharing rules should
 * not prevent the trigger or batch from reading its own records.
 */
public without sharing class CustomerOrderLineService {

    // ── COL QUERY FIELD LIST ─────────────────────────────────────────────
    // One field list so every query stays in sync automatically.
    private static final String COL_BASE_FIELDS =
        'Id, Name, OrderItem__c, Last_Synced_Date__c, ' +
        'blng_LastChargeToDate__c, blng_NextBillingDate__c, ' +
        'Contract_Number__c, Contract_Status__c, End_Date__c, ' +
        'OrderItemNumber__c, Product_Name__c, Quantity__c, ' +
        'Service_Date__c, Subscription_Term_Months__c, Total_Price__c';

    // ── TRIGGER ENTRY POINT ──────────────────────────────────────────────

    /**
     * Called by the OrderItem trigger. Routes each operation to the
     * correct handler. Accepts the operation type as a parameter so
     * the method is testable without a real trigger context.
     */
    public static void run(
        System.TriggerOperation op,
        Map<Id, OrderItem> newMap,
        Map<Id, OrderItem> oldMap,
        List<OrderItem>    oldList
    ) {
        switch on op {
            when AFTER_INSERT { createCOLsAsync(newMap.keySet()); }
            when AFTER_UPDATE { updateCOLsAsync(newMap.keySet()); }
            when AFTER_DELETE { handleDeletedOrderItems(oldList); }
            when else {
                System.debug('CustomerOrderLineService: unhandled operation — ' + op);
            }
        }
    }

    // ── BUILD / DIFF HELPERS ─────────────────────────────────────────────

    /**
     * Maps every relevant OrderItem field onto a new COL record.
     * Public so the nightly batch can reuse it.
     */
    public static CustomerOrderLine__c buildCOL(OrderItem o) {
        CustomerOrderLine__c col = new CustomerOrderLine__c();
        col.Name                        = AppUtils.formatColName(o);
        col.OrderItem__c                = o.Id;
        col.Account__c                  = o.Order?.AccountId;
        col.blng_LastChargeToDate__c    = o.blng__LastChargeToDate__c;
        col.blng_NextBillingDate__c     = o.blng__NextBillingDate__c;
        col.Contract_Number__c          = o.SBQQ__Contract__r?.ContractNumber;
        col.Contract_Status__c          = o.SBQQ__Contract__r?.Status;
        col.End_Date__c                 = o.EndDate;
        col.Last_Synced_Date__c         = System.now();
        col.OrderItemNumber__c          = o.OrderItemNumber;
        col.Product_Name__c             = o.Product2?.Name;
        col.Quantity__c                 = o.Quantity;
        col.Service_Date__c             = o.ServiceDate;
        col.Subscription_Term_Months__c = o.SBQQ__DefaultSubscriptionTerm__c;
        col.Total_Price__c              = o.TotalPrice;
        return col;
    }

    /**
     * Diffs old vs new OrderItem onto an existing COL.
     * Returns true when at least one field actually changed.
     * Public so the batch can reuse it for drift detection.
     */
    public static Boolean applyChanges(
        CustomerOrderLine__c col, OrderItem oldOI, OrderItem newOI
    ) {
        Boolean changed = false;

        if (oldOI.blng__LastChargeToDate__c != newOI.blng__LastChargeToDate__c) {
            col.blng_LastChargeToDate__c = newOI.blng__LastChargeToDate__c; changed = true;
        }
        if (oldOI.blng__NextBillingDate__c != newOI.blng__NextBillingDate__c) {
            col.blng_NextBillingDate__c = newOI.blng__NextBillingDate__c; changed = true;
        }

        String oldContractNum = oldOI.SBQQ__Contract__r?.ContractNumber;
        String newContractNum = newOI.SBQQ__Contract__r?.ContractNumber;
        if (oldContractNum != newContractNum) {
            col.Contract_Number__c = newContractNum; changed = true;
        }

        String oldStatus = oldOI.SBQQ__Contract__r?.Status;
        String newStatus = newOI.SBQQ__Contract__r?.Status;
        if (oldStatus != newStatus) {
            col.Contract_Status__c = newStatus; changed = true;
        }

        if (oldOI.EndDate != newOI.EndDate) {
            col.End_Date__c = newOI.EndDate; changed = true;
        }
        if (oldOI.OrderItemNumber != newOI.OrderItemNumber) {
            col.OrderItemNumber__c = newOI.OrderItemNumber; changed = true;
        }

        String oldProd = oldOI.Product2?.Name;
        String newProd = newOI.Product2?.Name;
        if (oldProd != newProd) {
            col.Product_Name__c = newProd; changed = true;
        }

        if (oldOI.Quantity != newOI.Quantity) {
            col.Quantity__c = newOI.Quantity; changed = true;
        }
        if (oldOI.ServiceDate != newOI.ServiceDate) {
            col.Service_Date__c = newOI.ServiceDate; changed = true;
        }
        if (oldOI.SBQQ__DefaultSubscriptionTerm__c != newOI.SBQQ__DefaultSubscriptionTerm__c) {
            col.Subscription_Term_Months__c = newOI.SBQQ__DefaultSubscriptionTerm__c; changed = true;
        }
        if (oldOI.TotalPrice != newOI.TotalPrice) {
            col.Total_Price__c = newOI.TotalPrice; changed = true;
        }

        return changed;
    }

    /**
     * Reconstructs a fake "before" OrderItem from the COL's stored values.
     * Uses JSON.deserialize because TotalPrice, OrderItemNumber, and
     * ContractNumber are read-only fields.
     * Public so the batch can reuse it for drift detection.
     */
    public static OrderItem buildPseudoOld(CustomerOrderLine__c col) {
        Map<String, Object> fields = new Map<String, Object>{
            'blng__LastChargeToDate__c'        => col.blng_LastChargeToDate__c,
            'blng__NextBillingDate__c'         => col.blng_NextBillingDate__c,
            'EndDate'                          => col.End_Date__c,
            'OrderItemNumber'                  => col.OrderItemNumber__c,
            'Quantity'                         => col.Quantity__c,
            'ServiceDate'                      => col.Service_Date__c,
            'SBQQ__DefaultSubscriptionTerm__c' => col.Subscription_Term_Months__c,
            'TotalPrice'                       => col.Total_Price__c,
            'SBQQ__Contract__r' => new Map<String, Object>{
                'ContractNumber' => col.Contract_Number__c,
                'Status'         => col.Contract_Status__c
            },
            'Product2' => new Map<String, Object>{
                'Name' => col.Product_Name__c
            }
        };
        return (OrderItem) JSON.deserialize(JSON.serialize(fields), OrderItem.class);
    }

    // ── AFTER INSERT (async) ─────────────────────────────────────────────

    /**
     * Re-queries OrderItems, builds COLs, and inserts them.
     * Skips any OrderItem that already has a COL (idempotent).
     */
    @future
    private static void createCOLsAsync(Set<Id> orderItemIds) {
        List<OrderItem> items = queryOrderItems(orderItemIds);

        Map<Id, CustomerOrderLine__c> existing = getColsByOrderItemIds(orderItemIds);

        List<CustomerOrderLine__c> toInsert = new List<CustomerOrderLine__c>();
        for (OrderItem o : items) {
            if (!existing.containsKey(o.Id)) {
                toInsert.add(buildCOL(o));
            }
        }

        if (toInsert.isEmpty()) return;

        Database.SaveResult[] results = Database.insert(toInsert, false);
        NotificationService.handleResults(
            'Customer Order Lines - Create Summary', toInsert.size(), results
        );
    }

    // ── AFTER UPDATE (async) ─────────────────────────────────────────────

    /**
     * Re-queries current OrderItem values, diffs them against COL stored
     * values (the "pseudo-old"), and updates only the COLs that changed.
     */
    @future
    private static void updateCOLsAsync(Set<Id> orderItemIds) {
        Map<Id, OrderItem> freshItems = new Map<Id, OrderItem>(
            queryOrderItems(orderItemIds)
        );

        Map<Id, CustomerOrderLine__c> existingByOI = getColsByOrderItemIds(orderItemIds);

        List<CustomerOrderLine__c> toUpdate = new List<CustomerOrderLine__c>();

        for (Id oiId : orderItemIds) {
            if (!existingByOI.containsKey(oiId)) continue;
            if (!freshItems.containsKey(oiId))   continue;

            CustomerOrderLine__c col   = existingByOI.get(oiId);
            OrderItem            newOI = freshItems.get(oiId);

            OrderItem pseudoOld = buildPseudoOld(col);

            if (applyChanges(col, pseudoOld, newOI)) {
                col.Last_Synced_Date__c = System.now();
                toUpdate.add(col);
            }
        }

        if (toUpdate.isEmpty()) return;

        Database.SaveResult[] results = Database.update(toUpdate, false);
        NotificationService.handleResults(
            'Customer Order Lines - Update Summary', toUpdate.size(), results
        );
    }

    // ── AFTER DELETE (sync) ──────────────────────────────────────────────

    /**
     * Tags COLs with [DEL] prefix. Must stay synchronous because OrderItem
     * Ids become unqueryable after the transaction commits.
     */
    private static void handleDeletedOrderItems(List<OrderItem> deletedOIList) {
        Set<Id> idSet = AppUtils.pluckIds(deletedOIList, 'Id');

        Map<Id, CustomerOrderLine__c> colMap = getColsByOrderItemIds(idSet);

        List<CustomerOrderLine__c> toUpdate = new List<CustomerOrderLine__c>();
        for (CustomerOrderLine__c col : colMap.values()) {
            col.Name                = AppUtils.prependDeletedTag(col.Name);
            col.Last_Synced_Date__c = System.now();
            toUpdate.add(col);
        }

        if (toUpdate.isEmpty()) return;

        Database.SaveResult[] results = Database.update(toUpdate, false);
        NotificationService.handleResults(
            'Customer Order Lines - Delete Summary', toUpdate.size(), results
        );
    }

    // ── PUBLIC QUERIES ───────────────────────────────────────────────────

    /**
     * Returns a Map keyed by OrderItem Id for quick COL lookup.
     * Null Ids are silently removed before querying.
     * Public so the batch class can look up existing COLs.
     */
    public static Map<Id, CustomerOrderLine__c> getColsByOrderItemIds(Set<Id> ids) {
        Map<Id, CustomerOrderLine__c> result = new Map<Id, CustomerOrderLine__c>();
        Set<Id> cleaned = AppUtils.cleanIdSet(ids);
        if (cleaned.isEmpty()) return result;
        for (CustomerOrderLine__c col : Database.query(
            'SELECT ' + COL_BASE_FIELDS +
            ' FROM CustomerOrderLine__c WHERE OrderItem__c IN :cleaned'
        )) {
            result.put(col.OrderItem__c, col);
        }
        return result;
    }

    /**
     * Returns COLs whose linked OrderItem no longer exists and that
     * haven't already been tagged [DEL]. Used by the nightly batch.
     */
    public static List<CustomerOrderLine__c> getOrphanedCols() {
        return [
            SELECT Id, Name, Last_Synced_Date__c
            FROM   CustomerOrderLine__c
            WHERE  OrderItem__c = null
               AND NOT Name LIKE '[DEL]%'
        ];
    }

    // ── PRIVATE QUERIES ──────────────────────────────────────────────────

    /**
     * Shared OrderItem query used by both async methods so the field list
     * is maintained in one place.
     */
    private static List<OrderItem> queryOrderItems(Set<Id> orderItemIds) {
        return [
            SELECT Id, OrderItemNumber, Product2.Name,
                   Order.AccountId, SBQQ__Contract__c,
                   SBQQ__Contract__r.ContractNumber, SBQQ__Contract__r.Status,
                   Quantity, TotalPrice, ServiceDate, EndDate,
                   blng__LastChargeToDate__c, blng__NextBillingDate__c,
                   SBQQ__DefaultSubscriptionTerm__c
            FROM   OrderItem
            WHERE  Id IN :orderItemIds
        ];
    }
}
