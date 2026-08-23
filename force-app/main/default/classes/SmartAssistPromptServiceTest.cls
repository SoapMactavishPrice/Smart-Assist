@IsTest
private class SmartAssistPromptServiceTest {
    @IsTest
    static void parsesJsonPromptResponse() {
        Account accountRecord = new Account(Name = 'SmartHome Customer');
        insert accountRecord;
        Contact contactRecord = new Contact(LastName = 'Customer', Email = 'customer@example.com', AccountId = accountRecord.Id);
        insert contactRecord;
        Product2 productRecord = new Product2(Name = 'Smart Door Lock Pro X', IsActive = true);
        insert productRecord;
        Asset assetRecord = new Asset(
            Name = 'Door Lock Asset',
            AccountId = accountRecord.Id,
            Product2Id = productRecord.Id,
            SerialNumber = 'SDL-10001',
            PurchaseDate = Date.today().addDays(-10),
            UsageEndDate = Date.today().addYears(1),
            Status = 'Purchased'
        );
        insert assetRecord;
        assetRecord = [
            SELECT Id, Name, SerialNumber, PurchaseDate, Status, UsageEndDate, Product2.Name
            FROM Asset
            WHERE Id = :assetRecord.Id
        ];

        SmartAssistPromptService.promptGateway = new MockPromptGateway(92);

        SmartAssistPromptService.AIAnalysisResult result =
            SmartAssistPromptService.analyze(assetRecord, contactRecord, 'The keypad stopped responding.');

        System.assertEquals('Connectivity', result.category);
        System.assertEquals('Keypad offline', result.subcategory);
        System.assertEquals('Positive', result.sentiment);
        System.assertEquals(92, result.confidenceScore);
        System.assert(result.aiResponse.contains('restart'));
    }

    @IsTest
    static void connectApiGatewayBuildsSupportedTestResponse() {
        Account accountRecord = new Account(Name = 'Gateway Customer');
        insert accountRecord;
        Contact contactRecord = new Contact(LastName = 'Gateway', Email = 'gateway@example.com', AccountId = accountRecord.Id);
        insert contactRecord;
        Product2 productRecord = new Product2(Name = 'Smart Thermostat Pro', IsActive = true);
        insert productRecord;
        Asset assetRecord = new Asset(
            Name = 'Thermostat Asset',
            AccountId = accountRecord.Id,
            Product2Id = productRecord.Id,
            SerialNumber = 'STP-20001'
        );
        insert assetRecord;
        assetRecord = [
            SELECT Id, Name, SerialNumber, PurchaseDate, Status, UsageEndDate, Product2.Name
            FROM Asset
            WHERE Id = :assetRecord.Id
        ];

        SmartAssistPromptService.promptGateway = new SmartAssistPromptService.ConnectApiPromptGateway();

        SmartAssistPromptService.AIAnalysisResult result =
            SmartAssistPromptService.analyze(assetRecord, contactRecord, 'Temperature is not changing.');

        System.assertEquals('General Support', result.category);
        System.assertEquals(88, result.confidenceScore);
    }

    private class MockPromptGateway implements SmartAssistPromptService.PromptGateway {
        private Decimal confidence;

        MockPromptGateway(Decimal confidence) {
            this.confidence = confidence;
        }

        public String generate(SmartAssistPromptService.PromptContext context) {
            System.assert(context.contextText.contains('Smart Door Lock Pro X'));
            return JSON.serialize(new Map<String, Object>{
                'aiResponse' => 'Please restart the hub and re-pair the keypad.',
                'category' => 'Connectivity',
                'subcategory' => 'Keypad offline',
                'summary' => 'Door lock keypad is not responding.',
                'recommendation' => 'Restart hub and re-pair.',
                'sentiment' => 'Positive',
                'confidenceScore' => confidence
            });
        }
    }
}
