GBCloudBox Client (iOS & Mac OS X)
============

GBCloudBox is a framework for over-the-air, asynchronous, in-the-background, resource syncing between iOS or Mac OS X apps and a server. Let's say your app depends on a javascript resoruce called `MyResource.js`, but you want to be able to change it often without resubmitting to the app store. GBCloudBox allows you to ship a bundled version of the resource inside your app, and push updated versions of your resource to the cloud and have your apps in the wild sync the resource once you push a new version.

It comes with a server (see below) implementation which is configured for 1 click deployment to Heroku. It is implemented using Ruby with Async Sinatra (Eventmachine) and is deployed with the Rainbows server. It consumes about 35MB/process. Configured to spawn 12 worker processes on Heroku, corresponding to 3 per core. Has been thoroughly load tested and can sustain a peak performance with 0% error rate of 1000 concurrent requests with an end-to-end response time of ~750ms on a single dyno (i.e. for free!); this corresponds to about 1300 req/s with a concurrency of 4000 simulatenously connected users. The server features graceful degradation at overload capacity: tested at 4000 concurrent users, the server will maintain a ~800ms response rate with 38% dropped requests for a throughput of 3100 successful req/s. This is all on a single free dyno. App is stateless so you can scale your dynos and multiply performance linearly for the price of additional dynos. Or you can create several single-dyno free Heroku apps, and load balance on the client for free.

Usage
------------

In your app include a folder called `GBCloudBoxResource.bundle`. Save any resources to be bundle along with the app inside there. Resources should be saved as a folder with numbered files inside to indicate versions. e.g. you would save the file `MyResource.js` version 4 as `GBCloudBoxResources.bundle/MyResource.js/4`. File version should be incrementing integers.

First import header:

```objective-c
#import <GBCloudBox/GBCloudBox.h>
```

Then you would register a resource like so:

// Tell GBCloudBox where to look for updates, enter an array of servers, the library will load balance between them
[GBCloudBox registerResource:@"MyResource.js" withSourceServers:@[@"mygbcloudboxserver1.herokuapp.com", @"mygbcloudboxserver2.herokuapp.com"]];


Then get the resource data like so:

NSData *scriptData = [GBCloudBox dataForResource:@"MyResource.js"];

And then you would have an `NSData` instance representing the latest version of your resource.

I like to register a deserializer for my resources, so that I can easily obtain native objects instead of NSData instances, in this case our resource is an NSString::

[GBCloudBox registerDeserializer:^id(NSData *data) {
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
} forResource:@"MyResource.js"];

And then every time I want the object it's as simple as:

NSString *script = [GBCloudBox objectForResource:@"MyResource.js"];

You have to decide when to sync the object. It is an asynchronous background sync. To sync the latest version with our server for our resource you would call:

[GBCloudBox syncResource:@"Facebook.js"];

And GBCloudBox will post a `kGBCloudBoxResourceUpdatedNotification` notification once it's updated. Then you can simply get the latest version by calling `objectForResource:` or `dataForResource:` like above.

There is also a block based API for registering an updated handler:

[GBCloudBox registerPostUpdateHandler:^(NSString *identifier, NSNumber *version, NSData *data) {
    //do something now that the resource has been updated
} forResource:@"MyResource.js"];

Storage
------------

Your app can come bundled with resources so that it's ready to go even without an internet connection right from day 1. When your app syncs with the server and gets an updated version, it caches/stores this version locally to disk so that from that point onwards the latest version is always available, even if the internet won't be accessible again. When there is an internet connection available, the library will make a best effort to update, and will take care of caching and making sure your app always has the latest version available. The library is clever to only download the resource when a new version is available, so you can have arbitrarily large resources.

Server (Ruby)
------------

See: [github.com/lmirosevic/GBCloudBoxServer-Ruby](https://github.com/lmirosevic/GBCloudBoxServer-Ruby)


Copyright & License
------------

Copyright 2013 Luka Mirosevic

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this work except in compliance with the License. You may obtain a copy of the License in the LICENSE file, or at:

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.