@IsTest
private class CustomerOrderLineServiceTest {

    // ─────────────────────────────────────────────
    // SHARED TEST DATA
    // ─────────────────────────────────────────────

    @testSetup
    static void setupData() {
        // Only create base OrderItem once
        CPQ_TestDataFactory.createOrderWithItem();
    }

    private static OrderItem getTestOI() {
        return [
            SELECT Id, OrderItemNumber,
                   Product2.Name,
                   Order.AccountId,
                   SBQQ__Contract__c,
                   SBQQ__Contract__r.ContractNumber,
                   SBQQ__Contract__r.Status,
                   Quantity,
                   TotalPrice,
                   ServiceDate,
                   EndDate,
                   blng__LastChargeToDate__c,
                   blng__NextBillingDate__c,
                   SBQQ__DefaultSubscriptionTerm__c
            FROM OrderItem
            LIMIT 1
        ];
    }

    // ─────────────────────────────────────────────
    // SECTION 1 — buildCOL
    // ─────────────────────────────────────────────

    @IsTest
    static void buildCOL_mapsFieldsCorrectly() {
        OrderItem oi = getTestOI();

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);

        System.assertEquals(oi.Id, col.OrderItem__c);
        System.assertEquals(oi.Quantity, col.Quantity__c);
        System.assertEquals(oi.TotalPrice, col.Total_Price__c);
        System.assertEquals(oi.EndDate, col.End_Date__c);
        System.assertEquals(oi.ServiceDate, col.Service_Date__c);
    }

    // ─────────────────────────────────────────────
    // SECTION 2 — applyChanges
    // ─────────────────────────────────────────────

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
    static void applyChanges_noChange_returnsFalse() {
        OrderItem oi = getTestOI();
        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);

        Boolean changed = CustomerOrderLineService.applyChanges(col, oi, oi);

        System.assertEquals(false, changed);
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

    // ─────────────────────────────────────────────
    // SECTION 3 — buildPseudoOld
    // ─────────────────────────────────────────────

    @IsTest
    static void buildPseudoOld_reconstructsFields() {
        OrderItem oi = getTestOI();
        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);

        OrderItem pseudo = CustomerOrderLineService.buildPseudoOld(col);

        System.assertEquals(col.Quantity__c, pseudo.Quantity);
        System.assertEquals(col.End_Date__c, pseudo.EndDate);
        System.assertEquals(col.Total_Price__c, pseudo.TotalPrice);
        System.assertEquals(col.Service_Date__c, pseudo.ServiceDate);
    }

    // ─────────────────────────────────────────────
    // SECTION 4 — QUERIES
    // ─────────────────────────────────────────────

    @IsTest
    static void getColsByOrderItemIds_returnsMap() {
        OrderItem oi = getTestOI();

        CPQ_TestDataFactory.createCOL(oi, 'COL-TEST');

        Map<Id, CustomerOrderLine__c> result =
            CustomerOrderLineService.getColsByOrderItemIds(
                new Set<Id>{ oi.Id }
            );

        System.assertEquals(1, result.size());
    }

    @IsTest
    static void getColsByOrderItemIds_null_returnsEmpty() {
        System.assertEquals(
            0,
            CustomerOrderLineService.getColsByOrderItemIds(null).size()
        );
    }

    // ─────────────────────────────────────────────
    // SECTION 5 — INTEGRATION (FIXED FOR YOUR ERRORS)
    // ─────────────────────────────────────────────

    @IsTest
    static void integration_afterInsert_createsCOL() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        Test.startTest();
        Test.stopTest();

        List<CustomerOrderLine__c> cols = [
            SELECT Id, Name
            FROM CustomerOrderLine__c
            WHERE OrderItem__c = :b.orderItem.Id
        ];

        System.assertEquals(1, cols.size());
        System.assert(cols[0].Name.startsWith('COL-'));
    }

    @IsTest
    static void integration_afterUpdate_updatesQuantity() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        Test.startTest();

        // IMPORTANT: requery before update (avoids stale trigger state issues)
        OrderItem oi = [
            SELECT Id, Quantity
            FROM OrderItem
            WHERE Id = :b.orderItem.Id
        ];

        oi.Quantity = 77;
        update oi;

        Test.stopTest();

        CustomerOrderLine__c col = [
            SELECT Quantity__c
            FROM CustomerOrderLine__c
            WHERE OrderItem__c = :oi.Id
            LIMIT 1
        ];

        System.assertEquals(77, col.Quantity__c);
    }

    @IsTest
    static void integration_afterUpdate_noChange_doesNotModifySyncDate() {
        CPQ_TestDataFactory.OrderBundle b =
            CPQ_TestDataFactory.createOrderWithItem();

        CustomerOrderLine__c col = [
            SELECT Last_Synced_Date__c
            FROM CustomerOrderLine__c
            WHERE OrderItem__c = :b.orderItem.Id
            LIMIT 1
        ];

        DateTime before = col.Last_Synced_Date__c;

        Test.startTest();
        update b.orderItem;
        Test.stopTest();

        DateTime after = [
            SELECT Last_Synced_Date__c
            FROM CustomerOrderLine__c
            WHERE OrderItem__c = :b.orderItem.Id
        ].Last_Synced_Date__c;

        System.assertEquals(before, after);
    }

    // ─────────────────────────────────────────────
    // SECTION 6 — EDGE CASES (SAFE)
    // ─────────────────────────────────────────────

    @IsTest
    static void run_doesNotThrow() {
        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.BEFORE_INSERT,
            new Map<Id, OrderItem>(),
            null,
            null
        );
        Test.stopTest();
    }

    @IsTest
    static void afterDelete_safeExecution() {
        OrderItem oi = getTestOI();

        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_DELETE,
            null,
            null,
            new List<OrderItem>{ oi }
        );
        Test.stopTest();

        System.assert(true);
    }
}
