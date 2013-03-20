//
//  GBCloudBox.h
//  GBCloudBox
//
//  Created by Luka Mirosevic on 20/03/2013.
//  Copyright (c) 2013 Goonbee. All rights reserved.
//

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