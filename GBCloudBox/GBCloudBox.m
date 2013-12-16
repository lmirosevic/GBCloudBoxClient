//
//  GBCloudBox.m
//  GBCloudBox
//
//  Created by Luka Mirosevic on 20/03/2013.
//  Copyright (c) 2013 Goonbee. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

#import "GBCloudBox.h"

#import "JSONKit.h"
#import <stdlib.h>

NSString * const kGBCloudBoxResourceUpdatedNotification = @"kGBCloudBoxResourceUpdatedNotification";

static NSString * const kBundledResourcesBundleName = @"GBCloudBoxResources";
static NSString * const kLocalResourcesDirectory = @"GBCloudBoxResources";
static NSString * const kRemoteResourcesMetaPath = @"GBCloudBoxResourcesMeta";
static BOOL const shouldUseSSL = YES;
static NSString * const kVersionKey = @"v";
static NSString * const kURLKey = @"url";

@implementation NSArray (GBToolbox)

-(NSArray *)map:(id(^)(id object))function {
    NSUInteger count = self.count;
    
    // creates a results array in which to store results, sets the capacity for faster writes
    NSMutableArray *resultsArray = [[NSMutableArray alloc] initWithCapacity:count];
    
    // applies the function to each item and stores the result in the new array
    for (NSUInteger i=0; i<count; i++) {
        resultsArray[i] = function(self[i]);
    }
    
    // returns an immutable copy
    return [resultsArray copy];
}

@end

typedef void(^ResourceMetaInfoHandler)(NSNumber *latestRemoteVersion, NSURL *remoteResourceURL);
typedef void(^ResourceDataHandler)(NSNumber *resourceVersion, NSData *resourceData);
typedef enum {
    GBCloudBoxLatestVersionNeither = 0,
    GBCloudBoxLatestVersionEqual,
    GBCloudBoxLatestVersionBundled,
    GBCloudBoxLatestVersionLocal,
} GBCloudBoxLatestVersion;

@interface GBCloudBoxResource : NSObject

@property (copy, atomic, readonly) NSString         *identifier;
@property (strong, atomic) NSMutableArray           *updatedHandlers;
@property (copy, atomic) Deserializer               deserializer;
@property (strong, atomic) NSArray                  *sourceServers;
@property (strong, atomic, readonly) NSString       *bundledResourcePath;

//init method
-(id)initWithResource:(NSString *)resourceIdentifier bundledResourcePath:(NSString *)bundledResourcePath andSourceServers:(NSArray *)sourceServers;

//updates the resource if necessary
-(void)update;

//returns the data for the resource, tries cache first, otherwise latest local version, otherwise latest bundled version
-(NSData *)data;

//returns the deserialized data for the resource
-(id)object;

//returns the number of the latest local version, if there isnt one it returns nil
-(NSNumber *)localVersion;

//return the number of the latest bundled version, if there isnt one it returns nil
-(NSNumber *)bundledVersion;

//returns the greatest of localVersion and bundledVersion
-(NSNumber *)latestAvailableVersion;

@end

@interface GBCloudBoxResource ()

@property (assign, atomic) NSNumber                 *cachedVersion;
@property (copy, atomic, readwrite) NSString        *identifier;
@property (strong, atomic, readwrite) NSString      *bundledResourcePath;
@property (strong, atomic) NSData                   *cachedData;
@property (assign, atomic) dispatch_queue_t         networkQueue;

@end

@implementation GBCloudBoxResource

#pragma mark - memory

-(id)initWithResource:(NSString *)resourceIdentifier bundledResourcePath:(NSString *)bundledResourcePath andSourceServers:(NSArray *)sourceServers {
    if (self = [super init]) {
        self.identifier = resourceIdentifier;
        self.bundledResourcePath = bundledResourcePath;
        self.sourceServers = sourceServers;
        self.updatedHandlers = [NSMutableArray new];
        self.networkQueue = dispatch_queue_create("com.goonbee.TabApp.networkQueue", NULL);
    }
    
    return self;
}

