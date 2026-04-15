1
2
3
4
// ─── CustomerOrderLinesTrigger ───────────────────────────────────────────────
trigger OrderItemAfterTrigger on OrderItem (after insert, after update, after delete) {
    CustomerOrderLineHandler.run(Trigger.newMap, Trigger.oldMap, Trigger.OLD);
}
