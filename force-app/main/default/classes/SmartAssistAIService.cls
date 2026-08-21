/**
 * SmartAssistAIService
 *
 * Reusable service responsible for invoking the SmartAssist 360 Prompt Builder
 * template ("SmartAssist360_Case_Analysis") and normalizing its output into a
 * structured, customer-safe result.
 *
 * This class intentionally contains NO security/ownership checks and NO DML -
 * those responsibilities live in SmartAssistSupportController. Keeping AI
 * invocation isolated here lets it be reused by other entry points (e.g. a
 * Flow-invoked context, batch re-analysis, etc.) without duplicating logic.
 */
public with sharing class SmartAssistAIService {

    // Name of the Prompt Builder template configured in Setup > Prompt Builder.
    // Must match the developer name of the deployed Prompt Template exactly.
    private static final String PROMPT_TEMPLATE_API_NAME = 'SmartAssist360_Case_Analysis';

    private static final Decimal DEFAULT_CONFIDENCE = 0;

    public class AIServiceException extends Exception {}

    /**
     * Structured, parsed result of a Prompt Builder invocation.
     */
    public class AIAnalysisResult {
        @AuraEnabled public String rawResponseText;
        @AuraEnabled public String category;
        @AuraEnabled public String subcategory;
        @AuraEnabled public String summary;
        @AuraEnabled public String recommendation;
        @AuraEnabled public Decimal confidenceScore;
    }

    /**
     * Input context passed to the prompt. Kept as a simple wrapper so the
     * caller (controller) doesn't need to know about Prompt Builder's
     * input-parameter naming conventions.
     */
    public class AIRequestContext {
        public String customerQuestion;
        public String productName;
        public String assetName;
        public String serialNumber;
        public String assetStatus;
        public String warrantyInfo;
        public String customerName;
    }

    /**
     * Invokes the SmartAssist360_Case_Analysis Prompt Builder template with the
     * supplied context and returns a parsed, structured result.
     *
     * @throws AIServiceException when the prompt invocation fails or the
     *         response cannot be interpreted. Callers are responsible for
     *         translating this into a customer-friendly message.
     */
    public static AIAnalysisResult analyze(AIRequestContext context) {
        if (context == null || String.isBlank(context.customerQuestion)) {
            throw new AIServiceException('A customer question is required for AI analysis.');
        }

        String generatedText;

        try {
            generatedText = invokePromptTemplate(context);
        } catch (AIServiceException ase) {
            throw ase;
        } catch (Exception ex) {
            // Never leak raw platform/API exception details to callers/customers.
            throw new AIServiceException('The AI service is currently unavailable.');
        }

        if (String.isBlank(generatedText)) {
            throw new AIServiceException('The AI service did not return a response.');
        }

        return parseModelResponse(generatedText);
    }

    /**
     * Calls the Prompt Builder template via ConnectApi and returns the raw
     * generated text. Isolated into its own method so the ConnectApi surface
     * area (which can evolve between platform releases) is easy to locate
     * and update in one place.
     */
    private static String invokePromptTemplate(AIRequestContext context) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:CustomerQuestion', wrap(context.customerQuestion));
        inputParams.put('Input:ProductName', wrap(context.productName));
        inputParams.put('Input:AssetName', wrap(context.assetName));
        inputParams.put('Input:SerialNumber', wrap(context.serialNumber));
        inputParams.put('Input:AssetStatus', wrap(context.assetStatus));
        inputParams.put('Input:WarrantyInfo', wrap(context.warrantyInfo));
        inputParams.put('Input:CustomerName', wrap(context.customerName));
        input.inputParams = inputParams;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
            ConnectApi.EinsteinLlm.generateMessagesForPromptTemplate(PROMPT_TEMPLATE_API_NAME, input);

        if (output == null || output.generations == null || output.generations.isEmpty()) {
            throw new AIServiceException('The AI service did not return a response.');
        }

        return output.generations[0].text;
    }

    private static ConnectApi.WrappedValue wrap(String value) {
        ConnectApi.WrappedValue wrapped = new ConnectApi.WrappedValue();
        wrapped.value = String.isBlank(value) ? '' : value;
        return wrapped;
    }

    /**
     * Parses the model's generated text into a structured result.
     *
     * The Prompt Template is expected to be configured to return a JSON object
     * with the shape:
     * {
     *   "responseText": "...",
     *   "category": "...",
     *   "subcategory": "...",
     *   "summary": "...",
     *   "recommendation": "...",
     *   "confidenceScore": 92
     * }
     *
     * If the response cannot be parsed as JSON (e.g. the template was
     * configured to return plain text), we degrade gracefully: the full text
     * is used as the response and a conservative default confidence is
     * applied so the low-confidence workflow (human follow-up) is triggered
     * rather than silently over-trusting an unparseable response.
     */
    private static AIAnalysisResult parseModelResponse(String generatedText) {
        AIAnalysisResult result = new AIAnalysisResult();

        String jsonCandidate = extractJsonObject(generatedText);

        if (jsonCandidate != null) {
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonCandidate);

                result.rawResponseText = coalesceString(parsed.get('responseText'), generatedText);
                result.category = coalesceString(parsed.get('category'), 'General');
                result.subcategory = coalesceString(parsed.get('subcategory'), 'Uncategorized');
                result.summary = coalesceString(parsed.get('summary'), '');
                result.recommendation = coalesceString(parsed.get('recommendation'), '');
                result.confidenceScore = coalesceConfidence(parsed.get('confidenceScore'));
                return result;
            } catch (Exception parseEx) {
                // Fall through to plain-text handling below.
            }
        }

        // Plain-text fallback: treat the entire response as the answer and
        // route to the low-confidence (human follow-up) workflow.
        result.rawResponseText = generatedText;
        result.category = 'General';
        result.subcategory = 'Uncategorized';
        result.summary = generatedText.length() > 240 ? generatedText.substring(0, 240) + '...' : generatedText;
        result.recommendation = 'A member of our support team will review your request.';
        result.confidenceScore = DEFAULT_CONFIDENCE;
        return result;
    }

    /**
     * Best-effort extraction of a JSON object from model output, in case the
     * model wraps the JSON in markdown code fences or surrounding prose.
     */
    private static String extractJsonObject(String text) {
        if (String.isBlank(text)) {
            return null;
        }
        Integer start = text.indexOf('{');
        Integer endInteger = text.lastIndexOf('}');
        if (start == -1 || endInteger == -1 || endInteger < start) {
            return null;
        }
        return text.substring(start, endInteger + 1);
    }

    private static String coalesceString(Object value, String fallback) {
        if (value == null) {
            return fallback;
        }
        String stringValue = String.valueOf(value).trim();
        return String.isBlank(stringValue) ? fallback : stringValue;
    }

    private static Decimal coalesceConfidence(Object value) {
        if (value == null) {
            return DEFAULT_CONFIDENCE;
        }
        try {
            Decimal confidence = Decimal.valueOf(String.valueOf(value));
            // Normalize a 0-1 fractional confidence (e.g. 0.92) to a percentage.
            if (confidence > 0 && confidence <= 1) {
                confidence = confidence * 100;
            }
            if (confidence < 0) {
                confidence = 0;
            }
            if (confidence > 100) {
                confidence = 100;
            }
            return confidence.setScale(2);
        } catch (Exception e) {
            return DEFAULT_CONFIDENCE;
        }
    }
}