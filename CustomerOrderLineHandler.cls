// ─── CustomerOrderLineHandler ────────────────────────────────────────────────
public class CustomerOrderLineHandler {
    
    public static void run(
        Map<Id, OrderItem> newOIMap, 
        List<OrderItem> newOIList, 
        List<OrderItem> oldOIList){
            
        switch on Trigger.OperationType {
            when AFTER_INSERT { CustomerOrderLineService.handleCreates(newOIMap); }  
            when AFTER_UPDATE { CustomerOrderLineService.handleUpdates(newOIMap, newOIList, oldOIList); }
            when AFTER_DELETE {  CustomerOrderLineService.handleUpdateToDeleted(oldOIList); }
            when else { System.debug('CustomerOrderLineHandler: unhandled operation'); }
        } 
        System.debug('CustomerOrderLine Trigger has run!');
    }
}
