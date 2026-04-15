// ─── CustomerOrderLineServiceTest ────────────────────────────────────────────
/**
 * Full test coverage for CustomerOrderLineService.
 *
 *  Section 1 — buildCOL           : field mapping
 *  Section 2 — applyChanges       : diff logic per field group
 *  Section 3 — buildPseudoOld     : round-trip reconstruction
 *  Section 4 — Queries            : getColsByOrderItemIds, getOrphanedCols
 *  Section 5 — Integration        : real DML → trigger → assert COL state
 *  Section 6 — Edge cases         : run() else branch, empty-result paths
 *
 * IMPORTANT — @testSetup creates a COL
 * ─────────────────────────────────────
 * The @testSetup calls createOrderWithItem() which inserts an OrderItem.
 * That fires the trigger, which enqueues createCOLsAsync(). Salesforce
 * executes @future methods during @testSetup, so by the time any test
 * method runs, the @testSetup OrderItem ALREADY HAS a COL.
 *
 * Tests that need "no COL" must delete it first. Tests that need "exactly
 * one COL" must not insert a second one manually.
 */
@IsTest
private class CustomerOrderLineServiceTest {

    // ── SHARED TEST DATA ─────────────────────────────────────────────────

    @testSetup
    static void setupData() {
        CPQ_TestDataFactory.createOrderWithItem();
    }

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

    /**
     * Builds an in-memory OrderItem with any fields — including read-only
     * ones like TotalPrice and OrderItemNumber.
     */
    private static OrderItem buildInMemoryOI(Map<String, Object> fields) {
        return (OrderItem) JSON.deserialize(JSON.serialize(fields), OrderItem.class);
    }

    // =====================================================================
    //  SECTION 1 — buildCOL
    // =====================================================================

    @IsTest
    static void buildCOL_mapsFieldsCorrectly() {
        OrderItem oi = getTestOI();

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);

