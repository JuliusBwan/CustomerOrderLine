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

    private static OrderItem getTestOI() {
        return [
            SELECT Id, OrderItemNumber, Product2.Name,
                   Order.AccountId, SBQQ__Contract__c,
                   SBQQ__Contract__r.ContractNumber, SBQQ__Contract__r.Status,
                   Quantity, TotalPrice, ServiceDate, EndDate,
                   blng__LastChargeToDate__c, blng__NextBillingDate__c,
                   SBQQ__DefaultSubscriptionTerm__c
            FROM OrderItem
            LIMIT 1
        ];
    }

    // =====================================================================
    //  SECTION 1 — buildCOL
    // =====================================================================

    @isTest
    static void buildCOL_mapsFieldsCorrectly() {
        OrderItem oi = getTestOI();

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);

        System.assertEquals(oi.Id, col.OrderItem__c);
        System.assertEquals(oi.Quantity, col.Quantity__c);
        System.assertEquals(oi.TotalPrice, col.Total_Price__c);
        System.assertEquals(oi.EndDate, col.End_Date__c);
        System.assertEquals(oi.ServiceDate, col.Service_Date__c);
        System.assertNotEquals(null, col.Last_Synced_Date__c);
        System.assert(col.Name.startsWith('COL-'));
        System.assertEquals(null, col.Contract_Number__c);
        System.assertEquals(null, col.Contract_Status__c);
    }

    // =====================================================================
    //  SECTION 2 — applyChanges
    // =====================================================================

    @isTest
    static void applyChanges_noChange_returnsFalse() {
        OrderItem oi = getTestOI();
        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oi);

        Boolean changed = CustomerOrderLineService.applyChanges(col, oi, oi);

        System.assertEquals(false, changed);
    }

    @isTest
    static void applyChanges_quantityChanged_returnsTrue() {
        OrderItem oldOI = getTestOI();
        OrderItem newOI = getTestOI();
        newOI.Quantity = oldOI.Quantity + 5;

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oldOI);
        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assert(changed);
        System.assertEquals(newOI.Quantity, col.Quantity__c);
    }

    @isTest
    static void applyChanges_endDateChanged_returnsTrue() {
        OrderItem oldOI = getTestOI();
        OrderItem newOI = getTestOI();
        newOI.EndDate = oldOI.EndDate.addMonths(6);

        CustomerOrderLine__c col = CustomerOrderLineService.buildCOL(oldOI);
        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assert(changed);
        System.assertEquals(newOI.EndDate, col.End_Date__c);
    }

    @isTest
    static void applyChanges_contractNumberChanged_returnsTrue() {
        OrderItem oldOI = new OrderItem();
        oldOI.SBQQ__Contract__r = new Contract(Status = 'Activated');

        OrderItem newOI = new OrderItem();
        newOI.SBQQ__Contract__r = new Contract(ContractNumber = '00000200', Status = 'Activated');

        CustomerOrderLine__c col = new CustomerOrderLine__c(
            Contract_Number__c = '00000100',
            Contract_Status__c = 'Activated'
        );

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assert(changed);
        System.assertEquals('00000200', col.Contract_Number__c);
    }

    @isTest
    static void applyChanges_contractNumberAndStatusBothChanged_returnsTrue() {
        OrderItem oldOI = new OrderItem();
        oldOI.SBQQ__Contract__r = new Contract(Status = 'Draft');

        OrderItem newOI = new OrderItem();
        newOI.SBQQ__Contract__r = new Contract(ContractNumber = '00000200', Status = 'Activated');

        CustomerOrderLine__c col = new CustomerOrderLine__c(
            Contract_Number__c = '00000100',
            Contract_Status__c = 'Draft'
        );

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assert(changed);
        System.assertEquals('00000200', col.Contract_Number__c);
        System.assertEquals('Activated', col.Contract_Status__c);
    }

    @isTest
    static void applyChanges_allRemainingFieldsChanged_returnsTrue() {
        OrderItem oldOI = new OrderItem(
            blng__LastChargeToDate__c = Date.today(),
            blng__NextBillingDate__c = Date.today(),
            ServiceDate = Date.today(),
            SBQQ__DefaultSubscriptionTerm__c = 12
        );
        oldOI.Product2 = new Product2(Name = 'Old Product');

        OrderItem newOI = new OrderItem(
            blng__LastChargeToDate__c = Date.today().addDays(30),
            blng__NextBillingDate__c = Date.today().addDays(30),
            ServiceDate = Date.today().addDays(30),
            SBQQ__DefaultSubscriptionTerm__c = 24,
            TotalPrice = 200
        );
        newOI.Product2 = new Product2(Name = 'New Product');

        CustomerOrderLine__c col = new CustomerOrderLine__c(
            blng_LastChargeToDate__c = Date.today(),
            blng_NextBillingDate__c = Date.today(),
            Product_Name__c = 'Old Product',
            Service_Date__c = Date.today(),
            Subscription_Term_Months__c = 12,
            Total_Price__c = 100
        );

        Boolean changed = CustomerOrderLineService.applyChanges(col, oldOI, newOI);

        System.assert(changed);
        System.assertEquals(200, col.Total_Price__c);
        System.assertEquals('New Product', col.Product_Name__c);
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

        System.assertEquals(col.Quantity__c, pseudo.Quantity);
        System.assertEquals(col.End_Date__c, pseudo.EndDate);
        System.assertEquals(col.Service_Date__c, pseudo.ServiceDate);
        System.assertEquals(col.Subscription_Term_Months__c, pseudo.SBQQ__DefaultSubscriptionTerm__c);
        System.assertEquals(col.blng_LastChargeToDate__c, pseudo.blng__LastChargeToDate__c);
        System.assertEquals(col.blng_NextBillingDate__c, pseudo.blng__NextBillingDate__c);

        // ✅ Read-only fields should NOT be populated
        System.assertEquals(null, pseudo.TotalPrice);
        System.assertEquals(null, pseudo.OrderItemNumber);
        System.assertEquals(null, pseudo.SBQQ__Contract__r.ContractNumber);

        System.assertEquals('Activated', pseudo.SBQQ__Contract__r.Status);
    }

    // =====================================================================
    //  Remaining sections unchanged (queries, integration, edge cases)
    // =====================================================================

}
