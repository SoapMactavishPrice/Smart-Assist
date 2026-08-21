/**
 * SmartAssistSupportController
 *
 * @AuraEnabled entry points for the smartAssistSupport LWC.
 *
 * Responsibilities (per SmartAssist 360 architecture):
 *   - Enforce customer-level security (a customer may only see/act on their
 *     own Assets, AI Conversations, and Cases).
 *   - Validate that the Asset supplied by the browser actually belongs to the
 *     logged-in customer before doing anything with it.
 *   - Invoke SmartAssistAIService (Prompt Builder) and persist the result to
 *     AI_Conversation__c.
 *   - Create Case records per the SmartAssist 360 workflow when required.
 *   - Never leak technical/Apex error detail to the client - all client-facing
 *     exceptions are AuraHandledException with a friendly message.
 *
 * This class is deliberately "thin on UI concerns" - the LWC owns all
 * presentation state. This class owns all business rules and data access.
 */
public with sharing class SmartAssistSupportController {

    private static final String GENERIC_ERROR =
        'We were unable to complete your request. Please try again, or contact support if the problem continues.';

    private static final Decimal CONFIDENCE_THRESHOLD = 85;

    // ====================================================================
    // Wrapper types
    // ====================================================================

    public class AssetContextWrapper {
        @AuraEnabled public Id assetId;
        @AuraEnabled public String productName;
        @AuraEnabled public String assetName;
        @AuraEnabled public String serialNumber;
        @AuraEnabled public Date purchaseDate;
        @AuraEnabled public String status;
        @AuraEnabled public String warrantyInfo;
    }

    public class AIResponseWrapper {
        @AuraEnabled public Id conversationId;
        @AuraEnabled public String aiResponse;
        @AuraEnabled public String category;
        @AuraEnabled public String subcategory;
        @AuraEnabled public String summary;
        @AuraEnabled public String recommendation;
        @AuraEnabled public Decimal confidenceScore;
    }

    public class CaseResultWrapper {
        @AuraEnabled public Id caseId;
        @AuraEnabled public String caseNumber;
    }

    public class AssetSummaryWrapper {
        @AuraEnabled public Id assetId;
        @AuraEnabled public String assetName;
        @AuraEnabled public String productName;
    }

    // ====================================================================
    // Public entry points
    // ====================================================================

    /**
     * Returns display-safe context for the selected Asset after verifying the
     * Asset belongs to the logged-in customer.
     */
    @AuraEnabled(cacheable=true)
    public static AssetContextWrapper getAssetContext(Id assetId) {
        try {
            Asset assetRecord = getOwnedAssetOrThrow(assetId);
            return toAssetContextWrapper(assetRecord);
        } catch (SecurityException se) {
            throw newFriendlyException('We could not find that product on your account.');
        } catch (Exception e) {
            throw logAndBuildAuraException(e);
        }
    }

    /**
     * Returns full display context for every Asset legitimately owned by the
     * logged-in customer (resolved server-side from User -> Contact ->
     * Account). This backs the My Products page, which is where Asset
     * selection is actually meant to happen per the SmartAssist 360
     * workflow.
     */
    @AuraEnabled(cacheable=true)
    public static List<AssetContextWrapper> getMyProducts() {
        try {
            Contact currentContact = getCurrentContactOrThrow();
            List<Asset> ownedAssets = queryOwnedAssets(currentContact);

            List<AssetContextWrapper> results = new List<AssetContextWrapper>();
            for (Asset a : ownedAssets) {
                results.add(toAssetContextWrapper(a));
            }
            return results;
        } catch (SecurityException se) {
            throw newFriendlyException('We could not verify your account.');
        } catch (Exception e) {
            throw logAndBuildAuraException(e);
        }
    }

    /**
     * Lightweight summary version of getMyProducts(), used only as a safe
     * fallback by the Support page for the rare case where it's reached
     * without an assetId already having been supplied by My Products (e.g. a
     * bookmarked/refreshed URL) - it is NOT used to let the customer pick an
     * arbitrary Asset within the Support component itself. When exactly one
     * Asset is owned, the Support LWC auto-resolves it; when zero or
     * multiple are owned, it directs the customer back to My Products.
     */
    @AuraEnabled(cacheable=true)
    public static List<AssetSummaryWrapper> getMyAssets() {
        try {
            Contact currentContact = getCurrentContactOrThrow();
            List<Asset> ownedAssets = queryOwnedAssets(currentContact);

            List<AssetSummaryWrapper> summaries = new List<AssetSummaryWrapper>();
            for (Asset a : ownedAssets) {
                AssetSummaryWrapper summary = new AssetSummaryWrapper();
                summary.assetId = a.Id;
                summary.assetName = a.Name;
                summary.productName = a.Product2 != null ? a.Product2.Name : a.Name;
                summaries.add(summary);
            }
            return summaries;
        } catch (SecurityException se) {
            throw newFriendlyException('We could not verify your account.');
        } catch (Exception e) {
            throw logAndBuildAuraException(e);
        }
    }

    /**
     * Submits the customer's question for AI analysis and persists the
     * resulting AI_Conversation__c record.
     */
    @AuraEnabled
    public static AIResponseWrapper askSmartAssist(Id assetId, String question) {
        if (String.isBlank(question)) {
            throw newFriendlyException('Please describe your issue before submitting.');
        }

        try {
            Asset assetRecord = getOwnedAssetOrThrow(assetId);
            Contact currentContact = getCurrentContactOrThrow();

            SmartAssistAIService.AIRequestContext requestContext = new SmartAssistAIService.AIRequestContext();
            requestContext.customerQuestion = question.trim();
            requestContext.productName = assetRecord.Product2 != null ? assetRecord.Product2.Name : assetRecord.Name;
            requestContext.assetName = assetRecord.Name;
            requestContext.serialNumber = assetRecord.SerialNumber;
            requestContext.assetStatus = assetRecord.Status;
            requestContext.warrantyInfo = buildWarrantyInfo(assetRecord);
            requestContext.customerName = currentContact.Name;

            SmartAssistAIService.AIAnalysisResult aiResult = SmartAssistAIService.analyze(requestContext);

            AI_Conversation__c conversation = new AI_Conversation__c(
                Account__c = assetRecord.AccountId,
                Contact__c = currentContact.Id,
                Asset__c = assetRecord.Id,
                Question__c = requestContext.customerQuestion,
                AI_Response__c = aiResult.rawResponseText,
                AI_Category__c = aiResult.category,
                AI_Subcategory__c = aiResult.subcategory,
                AI_Summary__c = aiResult.summary,
                AI_Recommendation__c = aiResult.recommendation,
                Confidence_Score__c = aiResult.confidenceScore,
                Conversation_Status__c = 'New',
                Case_Created__c = false
            );

            insertWithFlsCheck(conversation);

            AIResponseWrapper response = new AIResponseWrapper();
            response.conversationId = conversation.Id;
            response.aiResponse = aiResult.rawResponseText;
            response.category = aiResult.category;
            response.subcategory = aiResult.subcategory;
            response.summary = aiResult.summary;
            response.recommendation = aiResult.recommendation;
            response.confidenceScore = aiResult.confidenceScore;
            return response;

        } catch (SmartAssistAIService.AIServiceException aiEx) {
            throw newFriendlyException('SmartAssist is temporarily unavailable. Please try again shortly.');
        } catch (SecurityException se) {
            throw newFriendlyException('We could not find that product on your account.');
        } catch (Exception e) {
            throw logAndBuildAuraException(e);
        }
    }

    /**
     * Customer confirmed the AI answer solved their issue. Marks the
     * conversation Resolved and does NOT create a Case.
     */
    @AuraEnabled
    public static void markConversationResolved(Id conversationId) {
        try {
            AI_Conversation__c conversation = getOwnedConversationOrThrow(conversationId);
            conversation.Conversation_Status__c = 'Resolved';
            updateWithFlsCheck(conversation);
        } catch (SecurityException se) {
            throw newFriendlyException('We could not find that conversation on your account.');
        } catch (Exception e) {
            throw logAndBuildAuraException(e);
        }
    }

    /**
     * Customer declined to create a Case after saying the AI answer did not
     * solve their issue. Marks the conversation resolved without a Case.
     */
    @AuraEnabled
    public static void markConversationResolvedNoCase(Id conversationId) {
        try {
            AI_Conversation__c conversation = getOwnedConversationOrThrow(conversationId);
            conversation.Conversation_Status__c = 'Resolved';
            updateWithFlsCheck(conversation);
        } catch (SecurityException se) {
            throw newFriendlyException('We could not find that conversation on your account.');
        } catch (Exception e) {
            throw logAndBuildAuraException(e);
        }
    }

    /**
     * Creates a support Case from an AI Conversation, either because the
     * customer asked for one or because AI confidence was below threshold.
     * Queue/assignment is left entirely to existing Salesforce automation -
     * no Queue/Profile/RecordType Ids are set here.
     */
    @AuraEnabled
    public static CaseResultWrapper createSupportCase(Id conversationId) {
        try {
            AI_Conversation__c conversation = getOwnedConversationOrThrow(conversationId);

            if (conversation.Case_Created__c) {
                throw newFriendlyException('A support case has already been created for this conversation.');
            }

            Asset assetRecord = getOwnedAssetOrThrow(conversation.Asset__c);

            if (!Schema.sObjectType.Case.isCreateable()) {
                throw newFriendlyException(GENERIC_ERROR);
            }

            Case newCase = new Case(
                AccountId = assetRecord.AccountId,
                ContactId = conversation.Contact__c,
                AssetId = assetRecord.Id,
                Subject = buildCaseSubject(conversation),
                Description = buildCaseDescription(conversation)
            );
            assignFieldIfExists(newCase, 'AI_Category__c', conversation.AI_Category__c);
            assignFieldIfExists(newCase, 'AI_Subcategory__c', conversation.AI_Subcategory__c);
            assignFieldIfExists(newCase, 'AI_Summary__c', conversation.AI_Summary__c);
            assignFieldIfExists(newCase, 'AI_Recommendation__c', conversation.AI_Recommendation__c);
            assignFieldIfExists(newCase, 'AI_Confidence__c', conversation.Confidence_Score__c);
            assignFieldIfExists(newCase, 'AI_Conversation__c', conversation.Id);

            insert newCase;

            conversation.Case_Created__c = true;
            conversation.Conversation_Status__c = 'Case Created';
            updateWithFlsCheck(conversation);

            Case insertedCase = [
                SELECT Id, CaseNumber
                FROM Case
                WHERE Id = :newCase.Id
                WITH USER_MODE
                LIMIT 1
            ];

            CaseResultWrapper result = new CaseResultWrapper();
            result.caseId = insertedCase.Id;
            result.caseNumber = insertedCase.CaseNumber;
            return result;

        } catch (SecurityException se) {
            throw newFriendlyException('We could not find that conversation on your account.');
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw logAndBuildAuraException(e);
        }
    }

    // ====================================================================
    // Ownership / security helpers
    // ====================================================================

    /**
     * Resolves the Contact record for the currently logged-in Experience
     * Cloud (Person Account) user. Throws if the current user has no
     * associated Contact - this should never happen for a properly
     * provisioned community user, but we never assume.
     */
    private static Contact getCurrentContactOrThrow() {
        Id contactId = UserInfo.getUserId() != null ? [SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId()].ContactId : null;

        if (contactId == null) {
            throw new SecurityException('No associated customer contact for current user.');
        }

        List<Contact> contacts = [
            SELECT Id, Name, AccountId
            FROM Contact
            WHERE Id = :contactId
            WITH USER_MODE
            LIMIT 1
        ];

        if (contacts.isEmpty()) {
            throw new SecurityException('No associated customer contact for current user.');
        }
        return contacts[0];
    }

    /**
     * Returns every Asset owned (directly or via Account) by the given
     * Contact, with the fields needed for both the My Products list and the
     * Support page's single-Asset context. Shared by getMyProducts(),
     * getMyAssets(), and (by filtering to one Id) getOwnedAssetOrThrow().
     */
    private static List<Asset> queryOwnedAssets(Contact currentContact) {
        return [
            SELECT Id, Name, SerialNumber, PurchaseDate, Status, AccountId, ContactId,
                   Product2.Name, LifecycleStartDate, LifecycleEndDate
            FROM Asset
            WHERE ContactId = :currentContact.Id
               OR AccountId = :currentContact.AccountId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];
    }

    /**
     * Loads the requested Asset only if it is owned (directly or via Account)
     * by the currently logged-in customer. Never trusts the Asset Id supplied
     * by the browser beyond using it as a WHERE clause filter combined with
     * an ownership predicate.
     */
    private static Asset getOwnedAssetOrThrow(Id assetId) {
        if (assetId == null) {
            throw new SecurityException('No product was specified.');
        }

        Contact currentContact = getCurrentContactOrThrow();

        List<Asset> assets = [
            SELECT Id, Name, SerialNumber, PurchaseDate, Status, AccountId, ContactId,
                   Product2.Name, LifecycleStartDate, LifecycleEndDate
            FROM Asset
            WHERE Id = :assetId
              AND (ContactId = :currentContact.Id OR AccountId = :currentContact.AccountId)
            WITH USER_MODE
            LIMIT 1
        ];

        if (assets.isEmpty()) {
            throw new SecurityException('Asset not found or not owned by current user.');
        }
        return assets[0];
    }

    /**
     * Loads the requested AI_Conversation__c only if it belongs to the
     * currently logged-in customer's Contact/Account.
     */
    private static AI_Conversation__c getOwnedConversationOrThrow(Id conversationId) {
        if (conversationId == null) {
            throw new SecurityException('No conversation was specified.');
        }

        Contact currentContact = getCurrentContactOrThrow();

        List<AI_Conversation__c> conversations = [
            SELECT Id, Account__c, Contact__c, Asset__c, Conversation_Status__c,
                   AI_Category__c, AI_Subcategory__c, AI_Summary__c, AI_Recommendation__c,
                   Confidence_Score__c, Resolved_By_AI__c, Case_Created__c
            FROM AI_Conversation__c
            WHERE Id = :conversationId
              AND (Contact__c = :currentContact.Id OR Account__c = :currentContact.AccountId)
            WITH USER_MODE
            LIMIT 1
        ];

        if (conversations.isEmpty()) {
            throw new SecurityException('Conversation not found or not owned by current user.');
        }
        return conversations[0];
    }

    // ====================================================================
    // DML helpers (FLS-aware)
    // ====================================================================

    private static void insertWithFlsCheck(SObject record) {
        SObjectAccessDecision decision = Security.stripInaccessible(AccessType.CREATABLE, new List<SObject>{ record });
        List<SObject> sanitized = decision.getRecords();
        insert sanitized;
        record.Id = sanitized[0].Id;
    }

    private static void updateWithFlsCheck(SObject record) {
        SObjectAccessDecision decision = Security.stripInaccessible(AccessType.UPDATABLE, new List<SObject>{ record });
        update decision.getRecords();
    }

    /**
     * Defensively assigns a Case field only if it exists on the org's Case
     * schema, so this controller works whether or not optional AI fields on
     * Case have been deployed. Falls back to appending into Description when
     * a dedicated field is not present.
     */
    private static void assignFieldIfExists(Case caseRecord, String fieldName, Object value) {
        if (value == null) {
            return;
        }
        Map<String, Schema.SObjectField> caseFields = Schema.SObjectType.Case.fields.getMap();
        if (caseFields.containsKey(fieldName) && caseFields.get(fieldName).getDescribe().isCreateable()) {
            caseRecord.put(fieldName, value);
        }
    }

    // ====================================================================
    // Formatting helpers
    // ====================================================================

    private static AssetContextWrapper toAssetContextWrapper(Asset assetRecord) {
        AssetContextWrapper wrapper = new AssetContextWrapper();
        wrapper.assetId = assetRecord.Id;
        wrapper.productName = assetRecord.Product2 != null ? assetRecord.Product2.Name : assetRecord.Name;
        wrapper.assetName = assetRecord.Name;
        wrapper.serialNumber = assetRecord.SerialNumber;
        wrapper.purchaseDate = assetRecord.PurchaseDate;
        wrapper.status = assetRecord.Status;
        wrapper.warrantyInfo = buildWarrantyInfo(assetRecord);
        return wrapper;
    }

    private static String buildWarrantyInfo(Asset assetRecord) {
        if (assetRecord.LifecycleEndDate == null) {
            return null;
        }
        Boolean isUnderWarranty = assetRecord.LifecycleEndDate >= Date.today();
        String status = isUnderWarranty ? 'Under warranty' : 'Warranty expired';
        return status + ' (through ' + assetRecord.LifecycleEndDate.format() + ')';
    }

    private static String buildCaseSubject(AI_Conversation__c conversation) {
        String category = String.isNotBlank(conversation.AI_Category__c) ? conversation.AI_Category__c : 'Support Request';
        return 'SmartAssist: ' + category;
    }

    private static String buildCaseDescription(AI_Conversation__c conversation) {
        String summary = String.isNotBlank(conversation.AI_Summary__c) ? conversation.AI_Summary__c : '';
        String recommendation = String.isNotBlank(conversation.AI_Recommendation__c) ? conversation.AI_Recommendation__c : '';
        return 'AI Summary: ' + summary + '\n\nAI Recommendation: ' + recommendation;
    }

    // ====================================================================
    // Error handling
    // ====================================================================

    private static AuraHandledException logAndBuildAuraException(Exception e) {
        // In production, integrate with your org's logging framework here
        // (e.g. a Platform Event or custom log object). Stack traces and raw
        // exception messages are intentionally never returned to the client.
        System.debug(LoggingLevel.ERROR, 'SmartAssistSupportController error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        return newFriendlyException(GENERIC_ERROR);
    }

    /**
     * AuraHandledException requires setMessage() to be called explicitly -
     * the constructor argument alone is not reliably surfaced to the client.
     * All customer-facing exceptions are built through this helper so that
     * quirk only has to be handled in one place.
     */
    private static AuraHandledException newFriendlyException(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}