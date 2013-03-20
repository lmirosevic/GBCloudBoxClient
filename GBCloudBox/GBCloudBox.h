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

typedef void(^UpdateHandler)(NSNumber *version, NSData *data);

@interface GBCloudBox : NSObject

+(void)registerResource:(NSString *)resourceIdentifier withBundledResourcePath:(NSString *)bundledResourcePath andSourceServers:(NSArray *)servers;
+(void)registerUpdateHandler:(UpdateHandler)handler forResource:(NSString *)resourceIdentifier;
+(void)syncResource:(NSString *)resourceIdentifier;
+(void)syncResources;
+(NSData *)dataForResource:(NSString *)resourceIdentifier;

@end


//foo maybe change public facing version numbers to NSUInteger

//test it with malicious data, like what happens if i dont give it a server, or if the server doesnt exist/respond, or if the server responds with sth bad