// ─── CustomerOrderLineService ────────────────────────────────────────────────
public class CustomerOrderLineService {

    // ── BUILD / DIFF HELPERS ─────────────────────────────────────────────────

    /**
     * buildCOL — maps every relevant OrderItem field onto a new COL record.
     * Used by both the trigger path (async future) and the nightly batch.
     * Public so CustomerOrderLineBatch can call it without duplicating logic.
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
     * applyChanges — diffs old vs new OrderItem onto an existing COL.
     * Returns true when at least one field changed so callers know whether to update.
     * @TestVisible keeps it private but lets test classes call it directly.
     */
    @TestVisible
    private static Boolean applyChanges(CustomerOrderLine__c col, OrderItem oldOI, OrderItem newOI) {
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
        if (oldStatus != newStatus) { col.Contract_Status__c = newStatus; changed = true; }

        if (oldOI.EndDate != newOI.EndDate) {
            col.End_Date__c = newOI.EndDate; changed = true;
        }
        if (oldOI.OrderItemNumber != newOI.OrderItemNumber) {
            col.OrderItemNumber__c = newOI.OrderItemNumber; changed = true;
        }

        String oldProd = oldOI.Product2?.Name;
        String newProd = newOI.Product2?.Name;
        if (oldProd != newProd) { col.Product_Name__c = newProd; changed = true; }

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

    // ── AFTER INSERT ─────────────────────────────────────────────────────────

    /**
     * Called from the trigger. Immediately offloads to an async future method
     * so the original OrderItem save is not delayed.
     */
    public static void handleCreates(Set<Id> newOIIds) {
        createCOLsAsync(newOIIds);
    }

    /**
     * @future — runs after the transaction commits, in its own async context.
     * Re-queries OrderItems (futures cannot receive SObjects) then inserts COLs.
     * Skips any OrderItem that already has a COL (idempotent safety net).
     */
    @future
    private static void createCOLsAsync(Set<Id> orderItemIds) {
        List<OrderItem> items = [
            SELECT Id, OrderItemNumber, Product2.Name,
                   Order.AccountId, SBQQ__Contract__c,
                   SBQQ__Contract__r.ContractNumber, SBQQ__Contract__r.Status,
                   Quantity, TotalPrice, ServiceDate, EndDate,
                   blng__LastChargeToDate__c, blng__NextBillingDate__c,
                   SBQQ__DefaultSubscriptionTerm__c
            FROM   OrderItem
            WHERE  Id IN :orderItemIds
        ];

        Map<Id, CustomerOrderLine__c> existing =
            CustomerOrderLineRepository.getByOrderItemIds(orderItemIds);

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

    // ── AFTER UPDATE ─────────────────────────────────────────────────────────

    /**
     * Called from the trigger. Serialises old/new IDs and offloads to async.
     */
    public static void handleUpdates(Map<Id, OrderItem> newOIMap, Map<Id, OrderItem> oldOIMap) {
        List<Id> newIds = new List<Id>();
        List<Id> oldIds = new List<Id>();

        for (Id id : newOIMap.keySet()) {
            newIds.add(id);
            oldIds.add(id);
        }
        updateCOLsAsync(newIds, oldIds);
    }

    /**
     * @future — re-queries current state then diffs against COL stored values.
     */
    @future
    private static void updateCOLsAsync(List<Id> orderItemIds, List<Id> ignored) {
        Map<Id, OrderItem> freshItems = new Map<Id, OrderItem>([
            SELECT Id, OrderItemNumber, Product2.Name,
                   Order.AccountId, SBQQ__Contract__c,
                   SBQQ__Contract__r.ContractNumber, SBQQ__Contract__r.Status,
                   Quantity, TotalPrice, ServiceDate, EndDate,
                   blng__LastChargeToDate__c, blng__NextBillingDate__c,
                   SBQQ__DefaultSubscriptionTerm__c
            FROM   OrderItem
            WHERE  Id IN :orderItemIds
        ]);

        Set<Id> idSet = new Set<Id>(orderItemIds);
        Map<Id, CustomerOrderLine__c> existingByOI =
            CustomerOrderLineRepository.getByOrderItemIds(idSet);

        List<CustomerOrderLine__c> toUpdate = new List<CustomerOrderLine__c>();

        for (Id oiId : orderItemIds) {
            if (!existingByOI.containsKey(oiId)) continue;
            if (!freshItems.containsKey(oiId))   continue;

            CustomerOrderLine__c col   = existingByOI.get(oiId);
            OrderItem            newOI = freshItems.get(oiId);

            OrderItem pseudoOld = buildPseudoOld(col);

            Boolean changed = applyChanges(col, pseudoOld, newOI);
            if (changed) {
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

    /**
     * Reconstructs a "before" OrderItem from the COL's stored field values.
     * This is needed in the async path because old trigger values are gone
     * by the time the future method runs.
     */
    @TestVisible
    private static OrderItem buildPseudoOld(CustomerOrderLine__c col) {
        OrderItem pseudo = new OrderItem();
        pseudo.blng__LastChargeToDate__c        = col.blng_LastChargeToDate__c;
        pseudo.blng__NextBillingDate__c         = col.blng_NextBillingDate__c;
        pseudo.EndDate                          = col.End_Date__c;
        pseudo.OrderItemNumber                  = col.OrderItemNumber__c;
        pseudo.Quantity                         = col.Quantity__c;
        pseudo.ServiceDate                      = col.Service_Date__c;
        pseudo.SBQQ__DefaultSubscriptionTerm__c = col.Subscription_Term_Months__c;
        pseudo.TotalPrice                       = col.Total_Price__c;
        pseudo.SBQQ__Contract__r                = new Contract(
            ContractNumber = col.Contract_Number__c,
            Status         = col.Contract_Status__c
        );
        pseudo.Product2                         = new Product2(Name = col.Product_Name__c);
        return pseudo;
    }

    // ── AFTER DELETE ─────────────────────────────────────────────────────────

    /**
     * Delete MUST stay synchronous — OrderItem Ids are no longer queryable
     * after the transaction commits, so we act before the commit window closes.
     */
    public static void handleUpdateToDeleted(List<OrderItem> deletedOIList) {
        Set<Id> idSet = new Set<Id>();
        for (OrderItem oi : deletedOIList) { idSet.add(oi.Id); }

        List<CustomerOrderLine__c> cols =
            CustomerOrderLineRepository.getByOrderItemIdsList(idSet);

        List<CustomerOrderLine__c> toUpdate = new List<CustomerOrderLine__c>();
        for (CustomerOrderLine__c col : cols) {
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
}
