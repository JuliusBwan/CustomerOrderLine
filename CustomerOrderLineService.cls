// ─── CustomerOrderLineService ────────────────────────────────────────────────
public class CustomerOrderLineService {
    
    
    /**
     * buildCOL — single source of truth for OrderItem → COL field mapping.
     * Used by both the service (trigger path) and the batch (nightly path).
     * Public so CustomerOrderLineBatch can delegate here instead of duplicating.
     */
    public static CustomerOrderLine__c buildCOL(OrderItem o) {
        CustomerOrderLine__c col = new CustomerOrderLine__c();
        col.Name = CustomerOrderLinesUtils.formatColName(o);
        col.OrderItem__c = o.Id;
        col.Account__c = (o.OrderId != null)? o.Order.AccountId: null;
        col.blng_LastChargeToDate__c = o.blng__LastChargeToDate__c;
        col.blng_NextBillingDate__c = o.blng__NextBillingDate__c;
        col.Contract_Status__c = (o.SBQQ__Contract__c != null)? o.SBQQ__Contract__r.Status: null;
        col.End_Date__c = o.EndDate;
        col.Last_Synced_Date__c = System.now();
        col.OrderItemNumber__c = o.OrderItemNumber;
        col.Product_Name__c = (o.Product2 != null) ? o.Product2.Name : null;
        col.Quantity__c = o.Quantity;
        col.Service_Date__c = o.ServiceDate;
        col.Subscription_Term_Months__c = o.SBQQ__DefaultSubscriptionTerm__c;
        col.Total_Price__c = o.TotalPrice;
        return col;
    }

    /**
     * applyChanges — diffs old vs new OrderItem, writes changed values onto the existing COL, and returns true if anything actually changed.
     * Extracting this keeps handleUpdates readable and makes the diff logic independently testable.
     */
    @TestVisible
    private static Boolean applyChanges( CustomerOrderLine__c col, OrderItem oldOI, OrderItem newOI ) {
        Boolean changed = false;

        if (oldOI.blng__LastChargeToDate__c != newOI.blng__LastChargeToDate__c) {
            col.blng_LastChargeToDate__c = newOI.blng__LastChargeToDate__c; changed = true; }
        
        if (oldOI.blng__NextBillingDate__c != newOI.blng__NextBillingDate__c) {
            col.blng_NextBillingDate__c = newOI.blng__NextBillingDate__c; changed = true; }

        String oldStatus = oldOI.SBQQ__Contract__c != null ? oldOI.SBQQ__Contract__r.Status : null;
        String newStatus = newOI.SBQQ__Contract__c != null ? newOI.SBQQ__Contract__r.Status : null;
        if (oldStatus != newStatus) { col.Contract_Status__c = newStatus; changed = true; }

        if (oldOI.EndDate != newOI.EndDate) { col.End_Date__c = newOI.EndDate; changed = true; }
        
        if (oldOI.OrderItemNumber != newOI.OrderItemNumber) { col.OrderItemNumber__c = newOI.OrderItemNumber; changed = true; }

        String oldProd = oldOI.Product2 != null ? oldOI.Product2.Name : null;
        String newProd = newOI.Product2 != null ? newOI.Product2.Name : null;
        if (oldProd != newProd) { col.Product_Name__c = newProd; changed = true; }

        if (oldOI.Quantity != newOI.Quantity) { col.Quantity__c = newOI.Quantity; changed = true; }
        
        if (oldOI.ServiceDate != newOI.ServiceDate) { col.Service_Date__c = newOI.ServiceDate; changed = true; }
        
        if (oldOI.SBQQ__DefaultSubscriptionTerm__c != newOI.SBQQ__DefaultSubscriptionTerm__c) {
            col.Subscription_Term_Months__c = newOI.SBQQ__DefaultSubscriptionTerm__c; changed = true; }
        
        if (oldOI.TotalPrice != newOI.TotalPrice) { col.Total_Price__c = newOI.TotalPrice; changed = true; }

        return changed;
    }
    
    // ── AFTER INSERT ─────────────────────────────────────────────────────────
    public static void handleCreates(Map<Id, OrderItem> newOItemsMap) { 
        Map<Id, CustomerOrderLine__c> existingByOI = CustomerOrderLineRepository.getByOrderItemIds(newOItemsMap.keySet());
        
        List<CustomerOrderLine__c> toInsert = new List<CustomerOrderLine__c>();

        for (OrderItem o : newOItemsMap.values()) {
            if (!existingByOI.containsKey(o.Id)) {
                toInsert.add(buildCOL(o));
            }
        }
        
        if (toInsert.isEmpty()) { return; }

        Database.SaveResult[] results = Database.insert(toInsert, false);
        NotificationService.handleResults('Customer Order Lines - Create Summary', toInsert.size(), results);
    }

  
    // ── AFTER UPDATE ─────────────────────────────────────────────────────────    
    public static void handleUpdates(Map<Id, OrderItem> newOItemsMap, List<OrderItem> newOItems, List<OrderItem> oldOItems) {
        
        Map<Id, CustomerOrderLine__c> existingByOI = CustomerOrderLineRepository.getByOrderItemIds(newOItemsMap.keySet());
        
        List<CustomerOrderLine__c> toUpdate = new List<CustomerOrderLine__c>();

    for (Integer i = 0; i < newOItems.size(); i++) {
            OrderItem newOI = newOItems[i];
            OrderItem oldOI = oldOItems[i];

            if (!existingByOI.containsKey(newOI.Id)) { continue; }

            CustomerOrderLine__c col = existingByOI.get(newOI.Id);
            Boolean changed = applyChanges(col, oldOI, newOI);

            if (changed) { col.Last_Synced_Date__c = System.now(); toUpdate.add(col); }
        }
        
         if (toUpdate.isEmpty()) { return; }
        
        Database.SaveResult[] results = Database.update(toUpdate, false);
        NotificationService.handleResults('Customer Order Lines - Update Summary', toUpdate.size(), results);
    }
  
    
    // ── AFTER DELETE ─────────────────────────────────────────────────────────
    public static void handleUpdateToDeleted( OrderItem[] deletedOIList ) {
        Set<Id> idSet = new Set<Id>();
        for (OrderItem oi : deletedOIList) { idSet.add(oi.Id); }
        
        List<CustomerOrderLine__c> toUpdate = new List<CustomerOrderLine__c>();
        
        for (CustomerOrderLine__c col : [SELECT Id, Name FROM CustomerOrderLine__c WHERE OrderItem__c IN :idSet]) {
            col.Name = CustomerOrderLinesUtils.prependDeletedTag(col.Name);
            toUpdate.add(col);
        }

    if (toUpdate.isEmpty()) { return; }
        
        Database.SaveResult[] results = Database.update(toUpdate, false);
        NotificationService.handleResults('Customer Order Lines - Delete Summary', toUpdate.size(), results);
    }
}
