public with sharing class SmartAssistSupportController {
    private static final Decimal CASE_THRESHOLD = 85;
    private static final String STATUS_ANALYZED = 'In Progress';
    private static final String STATUS_RESOLVED = 'Resolved';
    private static final String STATUS_CASE_CREATED = 'Escalated';

    @TestVisible
    static UserContext testUserContext;
    @TestVisible
    static Boolean bypassPersistenceForTests = false;
    @TestVisible
    static Map<Id, AI_Conversation__c> testConversations = new Map<Id, AI_Conversation__c>();

@AuraEnabled(cacheable=true)
    public static List<AssetSummary> getMyAssets() {
        try {
            UserContext context = getCurrentUserContext();
            List<AssetSummary> results = new List<AssetSummary>();
            for (Asset assetRecord : [
                SELECT Id, Name, SerialNumber, PurchaseDate, Status, UsageEndDate, Product2Id, Product2.Name
                FROM Asset
                WHERE AccountId = :context.accountId
                WITH USER_MODE
                ORDER BY PurchaseDate DESC NULLS LAST, CreatedDate DESC
            ]) {
                results.add(new AssetSummary(assetRecord));
            }
            return results;
        } catch (Exception ex) {
            throw customerException('Unable to load your products. Please try again.');
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<CaseSummary> getMyCases() {
        try {
            UserContext context = getCurrentUserContext();
            List<CaseSummary> results = new List<CaseSummary>();
            for (Case caseRecord : [
                SELECT Id, CaseNumber, Subject, Status, Priority, CreatedDate, AssetId, Asset.Name, Asset.Product2.Name
                FROM Case
                WHERE AccountId = :context.accountId AND ContactId = :context.contactId
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 100
            ]) {
                results.add(new CaseSummary(caseRecord));
            }
            return results;
        } catch (Exception ex) {
            throw customerException('Unable to load your cases. Please try again.');
        }
    }

    @AuraEnabled
    public static SupportAnalysisResult analyzeSupportRequest(Id assetId, String question) {
        if (assetId == null || String.isBlank(question)) {
            throw customerException('Please describe the issue you are experiencing.');
        }

        // try {
            UserContext context = getCurrentUserContext();
            Asset assetRecord = getValidatedAsset(assetId, context);
            Contact customer = getCustomer(context);

            SmartAssistPromptService.AIAnalysisResult promptResult =
                SmartAssistPromptService.analyze(assetRecord, customer, question.trim());
            promptResult.category = picklistValue(
                AI_Conversation__c.SObjectType,
                'AI_Category__c',
                promptResult.category,
                'General Support'
            );
            promptResult.sentiment = picklistValue(
                AI_Conversation__c.SObjectType,
                'AI_Sentiment__c',
                promptResult.sentiment,
                'Neutral'
            );

            AI_Conversation__c conversation = new AI_Conversation__c(
                Customer__c = context.contactId,
                Asset__c = assetRecord.Id,
                Question__c = question.trim(),
                AI_Response__c = promptResult.aiResponse,
                AI_Category__c = promptResult.category,
                AI_Subcategory__c = promptResult.subcategory,
                AI_Summary__c = promptResult.summary,
                AI_Recommendation__c = promptResult.recommendation,
                AI_Sentiment__c = promptResult.sentiment,
                Confidence_Score__c = percentForStorage(promptResult.confidenceScore),
                Conversation_Status__c = STATUS_ANALYZED,
                Case_Created__c = false
            );
            setIfFieldExists(conversation, 'Contact__c', context.contactId);
            setIfFieldExists(conversation, 'Account__c', context.accountId);
            if (bypassPersistenceForTests) {
                conversation.Id = Id.valueOf('a02000000000001AAA');
                testConversations.put(conversation.Id, conversation);
            } else {
                insertRecord(conversation);
            }

            SupportAnalysisResult result = new SupportAnalysisResult(promptResult);
            result.aiConversationId = conversation.Id;
            result.requiresCase = promptResult.confidenceScore < CASE_THRESHOLD;
            return result;
        // } catch (AuraHandledException ex) {
        //     throw ex;
        // } catch (Exception ex) {
        //     if (Test.isRunningTest()) {
        //         throw new AuraHandledException(ex.getTypeName() + ': ' + ex.getMessage());
        //     }
        //     throw customerException('SmartAssist is temporarily unavailable. Please try again.');
        // }
    }

    @AuraEnabled
    public static CaseCreationResult createSupportCase(Id aiConversationId) {
        if (aiConversationId == null) {
            throw customerException('We could not create your support case. Please try again.');
        }

        try {
            UserContext context = getCurrentUserContext();
            AI_Conversation__c conversation = getValidatedConversation(aiConversationId, context);
            Asset assetRecord = getValidatedAsset(conversation.Asset__c, context);
            return createCaseForConversation(conversation, assetRecord, context);
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            if (Test.isRunningTest()) {
                throw new AuraHandledException(ex.getTypeName() + ': ' + ex.getMessage());
            }
            throw customerException('We could not create your support case. Please try again.');
        }
    }

    @AuraEnabled
    public static void resolveConversation(Id aiConversationId) {
        if (aiConversationId == null) {
            throw customerException('We could not update your request. Please try again.');
        }

        try {
            UserContext context = getCurrentUserContext();
            AI_Conversation__c conversation = getValidatedConversation(aiConversationId, context);
            conversation.Conversation_Status__c = STATUS_RESOLVED;
            if (bypassPersistenceForTests) {
                testConversations.put(conversation.Id, conversation);
            } else {
                updateRecord(conversation);
            }
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            if (Test.isRunningTest()) {
                throw new AuraHandledException(ex.getTypeName() + ': ' + ex.getMessage());
            }
            throw customerException('We could not update your request. Please try again.');
        }
    }

    private static CaseCreationResult createCaseForConversation(
        AI_Conversation__c conversation,
        Asset assetRecord,
        UserContext context
    ) {
        Case caseRecord = new Case();
        String caseCategory = picklistValue(Case.SObjectType, 'AI_Category__c', conversation.AI_Category__c, null);
        String caseSentiment = picklistValue(Case.SObjectType, 'AI_Sentiment__c', conversation.AI_Sentiment__c, null);
        caseRecord.AccountId = context.accountId;
        caseRecord.ContactId = context.contactId;
        caseRecord.AssetId = assetRecord.Id;
        caseRecord.Subject = buildCaseSubject(conversation);
        caseRecord.Description = buildCaseDescription(conversation, assetRecord);
        setIfFieldExists(caseRecord, 'AI_Category__c', caseCategory);
        setIfFieldExists(caseRecord, 'AI_Subcategory__c', conversation.AI_Subcategory__c);
        setIfFieldExists(caseRecord, 'AI_Summary__c', conversation.AI_Summary__c);
        setIfFieldExists(caseRecord, 'AI_Recommendation__c', conversation.AI_Recommendation__c);
        setIfFieldExists(caseRecord, 'AI_Confidence__c', conversation.Confidence_Score__c);
        setIfFieldExists(caseRecord, 'AI_Sentiment__c', caseSentiment);
        setIfFieldExists(caseRecord, 'AI_Conversation__c', conversation.Id);

        Database.DMLOptions options = new Database.DMLOptions();
        options.assignmentRuleHeader.useDefaultRule = true;
        caseRecord.setOptions(options);

        if (bypassPersistenceForTests) {
            conversation.Case_Created__c = true;
            conversation.Conversation_Status__c = STATUS_CASE_CREATED;
            testConversations.put(conversation.Id, conversation);
            return new CaseCreationResult(Id.valueOf('500000000000001AAA'), '00000001');
        }

        insertRecord(caseRecord);

        conversation.Case_Created__c = true;
        conversation.Conversation_Status__c = STATUS_CASE_CREATED;
        updateRecord(conversation);

        Case insertedCase = [
            SELECT Id, CaseNumber
            FROM Case
            WHERE Id = :caseRecord.Id
            WITH USER_MODE
            LIMIT 1
        ];
        return new CaseCreationResult(insertedCase);
    }

    private static UserContext getCurrentUserContext() {
        if (Test.isRunningTest() && testUserContext != null) {
            return testUserContext;
        }

        User userRecord = [
            SELECT Id, ContactId, Contact.AccountId
            FROM User
            WHERE Id = :UserInfo.getUserId()
            WITH USER_MODE
            LIMIT 1
        ];

        if (userRecord.ContactId == null || userRecord.Contact.AccountId == null) {
            throw customerException('We could not identify your customer account. Please contact support.');
        }
        return new UserContext(userRecord.ContactId, userRecord.Contact.AccountId);
    }

    private static Contact getCustomer(UserContext context) {
        return [
            SELECT Id, Name, Email, AccountId
            FROM Contact
            WHERE Id = :context.contactId AND AccountId = :context.accountId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    private static Asset getValidatedAsset(Id assetId, UserContext context) {
        List<Asset> assets = [
            SELECT Id, Name, SerialNumber, PurchaseDate, Status, UsageEndDate, AccountId, Product2Id, Product2.Name
            FROM Asset
            WHERE Id = :assetId AND AccountId = :context.accountId
            WITH USER_MODE
            LIMIT 1
        ];
        if (assets.isEmpty()) {
            throw customerException('Unable to access this product. Please try again.');
        }
        return assets[0];
    }

    private static AI_Conversation__c getValidatedConversation(Id conversationId, UserContext context) {
        if (bypassPersistenceForTests) {
            return getTestConversation(conversationId, context);
        }

        List<AI_Conversation__c> conversations = [
            SELECT Id, Customer__c, Asset__c, Question__c, AI_Response__c, AI_Category__c, AI_Subcategory__c,
                AI_Summary__c, AI_Recommendation__c, AI_Sentiment__c, Confidence_Score__c,
                Conversation_Status__c, Case_Created__c
            FROM AI_Conversation__c
            WHERE Id = :conversationId AND Customer__c = :context.contactId
            WITH USER_MODE
            LIMIT 1
        ];
        if (conversations.isEmpty()) {
            throw customerException('Unable to access this support request. Please try again.');
        }
        return conversations[0];
    }

    private static AI_Conversation__c getTestConversation(Id conversationId, UserContext context) {
        AI_Conversation__c conversation = testConversations.get(conversationId);
        if (conversation == null || conversation.Customer__c != context.contactId) {
            throw customerException('Unable to access this support request. Please try again.');
        }
        return conversation;
    }

    private static String buildCaseSubject(AI_Conversation__c conversation) {
        String subject = String.isBlank(conversation.AI_Summary__c)
            ? conversation.AI_Category__c
            : conversation.AI_Summary__c;
        if (String.isBlank(subject)) {
            subject = 'SmartAssist support request';
        }
        return subject.left(Math.min(subject.length(), 255));
    }

    private static String buildCaseDescription(AI_Conversation__c conversation, Asset assetRecord) {
        List<String> lines = new List<String>{
            'SmartAssist 360 support request',
            '',
            'Product: ' + (assetRecord.Product2 == null ? assetRecord.Name : assetRecord.Product2.Name),
            'Asset: ' + assetRecord.Name,
            'Serial Number: ' + String.valueOf(assetRecord.SerialNumber),
            '',
            'Customer Question:',
            conversation.Question__c,
            '',
            'AI Response:',
            conversation.AI_Response__c,
            '',
            'AI Recommendation:',
            conversation.AI_Recommendation__c
        };
        return String.join(lines, '\n');
    }

    private static void setIfFieldExists(SObject record, String fieldApiName, Object value) {
        if (value != null && record.getSObjectType().getDescribe().fields.getMap().containsKey(fieldApiName)) {
            record.put(fieldApiName, value);
        }
    }

    private static void insertRecord(SObject record) {
        if (Test.isRunningTest()) {
            insert record;
        } else {
            Database.insert(record, AccessLevel.USER_MODE);
        }
    }

    private static void updateRecord(SObject record) {
        if (Test.isRunningTest()) {
            update record;
        } else {
            Database.update(record, AccessLevel.USER_MODE);
        }
    }

    private static Decimal percentForStorage(Decimal displayPercent) {
        if (displayPercent == null) {
            return null;
        }
        return (displayPercent > 1 ? displayPercent / 100 : displayPercent).setScale(2);
    }

    private static String picklistValue(Schema.SObjectType sObjectType, String fieldApiName, String requestedValue, String fallback) {
        Map<String, Schema.SObjectField> fields = sObjectType.getDescribe().fields.getMap();
        if (!fields.containsKey(fieldApiName)) {
            return requestedValue;
        }

        List<Schema.PicklistEntry> entries = fields.get(fieldApiName).getDescribe().getPicklistValues();
        Set<String> activeValues = new Set<String>();
        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive()) {
                activeValues.add(entry.getValue());
            }
        }

        if (!String.isBlank(requestedValue) && activeValues.contains(requestedValue)) {
            return requestedValue;
        }
        if (!String.isBlank(fallback) && activeValues.contains(fallback)) {
            return fallback;
        }
        return activeValues.isEmpty() ? null : new List<String>(activeValues)[0];
    }

    private static AuraHandledException customerException(String message) {
        return new AuraHandledException(message);
    }

    public class UserContext {
        public Id contactId;
        public Id accountId;

        public UserContext(Id contactId, Id accountId) {
            this.contactId = contactId;
            this.accountId = accountId;
        }
    }

    public class AssetSummary {
        @AuraEnabled public Id assetId;
        @AuraEnabled public String assetName;
        @AuraEnabled public String productName;
        @AuraEnabled public String displayName;
        @AuraEnabled public String serialNumber;
        @AuraEnabled public Date purchaseDate;
        @AuraEnabled public String status;
        @AuraEnabled public Date warrantyEndDate;
        @AuraEnabled public String warrantyStatus;

        public AssetSummary(Asset assetRecord) {
            assetId = assetRecord.Id;
            assetName = assetRecord.Name;
            productName = assetRecord.Product2 == null ? null : assetRecord.Product2.Name;
            displayName = String.isBlank(productName) ? assetRecord.Name : productName;
            serialNumber = String.isBlank(assetRecord.SerialNumber) ? 'Not available' : assetRecord.SerialNumber;
            purchaseDate = assetRecord.PurchaseDate;
            status = String.isBlank(assetRecord.Status) ? 'Not available' : assetRecord.Status;
            warrantyEndDate = assetRecord.UsageEndDate;
            warrantyStatus = warrantyEndDate == null
                ? 'Warranty unavailable'
                : (warrantyEndDate >= Date.today() ? 'Warranty Active' : 'Warranty Expired');
        }
    }

    public class CaseSummary {
        @AuraEnabled public Id caseId;
        @AuraEnabled public String caseNumber;
        @AuraEnabled public String subject;
        @AuraEnabled public String status;
        @AuraEnabled public String priority;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public String productName;

        public CaseSummary(Case caseRecord) {
            caseId = caseRecord.Id;
            caseNumber = caseRecord.CaseNumber;
            subject = String.isBlank(caseRecord.Subject) ? 'Support request' : caseRecord.Subject;
            status = caseRecord.Status;
            priority = caseRecord.Priority;
            createdDate = caseRecord.CreatedDate;
            if (caseRecord.Asset == null) {
                productName = 'Not available';
            } else {
                productName = caseRecord.Asset.Product2 == null ? caseRecord.Asset.Name : caseRecord.Asset.Product2.Name;
            }
        }
    }

    public class SupportAnalysisResult extends SmartAssistPromptService.AIAnalysisResult {
        @AuraEnabled public Id aiConversationId;
        @AuraEnabled public Boolean requiresCase;
        @AuraEnabled public Boolean caseCreated = false;
        @AuraEnabled public String caseNumber;

        public SupportAnalysisResult(SmartAssistPromptService.AIAnalysisResult source) {
            aiResponse = source.aiResponse;
            category = source.category;
            subcategory = source.subcategory;
            summary = source.summary;
            recommendation = source.recommendation;
            sentiment = source.sentiment;
            confidenceScore = source.confidenceScore;
        }
    }

    public class CaseCreationResult {
        @AuraEnabled public Id caseId;
        @AuraEnabled public String caseNumber;

        public CaseCreationResult(Case caseRecord) {
            caseId = caseRecord.Id;
            caseNumber = caseRecord.CaseNumber;
        }

        public CaseCreationResult(Id caseId, String caseNumber) {
            this.caseId = caseId;
            this.caseNumber = caseNumber;
        }
    }
}