        System.assertEquals(oi.Id,          col.OrderItem__c,    'OrderItem__c');
        System.assertEquals(oi.Quantity,    col.Quantity__c,     'Quantity');
        System.assertEquals(oi.TotalPrice,  col.Total_Price__c,  'TotalPrice');
        System.assertEquals(oi.EndDate,     col.End_Date__c,     'EndDate');
        System.assertEquals(oi.ServiceDate, col.Service_Date__c, 'ServiceDate');
        System.assertNotEquals(null, col.Last_Synced_Date__c,    'Last_Synced_Date__c must be set');
        System.assert(col.Name.startsWith('COL-'),               'Name prefix');
        System.assertEquals(null, col.Contract_Number__c,        'Contract_Number__c null');
        System.assertEquals(null, col.Contract_Status__c,        'Contract_Status__c null');
    }

    // =====================================================================
    //  SECTION 2 — applyChanges
    // =====================================================================

    @IsTest
    static void applyChanges_noChange_returnsFalse() {
        OrderItem oi = getTestOI();
        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);

        Boolean changed = CustomerOrderLineService.applyChanges(col, oi, oi);

        System.assertEquals(false, changed);
    }

    @IsTest
    static void applyChanges_quantityChanged_returnsTrue() {
        OrderItem oldOI = getTestOI();
        OrderItem newOI = getTestOI();
        newOI.Quantity = oldOI.Quantity + 1;

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oldOI);
        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true, changed);
        System.assertEquals(newOI.Quantity, col.Quantity__c);
    }

    @IsTest
    static void applyChanges_endDateChanged_returnsTrue() {
        OrderItem oldOI = getTestOI();
        OrderItem newOI = getTestOI();
        newOI.EndDate = oldOI.EndDate.addDays(10);

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oldOI);
        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true, changed);
        System.assertEquals(newOI.EndDate, col.End_Date__c);
    }

    @IsTest
    static void applyChanges_contractNumberChanged_returnsTrue() {
        OrderItem oldOI = buildInMemoryOI(new Map<String, Object>{
            'SBQQ__Contract__r' => new Map<String, Object>{
                'ContractNumber' => '00000100', 'Status' => 'Activated'
            }
        });
        OrderItem newOI = buildInMemoryOI(new Map<String, Object>{
            'SBQQ__Contract__r' => new Map<String, Object>{
                'ContractNumber' => '00000200', 'Status' => 'Activated'
            }
        });

        CustomerOrderLine__c col = new CustomerOrderLine__c(
            Contract_Number__c = '00000100',
            Contract_Status__c = 'Activated'
        );

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true,        changed);
        System.assertEquals('00000200',  col.Contract_Number__c);
        System.assertEquals('Activated', col.Contract_Status__c);
    }

    @IsTest
    static void applyChanges_contractStatusChanged_returnsTrue() {
        OrderItem oldOI = buildInMemoryOI(new Map<String, Object>{
            'SBQQ__Contract__r' => new Map<String, Object>{
                'ContractNumber' => '00000100', 'Status' => 'Draft'
            }
        });
        OrderItem newOI = buildInMemoryOI(new Map<String, Object>{
            'SBQQ__Contract__r' => new Map<String, Object>{
                'ContractNumber' => '00000100', 'Status' => 'Activated'
            }
        });

        CustomerOrderLine__c col = new CustomerOrderLine__c(
            Contract_Number__c = '00000100',
            Contract_Status__c = 'Draft'
        );

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true,        changed);
        System.assertEquals('Activated', col.Contract_Status__c);
    }

    /**
     * Covers every remaining if-block inside applyChanges(): blng dates,
     * OrderItemNumber, Product Name, ServiceDate, SubscriptionTerm, TotalPrice.
     * All in-memory — no DML, no validation rules involved.
     */
    @IsTest
    static void applyChanges_allRemainingFieldsChanged_returnsTrue() {
        OrderItem oldOI = buildInMemoryOI(new Map<String, Object>{
            'blng__LastChargeToDate__c'        => Date.today(),
            'blng__NextBillingDate__c'         => Date.today(),
            'OrderItemNumber'                  => 'OLD-001',
            'ServiceDate'                      => Date.today(),
            'SBQQ__DefaultSubscriptionTerm__c' => 12,
            'TotalPrice'                       => 100,
            'Product2' => new Map<String, Object>{ 'Name' => 'Old Product' }
        });

        OrderItem newOI = buildInMemoryOI(new Map<String, Object>{
            'blng__LastChargeToDate__c'        => Date.today().addDays(30),
            'blng__NextBillingDate__c'         => Date.today().addDays(30),
            'OrderItemNumber'                  => 'NEW-002',
            'ServiceDate'                      => Date.today().addDays(30),
            'SBQQ__DefaultSubscriptionTerm__c' => 24,
            'TotalPrice'                       => 200,
            'Product2' => new Map<String, Object>{ 'Name' => 'New Product' }
        });

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

        System.assertEquals(true,                     changed);
        System.assertEquals(Date.today().addDays(30), col.blng_LastChargeToDate__c);
        System.assertEquals(Date.today().addDays(30), col.blng_NextBillingDate__c);
        System.assertEquals('NEW-002',                col.OrderItemNumber__c);
        System.assertEquals('New Product',            col.Product_Name__c);
        System.assertEquals(Date.today().addDays(30), col.Service_Date__c);
        System.assertEquals(24,                       col.Subscription_Term_Months__c);
        System.assertEquals(200,                      col.Total_Price__c);
    }

    // =====================================================================
    //  SECTION 3 — buildPseudoOld
    // =====================================================================

    @IsTest
    static void buildPseudoOld_reconstructsFields() {
        OrderItem oi = getTestOI();
        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);
        col.Contract_Number__c = '00000999';
        col.Contract_Status__c = 'Activated';

        OrderItem pseudo = CustomerOrderLineService.buildPseudoOld(col);

        System.assertEquals(col.Quantity__c,                  pseudo.Quantity);
        System.assertEquals(col.End_Date__c,                  pseudo.EndDate);
        System.assertEquals(col.Total_Price__c,               pseudo.TotalPrice);
        System.assertEquals(col.Service_Date__c,              pseudo.ServiceDate);
        System.assertEquals(col.OrderItemNumber__c,           pseudo.OrderItemNumber);
        System.assertEquals(col.Subscription_Term_Months__c,  pseudo.SBQQ__DefaultSubscriptionTerm__c);
        System.assertEquals(col.blng_LastChargeToDate__c,     pseudo.blng__LastChargeToDate__c);
        System.assertEquals(col.blng_NextBillingDate__c,      pseudo.blng__NextBillingDate__c);
        System.assertEquals('00000999',  pseudo.SBQQ__Contract__r.ContractNumber);
        System.assertEquals('Activated', pseudo.SBQQ__Contract__r.Status);
        System.assertEquals(col.Product_Name__c, pseudo.Product2.Name);
    }

    @IsTest
    static void buildPseudoOld_nullContractFields_reconstructsAsNull() {
        CustomerOrderLine__c col = new CustomerOrderLine__c(
            Contract_Number__c = null,
            Contract_Status__c = null
        );

        OrderItem pseudo = CustomerOrderLineService.buildPseudoOld(col);

        System.assertEquals(null, pseudo.SBQQ__Contract__r.ContractNumber);
        System.assertEquals(null, pseudo.SBQQ__Contract__r.Status);
    }

    // =====================================================================
    //  SECTION 4 — Queries
    // =====================================================================

    @IsTest
    static void getColsByOrderItemIds_returnsMap() {
        OrderItem oi = getTestOI();
        // @testSetup trigger already created a COL for this OI

        Map<Id, CustomerOrderLine__c> result =
            CustomerOrderLineService.getColsByOrderItemIds(new Set<Id>{ oi.Id });

        System.assertEquals(1, result.size());
        System.assert(result.containsKey(oi.Id));
    }

    @IsTest
    static void getColsByOrderItemIds_null_returnsEmpty() {
        System.assertEquals(0,
            CustomerOrderLineService.getColsByOrderItemIds(null).size());
    }

    @IsTest
    static void getColsByOrderItemIds_emptySet_returnsEmpty() {
        System.assertEquals(0,
            CustomerOrderLineService.getColsByOrderItemIds(new Set<Id>()).size());
    }

    @IsTest
    static void getColsByOrderItemIds_nullIdsInSet_cleaned() {
        OrderItem oi = getTestOI();
        // @testSetup trigger already created a COL for this OI

        Set<Id> mixed = new Set<Id>{ oi.Id, null };

        Map<Id, CustomerOrderLine__c> result =
            CustomerOrderLineService.getColsByOrderItemIds(mixed);

        System.assertEquals(1, result.size());
    }

    @IsTest
    static void getOrphanedCols_returnsUntaggedOrphans() {
        CustomerOrderLine__c orphan = CPQ_TestDataFactory.createOrphanCOL('COL-ORPHAN');

        List<CustomerOrderLine__c> result = CustomerOrderLineService.getOrphanedCols();

        Boolean found = false;
        for (CustomerOrderLine__c c : result) {
            if (c.Id == orphan.Id) { found = true; break; }
        }
        System.assert(found, 'Untagged orphan should be returned');
    }

    @IsTest
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
    //
    //  Each method uses ONE Test.startTest()/Test.stopTest() pair.
    //  Each creates FRESH data via createOrderWithItem() so the
    //  @future from @testSetup does not interfere.
    // =====================================================================

    @IsTest
    static void integration_afterInsert_createsCOL() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        Test.startTest();
        Test.stopTest();

        List<CustomerOrderLine__c> cols = [
            SELECT Id, Name FROM CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id
        ];

        System.assertEquals(1, cols.size());
        System.assert(cols[0].Name.startsWith('COL-'));
    }

    @IsTest
    static void integration_afterInsert_idempotent_noDuplicate() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        // Pre-create a COL so the @future idempotency check is exercised
        CPQ_TestDataFactory.createCOL(b.orderItem);

        Test.startTest();
        Test.stopTest();

        Integer count = [
            SELECT COUNT() FROM CustomerOrderLine__c
            WHERE  OrderItem__c = :b.orderItem.Id
        ];
        System.assertEquals(1, count, 'Should not create a duplicate');
    }

    @IsTest
    static void integration_afterUpdate_updatesQuantity() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        Test.startTest();

        // Requery before update — avoids stale reference issues
        OrderItem oi = [
            SELECT Id, Quantity FROM OrderItem
            WHERE  Id = :b.orderItem.Id
        ];
        oi.Quantity = 77;
        update oi;

        Test.stopTest();

        CustomerOrderLine__c col = [
            SELECT Quantity__c FROM CustomerOrderLine__c
            WHERE  OrderItem__c = :oi.Id LIMIT 1
        ];

        System.assertEquals(77, col.Quantity__c);
    }

    @IsTest
    static void integration_afterUpdate_noChange_doesNotModifySyncDate() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        // Manually create a COL with a known sync timestamp
        CustomerOrderLine__c preCOL = CPQ_TestDataFactory.createCOL(b.orderItem);

        DateTime syncedBefore = [
            SELECT Last_Synced_Date__c FROM CustomerOrderLine__c
            WHERE  Id = :preCOL.Id
        ].Last_Synced_Date__c;

        Test.startTest();
        // Requery and re-save with no changes
        OrderItem oi = [SELECT Id FROM OrderItem WHERE Id = :b.orderItem.Id];
        update oi;
        Test.stopTest();

        DateTime syncedAfter = [
            SELECT Last_Synced_Date__c FROM CustomerOrderLine__c
            WHERE  Id = :preCOL.Id
        ].Last_Synced_Date__c;

        System.assertEquals(syncedBefore, syncedAfter,
            'Last_Synced_Date__c should not change when no values changed');
    }

    @IsTest
    static void integration_afterDelete_tagsCOL() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        // Manually create a COL before deleting the OrderItem
        CustomerOrderLine__c col = CPQ_TestDataFactory.createCOL(b.orderItem);

        Test.startTest();
        delete b.orderItem;
        Test.stopTest();

        CustomerOrderLine__c tagged = [
            SELECT Name, Last_Synced_Date__c
            FROM   CustomerOrderLine__c WHERE Id = :col.Id
        ];

        System.assert(tagged.Name.startsWith('[DEL]'));
        System.assertNotEquals(null, tagged.Last_Synced_Date__c);
    }

    @IsTest
    static void integration_afterDelete_alreadyTagged_noDoubleTag() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        // Create a COL that's already tagged
        CustomerOrderLine__c col = CPQ_TestDataFactory.createCOL(
            b.orderItem, '[DEL] COL-PreTagged'
        );

        Test.startTest();
        delete b.orderItem;
        Test.stopTest();

        CustomerOrderLine__c checked = [
            SELECT Name FROM CustomerOrderLine__c WHERE Id = :col.Id
        ];

        System.assert(!checked.Name.startsWith('[DEL] [DEL]'),
            'Already-tagged COL should not receive a second [DEL]');
    }

    // =====================================================================
    //  SECTION 6 — Edge cases
    //
    //  These use the @testSetup OI directly. The trigger's @future already
    //  created a COL for it, so we account for that in assertions.
    // =====================================================================

    @IsTest
    static void run_unhandledOperation_doesNotThrow() {
        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.BEFORE_INSERT,
            new Map<Id, OrderItem>(), null, null
        );
        Test.stopTest();

        System.assert(true);
    }

    @IsTest
    static void afterDelete_noCOLsFound_doesNotThrow() {
        // Use a fresh OI with its COL deleted so the delete path finds nothing
        OrderItem oi = getTestOI();
        delete [SELECT Id FROM CustomerOrderLine__c WHERE OrderItem__c = :oi.Id];

        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_DELETE,
            null, null, new List<OrderItem>{ oi }
        );
        Test.stopTest();

        System.assert(true);
    }

    @IsTest
    static void createCOLsAsync_allExisting_skipsInsert() {
        // The @testSetup trigger already created a COL — verify it's there
        OrderItem oi = getTestOI();
        Integer countBefore = [
            SELECT COUNT() FROM CustomerOrderLine__c WHERE OrderItem__c = :oi.Id
        ];
        System.assert(countBefore >= 1, 'COL should already exist from @testSetup trigger');

        // Call AFTER_INSERT again — the idempotency check should skip the insert
        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_INSERT,
            new Map<Id, OrderItem>{ oi.Id => oi }, null, null
        );
        Test.stopTest();

        Integer countAfter = [
            SELECT COUNT() FROM CustomerOrderLine__c WHERE OrderItem__c = :oi.Id
        ];
        System.assertEquals(countBefore, countAfter, 'Should not create a duplicate');
    }

    @IsTest
    static void updateCOLsAsync_noCOL_skipsUpdate() {
        // Remove the COL created by @testSetup trigger so the update path
        // hits the "no COL found" continue branch
        OrderItem oi = getTestOI();
        delete [SELECT Id FROM CustomerOrderLine__c WHERE OrderItem__c = :oi.Id];

        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_UPDATE,
            new Map<Id, OrderItem>{ oi.Id => oi },
            new Map<Id, OrderItem>{ oi.Id => oi },
            null
        );
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM CustomerOrderLine__c WHERE OrderItem__c = :oi.Id];
        System.assertEquals(0, count);
    }

    @IsTest
    static void updateCOLsAsync_noChanges_doesNotUpdate() {
        // The @testSetup trigger already created a COL that matches the OI
        OrderItem oi = getTestOI();

        DateTime syncedBefore = [
            SELECT Last_Synced_Date__c FROM CustomerOrderLine__c
            WHERE  OrderItem__c = :oi.Id LIMIT 1
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
            SELECT Last_Synced_Date__c FROM CustomerOrderLine__c
            WHERE  OrderItem__c = :oi.Id LIMIT 1
        ].Last_Synced_Date__c;

        System.assertEquals(syncedBefore, syncedAfter);
    }
}
