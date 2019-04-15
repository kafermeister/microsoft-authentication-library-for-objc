//------------------------------------------------------------------------------
//
// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
//------------------------------------------------------------------------------

#import "MSALAccountsProvider.h"
#import "MSIDDefaultTokenCacheAccessor.h"
#import "MSALAuthority.h"
#import "MSALAuthority_Internal.h"
#import "MSIDAuthority.h"
#import "MSALAccount+Internal.h"
#import "MSIDAADNetworkConfiguration.h"
#import "MSIDAccount.h"
#import "MSIDAccountIdentifier.h"
#import "MSIDConfiguration.h"
#import "MSIDAppMetadataCacheItem.h"
#import "MSIDConstants.h"
#import "MSIDAADAuthority.h"
#import "MSIDB2CAuthority.h"
#import "MSIDADFSAuthority.h"
#import "MSALAADAccount.h"
#import "MSALB2CAccount.h"
#import "MSALADFSAccount.h"
#import "MSIDIdTokenClaims.h"
#import "MSALAccount+Internal.h"
#import "MSIDIdToken.h"

@interface MSALAccountsProvider()

@property (nullable, nonatomic) MSIDDefaultTokenCacheAccessor *tokenCache;
@property (nullable, nonatomic) NSString *clientId;

@end

@implementation MSALAccountsProvider

#pragma mark - Init

- (instancetype)initWithTokenCache:(MSIDDefaultTokenCacheAccessor *)tokenCache
                          clientId:(NSString *)clientId
{
    self = [super init];

    if (self)
    {
        _tokenCache = tokenCache;
        _clientId = clientId;
    }

    return self;
}

#pragma mark - Accounts

- (void)allAccountsFilteredByAuthority:(MSALAuthority *)authority
                       completionBlock:(MSALAccountsCompletionBlock)completionBlock;
{
    [authority.msidAuthority resolveAndValidate:NO
                              userPrincipalName:nil
                                        context:nil
                                completionBlock:^(NSURL * _Nullable openIdConfigurationEndpoint, BOOL validated, NSError * _Nullable error) {
                                    
                                    if (error)
                                    {
                                        completionBlock(nil, error);
                                        return;
                                    }
                                    
                                    NSError *accountsError = nil;
                                    NSArray *accounts = [self allAccountsForAuthority:authority.msidAuthority error:&accountsError];
                                    completionBlock(accounts, accountsError);
                                }];
}

#pragma mark - Accounts sync

- (NSArray <MSALAccount *> *)allAccounts:(NSError * __autoreleasing *)error
{
    return [self allAccountsForAuthority:nil error:error];
}

- (MSALAccount *)accountForHomeAccountId:(NSString *)homeAccountId
                                   error:(NSError * __autoreleasing *)error 
{
    NSError *msidError = nil;

    MSIDAppMetadataCacheItem *appMetadata = [self appMetadataItem];
    NSString *familyId = appMetadata ? appMetadata.familyId : MSID_DEFAULT_FAMILY_ID;

    MSIDAccountIdentifier *accountIdentifier = [[MSIDAccountIdentifier alloc] initWithDisplayableId:nil homeAccountId:homeAccountId];
    NSArray *msidAccounts = [self.tokenCache accountsWithAuthority:nil
                                                          clientId:self.clientId
                                                          familyId:familyId
                                                 accountIdentifier:accountIdentifier
                                                           context:nil
                                                             error:&msidError];
    
    if (msidError)
    {
        *error = msidError;
        return nil;
    }

    if ([msidAccounts count])
    {
        NSArray<MSALAccount *> *msalAccounts = [self msalAccountsFromMSIDAccounts:msidAccounts];
        if (msalAccounts.count == 1)
        {
            return msalAccounts[0];
        }
        else if (msalAccounts.count > 1)
        {
            MSID_LOG_WARN(nil, @"Retrieved more than 1 msal accounts for the same home accout id! (More info: environments are equal for first 2 accounts: %@, usernames are equal for first 2 accounts: %@)", msalAccounts[0].environment == msalAccounts[1].environment ? @"YES" : @"NO", msalAccounts[0].username == msalAccounts[1].username? @"YES" : @"NO");
            
            return msalAccounts[0];
        }
    }

    return nil;
}

- (MSALAccount *)accountForUsername:(NSString *)username
                              error:(NSError * __autoreleasing *)error
{
    NSError *msidError = nil;

    MSIDAppMetadataCacheItem *appMetadata = [self appMetadataItem];
    NSString *familyId = appMetadata ? appMetadata.familyId : MSID_DEFAULT_FAMILY_ID;

    MSIDAccountIdentifier *accountIdentifier = [[MSIDAccountIdentifier alloc] initWithDisplayableId:username homeAccountId:nil];

    NSArray *msidAccounts = [self.tokenCache accountsWithAuthority:nil
                                                          clientId:self.clientId
                                                          familyId:familyId
                                                 accountIdentifier:accountIdentifier
                                                           context:nil
                                                             error:&msidError];
    
    if (msidError)
    {
        *error = msidError;
        return nil;
    }
    
    if ([msidAccounts count])
    {
        NSArray<MSALAccount *> *msalAccounts = [self msalAccountsFromMSIDAccounts:msidAccounts];
        if (msalAccounts.count == 1)
        {
            return msalAccounts[0];
        }
        else if (msalAccounts.count > 1)
        {
            MSID_LOG_WARN(nil, @"Retrieved more than 1 msal accounts for the same username! (More info: environments are equal for first 2 accounts: %@, homeAccountIds are equal for first 2 accounts: %@)", msalAccounts[0].environment == msalAccounts[1].environment ? @"YES" : @"NO", msalAccounts[0].homeAccountId == msalAccounts[1].homeAccountId? @"YES" : @"NO");
            
            return msalAccounts[0];
        }
    }
    
    return nil;
}

