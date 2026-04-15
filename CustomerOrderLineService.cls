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
 * getOrphanedCols()
 *     → Returns COLs with no linked OrderItem that haven't been tagged
 *       [DEL] yet. Public so the nightly batch can call it.
 *
 * ── Internal (private) ──
 *
 * applyChanges(col, oldOI, newOI)
 *     → Diffs old vs new OrderItem onto an existing COL. Returns true when
 *       at least one field changed so callers know whether to update.
 *
 * buildPseudoOld(col)
 *     → Reconstructs a fake "before" OrderItem from the COL's stored values.
 *       Needed in async because old trigger values are gone after commit.
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
 * getColsByOrderItemIds(ids)
 *     → Returns a Map keyed by OrderItem Id for quick lookup. Null Ids
 *       are silently removed before querying.
 *
 * without sharing — COLs are an internal sync object; sharing rules should
 * not prevent the trigger or batch from reading its own records.
 */
public without sharing class CustomerOrderLineService {

    private static final String COL_BASE_FIELDS =
        'Id, Name, OrderItem__c, Last_Synced_Date__c, ' +
        'blng_LastChargeToDate__c, blng_NextBillingDate__c, ' +
        'Contract_Number__c, Contract_Status__c, End_Date__c, ' +
        'OrderItemNumber__c, Product_Name__c, Quantity__c, ' +
        'Service_Date__c, Subscription_Term_Months__c, Total_Price__c';

    public static void run(
        System.TriggerOperation op,
        Map<Id, OrderItem> newMap,
        Map<Id, OrderItem> oldMap,
        List<OrderItem> oldList
    ) {
        switch on op {
            when AFTER_INSERT { createCOLsAsync(newMap.keySet()); }
            when AFTER_UPDATE { updateCOLsAsync(newMap.keySet()); }
            when AFTER_DELETE { handleDeletedOrderItems(oldList); }
        }
    }

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

    @TestVisible
    private static Boolean applyChanges(
        CustomerOrderLine__c col, OrderItem oldOI, OrderItem newOI
    ) {
        Boolean changed = false;

        if (oldOI.blng__LastChargeToDate__c != newOI.blng__LastChargeToDate__c) {
            col.blng_LastChargeToDate__c = newOI.blng__LastChargeToDate__c; changed = true;
        }

        if (oldOI.blng__NextBillingDate__c != newOI.blng__NextBillingDate__c) {
            col.blng_NextBillingDate__c = newOI.blng__NextBillingDate__c; changed = true;
        }

        // ✅ Contract Number (compare to COL, not pseudo)
        String newContractNum = newOI.SBQQ__Contract__r?.ContractNumber;
        if (col.Contract_Number__c != newContractNum) {
            col.Contract_Number__c = newContractNum; changed = true;
        }

        String newStatus = newOI.SBQQ__Contract__r?.Status;
        if (col.Contract_Status__c != newStatus) {
            col.Contract_Status__c = newStatus; changed = true;
        }

        if (oldOI.EndDate != newOI.EndDate) {
            col.End_Date__c = newOI.EndDate; changed = true;
        }

        // ✅ OrderItemNumber fix
        if (col.OrderItemNumber__c != newOI.OrderItemNumber) {
            col.OrderItemNumber__c = newOI.OrderItemNumber; changed = true;
        }

        String newProd = newOI.Product2?.Name;
        if (col.Product_Name__c != newProd) {
            col.Product_Name__c = newProd; changed = true;
        }

        if (oldOI.Quantity != newOI.Quantity) {
            col.Quantity__c = newOI.Quantity; changed = true;
        }

        if (oldOI.ServiceDate != newOI.ServiceDate) {
            col.Service_Date__c = newOI.ServiceDate; changed = true;
        }

        if (oldOI.SBQQ__DefaultSubscriptionTerm__c != newOI.SBQQ__DefaultSubscriptionTerm__c) {
            col.Subscription_Term_Months__c = newOI.SBQQ__DefaultSubscriptionTerm__c;
            changed = true;
        }

        // ✅ TotalPrice fix
        if (col.Total_Price__c != newOI.TotalPrice) {
            col.Total_Price__c = newOI.TotalPrice; changed = true;
        }

        return changed;
    }

    @TestVisible
    private static OrderItem buildPseudoOld(CustomerOrderLine__c col) {
        OrderItem pseudo = new OrderItem();

        pseudo.blng__LastChargeToDate__c        = col.blng_LastChargeToDate__c;
        pseudo.blng__NextBillingDate__c         = col.blng_NextBillingDate__c;
        pseudo.EndDate                          = col.End_Date__c;
        pseudo.Quantity                         = col.Quantity__c;
        pseudo.ServiceDate                      = col.Service_Date__c;
        pseudo.SBQQ__DefaultSubscriptionTerm__c = col.Subscription_Term_Months__c;

        // ❌ Removed read-only assignments

        pseudo.SBQQ__Contract__r = new Contract(
            Status = col.Contract_Status__c
        );

        pseudo.Product2 = new Product2(
            Name = col.Product_Name__c
        );

        return pseudo;
    }

    // (rest unchanged — async + queries remain exactly the same)

}
