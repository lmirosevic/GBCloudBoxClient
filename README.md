GBCloudBox Client (iOS & Mac OS X)
============

GBCloudBox is a framework for over-the-air, asynchronous, in-the-background, resource syncing between iOS/Mac OS X apps and a server. Let's say your app depends on a javascript resource file called `MyResource.js`, but you want to be able to change it often without resubmitting your entire app to the App Store. GBCloudBox allows you to ship a bundled version of the resource inside your app, publish and distribute your app, and then once the app is out in the wild push updated versions of your resource to the cloud and have your apps in the wild automatically sync the resource as soon as the new one becomes available.

It comes with a [server implementation](https://github.com/lmirosevic/GBCloudBoxServer-Ruby) which is preconfigured for 1 click deployment to Heroku. It's thoroughly load tested and can support 1300 req/s with a concurrency of 1000 users on a single dyno (i.e. for free). At overload capacity, it degrades gracefully and can maintain ~800ms end-to-end response time with 4000 concurrently connected users with about 38% dropped requests; i.e. a throughput of 3100 successful req/s.

Usage
------------

In your app include a folder called `GBCloudBoxResource.bundle`. Save any resources which you want to ship along with the app inside there. Resources should be saved as a folder with numbered files inside to indicate versions. e.g. you would save the file `MyResource.js` version 4 as `GBCloudBoxResources.bundle/MyResource.js/4`. File version should be incrementing integers.

First import header:

```objective-c
#import <GBCloudBox/GBCloudBox.h>
```

Then you would register a resource like so:

```objective-c
// Tell GBCloudBox where to look for updates: enter an array of servers, the library will load balance between them
[GBCloudBox registerResource:@"MyResource.js" withSourceServers:@[@"mygbcloudboxserver1.herokuapp.com", @"mygbcloudboxserver2.herokuapp.com"]];
```

Then anywhere in your app get the resource data:

```objective-c
NSData *scriptData = [GBCloudBox dataForResource:@"MyResource.js"];
```

And then you would have an `NSData` instance representing the latest version of your resource.

I like to register a deserializer for my resources, so that I can easily obtain native objects instead of NSData instances, in this case our resource is an NSString so our deserializer would be something like:

```objective-c
[GBCloudBox registerDeserializer:^id(NSData *data) {
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
} forResource:@"MyResource.js"];
```

And then every time I want the NSString object it's as simple as:

```objective-c
NSString *script = [GBCloudBox objectForResource:@"MyResource.js"];
```

You have to decide when to sync the object. It is an asynchronous background sync so you can do it e.g. when your app starts up. To sync the latest version with our server for our resource you would call:

```objective-c
[GBCloudBox syncResource:@"Facebook.js"];
```

And GBCloudBox will post a `kGBCloudBoxResourceUpdatedNotification` notification once it's updated. Then you can simply get the latest version by calling `objectForResource:` or `dataForResource:` like above.

Alternatively, there's also a block based API for registering a post-update handler:

```objective-c
[GBCloudBox registerPostUpdateHandler:^(NSString *identifier, NSNumber *version, NSData *data) {
    //do something now that the resource has been updated
} forResource:@"MyResource.js"];
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