-(void)dealloc {
    dispatch_release(self.networkQueue);
}

#pragma mark - private API

//Functional Helpers

-(NSNumber *)_latestVersionForPaths:(NSArray *)paths {
    if (paths) {
        NSInteger acc = 0;
        NSString *fileName;
        NSInteger version;
        for (NSString *path in paths) {
            fileName = [path lastPathComponent];
            version = [fileName integerValue];
            
            if (version > acc) {
                acc = version;
            }
        }
        
        return @(acc);
    }
    else {
        return nil;
    }
}

-(NSData *)_dataForPath:(NSString *)path {
    BOOL isDir;
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    
    //its a file
    if (fileExists && !isDir) {
        return [[NSFileManager defaultManager] contentsAtPath:path];
    }
    //its a dir
    else if (fileExists && isDir) {
        @throw [NSException exceptionWithName:@"GBCloudBox" reason:@"expected file but found directory" userInfo:@{@"path": path}];
    }
    //file doesnt exist
    else {
        return nil;
    }
}

-(NSDictionary *)_dictionaryFromJSONData:(NSData *)data {
    if (data) {
        NSDictionary *result = [[JSONDecoder decoder] objectWithData:data];
        
        return result;
    }
    else {
        return nil;
    }
}

//Local helpers

-(NSString *)_localPathForResource {
#if TARGET_OS_IPHONE
    NSString *documentsDirectoryPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
#else
    NSString *documentsDirectoryPath = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject] stringByAppendingPathComponent:[[NSBundle mainBundle] infoDictionary][@"CFBundleIdentifier"]];
#endif
    
    //construct full path to resource
    NSString *path = [[documentsDirectoryPath stringByAppendingPathComponent:kLocalResourcesDirectory] stringByAppendingPathComponent:self.identifier];
    
    //check if there is something there already
    BOOL isDir;
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    
    //if theres a directory there
    if (fileExists && isDir) {
        //return path
        return path;
    }
    //nothing there
    else if (!fileExists) {
        //first create directory
        if (![[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil]) {
            @throw [NSException exceptionWithName:@"GBCloudBox" reason:@"couldnt create directory" userInfo:@{@"path": path}];
        }
        
        //return path
        return path;
    }
    //theres a file there
    else {
        @throw [NSException exceptionWithName:@"GBCloudBox" reason:@"found file instead of folder in path" userInfo:@{@"path": path}];
    }
}

-(NSArray *)_allLocalVersionsPaths {
    NSString *resourcePath = [self _localPathForResource];
    NSArray *raw = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:resourcePath error:nil];
    NSArray *mapped = [raw map:^id(id object) {
        return [resourcePath stringByAppendingPathComponent:(NSString *)object];
    }];
    
    return mapped;
}

-(NSNumber *)_latestLocalVersionNumber {
    return [self _latestVersionForPaths:[self _allLocalVersionsPaths]];
}

-(NSString *)_latestLocalVersionPath {
    return [[self _localPathForResource] stringByAppendingPathComponent:[[self _latestLocalVersionNumber] stringValue]];
}

-(NSString *)_localPathForVersion:(NSNumber *)version {
    return [[self _localPathForResource] stringByAppendingPathComponent:[version stringValue]];
}

-(NSData *)_dataForLatestLocalVersion {
    return [self _dataForPath:[self _latestLocalVersionPath]];
}

-(void)_storeResourceLocally:(NSData *)data withVersion:(NSNumber *)version {
    NSString *path = [self _localPathForVersion:version];
    
    [data writeToFile:path atomically:YES];
}

-(void)_deleteOlderLocalResourceVersions {
    NSString *latestLocalResourcePath = [self _latestLocalVersionPath];
    NSArray *allLocalVersionPaths = [self _allLocalVersionsPaths];
    
    for (NSString *path in allLocalVersionPaths) {
        //anything other than the latest path
        if (![path isEqualToString:latestLocalResourcePath]) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        }
    }
}

