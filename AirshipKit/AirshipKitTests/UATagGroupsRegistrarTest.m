/* Copyright 2018 Urban Airship and Contributors */

#import "UABaseTest.h"
#import "UATagGroupsRegistrar+Internal.h"
#import "UATagGroupsMutation+Internal.h"
#import "UAPreferenceDataStore+InternalTagGroupsMutation.h"

@interface UATagGroupsRegistrarTest : UABaseTest
@property (nonatomic, strong) UAPreferenceDataStore *dataStore;
@property (nonatomic, strong) UATagGroupsRegistrar *channelRegistrar;
@property (nonatomic, strong) UATagGroupsRegistrar *namedUserRegistrar;
@property (nonatomic, strong) NSOperationQueue *operationQueue;
@property (nonatomic, strong) id mockApplication;
@property (nonatomic, strong) id mockApiClient;
@end

@implementation UATagGroupsRegistrarTest

- (void)setUp {
    [super setUp];
    
    self.mockApplication = [self mockForClass:[UIApplication class]];
    [[[self.mockApplication stub] andReturn:self.mockApplication] sharedApplication];
    
    self.dataStore = [UAPreferenceDataStore preferenceDataStoreWithKeyPrefix:@"uataggroupsregistrar.test."];
    [self.dataStore removeAll];
    
    self.mockApiClient = [self mockForClass:[UATagGroupsAPIClient class]];

    self.operationQueue = [[NSOperationQueue alloc] init];

    self.channelRegistrar =  [UATagGroupsRegistrar channelTagGroupsRegistrarWithDataStore:self.dataStore
                                                                                apiClient:self.mockApiClient
                                                                           operationQueue:self.operationQueue];
    
    self.namedUserRegistrar =  [UATagGroupsRegistrar namedUserTagGroupsRegistrarWithDataStore:self.dataStore
                                                                                    apiClient:self.mockApiClient
                                                                               operationQueue:self.operationQueue];
}

- (void)tearDown {
    [self.operationQueue cancelAllOperations];
    [self.operationQueue waitUntilAllOperationsAreFinished];
    [self.dataStore removeAll];
    [super tearDown];
}

/**
 * Test updating tag groups calls the tag client for every pending mutation.
 */
- (void)testUpdateTagGroupsForAnID {
    NSString *testID = @"someID";
    // Background task
    [[[self.mockApplication stub] andReturnValue:OCMOCK_VALUE((NSUInteger)30)] beginBackgroundTaskWithExpirationHandler:OCMOCK_ANY];

    XCTestExpectation *expectation = [self expectationWithDescription:@"Async update tag groups call"];

    // Expect a set mutation, return 200
    [[[self.mockApiClient expect] andDo:^(NSInvocation *invocation) {
        void *arg;
        [invocation getArgument:&arg atIndex:4];

        void (^completionHandler)(NSUInteger) = (__bridge void (^)(NSUInteger))arg;
        completionHandler(200);
    }] updateTagGroupsForId:testID
     tagGroupsMutation:[OCMArg checkWithBlock:^BOOL(id obj) {
        UATagGroupsMutation *mutation = (UATagGroupsMutation *)obj;
        NSDictionary *expectedPayload = @{@"set": @{ @"group2": @[@"tag1"] } };
        return [expectedPayload isEqualToDictionary:[mutation payload]];
    }] completionHandler:OCMOCK_ANY];

    // Expect Add & Remove mutations, return 200
    [[[self.mockApiClient expect] andDo:^(NSInvocation *invocation) {
        void *arg;
        [invocation getArgument:&arg atIndex:4];

        [expectation fulfill];

        void (^completionHandler)(NSUInteger) = (__bridge void (^)(NSUInteger))arg;
        completionHandler(200);
    }] updateTagGroupsForId:testID
     tagGroupsMutation:[OCMArg checkWithBlock:^BOOL(id obj) {
        UATagGroupsMutation *mutation = (UATagGroupsMutation *)obj;
        NSDictionary *expectedPayload = @{@"add": @{ @"group1": @[@"tag1"] }, @"remove": @{ @"group1": @[@"tag2"] } };
        return [expectedPayload isEqualToDictionary:[mutation payload]];
    }] completionHandler:OCMOCK_ANY];
    [[self.mockApiClient reject] updateTagGroupsForId:OCMOCK_ANY tagGroupsMutation:OCMOCK_ANY completionHandler:OCMOCK_ANY];
    
    [self.channelRegistrar addTags:@[@"tag1"] group:@"group1"];
    [self.channelRegistrar removeTags:@[@"tag2"] group:@"group1"];
    [self.channelRegistrar setTags:@[@"tag1"] group:@"group2"];
    
    [self.channelRegistrar updateTagGroupsForID:testID];
    
    // wait until the queue clears
    XCTestExpectation *endBackgroundTaskExpecation = [self expectationWithDescription:@"End of background task"];
    [[[[self.mockApplication expect] ignoringNonObjectArgs] andDo:^(NSInvocation *invocation) {
        [endBackgroundTaskExpecation fulfill];
    }] endBackgroundTask:0];

    [self waitForExpectationsWithTimeout:5 handler:nil];
    
    [self.mockApiClient verify];
}

