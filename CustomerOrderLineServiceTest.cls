// ─── CustomerOrderLineServiceTest ────────────────────────────────────────────
/**
 * Unit + integration tests for CustomerOrderLineService.
 *
 * Covers:
 *  - buildCOL()              : field mapping including Contract_Number__c.
 *  - applyChanges()          : only changed fields get written; returns correct boolean.
 *  - buildPseudoOld()        : reconstructs the right field values from a COL.
 *  - handleCreates()         : async future creates COLs for new OrderItems.
 *  - handleUpdates()         : async future updates COLs when OI fields change.
 *  - handleUpdateToDeleted() : synchronously tags COLs as [DEL].
 *
 * NOTE: @future methods only execute after Test.stopTest(), so all async
 *       assertions are placed after that call.
 */
@isTest
private class CustomerOrderLineServiceTest {

    // ── TEST DATA SETUP ───────────────────────────────────────────────────────

    @testSetup
    static void setupData() {
        CPQ_TestDataFactory.createOrderWithItem();
    }

    // ── HELPER: fetch the test OrderItem ─────────────────────────────────────

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

    // ── buildCOL ──────────────────────────────────────────────────────────────

    @isTest
    static void buildCOL_mapsFieldsCorrectly() {
        OrderItem oi = getTestOI();

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);

