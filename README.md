GBCloudBox Client (iOS & Mac OS X)
============

GBCloudBox is a framework for over-the-air, asynchronous, in-the-background, resource syncing between iOS/Mac OS X apps and a server. Let's say your app depends on a javascript resource file called `MyResource.js`, but you want to be able to change it often without resubmitting your entire app to the App Store. GBCloudBox allows you to ship a bundled version of the resource inside your app, publish and distribute your app, and then once the app is out in the wild push updated versions of your resource to the cloud and have your apps in the wild automatically sync the resource as soon as the new one becomes available.

It comes with a [server implementation](https://github.com/lmirosevic/GBCloudBoxServer-Ruby) which is preconfigured for 1 click deployment to Heroku. It's thoroughly load tested and can support 1300 req/s with a concurrency of 1000 users on a single dyno (i.e. for free). At overload capacity, it degrades gracefully and can maintain ~800ms end-to-end response time with 4000 concurrently connected users with about 38% dropped requests; i.e. a throughput of 3100 successful req/s. You can also write your own server implementation if you wish.

Usage
------------

First add the GBCloudBox server(s):
```objective-c
//Set the source servers, takes an array so if you have multiple servers, the library will load balance between them
[GBCloudBox setSourceServers:@[@"https://www.server1.com", @"https://www.server2.com"]];
```

Then register a resource:
```objective-c
[GBCloudBox registerResource:@"MyResource.js"];
```

Then anywhere in your app you can get the resource data:
```objective-c
NSData *scriptData = [GBCloudBox dataForResource:@"MyResource.js"];
```

And then you would have an `NSData` instance representing the latest version of your resource.

I like to register a deserializer for my resources, so that I can easily obtain native objects instead of `NSData` instances, in this case our resource is an `NSString` so our deserializer would be something like:

```objective-c
[GBCloudBox setDeserializer:^id(NSData *data) {
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
} forResource:@"MyResource.js"];
```

Now every time I want the actual `NSString` object it's as simple as:

```objective-c
NSString *script = [GBCloudBox objectForResource:@"MyResource.js"];
```

You have to decide when to sync the object. It is an asynchronous background sync so you can do it e.g. when your app starts up. To sync the latest version with the server for our resource you would call:

```objective-c
[GBCloudBox syncResource:@"MyResource.js"];
```

To sync all registered resources just call:
```objective-c
[GBCloudBox syncResources];
```

GBCloudBox will post a `kGBCloudBoxResourceUpdatedNotification` notification once it's updated. Then you can simply get the latest version by calling `objectForResource:` or `dataForResource:` like above.

Alternatively, there's also a block based API for registering a post-update handler:

```objective-c
[GBCloudBox addPostUpdateHandler:^(NSString *identifier, NSInteger version, NSData *data) {
    //do something now that the resource has been updated
} forResource:@"MyResource.js"];
```

It's a good idea to bundle an initial version of the resource along with the app so it's available immediately (in case the user doesn't have internet or in case the app won't run without it).

In your app include a folder called `GBCloudBoxResource.bundle`. Save any resources which you want to ship along with the app inside there. Inside this bundle, add a `Manifest.plist` plist which enumerates the bundled resources along with their versions. The `Manifest.plist` has the following format:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>MyResource.js</key>
	<dict>
		<key>version</key>
		<integer>1</integer>
		<key>path</key>
		<string>Resources/MyResource.js</string>
	</dict>
	<key>SomeOtherResource.json</key>
	<dict>
		<key>version</key>
		<integer>4</integer>
		<key>path</key>
		<string>Resources/SomeOtherResource.json</string>
	</dict>
</dict>
</plist>
```

The library will then intelligently select the latest available resource, cache the latest version, and always stay up to date.

Don't forget to import header:

```objective-c
#import <GBCloudBox/GBCloudBox.h>
```

Storage
------------

Your app can come bundled with resources so that it's ready to go even without an internet connection right from day 1. When your app syncs with the server and gets an updated version, it caches/stores this version locally to disk so that from that point onwards the latest version is always available, even if the internet won't be accessible again. When there is an internet connection available, the library will make a best effort to update, and will take care of caching and making sure your app always has the latest version available. The library is clever to only download the resource when a new version is available, so you can have arbitrarily large resources and it will behave reasonably.

Server (Ruby)
------------

See: [github.com/lmirosevic/GBCloudBoxServer-Ruby](https://github.com/lmirosevic/GBCloudBoxServer-Ruby)


Copyright & License
------------

Copyright 2013 Luka Mirosevic

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this work except in compliance with the License. You may obtain a copy of the License in the LICENSE file, or at:

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

[![Bitdeli Badge](https://d2weczhvl823v0.cloudfront.net/lmirosevic/gbcloudboxclient/trend.png)](https://bitdeli.com/free "Bitdeli Badge")