#pragma mark - Accounts Convenience

+ (MSALAccount *)msalAccountFromMSIDAccount:(MSIDAccount *)msidAccount
{
    if ([msidAccount.authority.class isKindOfClass:MSIDAADAuthority.class])
    {
        return [[MSALAADAccount alloc] initWithMSIDAccount:msidAccount];
    }
    else if ([msidAccount.authority.class isKindOfClass:MSIDB2CAuthority.class])
    {
        return [[MSALB2CAccount alloc] initWithMSIDAccount:msidAccount];
    }
    else if ([msidAccount.authority.class isKindOfClass:MSIDADFSAuthority.class])
    {
        return [[MSALADFSAccount alloc] initWithMSIDAccount:msidAccount];
    }
    else
    {
        return [[MSALAccount alloc] initWithMSIDAccount:msidAccount];
    }
}

#pragma mark - Private

- (NSArray <MSALAccount *> *)allAccountsForAuthority:(MSIDAuthority *)authority
                                               error:(NSError * __autoreleasing *)error
{
    NSError *msidError = nil;

    MSIDAppMetadataCacheItem *appMetadata = [self appMetadataItem];
    NSString *familyId = appMetadata ? appMetadata.familyId : MSID_DEFAULT_FAMILY_ID;

    NSArray *msidAccounts = [self.tokenCache accountsWithAuthority:authority
                                                          clientId:self.clientId
                                                          familyId:familyId
                                                 accountIdentifier:nil
                                                           context:nil
                                                             error:&msidError];
    
    if (msidError)
    {
        *error = msidError;
        return nil;
    }
    
    return [self msalAccountsFromMSIDAccounts:msidAccounts];
}

- (NSArray<MSALAccount *> *)msalAccountsFromMSIDAccounts:(NSArray *)msidAccounts
{
    NSMutableSet *msalAccounts = [NSMutableSet new];
    
    for (MSIDAccount *msidAccount in msidAccounts)
    {
        [self loadIdTokenClaimsForMSIDAccount:msidAccount];
        
        MSALAccount *msalAccount = [self.class msalAccountFromMSIDAccount:msidAccount];
        if (!msalAccount) continue;
        
        MSALAccount *existAccount = [msalAccounts member:msalAccount];
        if (!existAccount)
        {
            [msalAccounts addObject:msalAccount];
        }
        else
        {
            [existAccount addTenantProfiles:msalAccount.tenantProfiles];
        }
    }
    
    return [msalAccounts allObjects];
}

- (void)loadIdTokenClaimsForMSIDAccount:(MSIDAccount *)msidAccount
{
    // Return if id token claims is already loaded. This normally happen msidAccount retrieved from legacy tokens
    if (msidAccount.idTokenClaims) return;
    
    MSIDConfiguration *config = [MSIDConfiguration new];
    config.authority = msidAccount.authority;
    config.clientId = self.clientId;
    NSError *error;
    MSIDIdToken *idToken = [self.tokenCache getIDTokenForAccount:msidAccount.accountIdentifier
                                                   configuration:config
                                                     idTokenType:MSIDIDTokenType
                                                         context:nil
                                                           error:&error];
    if (error || !idToken)
    {
        MSID_LOG_ERROR(nil, @"Failed to retrive ID token when load id token claims for msidAccount!");
    }
    
    error =  nil;
    msidAccount.idTokenClaims = [[MSIDIdTokenClaims alloc] initWithRawIdToken:idToken.rawIdToken error:&error];
    
    if (error)
    {
        MSID_LOG_ERROR(nil, @"Failed to create id token claims when load id token claims for msidAccount!");
    }
}

- (MSIDAppMetadataCacheItem *)appMetadataItem
{
    MSIDConfiguration *configuration = [[MSIDConfiguration alloc] initWithAuthority:nil redirectUri:nil clientId:self.clientId target:nil];

    NSError *error = nil;
    NSArray *appMetadataItems = [self.tokenCache getAppMetadataEntries:configuration context:nil error:&error];

    if (error)
    {
        MSID_LOG_WARN(nil, @"Failed to retrieve app metadata items with error code %ld, %@", (long)error.code, error.domain);
        return nil;
    }

    if ([appMetadataItems count])
    {
        return appMetadataItems[0];
    }

    return nil;
}

@end