        System.assertEquals(oi.Id,         col.OrderItem__c,       'OrderItem__c should match');
        System.assertEquals(oi.Quantity,   col.Quantity__c,        'Quantity should match');
        System.assertEquals(oi.TotalPrice, col.Total_Price__c,     'TotalPrice should match');
        System.assertNotEquals(null, col.Last_Synced_Date__c,      'Last_Synced_Date__c must be set');
        System.assert(col.Name.startsWith('COL-'),                 'Name should start with COL-');
        // No contract linked in test data — both contract fields should be null
        System.assertEquals(null, col.Contract_Number__c,          'Contract_Number__c should be null when no contract');
        System.assertEquals(null, col.Contract_Status__c,          'Contract_Status__c should be null when no contract');
    }

    // ── applyChanges ──────────────────────────────────────────────────────────

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
        newOI.Quantity  = oldOI.Quantity + 5;

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oldOI);
        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true,            changed,         'Changed quantity should flag as changed');
        System.assertEquals(newOI.Quantity,   col.Quantity__c, 'COL Quantity should be updated');
    }

    @isTest
    static void applyChanges_endDateChanged_returnsTrue() {
        OrderItem oldOI = getTestOI();
        OrderItem newOI = getTestOI();
        newOI.EndDate   = oldOI.EndDate.addMonths(6);

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oldOI);
        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true,          changed,          'Changed EndDate should flag as changed');
        System.assertEquals(newOI.EndDate, col.End_Date__c,  'COL EndDate should be updated');
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

        System.assertEquals(true,       changed,                  'Changed ContractNumber should flag true');
        System.assertEquals('00000200', col.Contract_Number__c,   'COL Contract_Number__c should reflect new value');
        System.assertEquals('Activated', col.Contract_Status__c,  'Unchanged Status should remain');
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

        System.assertEquals(true,        changed,                  'Both fields changed should flag true');
        System.assertEquals('00000200',  col.Contract_Number__c,   'Contract number should update');
        System.assertEquals('Activated', col.Contract_Status__c,   'Contract status should update');
    }

    @isTest
    static void applyChanges_contractNumberNullToPopulated_returnsTrue() {
        OrderItem oldOI = new OrderItem();
        oldOI.SBQQ__Contract__r = new Contract();

        OrderItem newOI = new OrderItem();
        newOI.SBQQ__Contract__r = new Contract(ContractNumber = '00000300', Status = 'Activated');

        CustomerOrderLine__c col = new CustomerOrderLine__c();

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assertEquals(true,       changed,                  'Null-to-populated should flag true');
        System.assertEquals('00000300', col.Contract_Number__c,   'Contract number should be set');
    }

    // ── buildPseudoOld ────────────────────────────────────────────────────────

    @isTest
    static void buildPseudoOld_reconstructsFieldsFromCOL() {
        OrderItem oi = getTestOI();
        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);
        col.Contract_Number__c = '00000999';
        col.Contract_Status__c = 'Activated';

        OrderItem pseudo = CustomerOrderLineService.buildPseudoOld(col);

        System.assertEquals(col.Quantity__c,    pseudo.Quantity,                          'Quantity should be reconstructed');
        System.assertEquals(col.End_Date__c,    pseudo.EndDate,                           'EndDate should be reconstructed');
        System.assertEquals(col.Total_Price__c, pseudo.TotalPrice,                        'TotalPrice should be reconstructed');
        System.assertEquals('00000999',         pseudo.SBQQ__Contract__r.ContractNumber,  'ContractNumber should be reconstructed');
        System.assertEquals('Activated',        pseudo.SBQQ__Contract__r.Status,          'Contract Status should be reconstructed');
    }

    @isTest
    static void buildPseudoOld_nullContractFields_reconstructsAsNull() {
        CustomerOrderLine__c col = new CustomerOrderLine__c(
            Contract_Number__c = null,
            Contract_Status__c = null
        );

        OrderItem pseudo = CustomerOrderLineService.buildPseudoOld(col);

        System.assertEquals(null, pseudo.SBQQ__Contract__r.ContractNumber,  'Null contract number should stay null');
        System.assertEquals(null, pseudo.SBQQ__Contract__r.Status,          'Null contract status should stay null');
    }

    // ── handleCreates (async) ─────────────────────────────────────────────────

    @isTest
    static void handleCreates_insertsCOLForNewOrderItem() {
        OrderItem oi = getTestOI();
        System.assertEquals(0, [SELECT COUNT() FROM CustomerOrderLine__c WHERE OrderItem__c = :oi.Id]);

        Test.startTest();
        CustomerOrderLineService.handleCreates(new Set<Id>{ oi.Id });
        Test.stopTest();

        List<CustomerOrderLine__c> cols = [
            SELECT Id, OrderItem__c FROM CustomerOrderLine__c WHERE OrderItem__c = :oi.Id
        ];
        System.assertEquals(1, cols.size(), 'Exactly one COL should be created');
    }

    @isTest
    static void handleCreates_idempotent_doesNotDuplicateCOL() {
        OrderItem oi = getTestOI();
        insert CustomerOrderLineService.buildCOL(oi);

        Test.startTest();
        CustomerOrderLineService.handleCreates(new Set<Id>{ oi.Id });
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM CustomerOrderLine__c WHERE OrderItem__c = :oi.Id];
        System.assertEquals(1, count, 'Second call should not create a duplicate COL');
    }

    // ── handleUpdates (async) ─────────────────────────────────────────────────

    @isTest
    static void handleUpdates_updatesCOLWhenOIChanges() {
        OrderItem oi = getTestOI();
        insert CustomerOrderLineService.buildCOL(oi);

        oi.Quantity = 99;
        update oi;

        Map<Id, OrderItem> newMap = new Map<Id, OrderItem>{ oi.Id => oi };
        Map<Id, OrderItem> oldMap = new Map<Id, OrderItem>{ oi.Id => getTestOI() };

        Test.startTest();
        CustomerOrderLineService.handleUpdates(newMap, oldMap);
        Test.stopTest();

        CustomerOrderLine__c updated = [
            SELECT Quantity__c FROM CustomerOrderLine__c WHERE OrderItem__c = :oi.Id
        ];
        System.assertEquals(99, updated.Quantity__c, 'COL Quantity should reflect OI change');
    }

    // ── handleUpdateToDeleted (sync) ──────────────────────────────────────────

    @isTest
    static void handleUpdateToDeleted_prependsDelTag() {
        OrderItem oi = getTestOI();
        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);
        insert col;

        Test.startTest();
        CustomerOrderLineService.handleUpdateToDeleted(new List<OrderItem>{ oi });
        Test.stopTest();

        CustomerOrderLine__c tagged = [
            SELECT Name, Last_Synced_Date__c FROM CustomerOrderLine__c WHERE Id = :col.Id
        ];
        System.assert(tagged.Name.startsWith('[DEL]'),           'Name should start with [DEL]');
        System.assertNotEquals(null, tagged.Last_Synced_Date__c, 'Last_Synced_Date__c should be stamped');
    }

    @isTest
    static void handleUpdateToDeleted_alreadyTagged_noDoubleTag() {
        OrderItem oi = getTestOI();
        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);
        col.Name = '[DEL] COL-Existing';
        insert col;

        Test.startTest();
        CustomerOrderLineService.handleUpdateToDeleted(new List<OrderItem>{ oi });
        Test.stopTest();

        CustomerOrderLine__c tagged = [SELECT Name FROM CustomerOrderLine__c WHERE Id = :col.Id];
        System.assert(!tagged.Name.startsWith('[DEL] [DEL]'), 'Should not double-tag an already-tagged COL');
    }
}
