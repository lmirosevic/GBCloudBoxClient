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


NSString * const kGBCloudBoxResourceUpdatedNotification = @"kGBCloudBoxResourceUpdatedNotification";

static NSString * const kLocalResourcesDirectory = @"GBCloudBoxResources";
static NSString * const kRemoteResourcesPath = @"GBCloudBoxResources";
static BOOL const shouldUseSSL = YES;

typedef void(^ResourceMetaInfoHandler)(NSNumber *latestRemoteVersion, NSURL *remoteResourceURL);
typedef void(^ResourceDataHandler)(NSNumber *resourceVersion, NSData *resourceData);

@interface GBCloudBoxResource : NSObject

@property (copy, atomic, readonly) NSString         *identifier;
@property (strong, atomic) NSMutableArray           *updatedHandlers;
@property (strong, atomic) NSArray                  *sourceServers;
@property (strong, atomic, readonly) NSString       *bundledResourcePath;

//init method
-(id)initWithResource:(NSString *)resourceIdentifier bundledResourcePath:(NSString *)bundledResourcePath andSourceServers:(NSArray *)sourceServers;

//updates the resource if necessary
-(void)update;

//returns the data for the resource, tries cache first, otherwise latest local version, otherwise latest bundled version
-(NSData *)data;

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
    return [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
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
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self _localPathForResource] error:nil];
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
    return self.sourceServers[arc4random_uniform(self.sourceServers.count)];
}

-(NSURL *)_remoteResourcePath {
    NSString *remoteResourcePath = [[[shouldUseSSL ? @"https://" : @"http://" stringByAppendingPathComponent:[self _randomSourceServer]] stringByAppendingPathComponent:kRemoteResourcesPath] stringByAppendingPathComponent:self.identifier];
    
    return [NSURL URLWithString:remoteResourcePath];
}

-(void)_fetchRemoteMetaInfo:(ResourceMetaInfoHandler)handler {
    dispatch_async(self.networkQueue, ^{
        NSData *metaInfoData = [NSData dataWithContentsOfURL:[self _remoteResourcePath]];
        NSDictionary *metaInfoDictionary = [self _dictionaryFromJSONData:metaInfoData];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (handler) {
                NSNumber *version = metaInfoDictionary[@"v"];
                NSURL *resourceURL = [NSURL URLWithString:metaInfoDictionary[@"url"]];
                handler(version, resourceURL);
            }
        });
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

-(void)_callHandlers {
    for (UpdateHandler handler in self.updatedHandlers) {
        if (handler) {
            handler(self.cachedVersion, self.cachedData);
        }
    }
}

#pragma mark - public API

//returns the data for the resource, tries cache first, otherwise latest local version, otherwise latest bundled version
-(NSData *)data {
    @synchronized(self) {
        //check cache first
        if (!_cachedData) {
            //try to get the latest local version
            if ((_cachedData = [self _dataForLatestLocalVersion])) {
                _cachedVersion = [self _latestLocalVersionNumber];
            }
            //otherwise try to get latest bundled version
            else if (!(_cachedData = [self _dataForLatestBundledVersion])) {
                _cachedVersion = [self _latestBundledVersionNumber];
            }
        }
        
        return _cachedData;
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
    NSNumber *localVersion = [self localVersion];
    NSNumber *bundledVersion = [self bundledVersion];
    
    NSComparisonResult result = [localVersion compare:bundledVersion];
    
    if (result == NSOrderedAscending) {
        return bundledVersion;
    }
    else {
        return localVersion;
    }
}

//asks the server if there is a newer version, and if there is: it fetches it, stores it in cache and on disk, deletes older local versions, calls handlers and posts notification
-(void)update {
    NSLog(@"fetch remote meta");
    //first fetch remote meta
    [self _fetchRemoteMetaInfo:^(NSNumber *latestRemoteVersion, NSURL *remoteResourceURL) {
        //check if remote has newer
        if ([[self latestAvailableVersion] compare:latestRemoteVersion] == NSOrderedAscending) {
            NSLog(@"fetch remote resource");
            //fetch remote resource
            [self _fetchResourceFromURL:remoteResourceURL handler:^(NSNumber *version, NSData *data) {
                //store the resource in cache
                self.cachedData = data;
                self.cachedVersion = version;
                
                //store to disk
                [self _storeResourceLocally:data withVersion:version];
                
                //remove older ones from disk
                [self _deleteOlderLocalResourceVersions];
                
                //call handlers
                [self _callHandlers];
                
                //send notification
                [[NSNotificationCenter defaultCenter] postNotificationName:kGBCloudBoxResourceUpdatedNotification object:self userInfo:@{@"data": data, @"version": version}];
            }];
        }
        else {
            NSLog(@"up to date");
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

+(void)registerResource:(NSString *)resourceIdentifier withBundledResourcePath:(NSString *)bundledResourcePath andSourceServers:(NSArray *)servers {
    if (resourceIdentifier && ![resourceIdentifier isEqualToString:@""]) {
        //if the resource doesn't exist, create it
        if (!_cb.resources[resourceIdentifier]) {
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

+(void)registerUpdateHandler:(UpdateHandler)handler forResource:(NSString *)resourceIdentifier {
    GBCloudBoxResource *resource;
    if ((resource = _cb.resources[resourceIdentifier])) {
        [resource.updatedHandlers addObject:[handler copy]];
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

@end
