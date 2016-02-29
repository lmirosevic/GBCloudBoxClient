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

#import <stdlib.h>
#import <CommonCrypto/CommonDigest.h>

#define _cb [GBCloudBox sharedInstance]

NSString * const kGBCloudBoxResourceUpdatedNotification = @"kGBCloudBoxResourceUpdatedNotification";

static NSString * const kBundledResourcesBundleName = @"GBCloudBoxResources.bundle";
static NSString * const kBundledResourcesManifestFile = @"Manifest.plist";
static NSString * const kBundledResourcesVersionKey = @"version";
static NSString * const kBundledResourcesPathKey = @"path";

static NSString * const kLocalResourcesDirectory = @"GBCloudBoxResources";

static NSString * const kRemoteResourcesMetaPath = @"GBCloudBoxResourcesMeta";
static NSString * const kRemoteMetaVersionKey = @"v";
static NSString * const kRemoteMetaMD5 = @"md5";
static NSString * const kRemoteMetaURLKey = @"url";

typedef void(^ResourceMetaInfoHandler)(NSInteger latestRemoteVersion, NSURL *remoteResourceURL, NSString *remoteResourceMD5);
typedef void(^ResourceDataHandler)(NSInteger resourceVersion, NSData *resourceData);
typedef enum {
    GBCloudBoxLatestVersionNeither = 0,
    GBCloudBoxLatestVersionEqual,
    GBCloudBoxLatestVersionBundled,
    GBCloudBoxLatestVersionLocal,
} GBCloudBoxLatestVersion;

static NSString *MD5ForData(NSData *data) {
    unsigned char result[16];
    CC_MD5(data.bytes, (CC_LONG)data.length, result);
    
    return [NSString stringWithFormat: @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            result[0], result[1], result[2], result[3],
            result[4], result[5], result[6], result[7],
            result[8], result[9], result[10], result[11],
            result[12], result[13], result[14], result[15]
            ];
}

static NSArray *MapNSArray(NSArray *array, id(^function)(id object)) {
    NSUInteger count = array.count;
    
    // creates a results array in which to store results, sets the capacity for faster writes
    NSMutableArray *resultsArray = [[NSMutableArray alloc] initWithCapacity:count];
    
    // applies the function to each item and stores the result in the new array
    for (NSUInteger i=0; i<count; i++) {
        resultsArray[i] = function(array[i]);
    }
    
    // returns an immutable copy
    return [resultsArray copy];
}

@interface GBCloudBoxResourceMeta : NSObject

@property (copy, atomic) NSString                               *path;
@property (assign, atomic) NSInteger                            version;

+(GBCloudBoxResourceMeta *)metaWithPath:(NSString *)path version:(NSInteger)version;

@end

@interface GBCloudBoxResource : NSObject

@property (copy, atomic, readonly) NSString                     *identifier;
@property (strong, atomic) NSMutableArray                       *updatedHandlers;
@property (copy, atomic) Deserializer                           deserializer;
@property (strong, atomic) NSArray                              *sourceServers;
@property (strong, atomic, readonly) GBCloudBoxResourceMeta     *bundledResourceMeta;

@property (assign, nonatomic, readonly) NSInteger               localVersion;
@property (assign, nonatomic, readonly) NSInteger               bundledVersion;
@property (assign, nonatomic, readonly) NSInteger               latestAvailableVersion;

//init method
-(id)initWithResource:(NSString *)resourceIdentifier sourceServers:(NSArray *)sourceServers;

//updates the resource if necessary
-(void)update;

//returns the data for the resource, tries cache first, otherwise latest local version, otherwise latest bundled version
-(NSData *)data;

//returns the deserialized data for the resource
-(id)object;

@end

@interface GBCloudBox ()

@property (strong, nonatomic) NSArray                           *defaultSourceServers;
@property (strong, nonatomic) NSMutableDictionary               *resources;
@property (strong, nonatomic) NSDictionary                      *bundledResourcesManifest;
@property (assign, atomic) dispatch_queue_t                     networkQueue;

+(GBCloudBox *)sharedInstance;

@end

#define ThrowNonExistentResourceError(resourceIdentifier) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"GBCloudBox: Resource %@ doesn't exist. Register it first.", resourceIdentifier] userInfo:nil];

@interface GBCloudBoxResource ()

@property (assign, atomic) NSInteger                            cachedVersion;
@property (copy, atomic, readwrite) NSString                    *identifier;
@property (strong, atomic) NSData                               *cachedData;
@property (strong, atomic, readwrite) GBCloudBoxResourceMeta    *bundledResourceMeta;

@end

@implementation GBCloudBoxResourceMeta

