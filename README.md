# Acidify

Make your app ready for the upcoming <a href="http://en.wikipedia.org/wiki/History_of_lysergic_acid_diethylamide#.22Bicycle_Day.22" target="_blank">Bicycle day</a> with Acidify. It is is a small, easy to use library that creates a psychedelic user experience for your iOS app. **No** changes in your original code are required. 


### What It Looks Like

|  before |  after |
|---|---|
|![Image](sample/before.gif?raw=true)|![Image](sample/after.gif?raw=true)|


### Usage
Add **Acidify.h** and **Acidify.m** files to your XCode project.
Just call **[Acidify start];** to turn on the effect, and
**[Acidify stop];** to stop it:

*For example*:
```objectivec 
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	[Acidify start];
    return YES;
}
```

Also check out the sample project.


### Supported Devices
Acidify requires iOS 7.1 or newer. 

Acidify performance depends on the complexity and performance of your app's original UI. For small and medium sized apps, Acidify typically runs at ~60 FPS even on old devices like iPhone 4.
