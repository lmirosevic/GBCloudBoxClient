//
//  GBCloudBox.h
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

#import <Foundation/Foundation.h>

extern NSString * const kGBCloudBoxResourceUpdatedNotification;

typedef void(^UpdateHandler)(NSString *identifier, NSInteger version, NSData *data);
typedef id(^Deserializer)(NSData *data);

@interface GBCloudBox : NSObject

//Simple
+(void)setSourceServers:(NSArray *)sourceServers;
+(NSArray *)sourceServers;
+(void)registerResource:(NSString *)resourceIdentifier;
+(void)registerResources:(NSArray *)resourceIdentifiers;
+(BOOL)isResourceRegistered:(NSString *)resourceIdentifier;
+(NSData *)dataForResource:(NSString *)resourceIdentifier;
+(void)setDeserializer:(Deserializer)deserializer forResource:(NSString *)resourceIdentifier;
+(id)objectForResource:(NSString *)resourceIdentifier;
+(void)addPostUpdateHandler:(UpdateHandler)handler forResource:(NSString *)resourceIdentifier;
+(void)syncResource:(NSString *)resourceIdentifier;
+(void)syncResources;

//Advanced
+(void)registerResource:(NSString *)resourceIdentifier withSourceServers:(NSArray *)sourceServers;

//Debug
+(BOOL)isMD5CheckThrows;                //if YES then throw an exception on MD5 checksum test failure
+(void)setMD5CheckThrows:(BOOL)throws;

@end