+(GBCloudBoxResourceMeta *)metaWithPath:(NSString *)path version:(NSInteger)version {
    GBCloudBoxResourceMeta *meta = [GBCloudBoxResourceMeta new];
    meta.path = path;
    meta.version = version;
    
    return meta;
}

@end

@implementation GBCloudBoxResource

#pragma mark - memory

-(id)initWithResource:(NSString *)resourceIdentifier sourceServers:(NSArray *)sourceServers {
    if (self = [super init]) {
        self.identifier = resourceIdentifier;
        self.sourceServers = sourceServers;
        self.updatedHandlers = [NSMutableArray new];
 
        [self _initializeBundledMeta];
    }
    
    return self;
}

#pragma mark - private API

-(void)_initializeBundledMeta {
    NSDictionary *resourceInfo;
    if ((resourceInfo = _cb.bundledResourcesManifest[self.identifier])) {
        NSString *path = [[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:kBundledResourcesBundleName] stringByAppendingPathComponent:resourceInfo[kBundledResourcesPathKey]];
        NSInteger version = [resourceInfo[kBundledResourcesVersionKey] integerValue];
        
        self.bundledResourceMeta = [GBCloudBoxResourceMeta metaWithPath:path version:version];
    }
    else {
        NSLog(@"GBCloudBox: Warning, no bundled resource available for %@. If the internet is down or the resource is requested before it gets updated, it won't be available.", self.identifier);
        self.bundledResourceMeta = nil;
    }
}

-(NSInteger)_latestVersionForPaths:(NSArray *)paths {
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
        
        return acc;
    }
    else {
        return 0;
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
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"GBCloudBox: Expected file but found directory" userInfo:@{@"path": path}];
    }
    //file doesnt exist
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
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"GBCloudBox: Couldnt create directory" userInfo:@{@"path": path}];
        }
        
        //return path
        return path;
    }
    //theres a file there
    else {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"GBCloudBox: Found file instead of folder in path" userInfo:@{@"path": path}];
    }
}

-(NSArray *)_allLocalVersionsPaths {
    NSString *resourcePath = [self _localPathForResource];
    NSArray *raw = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:resourcePath error:nil];
    NSArray *mapped = MapNSArray(raw, ^id(id object) {
        return [resourcePath stringByAppendingPathComponent:(NSString *)object];
    });
    
    return mapped;
}

-(NSInteger)_latestLocalVersionNumber {
    return [self _latestVersionForPaths:[self _allLocalVersionsPaths]];
}

-(NSString *)_latestLocalVersionPath {
    return [[self _localPathForResource] stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld", (long)[self _latestLocalVersionNumber]]];
}

-(NSString *)_localPathForVersion:(NSInteger)version {
    return [[self _localPathForResource] stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld", (long)version]];
}

-(NSData *)_dataForLatestLocalVersion {
    return [self _dataForPath:[self _latestLocalVersionPath]];
}

-(void)_storeResourceLocally:(NSData *)data withVersion:(NSInteger)version {
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

-(NSInteger)_latestBundledVersionNumber {
    return self.bundledResourceMeta.version;
}

-(NSString *)_latestBundledVersionPath {
    return self.bundledResourceMeta.path;
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
    NSString *remoteResourceURLString = [[self _randomSourceServer] stringByAppendingPathComponent:[kRemoteResourcesMetaPath stringByAppendingPathComponent:self.identifier]];
    
    return [NSURL URLWithString:remoteResourceURLString];
}

-(void)_fetchRemoteMetaInfo:(ResourceMetaInfoHandler)handler {
    dispatch_async(_cb.networkQueue, ^{
        NSURL *remoteResourceMetaPath = [self _remoteResourceMetaPath];
        NSData *metaInfoData = [NSData dataWithContentsOfURL:remoteResourceMetaPath];
        
        NSDictionary *metaInfoDictionary = metaInfoData.length > 0 ? [NSJSONSerialization JSONObjectWithData:metaInfoData options:0 error:nil] : nil;

        if (metaInfoDictionary && [metaInfoDictionary isKindOfClass:NSDictionary.class]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (handler) {
                    NSInteger version = metaInfoDictionary[kRemoteMetaVersionKey] != [NSNull null] ? [metaInfoDictionary[kRemoteMetaVersionKey] integerValue] : 0;
                    NSURL *resourceURL = metaInfoDictionary[kRemoteMetaURLKey] != [NSNull null] ? [NSURL URLWithString:metaInfoDictionary[kRemoteMetaURLKey]] : nil;
                    NSString *resourceMD5 = metaInfoDictionary[kRemoteMetaMD5] != [NSNull null] ? metaInfoDictionary[kRemoteMetaMD5] : nil;
                    handler(version, resourceURL, resourceMD5);
                }
            });
        }
    });
}

-(void)_fetchResourceFromURL:(NSURL *)remoteResourceURL handler:(ResourceDataHandler)handler {
    dispatch_async(_cb.networkQueue, ^{
        NSURLRequest *request = [NSURLRequest requestWithURL:remoteResourceURL];
        NSHTTPURLResponse *response;
        NSData *responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:nil];

        NSDictionary *headers = [response allHeaderFields];
        NSInteger responseVersion = [headers[@"Resource-Version"] integerValue];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (handler) {
                handler(responseVersion, responseData);
            }
        });
    });
}

