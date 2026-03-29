// ─── CustomerOrderLineHandler ────────────────────────────────────────────────
/**
 * Handler class called by the OrderItem trigger.
 *
 * Responsibilities:
 *  - Route each trigger operation to the correct service method.
 *  - Insert / Update fire asynchronously (@future) so the original save is not blocked.
 *  - Delete stays synchronous because OrderItem Ids are gone after commit.
 *
 * Design note — why pass Maps/Lists from here, not from the trigger?
 *  Keeping all Trigger.* references inside the handler (not scattered across
 *  service classes) makes the service independently testable without a real trigger context.
 */
public class CustomerOrderLineHandler {

    public static void run(
        Map<Id, OrderItem> newOIMap,
        Map<Id, OrderItem> oldOIMap,
        List<OrderItem>    oldOIList
    ) {
        switch on Trigger.operationType {

            when AFTER_INSERT {
                // Pass only the Id set — the @future method re-queries what it needs
                CustomerOrderLineService.handleCreates(newOIMap.keySet());
            }

            when AFTER_UPDATE {
                // Pass new and old maps; service extracts Ids and goes async
                CustomerOrderLineService.handleUpdates(newOIMap, oldOIMap);
            }

            when AFTER_DELETE {
                // Must be synchronous — Ids become unqueryable after commit
                CustomerOrderLineService.handleUpdateToDeleted(oldOIList);
            }

            when else {
                System.debug('CustomerOrderLineHandler: unhandled operation — ' + Trigger.operationType);
            }
        }
    }
}