- (void)testUpdateTagGroupsWithInvalidBackground {
    // SETUP
    [self.channelRegistrar addTags:@[@"tag1"] group:@"group1"];
    
    // Prevent beginRegistrationBackgroundTask early return
    [[[self.mockApplication stub] andReturnValue:OCMOCK_VALUE(UIBackgroundTaskInvalid)] beginBackgroundTaskWithExpirationHandler:OCMOCK_ANY];
    
    // EXPECTATIONS
    [[self.mockApiClient reject] updateTagGroupsForId:OCMOCK_ANY
                                    tagGroupsMutation:OCMOCK_ANY
                                    completionHandler:OCMOCK_ANY];

    // TEST
    [self.channelRegistrar updateTagGroupsForID:@"someID"];
    
    // VERIFY
    [self.mockApiClient verify];
}

- (void)testSetEmptyTagListClearsTags {
    [self.channelRegistrar setTags:@[@"tag2", @"tag1"] group: @"group"];
    [self.operationQueue waitUntilAllOperationsAreFinished];

    NSDictionary *expected = @{ @"set": @{ @"group": @[@"tag2", @"tag1"] } };
    XCTAssertEqualObjects(expected, [self.dataStore peekTagGroupsMutationForKey:@"UAPushTagGroupsMutations"].payload);
}

- (void)testSetWithEmptyGroupDoesntSetTags {
    [self.channelRegistrar setTags:@[@"tag1"] group:@""];
    [self.operationQueue waitUntilAllOperationsAreFinished];

    XCTAssertNil([self.dataStore peekTagGroupsMutationForKey:@"UAPushTagGroupsMutations"]);
}

- (void)testAddEmptyTagListOrEmptyGroupDoesntAddTags {
    [self.channelRegistrar addTags:@[] group:@"group1"];
    [self.channelRegistrar addTags:@[@"tag1"] group:@""];
    [self.operationQueue waitUntilAllOperationsAreFinished];

    XCTAssertNil([self.dataStore peekTagGroupsMutationForKey:@"UAPushTagGroupsMutations"]);
}

- (void)testRemoveEmptyTagListOrEmptyGroupDoesntRemoveTags {
    [self.channelRegistrar setTags:@[@"tag2", @"tag1"] group:@"group"];
    [self.channelRegistrar removeTags:@[] group:@"group"];
    [self.channelRegistrar removeTags:@[@"tag1"] group:@""];

    [self.operationQueue waitUntilAllOperationsAreFinished];

    // Should still only be the set mutation
    NSDictionary *expected = @{ @"set": @{ @"group": @[@"tag2", @"tag1"] } };
    XCTAssertEqualObjects(expected, [self.dataStore peekTagGroupsMutationForKey:@"UAPushTagGroupsMutations"].payload);
}

- (void)testChannelAndNamedUserTagsAreIndependent {
    [self.channelRegistrar setTags:@[@"tag1"] group:@"cool"];
    [self.namedUserRegistrar setTags:@[@"tag2"] group:@"cool"];

    [self.operationQueue waitUntilAllOperationsAreFinished];

    NSDictionary *channelExpectedPayload = @{ @"set": @{ @"cool": @[@"tag1"] } };
    XCTAssertEqualObjects(channelExpectedPayload, [self.dataStore peekTagGroupsMutationForKey:@"UAPushTagGroupsMutations"].payload);

    NSDictionary *namedUserExpectedPayload = @{ @"set": @{ @"cool": @[@"tag2"] } };
    XCTAssertEqualObjects(namedUserExpectedPayload, [self.dataStore peekTagGroupsMutationForKey:@"UANamedUserTagGroupsMutations"].payload);
}

- (void)testClearAllPendingUpdatesCancelsAndClearsMutations {
    [self.namedUserRegistrar setTags:@[@"tag2"] group:@"cool"];
    [self.operationQueue waitUntilAllOperationsAreFinished];

    NSDictionary *namedUserExpectedPayload = @{ @"set": @{ @"cool": @[@"tag2"] } };
    XCTAssertEqualObjects(namedUserExpectedPayload, [self.dataStore peekTagGroupsMutationForKey:@"UANamedUserTagGroupsMutations"].payload);

    [self.namedUserRegistrar clearAllPendingTagUpdates];
    [self.operationQueue waitUntilAllOperationsAreFinished];

    XCTAssertNil([self.dataStore peekTagGroupsMutationForKey:@"UANamedUserTagGroupsMutations"]);
}

@end
