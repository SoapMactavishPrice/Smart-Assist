public with sharing class SmartAssistPromptService {
    public static final String PROMPT_TEMPLATE_LABEL = 'SmartAssist 360 - Case Analysis';
    public static final String PROMPT_TEMPLATE_DEVELOPER_NAME = 'SmartAssist_360_Case_Analysis';

    @TestVisible
    static PromptGateway promptGateway = new ConnectApiPromptGateway();

    public static AIAnalysisResult analyze(Asset assetRecord, Contact customer, String question) {
        if (assetRecord == null || customer == null || String.isBlank(question)) {
            throw new SmartAssistPromptException('SmartAssist is temporarily unavailable. Please try again.');
        }

        PromptContext context = new PromptContext(assetRecord, customer, question);
        String promptOutput = promptGateway.generate(context);
        AIAnalysisResult result = parsePromptOutput(promptOutput);
        result.category = valueOrDefault(result.category, 'General Support');
        result.subcategory = valueOrDefault(result.subcategory, 'Product Issue');
        result.summary = valueOrDefault(result.summary, question.left(Math.min(question.length(), 1000)));
        result.recommendation = valueOrDefault(result.recommendation, 'A support specialist should review this request.');
        result.aiResponse = valueOrDefault(result.aiResponse, result.recommendation);
        result.sentiment = valueOrDefault(result.sentiment, 'Neutral');
        result.confidenceScore = normalizeConfidence(result.confidenceScore);
        return result;
    }

    private static AIAnalysisResult parsePromptOutput(String promptOutput) {
        AIAnalysisResult result = new AIAnalysisResult();
        if (String.isBlank(promptOutput)) {
            return result;
        }

        String jsonText = extractJson(promptOutput);
        if (String.isBlank(jsonText)) {
            result.aiResponse = promptOutput;
            return result;
        }

        try {
            Map<String, Object> values = (Map<String, Object>) JSON.deserializeUntyped(jsonText);
            result.category = firstString(values, new List<String>{ 'category', 'AI Category', 'aiCategory', 'AI_Category' });
            result.subcategory = firstString(values, new List<String>{ 'subcategory', 'AI Subcategory', 'aiSubcategory', 'AI_Subcategory' });
            result.summary = firstString(values, new List<String>{ 'summary', 'AI Summary', 'aiSummary', 'AI_Summary' });
            result.recommendation = firstString(values, new List<String>{ 'recommendation', 'AI Recommendation', 'aiRecommendation', 'AI_Recommendation' });
            result.aiResponse = firstString(values, new List<String>{ 'aiResponse', 'AI Response', 'response', 'AI_Response' });
            result.sentiment = firstString(values, new List<String>{ 'sentiment', 'AI Sentiment', 'aiSentiment', 'AI_Sentiment' });
            result.confidenceScore = firstDecimal(values, new List<String>{ 'confidenceScore', 'Confidence Score', 'confidence', 'AI Confidence', 'AI_Confidence' });
        } catch (Exception ex) {
            result.aiResponse = promptOutput;
        }
        return result;
    }

    private static String extractJson(String value) {
        Integer startIndex = value.indexOf('{');
        Integer endIndex = value.lastIndexOf('}');
        if (startIndex < 0 || endIndex <= startIndex) {
            return null;
        }
        return value.substring(startIndex, endIndex + 1);
    }

    private static String firstString(Map<String, Object> values, List<String> keys) {
        for (String key : keys) {
            if (values.containsKey(key) && values.get(key) != null) {
                return String.valueOf(values.get(key));
            }
        }
        return null;
    }

    private static Decimal firstDecimal(Map<String, Object> values, List<String> keys) {
        for (String key : keys) {
            if (values.containsKey(key) && values.get(key) != null) {
                Object rawValue = values.get(key);
                if (rawValue instanceof Decimal) {
                    return (Decimal) rawValue;
                }
                if (rawValue instanceof Integer) {
                    return Decimal.valueOf((Integer) rawValue);
                }
                if (rawValue instanceof Long) {
                    return Decimal.valueOf((Long) rawValue);
                }
                if (rawValue instanceof Double) {
                    return Decimal.valueOf((Double) rawValue);
                }
                String textValue = String.valueOf(rawValue).replace('%', '').trim();
                if (!String.isBlank(textValue)) {
                    return Decimal.valueOf(textValue);
                }
            }
        }
        return 0;
    }

    private static Decimal normalizeConfidence(Decimal value) {
        if (value == null) {
            return 0;
        }
        Decimal normalized = value <= 1 ? value * 100 : value;
        if (normalized < 0) {
            return 0;
        }
        if (normalized > 100) {
            return 100;
        }
        return normalized.setScale(0);
    }

    private static String valueOrDefault(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }

    private static String buildContextText(Asset assetRecord, Contact customer, String question) {
        List<String> lines = new List<String>();
        lines.add('Customer Name: ' + safe(customer.Name));
        lines.add('Customer Email: ' + safe(customer.Email));
        lines.add('Person Account Id: ' + safe(customer.AccountId));
        lines.add('Asset Name: ' + safe(assetRecord.Name));
        lines.add('Product Name: ' + safe(assetRecord.Product2 == null ? null : assetRecord.Product2.Name));
        lines.add('Serial Number: ' + safe(assetRecord.SerialNumber));
        lines.add('Asset Status: ' + safe(assetRecord.Status));
        lines.add('Purchase Date: ' + safeDate(assetRecord.PurchaseDate));
        lines.add('Warranty End Date: ' + safeDate(assetRecord.UsageEndDate));
        lines.add('Customer Question: ' + question);
        return String.join(lines, '\n');
    }

    private static String safe(Object value) {
        return value == null ? 'Not available' : String.valueOf(value);
    }

    private static String safeDate(Date value) {
        return value == null ? 'Not available' : String.valueOf(value);
    }

    public virtual class AIAnalysisResult {
        @AuraEnabled public String aiResponse;
        @AuraEnabled public String category;
        @AuraEnabled public String subcategory;
        @AuraEnabled public String summary;
        @AuraEnabled public String recommendation;
        @AuraEnabled public String sentiment;
        @AuraEnabled public Decimal confidenceScore;
    }

    public class PromptContext {
        public Asset assetRecord;
        public Contact customer;
        public String question;
        public String contextText;

        public PromptContext(Asset assetRecord, Contact customer, String question) {
            this.assetRecord = assetRecord;
            this.customer = customer;
            this.question = question;
            this.contextText = SmartAssistPromptService.buildContextText(assetRecord, customer, question);
        }
    }

    public interface PromptGateway {
        String generate(PromptContext context);
    }

    public class ConnectApiPromptGateway implements PromptGateway {
        public String generate(PromptContext context) {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.isPreview = false;
            input.inputParams = new Map<String, ConnectApi.WrappedValue>();

            ConnectApi.WrappedValue customerQuestionValue = new ConnectApi.WrappedValue();
            customerQuestionValue.value = context.question;

            input.inputParams.put('Input:Customer_Question', customerQuestionValue);

            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.applicationName = 'PromptBuilderPreview';
            input.additionalConfig.numGenerations = 1;
            input.additionalConfig.enablePiiMasking = false;

            if (Test.isRunningTest()) {
                return JSON.serialize(new Map<String, Object>{
                    'category' => 'General Support',
                    'subcategory' => 'Test',
                    'summary' => 'Test prompt invocation.',
                    'recommendation' => 'No action required.',
                    'confidence' => 88
                });
            }

            System.debug('SmartAssist Prompt Input: ' + input);

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PROMPT_TEMPLATE_DEVELOPER_NAME, input);


            System.debug('SmartAssist Prompt Output: ' + output);  
            if (output == null || output.generations == null || output.generations.isEmpty()) {
                throw new SmartAssistPromptException('SmartAssist is temporarily unavailable. Please try again.');
            }
            return output.generations[0].text;
        }
    }

    public class SmartAssistPromptException extends Exception {
    }
}
