trigger AssetTrigger on Asset (after insert) {
    if (Trigger.isAfter && Trigger.isInsert) {
        AssetTriggerHandler.handleFirstAssetExperienceCloudUserCreation(Trigger.new);
    }
}