//Other helpers

-(GBCloudBoxLatestVersion)_latestVersionStatus {
    NSInteger localVersion = [self localVersion];
    NSInteger bundledVersion = [self bundledVersion];
    
    //if they r both set, then find the biggest one
    if (localVersion && bundledVersion) {
        if (bundledVersion > localVersion) {
            return GBCloudBoxLatestVersionBundled;
        }
        else if (bundledVersion < localVersion) {
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
            handler(self.identifier, self.cachedVersion, self.cachedData);
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
-(NSInteger)localVersion {
    return [self _latestLocalVersionNumber];
}

//returns the number of the latest bundled version, if there isnt one it returns nil
-(NSInteger)bundledVersion {
    return [self _latestBundledVersionNumber];
}

//returns the greatest of localVersion and bundledVersion
-(NSInteger)latestAvailableVersion {
    switch ([self _latestVersionStatus]) {
        case GBCloudBoxLatestVersionLocal: {
            return [self localVersion];
        } break;
            
        case GBCloudBoxLatestVersionBundled:
        case GBCloudBoxLatestVersionEqual: {
            return [self bundledVersion];
        } break;
            
        case GBCloudBoxLatestVersionNeither: {
            return 0;
        } break;
    }
}

//asks the server if there is a newer version, and if there is: it fetches it, stores it in cache and on disk, deletes older local versions, calls handlers and posts notification
-(void)update {
    //first fetch remote meta
    [self _fetchRemoteMetaInfo:^(NSInteger latestRemoteVersion, NSURL *remoteResourceURL, NSString *remoteResourceMD5) {
        //check if remote has newer
        if (latestRemoteVersion > [self latestAvailableVersion]) {
            //fetch remote resource
            [self _fetchResourceFromURL:remoteResourceURL handler:^(NSInteger resourceVersion, NSData *resourceData) {
                //check fetched file integrity
                NSString *fetchedResourceMD5 = MD5ForData(resourceData);
                //md5 checksum is optional, we proceed if meta doesn't have an md5
                if(!remoteResourceMD5 || [fetchedResourceMD5 isEqual:remoteResourceMD5]) {
                    //if the resource fetch had the version HTTP header set, then use that, otherwise just assume the version is what the meta returned
                    NSInteger version = resourceVersion ?: latestRemoteVersion;
                    
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
                    if (resourceVersion) userInfo[@"version"] = @(resourceVersion);
                    
                    [[NSNotificationCenter defaultCenter] postNotificationName:kGBCloudBoxResourceUpdatedNotification object:self userInfo:[userInfo copy]];
                }
#ifdef GBCLOUDBOX_FAILED_MD5_CHECK_THROWS
                else {
                    if(remoteResourceMD5) {
                        //file integrity check failed
                        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[NSString stringWithFormat:@"GBCloudBox: md5 checksums don't match.\nRemote meta md5:\t%@\nFetched md5:\t\t%@", remoteResourceMD5, fetchedResourceMD5] userInfo:nil];
                    }
                }
#endif
            }];
        }
        else {
            //noop: up to date
        }
    }];
}

@end

@implementation GBCloudBox

#pragma mark - Memory

+(GBCloudBox *)sharedInstance {
    static GBCloudBox *sharedInstance;
    
    @synchronized(self) {
        if (!sharedInstance) {
            sharedInstance = [[GBCloudBox alloc] init];
        }
        return sharedInstance;
    }
}

-(id)init {
    self = [super init];
    if (self) {
        self.resources = [NSMutableDictionary new];
        self.bundledResourcesManifest = [self _readBundledResourcesManifest];
        self.networkQueue = dispatch_queue_create("com.goonbee.GBCloudBox.networkQueue", NULL);
    }
    return self;
}

-(void)dealloc {
    dispatch_release(self.networkQueue);
}

#pragma mark- public API

+(void)setSourceServers:(NSArray *)sourceServers {
    _cb.defaultSourceServers = sourceServers;
}

+(NSArray *)sourceServers {
    return _cb.defaultSourceServers;
}

+(void)registerResources:(NSArray *)resourceIdentifiers {
    for (NSString *resource in resourceIdentifiers) {
        [self registerResource:resource];
    }
}

+(void)registerResource:(NSString *)resourceIdentifier {
    [self registerResource:resourceIdentifier withSourceServers:nil];
}

+(BOOL)isResourceRegistered:(NSString *)resourceIdentifier {
    if (![resourceIdentifier isKindOfClass:NSString.class]) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"GBCloudBox: Must pass valid string for resourceIdentifier." userInfo:nil];
    
    return [self _isResourceRegistered:resourceIdentifier];
}

+(void)registerResource:(NSString *)resourceIdentifier withSourceServers:(NSArray *)servers {
    if (!resourceIdentifier || [resourceIdentifier isEqualToString:@""]) @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"GBCloudBox: Must pass valid string for resourceIdentifier." userInfo:nil];
    if ([self _isResourceRegistered:resourceIdentifier]) [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"GBCloudBox: Resource %@ is already registered", resourceIdentifier] userInfo:nil];
    
    NSArray *sourceServers = servers ?: [self sourceServers];
    if (!(sourceServers.count > 0)) [NSException exceptionWithName:NSInvalidArgumentException reason:@"GBCloudBox: No source servers registered." userInfo:nil];

    _cb.resources[resourceIdentifier] = [[GBCloudBoxResource alloc] initWithResource:resourceIdentifier sourceServers:sourceServers];
}

