// ─── CustomerOrderLineServiceTest ────────────────────────────────────────────
/**
 * Full test coverage for CustomerOrderLineService.
 *
 * This single test class replaces:
 *  - CustomerOrderLineHandlerTest    (integration tests via real DML)
 *  - CustomerOrderLineServiceTest    (unit tests on helpers)
 *  - CustomerOrderLineRepositoryTest (query tests)
 *
 * STRUCTURE
 * ─────────
 *  Section 1 — buildCOL           : field mapping
 *  Section 2 — applyChanges       : diff logic, one test per field group
 *  Section 3 — buildPseudoOld     : round-trip reconstruction
 *  Section 4 — Queries            : getColsByOrderItemIds, getOrphanedCols, queryOrderItems
 *  Section 5 — Integration        : real DML → trigger → assert COL state
 *  Section 6 — Edge cases         : run() else branch, empty-result paths
 *
 * NOTES
 * ─────
 *  @testSetup inserts an Account → Order → OrderItem via CPQ_TestDataFactory.
 *  The trigger fires on the OrderItem insert but the @future does NOT execute
 *  during @testSetup, so no COL exists when test methods begin. Tests that
 *  need a COL create one explicitly.
 *
 *  Integration tests create FRESH data inside each method so they can control
 *  @future execution with Test.startTest() / Test.stopTest().
 */
@isTest
private class CustomerOrderLineServiceTest {

    // ── SHARED TEST DATA ─────────────────────────────────────────────────

    @testSetup
    static void setupData() {
        CPQ_TestDataFactory.createOrderWithItem();
    }

    /** Re-query the OrderItem with all fields the service needs. */
    private static OrderItem getTestOI() {
        return [
            SELECT Id, OrderItemNumber, Product2.Name,
                   Order.AccountId, SBQQ__Contract__c,
                   SBQQ__Contract__r.ContractNumber, SBQQ__Contract__r.Status,
                   Quantity, TotalPrice, ServiceDate, EndDate,
                   blng__LastChargeToDate__c, blng__NextBillingDate__c,
                   SBQQ__DefaultSubscriptionTerm__c
            FROM   OrderItem
            LIMIT  1
        ];
    }

    // =====================================================================
    //  SECTION 1 — buildCOL
    // =====================================================================

    @isTest
    static void buildCOL_mapsFieldsCorrectly() {
        OrderItem oi = getTestOI();

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);

