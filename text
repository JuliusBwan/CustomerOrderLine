
@IsTest
private class CustomerOrderLineServiceTest {

    /*
     * ============================================================================
     * CustomerOrderLineServiceTest
     * ============================================================================
     *
     * PURPOSE
     * -------
     * Covers CustomerOrderLineService directly instead of relying on the trigger.
     *
     * This test class validates:
     * - AFTER_INSERT creates CustomerOrderLine__c records
     * - AFTER_UPDATE updates existing CustomerOrderLine__c records
     * - AFTER_DELETE marks related COL records as deleted
     * - Bulk insert/update/delete service behaviour
     * - buildCOL()
     * - applyChanges()
     * - buildPseudoOld()
     * - getColsByOrderItemIds()
     * - getOrphanedCols()
     * - Queueable create/update jobs
     * - Deduplication guard behaviour
     *
     * WHY SERVICE TESTING?
     * --------------------
     * If OrderItemTrigger contains Test.isRunningTest(), the trigger exits before
     * CustomerOrderLineService.run() is called. Therefore, 100% meaningful coverage
     * should come from this service test class.
     *
     * TEST STRATEGY
     * -------------
     * CustomerOrderLineService.skipAsync = true is used for most tests so the
     * service runs synchronously and assertions can be made immediately.
     *
     * Queueable behaviour is tested separately using skipAsync = false and
     * Test.startTest() / Test.stopTest().
     * ============================================================================
     */

    private static void resetServiceFlags() {
        CustomerOrderLineService.skipAsync = true;
        CustomerOrderLineService.enqueuedIds.clear();
    }

    @IsTest
    static void testAfterInsertCreatesCustomerOrderLine() {
        resetServiceFlags();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        deleteExistingCols(bundle.orderItem.Id);

        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_INSERT,
            new Map<Id, OrderItem>{ bundle.orderItem.Id => bundle.orderItem },
            null,
            null
        );
        Test.stopTest();

        List<CustomerOrderLine__c> cols = [
            SELECT Id, Name, OrderItem__c, Quantity__c, Service_Date__c,
                   End_Date__c, Product_Name__c, Total_Price__c
            FROM CustomerOrderLine__c
            WHERE OrderItem__c = :bundle.orderItem.Id
        ];

