/**
 * Created by victorviorstov on 15.02.22.
 */

public without sharing class RegistrationFormController {

    private static final Map<String, String> b2bMap = getCSMap(B2B_Settings__c.getAll().values());
    @TestVisible
    private static final Id PROFILE_ID = [SELECT Id FROM Profile WHERE Name = :b2bMap.get('Community Profile Name')]?.Id;
    @TestVisible
    private static final Id PS_ID = [SELECT Id FROM PermissionSetGroup WHERE DeveloperName = :b2bMap.get('Community Permission Set')]?.Id;
    @TestVisible
    private static final Id ACCOUNT_CUSTOMER_RT_ID = Schema.SObjectType.Account.getRecordTypeInfosByName().get(b2bMap.get('Account Customer RT Name')).getRecordTypeId();
    @TestVisible
    private static final Id BUYER_GROUP_ID = [SELECT Id FROM BuyerGroup WHERE Name =: b2bMap.get('Buyer Group Name') LIMIT 1]?.Id; //TODO add where condition by name

    //Main logic
    /*
    1) check for existing user
    2) if user exist: get user.Id and user.AccountId
    3) check for existing account
    4) if account exist: get account.Id
    5) check for existing contact
    6) if contact exist: get contact.Id, contact.AccountId, get user.Id by querying Users with condition: user.contactId =: contact.Id
    7) create account if account Id equals null
    8) create contact if contact Id equals null
    9) check for existing assigment an account to a buyer group
    10) create buyer group member if assigment does not exist
    11) check for existing contact point address for both account addresses
    12) create contact point address for each missing address (shipping, billing) for an account
    13) create user if user.Id equals null
    14) check for existing permission set assigment for a user
    15) create permission set assigment if does not exist
    */

    @AuraEnabled
    public static Map<String, Id> prepareForUserCreation(String userDataJSON) {

        try {
            Map<String, Id> objectIdMap = new Map<String, Id>();
            RegistrationFormController.UserData ud = (RegistrationFormController.UserData) JSON.deserialize(userDataJSON, RegistrationFormController.UserData.class);

            objectIdMap = putToMap(objectIdMap, checkForUser(ud.email));
            objectIdMap = putToMap(objectIdMap, checkForAccount(ud.customerNumber));
            objectIdMap = putToMap(objectIdMap, checkForContact(ud.email, ud.firstName, ud.lastName));
            if (!objectIdMap.containsKey('Account')) {
                objectIdMap.put('Account', createAccount(ud));
            }
            objectIdMap = putToMap(objectIdMap, checkForBuyerAccount(objectIdMap.get('Account')));
            if (!objectIdMap.containsKey('BuyerAccount')) {
                objectIdMap.put('BuyerAccount', createBuyerAccount(ud, objectIdMap.get('Account')));
            }
            if (!objectIdMap.containsKey('Contact')) {
                objectIdMap.put('Contact', createContact(ud, objectIdMap.get('Account')));
            }
            objectIdMap = putToMap(objectIdMap, checkForBuyerGroupMember(objectIdMap.get('Account')));
            if (!objectIdMap.containsKey('BuyerGroupMember')) {
                objectIdMap.put('BuyerGroupMember', createBuyerGroupMember(ud, objectIdMap.get('Account')));
            }
            objectIdMap = putToMap(objectIdMap, checkForContactPointAddress(ud, objectIdMap.get('Account')));
            if (!objectIdMap.containsKey('ContactPointAccessBilling')) {
                objectIdMap.put('ContactPointAccessBilling', createContactPointAddress(ud, objectIdMap.get('Account'), true));
            }
            if (!objectIdMap.containsKey('ContactPointAccessShipping')) {
                objectIdMap.put('ContactPointAccessShipping', createContactPointAddress(ud, objectIdMap.get('Account'), false));
            }
            return objectIdMap;
        } catch (Exception e) {
            System.debug(e.getMessage());
            System.debug(e.getStackTraceString());
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void registerUser(String userDataJSON, Map<String, Id> objectIdMap) {

        try {
            RegistrationFormController.UserData ud = (RegistrationFormController.UserData) JSON.deserialize(userDataJSON, RegistrationFormController.UserData.class);
            User u;
            if (objectIdMap.containsKey('User') && String.isNotBlank(objectIdMap.get('User'))) {
                u = new User(
                        Id = objectIdMap.get('User')
                );
            } else {
                u = new User(
                        LastName = ud.lastName,
                        FirstName = ud.firstName,
                        Email = ud.email,
                        ContactId = objectIdMap.get('Contact'),
                        TimeZoneSidKey = b2bMap.get('User Time Zone'),
                        LanguageLocaleKey = 'en_US',
                        EmailEncodingKey = 'UTF-8',
                        LocaleSidKey = 'en_US'
                );
                checkUserFields(u);
                insert u;
            }
            if (!checkForPermissionSetAssigment(u.Id)) {
                createPermissionSetGroupAssignmentsForUsers(u.Id);
            }
        } catch (Exception e) {
            System.debug('e.getMessage(): ' + e);
            System.debug('e.getMessage(): ' + e.getStackTraceString());
            throw new AuraHandledException(e.getMessage());
        }
    }

    //check for existing records
    private static Map<String, Id> checkForUser(String email) {

        Map<String, Id> objectIdMap;
        if (String.isNotBlank(email)) {
            for (User u: [SELECT Id, AccountId FROM User WHERE (Email =: email OR Username =: email) AND AccountId != null LIMIT 1]) {
                objectIdMap = new Map<String, Id>{'User' => u.Id};
                if (String.isNotBlank(u.AccountId)) {
                    objectIdMap.put('Account', u.AccountId);
                }
            }
        }
        return objectIdMap;
    }

    private static Map<String, Id> checkForAccount(String customerNumber) {

        Map<String, Id> objectIdMap;
        if (String.isNotBlank(customerNumber)) {
            for (Account a: [SELECT Id FROM Account WHERE ParentID =: customerNumber LIMIT 1]) {
                objectIdMap = new Map<String, Id>{'Account' => a.Id};
            }
        }
        return objectIdMap;
    }

    private static Map<String, Id> checkForBuyerAccount(String accountId) {

        Map<String, Id> objectIdMap;
        if (String.isNotBlank(accountId)) {
            for (BuyerAccount ba: [SELECT Id FROM BuyerAccount WHERE BuyerId =: accountId LIMIT 1]) {
                objectIdMap = new Map<String, Id>{'BuyerAccount' => ba.Id};
            }
        }
        return objectIdMap;
    }

    private static Map<String, Id> checkForContact(String email, String firstName, String lastName) {

        Map<String, Id> objectIdMap;
        if (
                String.isNotBlank(email) || 
                (String.isNotBlank(firstName) || String.isNotBlank(lastName))
        ) {
            for (Contact c: [SELECT Id, AccountId FROM Contact WHERE Email =: email OR (LastName =: lastName AND FirstName =: firstName) LIMIT 1]) {
                objectIdMap = new Map<String, Id>{'Contact' => c.Id};
                if (String.isNotBlank(c.AccountId)) {
                    objectIdMap.put('Account', c.AccountId);
                }
                for (User u: [SELECT Id FROM User WHERE ContactId =: c.Id LIMIT 1]) {
                    objectIdMap.put('User', u.Id);
                }
            }
        }
        return objectIdMap;
    }

    private static Map<String, Id> checkForBuyerGroupMember(Id accountId) {

        Map<String, Id> objectIdMap;
        if (String.isNotBlank(accountId)) {
            for (BuyerGroupMember bgm: [SELECT Id FROM BuyerGroupMember WHERE BuyerId =: accountId AND BuyerGroupId =: BUYER_GROUP_ID LIMIT 1]) {
                objectIdMap = new Map<String, Id>{'BuyerGroupMember' => bgm.Id};
            }
        }
        return objectIdMap;
    }

    private static Map<String, Id> checkForContactPointAddress(RegistrationFormController.UserData ud, Id accountId) {

        Map<String, Id> objectIdMap;
        if (ud != null) {
            String billing = 'Billing';
            String shipping = 'Shipping';
            String query = 'SELECT  Id, ' +
                                    'AddressType ' +
                            'FROM    ContactPointAddress ' +
                            'WHERE   ParentId = \'' + accountId + '\' AND ' +
                                    '(' +
                                        '(' +
                                            'CountryCode = \'' + String.escapeSingleQuotes(ud.billingCountry) + '\' AND ' +
                                            'StateCode = \'' + (String.isBlank(ud.billingState) ? '' : String.escapeSingleQuotes(ud.billingState)) + '\' AND ' +
                                            'City = \'' + String.escapeSingleQuotes(ud.billingCity) + '\' AND ' +
                                            'Street = \'' + String.escapeSingleQuotes(ud.billingStreet) + '\' AND ' +
                                            'PostalCode = \'' + String.escapeSingleQuotes(ud.billingCode) + '\'' +
                                        ')' +
                                        (
                                            ud.sameAsBilling ?
                                            '' :
                                            ' OR (' +
                                                'CountryCode = \'' + String.escapeSingleQuotes(ud.shippingCountry) + '\' AND ' +
                                                'StateCode = \'' + (String.isBlank(ud.shippingState) ? '' : String.escapeSingleQuotes(ud.shippingState)) + '\' AND ' +
                                                'City = \'' + String.escapeSingleQuotes(ud.shippingCity) + '\' AND ' +
                                                'Street = \'' + String.escapeSingleQuotes(ud.shippingStreet) + '\' AND ' +
                                                'PostalCode = \'' + String.escapeSingleQuotes(ud.shippingCode) + '\'' +
                                            ')'
                                        ) +
                                    ') ' +
                            'LIMIT   2';
            List<ContactPointAddress> cpaList = Database.query(query);
            for (ContactPointAddress cpa: cpaList) {
                if (billing.equals(cpa.AddressType)) {
                    objectIdMap = new Map<String, Id>{'ContactPointAddress' + billing => cpa.Id};
                } else if (shipping.equals(cpa.AddressType)) {
                    objectIdMap = new Map<String, Id>{'ContactPointAddress' + shipping => cpa.Id};
                }

            }
        }
        return objectIdMap;
    }

    private static Boolean checkForPermissionSetAssigment(Id userId) {

        Boolean psaExist = false;
        if (String.isNotBlank(userId)) {
            for (PermissionSetAssignment psa: [SELECT Id FROM PermissionSetAssignment WHERE AssigneeId =: userId AND PermissionSetGroupId =: PS_ID LIMIT 1]) {
                psaExist = true;
            }
        }
        return psaExist;
    }
    
    //create records
    private static Id createAccount(RegistrationFormController.UserData ud) {

        Account a =  new Account(
                Name = ud.companyName,
                RecordTypeId = ACCOUNT_CUSTOMER_RT_ID,
                ShippingCountryCode = ud.sameAsBilling ? ud.billingCountry : ud.shippingCountry,
                ShippingStateCode = ud.sameAsBilling ? ud.billingState : ud.shippingState,
                ShippingCity = ud.sameAsBilling ? ud.billingCity : ud.shippingCity,
                ShippingStreet = ud.sameAsBilling ? ud.billingStreet : ud.shippingStreet,
                ShippingPostalCode = ud.sameAsBilling ? ud.billingCode : ud.shippingCode,
                BillingCountryCode = ud.billingCountry,
                BillingStateCode = ud.billingState,
                BillingCity = ud.billingCity,
                BillingStreet = ud.billingStreet,
                BillingPostalCode = ud.billingCode
                //Removed due to Duet removal. if needed these will need replaced -John Meighen 9-30-2023
                //DUET__extlogicalid__c = b2bMap.get('Logical Id'),
                //DUET__extaccountingentityid__c = b2bMap.get('Accounting Entity Id'),
                //DUET__parentaccountexternalid__c = ud.existingCustomer ? ud.customerNumber : null
        );
        insert a;
        return a.Id;
    }

    private static Id createBuyerAccount(RegistrationFormController.UserData ud, Id accountId) {

        BuyerAccount ba = new BuyerAccount(
                BuyerId = accountId,
                Name = ud.companyName,
                IsActive = true
        );
        insert ba;
        return ba.Id;
    }

    private static Id createContact(RegistrationFormController.UserData ud, Id accountId) {

        Contact c = new Contact(
            FirstName = ud.firstName,
            LastName = ud.lastName,
            Email = ud.email,
            AccountId = accountId
        );
        upsert c;
        return c.Id;
    }

    private static Id createContactPointAddress(RegistrationFormController.UserData ud, Id accountId, Boolean isBillingAddress) {
        
        Boolean sameAsBilling = ud.sameAsBilling || isBillingAddress;
        ContactPointAddress cpa = new ContactPointAddress(
                AddressType = isBillingAddress ? 'Billing' : 'Shipping',
                CountryCode = sameAsBilling ? ud.billingCountry : ud.shippingCountry,
                StateCode = sameAsBilling ? ud.billingState : ud.shippingState,
                City = sameAsBilling ? ud.billingCity : ud.shippingCity,
                Street = sameAsBilling ? ud.billingStreet : ud.shippingStreet,
                PostalCode = sameAsBilling ? ud.billingCode : ud.shippingCode,
                ParentId = accountId,
                Name = ud.companyName + ' ' + (isBillingAddress ? 'Billing' : 'Shipping') + ' Address'
        );
        upsert cpa;
        return cpa.Id;
    }

    private static Id createBuyerGroupMember(RegistrationFormController.UserData ud, Id accountId) {

        BuyerGroupMember bgm = new BuyerGroupMember(
                BuyerGroupId = BUYER_GROUP_ID,
                BuyerId = accountId
        );
        upsert bgm;
        return bgm.Id;
    }

    @future
    private static void createPermissionSetGroupAssignmentsForUsers(Id userId) {

        if (String.isNotBlank(userId)) {
            insert new PermissionSetAssignment(
                    AssigneeId = userId,
                    PermissionSetGroupId = PS_ID
            );
        }
    }

    //helper methods
    private static Map<String, String> getCSMap(List<B2B_Settings__c> b2bList) {

        Map<String, String> tempB2bMap = new Map<String, String>();
        for (B2B_Settings__c b2b: b2bList) {
            tempB2bMap.put(b2b.Name, b2b.Setting_Value__c);
        }
        return tempB2bMap;
    }

    private static void checkUserFields(User u) {
        checkUserAlias(u);
        checkUserProfile(u);
        checkUserCommunityNickname(u);
        checkUsername(u);
    }

    private static void checkUserAlias(User u) {
        if (String.isBlank(u.Alias)) {
            u.Alias = cutFieldLength(((u.FirstName != null ? u.FirstName + u.LastName: u.LastName) + getRandomString()).replaceAll('[^a-zA-Z]',''), 8);
        }
    }

    private static void checkUserProfile(User u) {
        if (String.isBlank(u.ProfileId)) {
            u.ProfileId = PROFILE_ID;
        }
    }

    private static void checkUserCommunityNickname(User u) {
        if (String.isBlank(u.CommunityNickname)) {
            u.CommunityNickname = cutFieldLength(((u.FirstName != null ? u.FirstName + u.LastName: u.LastName) + getRandomString()).replaceAll('[^a-zA-Z]',''), 40);
        }
    }

    private static void checkUsername(User u) {
        if (String.isBlank(u.Username)) {
            u.Username = u.Email;
        }
    }

    private static String getRandomString() {
        Blob b = crypto.generateAesKey(128);
        String key = EncodingUtil.convertToHex(b);
        return cutFieldLength(key, 10);
    }

    private static Map<String, Id> putToMap(Map<String, Id> mainMap, Map<String, Id> tempMap) {
        if (tempMap != null) {
            for (String key: tempMap.keySet()) {
                if (
                        !mainMap.containsKey(key) ||
                                (mainMap.containsKey(key) && String.isBlank(mainMap.get(key)))
                        ) {
                    mainMap.put(key, tempMap.get(key));
                }
            }
        }
        return mainMap;
    }

    private static String cutFieldLength(String stringToCut, Integer size) {
        if (stringToCut.length() > size && size > 0) {
            stringToCut = stringToCut.left(size);
        }
        return stringToCut;
    }

    //wrapper classes
    public class UserData {

        @AuraEnabled
        public String firstName;
        @AuraEnabled
        public String lastName;
        @AuraEnabled
        public String email;
        @AuraEnabled
        public String companyName;
        @AuraEnabled
        public Boolean existingCustomer;
        @AuraEnabled
        public String customerNumber;
        @AuraEnabled
        public String billingCountry;
        @AuraEnabled
        public String billingState;
        @AuraEnabled
        public String billingCity;
        @AuraEnabled
        public String billingStreet;
        @AuraEnabled
        public String billingCode;
        @AuraEnabled
        public Boolean sameAsBilling;
        @AuraEnabled
        public String shippingCountry;
        @AuraEnabled
        public String shippingState;
        @AuraEnabled
        public String shippingCity;
        @AuraEnabled
        public String shippingStreet;
        @AuraEnabled
        public String shippingCode;
    }
}