//Bundled helpers

-(NSArray *)_allBundledVersionsPaths {
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.bundledResourcePath error:nil];
}

-(NSNumber *)_latestBundledVersionNumber {
    return [self _latestVersionForPaths:[self _allBundledVersionsPaths]];
}

-(NSString *)_latestBundledVersionPath {
    return [self.bundledResourcePath stringByAppendingPathComponent:[[self _latestBundledVersionNumber] stringValue]];
}

-(NSData *)_dataForLatestBundledVersion {
    return [self _dataForPath:[self _latestBundledVersionPath]];
}

//Remote interaction helpers

-(NSString *)_randomSourceServer {
    if (self.sourceServers.count > 0) {
        return self.sourceServers[arc4random() % self.sourceServers.count];
    }
    else {
        return nil;
    }
}

-(NSURL *)_remoteResourceMetaPath {
    //first strip off the protocol if its there
    NSString *rawSourceServer = [self _randomSourceServer];
    NSRange range = [rawSourceServer rangeOfString:@"://"];
    NSString *processedSourceServer;
    if (range.location == NSNotFound) {
        processedSourceServer = rawSourceServer;
    }
    else {
        processedSourceServer = [rawSourceServer substringFromIndex:(range.location + 3)];
    }
    
    NSString *remoteResourcePath = [processedSourceServer stringByAppendingPathComponent:[kRemoteResourcesMetaPath stringByAppendingPathComponent:self.identifier]];
    NSString *fullPath = [NSString stringWithFormat:@"%@://%@", shouldUseSSL ? @"https" : @"http", remoteResourcePath];
    
    return [NSURL URLWithString:fullPath];
}

-(void)_fetchRemoteMetaInfo:(ResourceMetaInfoHandler)handler {
    dispatch_async(self.networkQueue, ^{
        NSURL *remoteResourceMetaPath = [self _remoteResourceMetaPath];
        NSData *metaInfoData = [NSData dataWithContentsOfURL:remoteResourceMetaPath];
        NSDictionary *metaInfoDictionary = [self _dictionaryFromJSONData:metaInfoData];

        if (metaInfoDictionary) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (handler) {
                    NSNumber *version = metaInfoDictionary[kVersionKey] != [NSNull null] ? metaInfoDictionary[kVersionKey] : nil;
                    NSURL *resourceURL = metaInfoDictionary[kURLKey] != [NSNull null] ? [NSURL URLWithString:metaInfoDictionary[kURLKey]] : nil;
                    
                    handler(version, resourceURL);
                }
            });
        }
    });
}

-(void)_fetchResourceFromURL:(NSURL *)remoteResourceURL handler:(ResourceDataHandler)handler {
    dispatch_async(self.networkQueue, ^{
        NSURLRequest *request = [NSURLRequest requestWithURL:remoteResourceURL];
        NSHTTPURLResponse *response;
        NSData *responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:nil];

        NSDictionary *headers = [response allHeaderFields];
        NSNumber *responseVersion = @([headers[@"Resource-Version"] integerValue]);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (handler) {
                handler(responseVersion, responseData);
            }
        });
    });
}

//Other helpers

-(GBCloudBoxLatestVersion)_latestVersionStatus {
    NSNumber *localVersion = [self localVersion];
    NSNumber *bundledVersion = [self bundledVersion];
    
    //if they r both set, then find the biggest one
    if (localVersion && bundledVersion) {
        NSComparisonResult result = [localVersion compare:bundledVersion];
        
        if (result == NSOrderedAscending) {
            return GBCloudBoxLatestVersionBundled;
        }
        else if (result == NSOrderedDescending) {
            return GBCloudBoxLatestVersionLocal;
        }
        else {
            return GBCloudBoxLatestVersionEqual;
        }
    }
    //just local
    else if (localVersion) {
        return GBCloudBoxLatestVersionLocal;
    }
    //just bundled
    else if (bundledVersion) {
        return GBCloudBoxLatestVersionBundled;
    }
    //none
    else {
        return GBCloudBoxLatestVersionNeither;
    }
}

