// ─── CustomerOrderLineHandlerTest ────────────────────────────────────────────
/**
 * Tests for CustomerOrderLineHandler.
 *
 * IMPORTANT — why we can't call CustomerOrderLineHandler.run() directly:
 * -----------------------------------------------------------------------
 * run() reads Trigger.operationType, which is only populated inside a real
 * trigger context. Calling run() from a test class outside of a trigger would
 * throw a NullPointerException on that line.
 *
 * The correct approach: perform real DML on OrderItem (insert / update / delete)
 * and let the trigger fire naturally. We then assert on the COL records that
 * result from that DML.
 *
 * Async note:
 * -----------
 * AFTER_INSERT and AFTER_UPDATE dispatch to @future methods inside the service.
 * @future methods only execute after Test.stopTest(), so all COL assertions for
 * those paths are placed after that call.
 *
 * AFTER_DELETE is synchronous — assertions can be made immediately after
 * Test.stopTest() as well, but for consistency they follow the same pattern.
 */
@isTest
private class CustomerOrderLineHandlerTest {

    // ── AFTER INSERT — trigger creates a COL ─────────────────────────────────

    @isTest
    static void afterInsert_createsOneCOLPerOrderItem() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        // The insert already happened inside the factory (trigger has fired).
        // Drive the @future to completion.
        Test.startTest();
        Test.stopTest();

        List<CustomerOrderLine__c> cols = [
            SELECT Id, OrderItem__c, Name
            FROM   CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id
        ];

        Assert.areEqual(1, cols.size(),
            'Exactly one COL should be created after an OrderItem insert');
        Assert.isTrue(cols[0].Name.startsWith('COL-'),
            'COL Name should be formatted with COL- prefix');
    }

    @isTest
    static void afterInsert_idempotent_doesNotCreateDuplicateCOL() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        // Manually insert a COL before the future runs — simulates a race condition
        // or a record already created by an earlier batch run
        CPQ_TestDataFactory.createCOL(b.orderItem);

        Test.startTest();
        Test.stopTest();

        Integer count = [
            SELECT COUNT()
            FROM   CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id
        ];

        Assert.areEqual(1, count,
            'A second COL should NOT be created when one already exists');
    }

    // ── AFTER UPDATE — trigger updates the existing COL ──────────────────────

    @isTest
    static void afterUpdate_updatesQuantityOnCOL() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        // Let the insert future settle so the COL exists before we update
        Test.startTest();
        Test.stopTest();

        // Now update the OrderItem quantity — fires the AFTER_UPDATE trigger path
        Test.startTest();
        b.orderItem.Quantity = 99;
        update b.orderItem;
        Test.stopTest(); // flush the update @future

        CustomerOrderLine__c col = [
            SELECT Quantity__c
            FROM   CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id
            LIMIT  1
        ];

        Assert.areEqual(99, col.Quantity__c,
            'COL Quantity__c should reflect the updated OrderItem Quantity');
    }

    @isTest
    static void afterUpdate_noChange_doesNotAlterLastSyncedDate() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        Test.startTest();
        Test.stopTest(); // settle insert future — COL now exists

        // Read the timestamp written by the insert
        DateTime syncedAfterInsert = [
            SELECT Last_Synced_Date__c
            FROM   CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id
            LIMIT  1
        ].Last_Synced_Date__c;

        // Update with identical values — applyChanges() should return false
        Test.startTest();
        update b.orderItem; // no field actually changed
        Test.stopTest();

        DateTime syncedAfterUpdate = [
            SELECT Last_Synced_Date__c
            FROM   CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id
            LIMIT  1
        ].Last_Synced_Date__c;

        Assert.areEqual(syncedAfterInsert, syncedAfterUpdate,
            'Last_Synced_Date__c should not change when no field values changed');
    }

    // ── AFTER DELETE — trigger tags COL as [DEL] ─────────────────────────────

    @isTest
    static void afterDelete_tagsCOLWithDelPrefix() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        // Ensure the COL exists before we delete the OrderItem
        Test.startTest();
        Test.stopTest();

        Id oiId  = b.orderItem.Id;
        Id colId = [SELECT Id FROM CustomerOrderLine__c WHERE OrderItem__c = :oiId LIMIT 1].Id;

        // Delete fires the synchronous AFTER_DELETE path
        Test.startTest();
        delete b.orderItem;
        Test.stopTest();

        CustomerOrderLine__c tagged = [
            SELECT Name, Last_Synced_Date__c
            FROM   CustomerOrderLine__c
            WHERE  Id = :colId
        ];

        Assert.isTrue(tagged.Name.startsWith('[DEL]'),
            'COL Name should be prefixed with [DEL] after the OrderItem is deleted');
        Assert.isNotNull(tagged.Last_Synced_Date__c,
            'Last_Synced_Date__c should be stamped when the delete is processed');
    }

    @isTest
    static void afterDelete_alreadyTaggedCOL_noDoubleTag() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        Test.startTest();
        Test.stopTest(); // settle insert

        // Manually pre-tag the COL to simulate it being tagged already
        CustomerOrderLine__c col = [
            SELECT Id, Name FROM CustomerOrderLine__c WHERE OrderItem__c = :b.orderItem.Id LIMIT 1
        ];
        col.Name = '[DEL] ' + col.Name;
        update col;

        Test.startTest();
        delete b.orderItem;
        Test.stopTest();

        CustomerOrderLine__c checked = [
            SELECT Name FROM CustomerOrderLine__c WHERE Id = :col.Id
        ];

        Assert.isFalse(checked.Name.startsWith('[DEL] [DEL]'),
            'An already-tagged COL should not receive a second [DEL] prefix');
    }
}