+(void)addPostUpdateHandler:(UpdateHandler)handler forResource:(NSString *)resourceIdentifier {
    GBCloudBoxResource *resource;
    if ((resource = _cb.resources[resourceIdentifier])) {
        [resource.updatedHandlers addObject:[handler copy]];
    }
    else {
        ThrowNonExistentResourceError(resourceIdentifier)
    }
}

+(void)setDeserializer:(Deserializer)deserializer forResource:(NSString *)resourceIdentifier {
    GBCloudBoxResource *resource;
    if ((resource = _cb.resources[resourceIdentifier])) {
        resource.deserializer = deserializer;
    }
    else {
        ThrowNonExistentResourceError(resourceIdentifier)
    }
}

+(void)syncResource:(NSString *)resourceIdentifier {
    GBCloudBoxResource *resource;
    if ((resource = _cb.resources[resourceIdentifier])) {
        [resource update];
    }
    else {
        ThrowNonExistentResourceError(resourceIdentifier)
    }
}

+(void)syncResources {
    for (GBCloudBoxResource *resourceName in _cb.resources) {
        [_cb.resources[resourceName] update];
    }
}

+(NSData *)dataForResource:(NSString *)resourceIdentifier {
    GBCloudBoxResource *resource;
    if ((resource = _cb.resources[resourceIdentifier])) {
        return [resource data];
    }
    else {
        ThrowNonExistentResourceError(resourceIdentifier)
    }
}

+(id)objectForResource:(NSString *)resourceIdentifier {
    GBCloudBoxResource *resource;
    if ((resource = _cb.resources[resourceIdentifier])) {
        return [resource object];
    }
    else {
        ThrowNonExistentResourceError(resourceIdentifier)
    }
}

#pragma mark - Private API

-(NSDictionary *)_readBundledResourcesManifest {
    NSString *manifestFilePath = [[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:kBundledResourcesBundleName] stringByAppendingPathComponent:kBundledResourcesManifestFile];
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:manifestFilePath];
    
    //verify the manifest
    if (![self _isManifestValid:manifest]) @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[NSString stringWithFormat:@"GBCloudBox: The manifest file %@ in %@ is invalid.", kBundledResourcesManifestFile, kBundledResourcesBundleName] userInfo:nil];
    
    return manifest;
}

-(BOOL)_isManifestValid:(NSDictionary *)manifest {
    //check that the manifest is a valid dict
    if (![manifest isKindOfClass:NSDictionary.class]) return NO;
    
    for (NSString *resource in manifest) {
        //check that key is string
        if (![resource isKindOfClass:NSString.class]) return NO;
        
        //check that version is number
        if (!([manifest[resource][kBundledResourcesVersionKey] integerValue] > 0)) return NO;
        
        //check that path is string
        if (![manifest[resource][kBundledResourcesPathKey] isKindOfClass:NSString.class]) return NO;
    }
    
    //must be valid
    return YES;
}

+(BOOL)_isResourceRegistered:(NSString *)resourceIdentifier {
    return (_cb.resources[resourceIdentifier] != nil);
}

@end