-(void)_callHandlers {
    for (UpdateHandler handler in self.updatedHandlers) {
        if (handler) {
            handler(self.identifier, [self.cachedVersion integerValue], self.cachedData);
        }
    }
}

#pragma mark - public API

//returns the data for the resource, tries cache first, otherwise latest local version, otherwise latest bundled version
-(NSData *)data {
    @synchronized(self) {
        //check cache first
        if (!_cachedData) {
            switch ([self _latestVersionStatus]) {
                case GBCloudBoxLatestVersionLocal: {
                    _cachedData = [self _dataForLatestLocalVersion];
                    _cachedVersion = [self _latestLocalVersionNumber];
                } break;
                    
                case GBCloudBoxLatestVersionBundled:
                case GBCloudBoxLatestVersionEqual: {
                    _cachedData = [self _dataForLatestBundledVersion];
                    _cachedVersion = [self _latestBundledVersionNumber];
                } break;
                    
                case GBCloudBoxLatestVersionNeither: {
                    return nil;
                } break;
            }
        }
        
        return _cachedData;
    }
}

//returns the deserialized data for the resource
-(id)object {
    if (self.deserializer) {
        return self.deserializer([self data]);
    }
    else {
        return nil;
    }
}

//returns the local version of the stored file
-(NSNumber *)localVersion {
    return [self _latestLocalVersionNumber];
}

//returns the number of the latest bundled version, if there isnt one it returns nil
-(NSNumber *)bundledVersion {
    return [self _latestBundledVersionNumber];
}

//returns the greatest of localVersion and bundledVersion
-(NSNumber *)latestAvailableVersion {
    switch ([self _latestVersionStatus]) {
        case GBCloudBoxLatestVersionLocal: {
            return [self localVersion];
        } break;
            
        case GBCloudBoxLatestVersionBundled:
        case GBCloudBoxLatestVersionEqual: {
            return [self bundledVersion];
        } break;
            
        case GBCloudBoxLatestVersionNeither: {
            return nil;
        } break;
    }
}

//asks the server if there is a newer version, and if there is: it fetches it, stores it in cache and on disk, deletes older local versions, calls handlers and posts notification
-(void)update {
    //first fetch remote meta
    [self _fetchRemoteMetaInfo:^(NSNumber *latestRemoteVersion, NSURL *remoteResourceURL) {
        //check if remote has newer
        if (latestRemoteVersion && [[self latestAvailableVersion] compare:latestRemoteVersion] == NSOrderedAscending) {
            //fetch remote resource
            [self _fetchResourceFromURL:remoteResourceURL handler:^(NSNumber *resourceVersion, NSData *resourceData) {
                //if the resource fetch had the version HTTP header set, then use that, otherwise just assume the version is what the meta returned
                NSNumber *version = resourceVersion ?: latestRemoteVersion;
                
                //store the resource in cache
                self.cachedData = resourceData;
                self.cachedVersion = version;
                
                //store to disk
                [self _storeResourceLocally:resourceData withVersion:version];
                
                //remove older ones from disk
                [self _deleteOlderLocalResourceVersions];
                
                //call handlers
                [self _callHandlers];
                
                //send notification
                NSMutableDictionary *userInfo = [NSMutableDictionary new];
                userInfo[@"identifier"] = self.identifier;
                if (resourceData) userInfo[@"data"] = resourceData;
                if (resourceVersion) userInfo[@"version"] = resourceVersion;
                
                [[NSNotificationCenter defaultCenter] postNotificationName:kGBCloudBoxResourceUpdatedNotification object:self userInfo:[userInfo copy]];
            }];
        }
        else {
            //noop: up to date
        }
    }];
}

@end


