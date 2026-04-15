@IsTest
public class CPQ_TestDataFactory {

    // ─────────────────────────────────────────────
    // CACHED RECORDS
    // ─────────────────────────────────────────────
    private static Product2 cachedProduct;
    private static PricebookEntry cachedPBE;
    private static blng__BillingRule__c cachedBillingRule;
    private static blng__RevenueRecognitionRule__c cachedRevRecRule;
    private static blng__TaxRule__c cachedTaxRule;

    // ─────────────────────────────────────────────
    // BILLING RULE
    // ─────────────────────────────────────────────
    public static blng__BillingRule__c getBillingRule() {
        if (cachedBillingRule == null) {
            cachedBillingRule = new blng__BillingRule__c(
                Name = 'Sample Billing Rule',
                blng__Active__c = true,
                blng__GenerateInvoices__c = 'No',
                blng__InitialBillingTrigger__c = 'Order Product Activation Date'
            );
            insert cachedBillingRule;
        }
        return cachedBillingRule;
    }

    // ─────────────────────────────────────────────
    // REV REC RULE
    // ─────────────────────────────────────────────
    public static blng__RevenueRecognitionRule__c getRevRecRule() {
        if (cachedRevRecRule == null) {
            cachedRevRecRule = new blng__RevenueRecognitionRule__c(
                Name = 'Sample Revenue Recognition Rule',
                blng__Active__c = true,
                blng__CreateRevenueSchedule__c = 'No'
            );
            insert cachedRevRecRule;
        }
        return cachedRevRecRule;
    }

    // ─────────────────────────────────────────────
    // TAX RULE
    // ─────────────────────────────────────────────
    public static blng__TaxRule__c getTaxRule() {
        if (cachedTaxRule == null) {
            cachedTaxRule = new blng__TaxRule__c(
                Name = 'Sample Tax Rule',
                blng__Active__c = true,
                blng__TaxableYesNo__c = 'Yes'
            );
            insert cachedTaxRule;
        }
        return cachedTaxRule;
    }

    // ─────────────────────────────────────────────
    // PRODUCT (SOURCE OF TRUTH)
    // ─────────────────────────────────────────────
    public static Product2 getProduct() {
        if (cachedProduct == null) {

            cachedProduct = new Product2(
                Name = 'Test Product',
                ProductCode = 'TEST-PROD',
                IsActive = true,
                CurrencyIsoCode = 'GBP',

                SBQQ__ChargeType__c = 'Recurring',
                SBQQ__BillingType__c = 'Advance',
                SBQQ__BillingFrequency__c = 'Annual',
                SBQQ__SubscriptionType__c = 'Renewable',
                SBQQ__SubscriptionPricing__c = 'Fixed Price',
                SBQQ__SubscriptionTerm__c = 12,
                SBQQ__PricingMethod__c = 'List',
                SBQQ__DefaultQuantity__c = 1,
                SBQQ__Component__c = true,
                SBQQ__AssetConversion__c = 'One per quote line',

                // ✅ ALL BILLING LOGIC MOVED HERE
                blng__BillingRule__c = getBillingRule().Id,
                blng__RevenueRecognitionRule__c = getRevRecRule().Id,
                blng__TaxRule__c = getTaxRule().Id,
                blng__BillingDayOfMonth__c = 1
            );

            insert cachedProduct;
        }
        return cachedProduct;
    }

    // ─────────────────────────────────────────────
    // PRICEBOOK ENTRY
    // ─────────────────────────────────────────────
    public static PricebookEntry getStandardPBE() {
        if (cachedPBE == null) {
            cachedPBE = new PricebookEntry(
                Pricebook2Id = Test.getStandardPricebookId(),
                Product2Id = getProduct().Id,
                UnitPrice = 100,
                IsActive = true
            );
            insert cachedPBE;
        }
        return cachedPBE;
    }

    // ─────────────────────────────────────────────
    // LEGAL ENTITY
    // ─────────────────────────────────────────────
    public static blng__LegalEntity__c createLegalEntity() {
        blng__LegalEntity__c le = new blng__LegalEntity__c(
            Name = 'Test LE',
            blng__Active__c = true,
            BC_Company_Id__c = String.valueOf(System.currentTimeMillis()),
            BC_Company_Name__c = 'Test LE',
            BC_Environment__c = 'Production'
        );
        insert le;
        return le;
    }

    // ─────────────────────────────────────────────
    // ACCOUNT (FIXED FOR DUPLICATE RULES)
    // ─────────────────────────────────────────────
    public static Account createAccount() {

        blng__LegalEntity__c le = createLegalEntity();
        String unique = String.valueOf(DateTime.now().getTime());

        Account a = new Account(
            Name = 'Test Account ' + unique,
            GBG_Billing_Entity__c = le.Id,
            ShippingStreet = '83 Phoenix Street',
            ShippingCity = 'Sutton-in-Ashfield',
            ShippingPostalCode = 'NG17',
            ShippingCountry = 'United Kingdom',
            BillingStreet = '83 Phoenix Street',
            BillingCity = 'Sutton-in-Ashfield',
            BillingPostalCode = 'NG17',
            BillingCountry = 'United Kingdom',
            Correspondence_Address_SameAs_Registered__c = true
        );

        insert a;
        return a;
    }

    // ─────────────────────────────────────────────
    // ORDER BUNDLE
    // ─────────────────────────────────────────────
    public class OrderBundle {
        public Account account;
        public Product2 product;
        public PricebookEntry pbe;
        public Order orderRec;
        public OrderItem orderItem;
    }

    // ─────────────────────────────────────────────
    // ORDER + ORDER ITEM (STABLE VERSION)
    // ─────────────────────────────────────────────
    public static OrderBundle createOrderWithItem() {
        return createOrderWithItem(2, 100);
    }

    public static OrderBundle createOrderWithItem(Decimal quantity, Decimal unitPrice) {

        OrderBundle b = new OrderBundle();

        b.account = createAccount();
        b.product = getProduct();
        b.pbe = getStandardPBE();

        b.orderRec = new Order(
            AccountId = b.account.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert b.orderRec;

        // ✅ CLEAN ORDER ITEM (NO CPQ FIELDS HERE)
        OrderItem oi = new OrderItem(
            OrderId = b.orderRec.Id,
            PricebookEntryId = b.pbe.Id,
            Quantity = quantity,
            UnitPrice = unitPrice,
            ServiceDate = Date.today(),
            EndDate = Date.today().addMonths(12)
        );

        insert oi;

        b.orderItem = oi;
        return b;
    }

    // ─────────────────────────────────────────────
    // COL HELPERS
    // ─────────────────────────────────────────────
    public static CustomerOrderLine__c createCOL(OrderItem oi) {
        return createCOL(oi, 'COL-' + oi.Id);
    }

    public static CustomerOrderLine__c createCOL(OrderItem oi, String name) {
        CustomerOrderLine__c col = new CustomerOrderLine__c(
            Name = name,
            OrderItem__c = oi.Id
        );
        insert col;
        return col;
    }

    public static CustomerOrderLine__c createOrphanCOL(String name) {
        CustomerOrderLine__c col = new CustomerOrderLine__c(Name = name);
        insert col;
        return col;
    }
}