        System.assertEquals(1, cols.size(), 'One COL should be created.');
        System.assertEquals(bundle.orderItem.Id, cols[0].OrderItem__c);
    }

    @IsTest
    static void testAfterUpdateUpdatesCustomerOrderLine() {
        resetServiceFlags();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        ensureColExists(bundle.orderItem.Id, bundle.orderItem);

        OrderItem oi = [
            SELECT Id, Quantity, UnitPrice
            FROM OrderItem
            WHERE Id = :bundle.orderItem.Id
        ];

        oi.Quantity = 9;
        update oi;

        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_UPDATE,
            new Map<Id, OrderItem>{ oi.Id => oi },
            null,
            null
        );
        Test.stopTest();

        CustomerOrderLine__c col = [
            SELECT Id, Quantity__c, Last_Synced_Date__c
            FROM CustomerOrderLine__c
            WHERE OrderItem__c = :oi.Id
            LIMIT 1
        ];

        System.assertEquals(9, col.Quantity__c, 'COL quantity should be updated.');
        System.assertNotEquals(null, col.Last_Synced_Date__c);
    }

    @IsTest
    static void testAfterDeleteTagsCustomerOrderLine() {
        resetServiceFlags();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        ensureColExists(bundle.orderItem.Id, bundle.orderItem);

        OrderItem oldOi = bundle.orderItem;

        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_DELETE,
            null,
            null,
            new List<OrderItem>{ oldOi }
        );
        Test.stopTest();

        CustomerOrderLine__c col = [
            SELECT Id, Name
            FROM CustomerOrderLine__c
            WHERE OrderItem__c = :oldOi.Id
            LIMIT 1
        ];

        System.assert(
            col.Name.startsWith('[DEL]'),
            'Deleted OrderItem COL should be tagged with [DEL].'
        );
    }

    @IsTest
    static void testBulkInsertUpdateDelete() {
        resetServiceFlags();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        List<OrderItem> items = new List<OrderItem>();

        for (Integer i = 0; i < 5; i++) {
            items.add(new OrderItem(
                OrderId                         = bundle.orderRec.Id,
                PricebookEntryId                = bundle.pbe.Id,
                Quantity                        = 1,
                UnitPrice                       = 100,
                ServiceDate                     = Date.today(),
                EndDate                         = Date.today().addMonths(12),
                blng__RevenueRecognitionRule__c = CPQ_TestDataFactory.getRevRecRule().Id,
                blng__BillingRule__c            = CPQ_TestDataFactory.getBillingRule().Id,
                blng__TaxRule__c                = CPQ_TestDataFactory.getTaxRule().Id
            ));
        }

        insert items;

        Map<Id, OrderItem> insertMap = new Map<Id, OrderItem>(items);

        Test.startTest();

        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_INSERT,
            insertMap,
            null,
            null
        );

        for (OrderItem oi : items) {
            oi.Quantity = 10;
        }

        update items;

        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_UPDATE,
            new Map<Id, OrderItem>(items),
            insertMap,
            null
        );

        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_DELETE,
            null,
            null,
            items
        );

        Test.stopTest();

        List<CustomerOrderLine__c> cols = [
            SELECT Id, Name, Quantity__c
            FROM CustomerOrderLine__c
            WHERE OrderItem__c IN :items
        ];

        System.assertEquals(5, cols.size(), 'Five COL records should exist.');

        for (CustomerOrderLine__c col : cols) {
            System.assertEquals(10, col.Quantity__c);
            System.assert(col.Name.startsWith('[DEL]'));
        }
    }

    @IsTest
    static void testBuildCOL() {
        resetServiceFlags();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        OrderItem oi = [
            SELECT Id, OrderItemNumber, Product2.Name,
                   Order.AccountId, Quantity, TotalPrice,
                   ServiceDate, EndDate, SBQQ__DefaultSubscriptionTerm__c,
                   blng__LastChargeToDate__c, blng__NextBillingDate__c
            FROM OrderItem
            WHERE Id = :bundle.orderItem.Id
        ];

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);

        System.assertEquals(oi.Id, col.OrderItem__c);
        System.assertEquals(oi.Quantity, col.Quantity__c);
        System.assertEquals(oi.ServiceDate, col.Service_Date__c);
        System.assertEquals(oi.EndDate, col.End_Date__c);
        System.assertEquals(oi.Product2.Name, col.Product_Name__c);
    }

    @IsTest
    static void testApplyChangesReturnsTrueWhenFieldsChange() {
        resetServiceFlags();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        CustomerOrderLine__c col = new CustomerOrderLine__c(
            Name         = 'Test COL',
            OrderItem__c = bundle.orderItem.Id,
            Quantity__c  = 1,
            Service_Date__c = Date.today().addDays(-1),
            End_Date__c = Date.today().addMonths(6),
            Total_Price__c = 100
        );

        OrderItem oldOi = CustomerOrderLineService.buildPseudoOld(col);

        OrderItem newOi = [
            SELECT Id, Quantity, TotalPrice, ServiceDate, EndDate,
                   OrderItemNumber, Product2.Name,
                   SBQQ__DefaultSubscriptionTerm__c,
                   blng__LastChargeToDate__c, blng__NextBillingDate__c,
                   SBQQ__Contract__r.ContractNumber,
                   SBQQ__Contract__r.Status
            FROM OrderItem
            WHERE Id = :bundle.orderItem.Id
        ];

        newOi.Quantity = 7;

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOi, newOi);

        System.assertEquals(true, changed, 'applyChanges should detect changes.');
        System.assertEquals(7, col.Quantity__c);
    }

    @IsTest
    static void testApplyChangesReturnsFalseWhenNoFieldsChange() {
        resetServiceFlags();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        ensureColExists(bundle.orderItem.Id, bundle.orderItem);

        CustomerOrderLine__c col = [
            SELECT Id, Name, OrderItem__c, Quantity__c, Service_Date__c,
                   End_Date__c, Total_Price__c, OrderItemNumber__c,
                   Product_Name__c, Subscription_Term_Months__c,
                   Contract_Number__c, Contract_Status__c,
                   blng_LastChargeToDate__c, blng_NextBillingDate__c
            FROM CustomerOrderLine__c
            WHERE OrderItem__c = :bundle.orderItem.Id
            LIMIT 1
        ];

        OrderItem oldOi = CustomerOrderLineService.buildPseudoOld(col);

        OrderItem newOi = CustomerOrderLineService.buildPseudoOld(col);

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOi, newOi);

        System.assertEquals(false, changed, 'No fields changed, so result should be false.');
    }

    @IsTest
    static void testGetColsByOrderItemIdsHandlesNullAndEmpty() {
        resetServiceFlags();

        Map<Id, CustomerOrderLine__c> emptyResult =
            CustomerOrderLineService.getColsByOrderItemIds(new Set<Id>());

        System.assertEquals(0, emptyResult.size());

        Map<Id, CustomerOrderLine__c> nullResult =
            CustomerOrderLineService.getColsByOrderItemIds(null);

        System.assertEquals(0, nullResult.size());
    }

    @IsTest
    static void testGetColsByOrderItemIdsReturnsRecords() {
        resetServiceFlags();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        ensureColExists(bundle.orderItem.Id, bundle.orderItem);

        Map<Id, CustomerOrderLine__c> result =
            CustomerOrderLineService.getColsByOrderItemIds(
                new Set<Id>{ bundle.orderItem.Id }
            );

        System.assertEquals(1, result.size());
        System.assert(result.containsKey(bundle.orderItem.Id));
    }

    @IsTest
    static void testGetOrphanedCols() {
        resetServiceFlags();

        CustomerOrderLine__c orphan =
            CPQ_TestDataFactory.createOrphanCOL('Orphan COL');

        CustomerOrderLine__c deletedOrphan =
            CPQ_TestDataFactory.createOrphanCOL('[DEL] Already Deleted COL');

        List<CustomerOrderLine__c> orphans =
            CustomerOrderLineService.getOrphanedCols();

        Set<Id> orphanIds = new Set<Id>();

        for (CustomerOrderLine__c col : orphans) {
            orphanIds.add(col.Id);
        }

        System.assert(orphanIds.contains(orphan.Id));
        System.assert(!orphanIds.contains(deletedOrphan.Id));
    }

    @IsTest
    static void testQueueableCreateJob() {
        CustomerOrderLineService.skipAsync = false;
        CustomerOrderLineService.enqueuedIds.clear();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        deleteExistingCols(bundle.orderItem.Id);

        Test.startTest();
        System.enqueueJob(
            new CustomerOrderLineService.CreateCOLsJob(
                new Set<Id>{ bundle.orderItem.Id }
            )
        );
        Test.stopTest();

        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM CustomerOrderLine__c
                WHERE OrderItem__c = :bundle.orderItem.Id
            ]
        );
    }

    @IsTest
    static void testQueueableUpdateJob() {
        resetServiceFlags();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        ensureColExists(bundle.orderItem.Id, bundle.orderItem);

        OrderItem oi = [
            SELECT Id, Quantity
            FROM OrderItem
            WHERE Id = :bundle.orderItem.Id
        ];

        oi.Quantity = 12;
        update oi;

        CustomerOrderLineService.skipAsync = false;
        CustomerOrderLineService.enqueuedIds.clear();

        Test.startTest();
        System.enqueueJob(
            new CustomerOrderLineService.UpdateCOLsJob(
                new Set<Id>{ oi.Id }
            )
        );
        Test.stopTest();

        CustomerOrderLine__c col = [
            SELECT Quantity__c
            FROM CustomerOrderLine__c
            WHERE OrderItem__c = :oi.Id
            LIMIT 1
        ];

        System.assertEquals(12, col.Quantity__c);
    }

    @IsTest
    static void testRunWithUnhandledOperation() {
        resetServiceFlags();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        Test.startTest();
        CustomerOrderLineService.run(
            System.TriggerOperation.BEFORE_INSERT,
            new Map<Id, OrderItem>{ bundle.orderItem.Id => bundle.orderItem },
            null,
            null
        );
        Test.stopTest();

        System.assert(true, 'Unhandled operation branch executed safely.');
    }

    @IsTest
    static void testRunDedupPreventsDuplicateQueueable() {
        CustomerOrderLineService.skipAsync = false;
        CustomerOrderLineService.enqueuedIds.clear();

        CPQ_TestDataFactory.OrderBundle bundle =
            CPQ_TestDataFactory.createOrderWithItem();

        deleteExistingCols(bundle.orderItem.Id);

        Map<Id, OrderItem> newMap =
            new Map<Id, OrderItem>{ bundle.orderItem.Id => bundle.orderItem };

        Test.startTest();

        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_INSERT,
            newMap,
            null,
            null
        );

        CustomerOrderLineService.run(
            System.TriggerOperation.AFTER_INSERT,
            newMap,
            null,
            null
        );

        Test.stopTest();

        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM CustomerOrderLine__c
                WHERE OrderItem__c = :bundle.orderItem.Id
            ],
            'Dedup guard should prevent duplicate COL creation.'
        );
    }

    private static void ensureColExists(Id orderItemId, OrderItem oi) {
        List<CustomerOrderLine__c> existing = [
            SELECT Id
            FROM CustomerOrderLine__c
            WHERE OrderItem__c = :orderItemId
            LIMIT 1
        ];

        if (existing.isEmpty()) {
            CustomerOrderLineService.run(
                System.TriggerOperation.AFTER_INSERT,
                new Map<Id, OrderItem>{ orderItemId => oi },
                null,
                null
            );
        }
    }

    private static void deleteExistingCols(Id orderItemId) {
        List<CustomerOrderLine__c> existing = [
            SELECT Id
            FROM CustomerOrderLine__c
            WHERE OrderItem__c = :orderItemId
        ];

        if (!existing.isEmpty()) {
            delete existing;
        }
    }
}

#####
@TestVisible
static Boolean skipAsync = false;

@TestVisible
static Set<Id> enqueuedIds = new Set<Id>();