@interface GBCloudBox ()

@property (strong, nonatomic) NSMutableDictionary *resources;

@end


@implementation GBCloudBox

#pragma mark - memory

#define _cb [GBCloudBox sharedInstance]
+(GBCloudBox *)sharedInstance {
    static GBCloudBox *sharedInstance;
    
    @synchronized(self) {
        if (!sharedInstance) {
            sharedInstance = [[GBCloudBox alloc] init];
        }
        return sharedInstance;
    }
}

- (id)init {
    self = [super init];
    if (self) {
        self.resources = [NSMutableDictionary new];
    }
    return self;
}

- (void)dealloc {
    self.resources = nil;
}

#pragma mark- public API

+(void)registerResource:(NSString *)resourceIdentifier withSourceServers:(NSArray *)servers {
    if (resourceIdentifier && ![resourceIdentifier isEqualToString:@""]) {
        //if the resource doesn't exist, create it
        if (!_cb.resources[resourceIdentifier]) {
            NSString *bundledResourcePath = [[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.bundle", kBundledResourcesBundleName]] stringByAppendingPathComponent:resourceIdentifier];
            _cb.resources[resourceIdentifier] = [[GBCloudBoxResource alloc] initWithResource:resourceIdentifier bundledResourcePath:bundledResourcePath andSourceServers:servers];
        }
        else {
            NSLog(@"GBCloudBox: resource \"%@\" already exists", resourceIdentifier);
        }
    }
    else {
        @throw [NSException exceptionWithName:@"GBCloudBox" reason:@"must pass valid string for resource identifier" userInfo:nil];
    }
    
}

+(void)registerPostUpdateHandler:(UpdateHandler)handler forResource:(NSString *)resourceIdentifier {
    GBCloudBoxResource *resource;
    if ((resource = _cb.resources[resourceIdentifier])) {
        [resource.updatedHandlers addObject:[handler copy]];
    }
    else {
        @throw [NSException exceptionWithName:@"GBCloudBox" reason:@"resource doesn't exist. create it first" userInfo:@{@"resourceIdentiier": resourceIdentifier}];
    }
}

+(void)registerDeserializer:(Deserializer)deserializer forResource:(NSString *)resourceIdentifier {
    GBCloudBoxResource *resource;
    if ((resource = _cb.resources[resourceIdentifier])) {
        resource.deserializer = deserializer;
    }
    else {
        @throw [NSException exceptionWithName:@"GBCloudBox" reason:@"resource doesn't exist. create it first" userInfo:@{@"resourceIdentiier": resourceIdentifier}];
    }
}

+(void)syncResource:(NSString *)resourceIdentifier {
    GBCloudBoxResource *resource;
    if ((resource = _cb.resources[resourceIdentifier])) {
        [resource update];
    }
    else {
        @throw [NSException exceptionWithName:@"GBCloudBox" reason:@"resource doesn't exist. create it first" userInfo:@{@"resourceIdentiier": resourceIdentifier}];
    }
}

+(void)syncResources {
    for (GBCloudBoxResource *resource in _cb.resources) {
        [resource update];
    }
}

+(NSData *)dataForResource:(NSString *)resourceIdentifier {
    GBCloudBoxResource *resource;
    if ((resource = _cb.resources[resourceIdentifier])) {
        return [resource data];
    }
    else {
        @throw [NSException exceptionWithName:@"GBCloudBox" reason:@"resource doesn't exist. create it first" userInfo:@{@"resourceIdentiier": resourceIdentifier}];
    }
}

+(id)objectForResource:(NSString *)resourceIdentifier {
    GBCloudBoxResource *resource;
    if ((resource = _cb.resources[resourceIdentifier])) {
        return [resource object];
    }
    else {
        @throw [NSException exceptionWithName:@"GBCloudBox" reason:@"resource doesn't exist. create it first" userInfo:@{@"resourceIdentiier": resourceIdentifier}];
    }
}

@end