        System.assertEquals(oi.Id,         col.OrderItem__c,       'OrderItem__c');
        System.assertEquals(oi.Quantity,   col.Quantity__c,        'Quantity');
        System.assertEquals(oi.TotalPrice, col.Total_Price__c,     'TotalPrice');
        System.assertEquals(oi.EndDate,    col.End_Date__c,        'EndDate');
        System.assertEquals(oi.ServiceDate,col.Service_Date__c,    'ServiceDate');
        System.assertNotEquals(null, col.Last_Synced_Date__c,      'Last_Synced_Date__c must be set');
        System.assert(col.Name.startsWith('COL-'),                 'Name prefix');
        // No contract linked in test data — both should be null
        System.assertEquals(null, col.Contract_Number__c,          'Contract_Number__c null');
        System.assertEquals(null, col.Contract_Status__c,          'Contract_Status__c null');
    }

    // =====================================================================
    //  SECTION 2 — applyChanges
    // =====================================================================

    @isTest
    static void applyChanges_noChange_returnsFalse() {
        OrderItem oi = getTestOI();
        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);

        Boolean changed = CustomerOrderLineService.applyChanges(col, oi, oi);

        System.assertEquals(false, changed, 'Identical OIs should produce no change');
    }

    @isTest
    static void applyChanges_quantityChanged_returnsTrue() {
        OrderItem oldOI = getTestOI();
        OrderItem newOI = getTestOI();
        newOI.Quantity = oldOI.Quantity + 5;

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oldOI);
        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true,           changed,         'Should flag changed');
        System.assertEquals(newOI.Quantity,  col.Quantity__c, 'Quantity should update');
    }

    @isTest
    static void applyChanges_endDateChanged_returnsTrue() {
        OrderItem oldOI = getTestOI();
        OrderItem newOI = getTestOI();
        newOI.EndDate = oldOI.EndDate.addMonths(6);

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oldOI);
        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true,          changed,         'Should flag changed');
        System.assertEquals(newOI.EndDate, col.End_Date__c, 'EndDate should update');
    }

    @isTest
    static void applyChanges_contractNumberChanged_returnsTrue() {
        OrderItem oldOI = new OrderItem();
        oldOI.SBQQ__Contract__r = new Contract(ContractNumber = '00000100', Status = 'Activated');

        OrderItem newOI = new OrderItem();
        newOI.SBQQ__Contract__r = new Contract(ContractNumber = '00000200', Status = 'Activated');

        CustomerOrderLine__c col = new CustomerOrderLine__c(
            Contract_Number__c = '00000100',
            Contract_Status__c = 'Activated'
        );

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true,        changed,                'Should flag changed');
        System.assertEquals('00000200',  col.Contract_Number__c, 'Contract number should update');
        System.assertEquals('Activated', col.Contract_Status__c, 'Unchanged status should remain');
    }

    @isTest
    static void applyChanges_contractNumberAndStatusBothChanged_returnsTrue() {
        OrderItem oldOI = new OrderItem();
        oldOI.SBQQ__Contract__r = new Contract(ContractNumber = '00000100', Status = 'Draft');

        OrderItem newOI = new OrderItem();
        newOI.SBQQ__Contract__r = new Contract(ContractNumber = '00000200', Status = 'Activated');

        CustomerOrderLine__c col = new CustomerOrderLine__c(
            Contract_Number__c = '00000100',
            Contract_Status__c = 'Draft'
        );

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true,        changed,                'Should flag changed');
        System.assertEquals('00000200',  col.Contract_Number__c, 'Number should update');
        System.assertEquals('Activated', col.Contract_Status__c, 'Status should update');
    }

    @isTest
    static void applyChanges_contractNumberNullToPopulated_returnsTrue() {
        OrderItem oldOI = new OrderItem();
        oldOI.SBQQ__Contract__r = new Contract();

        OrderItem newOI = new OrderItem();
        newOI.SBQQ__Contract__r = new Contract(ContractNumber = '00000300', Status = 'Activated');

        CustomerOrderLine__c col = new CustomerOrderLine__c();

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true,       changed,                'Null-to-populated should flag changed');
        System.assertEquals('00000300', col.Contract_Number__c, 'Contract number should be set');
    }

    /**
     * Changes every remaining field that the individual tests above don't
     * cover. This ensures 100% line coverage of every if-block inside
     * applyChanges().
     */
    @isTest
    static void applyChanges_allRemainingFieldsChanged_returnsTrue() {
        OrderItem oldOI = new OrderItem(
            blng__LastChargeToDate__c        = Date.today(),
            blng__NextBillingDate__c         = Date.today(),
            OrderItemNumber                  = 'OLD-001',
            ServiceDate                      = Date.today(),
            SBQQ__DefaultSubscriptionTerm__c = 12,
            TotalPrice                       = 100
        );
        oldOI.Product2 = new Product2(Name = 'Old Product');

        OrderItem newOI = new OrderItem(
            blng__LastChargeToDate__c        = Date.today().addDays(30),
            blng__NextBillingDate__c         = Date.today().addDays(30),
            OrderItemNumber                  = 'NEW-002',
            ServiceDate                      = Date.today().addDays(30),
            SBQQ__DefaultSubscriptionTerm__c = 24,
            TotalPrice                       = 200
        );
        newOI.Product2 = new Product2(Name = 'New Product');

        CustomerOrderLine__c col = new CustomerOrderLine__c(
            blng_LastChargeToDate__c    = Date.today(),
            blng_NextBillingDate__c     = Date.today(),
            OrderItemNumber__c          = 'OLD-001',
            Product_Name__c             = 'Old Product',
            Service_Date__c             = Date.today(),
            Subscription_Term_Months__c = 12,
            Total_Price__c              = 100
        );

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true, changed, 'All changes should flag true');
        System.assertEquals(Date.today().addDays(30), col.blng_LastChargeToDate__c,    'LastChargeToDate');
        System.assertEquals(Date.today().addDays(30), col.blng_NextBillingDate__c,     'NextBillingDate');
        System.assertEquals('NEW-002',                col.OrderItemNumber__c,          'OrderItemNumber');
        System.assertEquals('New Product',            col.Product_Name__c,             'Product Name');
        System.assertEquals(Date.today().addDays(30), col.Service_Date__c,             'ServiceDate');
        System.assertEquals(24,                       col.Subscription_Term_Months__c, 'SubscriptionTerm');
        System.assertEquals(200,                      col.Total_Price__c,              'TotalPrice');
    }

    // =====================================================================
    //  SECTION 3 — buildPseudoOld
    // =====================================================================

    @isTest
    static void buildPseudoOld_reconstructsFieldsFromCOL() {
        OrderItem oi = getTestOI();
        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);
        col.Contract_Number__c = '00000999';
        col.Contract_Status__c = 'Activated';

        OrderItem pseudo = CustomerOrderLineService.buildPseudoOld(col);

        System.assertEquals(col.Quantity__c,                  pseudo.Quantity,         'Quantity');
        System.assertEquals(col.End_Date__c,                  pseudo.EndDate,          'EndDate');
        System.assertEquals(col.Total_Price__c,               pseudo.TotalPrice,       'TotalPrice');
        System.assertEquals(col.Service_Date__c,              pseudo.ServiceDate,      'ServiceDate');
        System.assertEquals(col.OrderItemNumber__c,           pseudo.OrderItemNumber,  'OrderItemNumber');
        System.assertEquals(col.Subscription_Term_Months__c,  pseudo.SBQQ__DefaultSubscriptionTerm__c, 'SubTerm');
        System.assertEquals(col.blng_LastChargeToDate__c,     pseudo.blng__LastChargeToDate__c,        'LastCharge');
        System.assertEquals(col.blng_NextBillingDate__c,      pseudo.blng__NextBillingDate__c,         'NextBilling');
        System.assertEquals('00000999',  pseudo.SBQQ__Contract__r.ContractNumber, 'ContractNumber');
        System.assertEquals('Activated', pseudo.SBQQ__Contract__r.Status,         'Contract Status');
    }

    @isTest
    static void buildPseudoOld_nullContractFields_reconstructsAsNull() {
        CustomerOrderLine__c col = new CustomerOrderLine__c(
            Contract_Number__c = null,
            Contract_Status__c = null
        );

        OrderItem pseudo = CustomerOrderLineService.buildPseudoOld(col);

        System.assertEquals(null, pseudo.SBQQ__Contract__r.ContractNumber, 'Null number stays null');
        System.assertEquals(null, pseudo.SBQQ__Contract__r.Status,         'Null status stays null');
    }

    // =====================================================================
    //  SECTION 4 — Queries
    // =====================================================================

    // ── queryOrderItems ──────────────────────────────────────────────────

    @isTest
    static void queryOrderItems_returnsResults() {
        OrderItem oi = getTestOI();

        List<OrderItem> result = CustomerOrderLineService.queryOrderItems(
            new Set<Id>{ oi.Id }
        );

        System.assertEquals(1, result.size(), 'Should find the test OrderItem');
        System.assertEquals(oi.Id, result[0].Id);
    }

    @isTest
    static void queryOrderItems_emptySet_returnsEmpty() {
        List<OrderItem> result = CustomerOrderLineService.queryOrderItems(new Set<Id>());
        System.assertEquals(0, result.size(), 'Empty set should return empty list');
    }

    // ── getColsByOrderItemIds ────────────────────────────────────────────

    @isTest
    static void getColsByOrderItemIds_returnsCorrectMap() {
        OrderItem oi = getTestOI();
        CPQ_TestDataFactory.createCOL(oi, 'COL-TEST');

        Map<Id, CustomerOrderLine__c> result =
            CustomerOrderLineService.getColsByOrderItemIds(new Set<Id>{ oi.Id });

        System.assertEquals(1, result.size(),    'Should find one COL');
        System.assert(result.containsKey(oi.Id), 'Key should be the OrderItem Id');
    }

    @isTest
    static void getColsByOrderItemIds_nullSet_returnsEmptyMap() {
        Map<Id, CustomerOrderLine__c> result =
            CustomerOrderLineService.getColsByOrderItemIds(null);
        System.assertEquals(0, result.size(), 'Null should return empty map');
    }

    @isTest
    static void getColsByOrderItemIds_emptySet_returnsEmptyMap() {
        Map<Id, CustomerOrderLine__c> result =
            CustomerOrderLineService.getColsByOrderItemIds(new Set<Id>());
        System.assertEquals(0, result.size(), 'Empty set should return empty map');
    }

    @isTest
    static void getColsByOrderItemIds_nullIdsInSet_cleaned() {
        OrderItem oi = getTestOI();
        CPQ_TestDataFactory.createCOL(oi, 'COL-TEST');

        Set<Id> mixed = new Set<Id>{ oi.Id, null };

        Map<Id, CustomerOrderLine__c> result =
            CustomerOrderLineService.getColsByOrderItemIds(mixed);

        System.assertEquals(1, result.size(), 'Null Id should be silently removed');
    }

    // ── getOrphanedCols ──────────────────────────────────────────────────

    @isTest
    static void getOrphanedCols_returnsUntaggedOrphans() {
        CustomerOrderLine__c orphan = CPQ_TestDataFactory.createOrphanCOL('COL-ORPHAN');

        List<CustomerOrderLine__c> result = CustomerOrderLineService.getOrphanedCols();

        Boolean found = false;
        for (CustomerOrderLine__c c : result) {
            if (c.Id == orphan.Id) { found = true; break; }
        }
        System.assert(found, 'Untagged orphan should be returned');
    }

    @isTest
    static void getOrphanedCols_excludesTaggedOrphans() {
        CustomerOrderLine__c tagged = CPQ_TestDataFactory.createOrphanCOL('[DEL] COL-OLD');

        List<CustomerOrderLine__c> result = CustomerOrderLineService.getOrphanedCols();

        Boolean found = false;
        for (CustomerOrderLine__c c : result) {
            if (c.Id == tagged.Id) { found = true; break; }
        }
        System.assert(!found, 'Tagged orphan should be excluded');
    }

    // =====================================================================
    //  SECTION 5 — Integration (real DML → trigger → assert COL)
    // =====================================================================

    @isTest
    static void integration_afterInsert_createsCOL() {
        CPQ_TestDataFactory.OrderBundle b = CPQ_TestDataFactory.createOrderWithItem();

        Test.startTest();
        Test.stopTest(); // @future executes — COL is created

        List<CustomerOrderLine__c> cols = [
            SELECT Id, Name FROM CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id
        ];

        Assert.areEqual(1, cols.size(), 'One COL should be created');
        Assert.isTrue(cols[0].Name.startsWith('COL-'), 'Name should have COL- prefix');
    }

    @isTest
    static void integration_afterInsert_idempotent_noDuplicate() {
        CPQ_TestDataFactory.OrderBundle b = CPQ_TestDataFactory.createOrderWithItem();

        // Pre-create a COL before the @future runs
        CPQ_TestDataFactory.createCOL(b.orderItem);

        Test.startTest();
        Test.stopTest();

        Integer count = [
            SELECT COUNT() FROM CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id
        ];
        Assert.areEqual(1, count, 'Should not create a duplicate');
    }

    @isTest
    static void integration_afterUpdate_updatesQuantity() {
        CPQ_TestDataFactory.OrderBundle b = CPQ_TestDataFactory.createOrderWithItem();

        // Let the insert @future complete so the COL exists
        Test.startTest();
        Test.stopTest();

        // Update the OrderItem — fires AFTER_UPDATE
        Test.startTest();
        b.orderItem.Quantity = 99;
        update b.orderItem;
        Test.stopTest(); // update @future executes

        CustomerOrderLine__c col = [
            SELECT Quantity__c FROM CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id LIMIT 1
        ];
        Assert.areEqual(99, col.Quantity__c, 'COL should reflect updated quantity');
    }

    @isTest
    static void integration_afterUpdate_noChange_lastSyncedDateUnchanged() {
        CPQ_TestDataFactory.OrderBundle b = CPQ_TestDataFactory.createOrderWithItem();

        Test.startTest();
        Test.stopTest(); // COL exists

        DateTime syncedAfterInsert = [
            SELECT Last_Synced_Date__c FROM CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id LIMIT 1
        ].Last_Synced_Date__c;

        // Re-save with identical values
        Test.startTest();
        update b.orderItem;
        Test.stopTest();

        DateTime syncedAfterUpdate = [
            SELECT Last_Synced_Date__c FROM CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id LIMIT 1
        ].Last_Synced_Date__c;

        Assert.areEqual(syncedAfterInsert, syncedAfterUpdate,
            'Last_Synced_Date__c should not change when no values changed');
    }

    @isTest
    static void integration_afterDelete_tagsCOL() {
        CPQ_TestDataFactory.OrderBundle b = CPQ_TestDataFactory.createOrderWithItem();

        Test.startTest();
        Test.stopTest(); // COL exists

        Id oiId  = b.orderItem.Id;
        Id colId = [SELECT Id FROM CustomerOrderLine__c WHERE OrderItem__c = :oiId LIMIT 1].Id;

        // Delete fires synchronous AFTER_DELETE path
        Test.startTest();
        delete b.orderItem;
        Test.stopTest();

        CustomerOrderLine__c tagged = [
            SELECT Name, Last_Synced_Date__c FROM CustomerOrderLine__c WHERE Id = :colId
        ];

        Assert.isTrue(tagged.Name.startsWith('[DEL]'), 'Should be tagged [DEL]');
        Assert.isNotNull(tagged.Last_Synced_Date__c,   'Last_Synced_Date__c should be stamped');
    }

    @isTest
    static void integration_afterDelete_alreadyTagged_noDoubleTag() {
        CPQ_TestDataFactory.OrderBundle b = CPQ_TestDataFactory.createOrderWithItem();

        Test.startTest();
        Test.stopTest(); // COL exists

        // Manually pre-tag the COL
        CustomerOrderLine__c col = [
            SELECT Id, Name FROM CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id LIMIT 1
        ];
        col.Name = '[DEL] ' + col.Name;
        update col;

        Test.startTest();
        delete b.orderItem;
        Test.stopTest();

        CustomerOrderLine__c checked = [SELECT Name FROM CustomerOrderLine__c WHERE Id = :col.Id];
        Assert.isFalse(checked.Name.startsWith('[DEL] [DEL]'),
            'Already-tagged COL should not receive a second [DEL]');
    }

    // =====================================================================
    //  SECTION 6 — Edge cases
    // =====================================================================

    @isTest
    static void run_unhandledOperation_doesNotThrow() {
        // BEFORE_INSERT is a valid enum value but not handled by the switch.
        // Calling run() directly with it should hit the else branch safely.
        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.BEFORE_INSERT,
            new Map<Id, OrderItem>(), null, null
        );
        Test.stopTest();

        System.assert(true, 'Unhandled operation should not throw');
    }

    @isTest
    static void handleDeletedOrderItems_noCOLsFound_noException() {
        // Call the service with a valid OrderItem that has no COL.
        // The method should exit early with no DML and no exception.
        OrderItem oi = getTestOI();

        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_DELETE,
            null, null, new List<OrderItem>{ oi }
        );
        Test.stopTest();

        System.assert(true, 'Empty COL result should not throw');
    }

    @isTest
    static void createCOLsAsync_allExisting_skipsInsert() {
        // Pre-create a COL for the OrderItem, then trigger the insert path.
        // The idempotency check should skip the insert entirely.
        OrderItem oi = getTestOI();
        insert CustomerOrderLineService.buildCOL(oi);

        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_INSERT,
            new Map<Id, OrderItem>{ oi.Id => oi }, null, null
        );
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM CustomerOrderLine__c WHERE OrderItem__c = :oi.Id];
        System.assertEquals(1, count, 'Should not create a duplicate');
    }

    @isTest
    static void updateCOLsAsync_noCOL_skipsUpdate() {
        // Trigger the update path for an OrderItem that has no COL.
        // The method should skip it via the continue statement.
        OrderItem oi = getTestOI();

        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_UPDATE,
            new Map<Id, OrderItem>{ oi.Id => oi },
            new Map<Id, OrderItem>{ oi.Id => oi },
            null
        );
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM CustomerOrderLine__c WHERE OrderItem__c = :oi.Id];
        System.assertEquals(0, count, 'No COL should be created or updated');
    }

    @isTest
    static void updateCOLsAsync_noChanges_doesNotUpdate() {
        // Create a COL that already matches the OrderItem values.
        // applyChanges() should return false and nothing should be updated.
        OrderItem oi = getTestOI();
        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);
        insert col;

        DateTime syncedBefore = [
            SELECT Last_Synced_Date__c FROM CustomerOrderLine__c WHERE Id = :col.Id
        ].Last_Synced_Date__c;

        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_UPDATE,
            new Map<Id, OrderItem>{ oi.Id => oi },
            new Map<Id, OrderItem>{ oi.Id => oi },
            null
        );
        Test.stopTest();

        DateTime syncedAfter = [
            SELECT Last_Synced_Date__c FROM CustomerOrderLine__c WHERE Id = :col.Id
        ].Last_Synced_Date__c;

        System.assertEquals(syncedBefore, syncedAfter,
            'Last_Synced_Date__c should not change when values are identical');
    }
}
