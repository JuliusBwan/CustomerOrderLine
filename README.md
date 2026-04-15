// ─── OrderItemAfterTrigger ────────────────────────────────────────────────────
// One-liner: routes to the service which handles everything internally.
trigger OrderItemAfterTrigger on OrderItem (after insert, after update, after delete) {
    CustomerOrderLineService.run(Trigger.operationType, Trigger.newMap, Trigger.oldMap, Trigger.old);
}
