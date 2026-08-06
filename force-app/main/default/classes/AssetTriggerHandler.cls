public with sharing class AssetTriggerHandler {

    public static void handleFirstAssetExperienceCloudUserCreation(List<Asset> assets) {

        Set<Id> accountIds = new Set<Id>();
        for (Asset asset : assets) {
            if (asset.AccountId != null) {
                accountIds.add(asset.AccountId);
            }
        }

        if (accountIds.isEmpty()) {
            return;
        }

        Map<Id, Integer> accountsAssetCount = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT AccountId, COUNT(Id) assetCount
            FROM Asset
            WHERE AccountId IN :accountIds
            GROUP BY AccountId
        ]) {
            accountsAssetCount.put((Id) ar.get('AccountId'), (Integer) ar.get('assetCount'));
        }

        Set<Id> firstAssetAccountIds = new Set<Id>();
        for (Id accId : accountsAssetCount.keySet()) {
            if (accountsAssetCount.get(accId) == 1) {
                firstAssetAccountIds.add(accId);
            }
        }

        if (!firstAssetAccountIds.isEmpty()) {
            createExperienceCloudUsersForAccounts(firstAssetAccountIds);
        }
    }

    public static void createExperienceCloudUsersForAccounts(Set<Id> accountIds) {

        Map<Id, Contact> contactByAccountId = new Map<Id, Contact>();
        for (Account acc : [
            SELECT Id,
                   (SELECT Id, FirstName, LastName, Email FROM Contacts LIMIT 1)
            FROM Account
            WHERE Id IN :accountIds
        ]) {
            if (!acc.Contacts.isEmpty() && String.isNotBlank(acc.Contacts[0].Email)) {
                contactByAccountId.put(acc.Id, acc.Contacts[0]);
            }
        }

        if (contactByAccountId.isEmpty()) {
            return;
        }

        Set<Id> contactIds = new Set<Id>();
        for (Contact c : contactByAccountId.values()) {
            contactIds.add(c.Id);
        }

        Set<Id> contactIdsWithUsers = new Set<Id>();
        for (User u : [SELECT ContactId FROM User WHERE ContactId IN :contactIds]) {
            contactIdsWithUsers.add(u.ContactId);
        }

        Profile customerProfile = [
            SELECT Id FROM Profile
            WHERE Name = 'Customer Community Login User'
            LIMIT 1
        ];

        Set<String> desiredUsernames = new Set<String>();
        for (Contact c : contactByAccountId.values()) {
            if (!contactIdsWithUsers.contains(c.Id)) {
                desiredUsernames.add(c.Email);
            }
        }

        Set<String> takenUsernames = new Set<String>();
        if (!desiredUsernames.isEmpty()) {
            for (User u : [SELECT Username FROM User WHERE Username IN :desiredUsernames]) {
                takenUsernames.add(u.Username);
            }
        }

        List<User> newUsers = new List<User>();
        Set<String> usernamesUsedThisRun = new Set<String>();

        for (Id accId : contactByAccountId.keySet()) {
            Contact con = contactByAccountId.get(accId);

            if (contactIdsWithUsers.contains(con.Id)) {
                continue;
            }

            String finalUsername = con.Email;
            if (takenUsernames.contains(finalUsername) || usernamesUsedThisRun.contains(finalUsername)) {
                finalUsername = con.Email.substringBefore('@') + '.' + con.Id +
                                 '@' + con.Email.substringAfter('@');
            }
            usernamesUsedThisRun.add(finalUsername);

            newUsers.add(new User(
                FirstName         = con.FirstName,
                LastName          = con.LastName,
                Email             = con.Email,
                ContactId         = con.Id,
                ProfileId         = customerProfile.Id,
                Username          = finalUsername,
                Alias             = (con.LastName.length() > 6 ? con.LastName.substring(0, 6) : con.LastName),
                TimeZoneSidKey    = 'America/Los_Angeles',
                LocaleSidKey      = 'en_US',
                EmailEncodingKey  = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                IsActive          = true
            ));
        }

        if (newUsers.isEmpty()) {
            return;
        }

        List<Database.SaveResult> results = Database.insert(newUsers, false);

        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                try {
                    System.resetPassword(results[i].getId(), true);
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR,
                        'User created but invite email failed for User ' +
                        results[i].getId() + ': ' + e.getMessage());
                }
            } else {
                for (Database.Error err : results[i].getErrors()) {
                    System.debug(LoggingLevel.ERROR,
                        'Failed to create Experience Cloud user for Account ' +
                        newUsers[i].AccountId + ': ' + err.getMessage());
                }
            }
        }
    }
}