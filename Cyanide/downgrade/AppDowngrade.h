//
//  AppDowngrade.h
//  App Downgrade — SpringBoard-side payload entry point.
//
//  Asks SpringBoard to hand a purchase request for one specific App Store
//  version to the App Store daemon. Everything runs on a background queue and
//  the payload takes the SpringBoard RemoteCall session itself, so callers do
//  not need to hold settings_rc_lock().
//
//  appInfo must carry "trackId" (NSNumber or NSString). versionId is the
//  AppExtVrsId of the version to install.
//

#ifndef AppDowngrade_h
#define AppDowngrade_h

#import <Foundation/Foundation.h>

void app_downgrade_trigger_in_springboard(NSDictionary *appInfo, NSNumber *versionId);

#endif
