@IsTest
private class SmartAssistSupportControllerTest {
    @TestSetup
    static void setupData() {
        Account accountRecord = new Account(Name = 'SmartHome Person Account Context');
        insert accountRecord;
        Contact contactRecord = new Contact(LastName = 'Portal Customer', Email = 'portal@example.com', AccountId = accountRecord.Id);
        insert contactRecord;
        Product2 productRecord = new Product2(Name = 'Smart Door Lock Pro X', IsActive = true);
        insert productRecord;
        Asset assetRecord = new Asset(
            Name = 'Front Door Lock',
            AccountId = accountRecord.Id,
            Product2Id = productRecord.Id,
            SerialNumber = 'SDL-10001',
            PurchaseDate = Date.today().addDays(-30),
            UsageEndDate = Date.today().addYears(1),
            Status = 'Purchased'
        );
        insert assetRecord;
    }

    @IsTest
    static void getMyAssetsReturnsOnlyCustomerAssets() {
        SmartAssistSupportController.testUserContext = getContext();

        Test.startTest();
        List<SmartAssistSupportController.AssetSummary> assets = SmartAssistSupportController.getMyAssets();
        Test.stopTest();

        System.assertEquals(1, assets.size());
        System.assertEquals('Smart Door Lock Pro X', assets[0].displayName);
        System.assertEquals('Warranty Active', assets[0].warrantyStatus);
    }

    @IsTest
    static void getMyCasesReturnsOnlyCustomerCases() {
        SmartAssistSupportController.UserContext context = getContext();
        SmartAssistSupportController.testUserContext = context;
        Asset assetRecord = [SELECT Id FROM Asset LIMIT 1];
        insert new Case(
            AccountId = context.accountId,
            ContactId = context.contactId,
            AssetId = assetRecord.Id,
            Subject = 'Smart lock not responding',
            Status = 'New',
            Priority = 'High'
        );

        Test.startTest();
        List<SmartAssistSupportController.CaseSummary> cases = SmartAssistSupportController.getMyCases();
        Test.stopTest();

        System.assertEquals(1, cases.size());
        System.assertEquals('Smart lock not responding', cases[0].subject);
        System.assertEquals('High', cases[0].priority);
    }

    @IsTest
    static void analyzeCreatesConversationAndHighConfidenceDoesNotRequireCase() {
        SmartAssistSupportController.testUserContext = getContext();
        SmartAssistSupportController.bypassPersistenceForTests = true;
        SmartAssistSupportController.testConversations.clear();
        SmartAssistPromptService.promptGateway = new MockPromptGateway(90);
        Asset assetRecord = [SELECT Id FROM Asset LIMIT 1];

        Test.startTest();
        SmartAssistSupportController.SupportAnalysisResult result =
            SmartAssistSupportController.analyzeSupportRequest(assetRecord.Id, 'The keypad stopped responding.');
        Test.stopTest();

        System.assertEquals(false, result.requiresCase);
        System.assertEquals(90, result.confidenceScore);
        System.assertNotEquals(null, result.aiConversationId);

        AI_Conversation__c conversation = SmartAssistSupportController.testConversations.get(result.aiConversationId);
        System.assertEquals('Active', conversation.Conversation_Status__c);
        System.assertEquals(false, conversation.Case_Created__c);
        System.assertEquals(0.90, conversation.Confidence_Score__c);
    }

    @IsTest
    static void createSupportCaseUpdatesConversation() {
        SmartAssistSupportController.testUserContext = getContext();
        SmartAssistSupportController.bypassPersistenceForTests = true;
        SmartAssistSupportController.testConversations.clear();
        SmartAssistPromptService.promptGateway = new MockPromptGateway(70);
        Asset assetRecord = [SELECT Id FROM Asset LIMIT 1];

        SmartAssistSupportController.SupportAnalysisResult analysis =
            SmartAssistSupportController.analyzeSupportRequest(assetRecord.Id, 'The device will not unlock.');

        Test.startTest();
        SmartAssistSupportController.CaseCreationResult caseResult =
            SmartAssistSupportController.createSupportCase(analysis.aiConversationId);
        Test.stopTest();

        System.assertNotEquals(null, caseResult.caseId);
        System.assertNotEquals(null, caseResult.caseNumber);

        AI_Conversation__c conversation = SmartAssistSupportController.testConversations.get(analysis.aiConversationId);
        System.assertEquals(true, conversation.Case_Created__c);
        System.assertEquals('Escalated', conversation.Conversation_Status__c);
    }

    @IsTest
    static void resolveConversationMarksResolved() {
        SmartAssistSupportController.testUserContext = getContext();
        SmartAssistSupportController.bypassPersistenceForTests = true;
        SmartAssistSupportController.testConversations.clear();
        SmartAssistPromptService.promptGateway = new MockPromptGateway(96);
        Asset assetRecord = [SELECT Id FROM Asset LIMIT 1];
        SmartAssistSupportController.SupportAnalysisResult analysis =
            SmartAssistSupportController.analyzeSupportRequest(assetRecord.Id, 'How do I reset this product?');

        Test.startTest();
        SmartAssistSupportController.resolveConversation(analysis.aiConversationId);
        Test.stopTest();

        AI_Conversation__c conversation = SmartAssistSupportController.testConversations.get(analysis.aiConversationId);
        System.assertEquals('Resolved', conversation.Conversation_Status__c);
    }

    @IsTest
    static void analyzeRejectsBlankQuestion() {
        SmartAssistSupportController.testUserContext = getContext();
        Asset assetRecord = [SELECT Id FROM Asset LIMIT 1];

        try {
            SmartAssistSupportController.analyzeSupportRequest(assetRecord.Id, ' ');
            System.assert(false, 'Expected blank question to be rejected.');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
    }

    @IsTest
    static void createAndResolveRejectMissingConversation() {
        try {
            SmartAssistSupportController.createSupportCase(null);
            System.assert(false, 'Expected missing conversation to be rejected.');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }

        try {
            SmartAssistSupportController.resolveConversation(null);
            System.assert(false, 'Expected missing conversation to be rejected.');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
    }

    private static SmartAssistSupportController.UserContext getContext() {
        Contact contactRecord = [SELECT Id, AccountId FROM Contact LIMIT 1];
        return new SmartAssistSupportController.UserContext(contactRecord.Id, contactRecord.AccountId);
    }

    private class MockPromptGateway implements SmartAssistPromptService.PromptGateway {
        private Decimal confidence;

        MockPromptGateway(Decimal confidence) {
            this.confidence = confidence;
        }

        public String generate(SmartAssistPromptService.PromptContext context) {
            return JSON.serialize(new Map<String, Object>{
                'aiResponse' => 'Restart the hub, check the batteries, and retry pairing.',
                'category' => 'Hardware',
                'subcategory' => 'Lock keypad',
                'summary' => 'Door lock is not responding.',
                'recommendation' => 'Create a case if restart does not help.',
                'sentiment' => 'Neutral',
                'confidenceScore' => confidence
            });
        }
    }
}
