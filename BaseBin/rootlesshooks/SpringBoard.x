#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/objc.h>
#import <libroot.h>
#import <fcntl.h>
#import <libjailbreak/jbclient_xpc.h>
#import <dlfcn.h>

bool string_has_prefix(const char *str, const char* prefix)
{
	if (!str || !prefix) {
		return false;
	}

	size_t str_len = strlen(str);
	size_t prefix_len = strlen(prefix);

	if (str_len < prefix_len) {
		return false;
	}

	return !strncmp(str, prefix, prefix_len);
}

@interface XBSnapshotContainerIdentity : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString* bundleIdentifier;
- (NSString*)snapshotContainerPath;
@end

%hook XBSnapshotContainerIdentity

- (NSString *)snapshotContainerPath
{
	NSString *path = %orig;
	if([path hasPrefix:@"/var/mobile/Library/SplashBoard/Snapshots/"] && ![self.bundleIdentifier hasPrefix:@"com.apple."]) {
		return JBROOT_PATH_NSSTRING(path);
	}
	return path;
}

%end

static NSDictionary *gCachedConfig = nil;

static NSDictionary *get_stealth_config(void)
{
	NSDictionary *newConfig = [NSDictionary dictionaryWithContentsOfFile:JBROOT_PATH_NSSTRING(@"/basebin/config.plist")];
	if (newConfig) {
		gCachedConfig = newConfig;
	}
	return gCachedConfig;
}

static BOOL is_stealth_bundle_id(NSString *bundleID)
{
	if (!bundleID || bundleID.length == 0) return NO;

	NSDictionary *config = get_stealth_config();
	if (config) {
		NSNumber *stealthMode = config[@"StealthMode"];
		if (stealthMode && ![stealthMode boolValue]) return NO;

		NSArray *stealthApps = config[@"StealthApps"];
		if (stealthApps) {
			for (NSString *app in stealthApps) {
				if ([bundleID isEqualToString:app] || [bundleID localizedCaseInsensitiveContainsString:app]) {
					return YES;
				}
			}
		}
	}

	// Built-in safety fallback for high-security applications
	if ([bundleID localizedCaseInsensitiveContainsString:@"vn.com.vneid"] ||
	    [bundleID localizedCaseInsensitiveContainsString:@"com.mbmobile"] ||
	    [bundleID localizedCaseInsensitiveContainsString:@"VNID"] ||
	    [bundleID localizedCaseInsensitiveContainsString:@"MB Bank"] ||
	    [bundleID localizedCaseInsensitiveContainsString:@"shopee"] ||
	    [bundleID localizedCaseInsensitiveContainsString:@"ShopeeVN"] ||
	    [bundleID localizedCaseInsensitiveContainsString:@"com.beeasy.shopee.vn"]) {
		return YES;
	}

	return NO;
}

static BOOL gStealthVarJbHidden = NO;
static NSString *gActiveStealthBundle = nil;

static void set_stealth_var_jb_hidden(BOOL hidden)
{
	if (gStealthVarJbHidden != hidden) {
		gStealthVarJbHidden = hidden;
		int (*set_stealth_fn)(bool) = (int (*)(bool))dlsym(RTLD_DEFAULT, "jbclient_systemwide_set_stealth_mode");
		if (set_stealth_fn) {
			set_stealth_fn(hidden);
		}
	}
}

static void update_stealth_mode_for_display(NSString *bundleID)
{
	if (bundleID && is_stealth_bundle_id(bundleID)) {
		gActiveStealthBundle = bundleID;
		set_stealth_var_jb_hidden(YES);
	} else if (gActiveStealthBundle) {
		gActiveStealthBundle = nil;
		set_stealth_var_jb_hidden(NO);
	}
}

// Battery Drain SafeShutdown Hibernation Protection
static BOOL gInDeepHibernation = NO;

static BOOL is_battery_drain_protection_enabled(void)
{
	NSDictionary *config = get_stealth_config();
	if (config) {
		NSNumber *opt = config[@"BatteryDrainProtection"];
		if (opt) return [opt boolValue];
	}
	return YES; // Default enabled
}

static BOOL should_enter_deep_hibernation(void)
{
	if (!is_battery_drain_protection_enabled()) return NO;

	UIDevice *device = [UIDevice currentDevice];
	[device setBatteryMonitoringEnabled:YES];
	float level = [device batteryLevel];
	UIDeviceBatteryState state = [device batteryState];

	if (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull) {
		return NO;
	}

	// Trigger on critical battery level (<= 2%)
	if (level >= 0.0f && level <= 0.02f) {
		return YES;
	}

	return NO;
}

@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
- (void)setBacklightFactor:(float)factor;
- (float)backlightFactor;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (void)lockUIFromSource:(int)source withOptions:(id)options;
- (void)wakeUpScreenForReason:(id)reason;
@end

static void enter_deep_hibernation(void)
{
	if (gInDeepHibernation) return;
	gInDeepHibernation = YES;

	@try {
		SBLockScreenManager *lsm = [%c(SBLockScreenManager) sharedInstance];
		if (lsm && [lsm respondsToSelector:@selector(lockUIFromSource:withOptions:)]) {
			[lsm lockUIFromSource:1 withOptions:nil];
		}

		SBBacklightController *bl = [%c(SBBacklightController) sharedInstance];
		if (bl && [bl respondsToSelector:@selector(setBacklightFactor:)]) {
			[bl setBacklightFactor:0.0f];
		}
	}
	@catch (NSException *e) {
	}
}

static void exit_deep_hibernation(void)
{
	if (!gInDeepHibernation) return;
	gInDeepHibernation = NO;

	@try {
		SBBacklightController *bl = [%c(SBBacklightController) sharedInstance];
		if (bl && [bl respondsToSelector:@selector(setBacklightFactor:)]) {
			[bl setBacklightFactor:1.0f];
		}

		SBLockScreenManager *lsm = [%c(SBLockScreenManager) sharedInstance];
		if (lsm && [lsm respondsToSelector:@selector(wakeUpScreenForReason:)]) {
			[lsm wakeUpScreenForReason:@"EndorphinChargerPluggedIn"];
		}
	}
	@catch (NSException *e) {
	}
}

@interface SpringBoard : UIApplication
@end

%hook SpringBoard

- (void)frontDisplayDidChange:(id)currentDisplay
{
	%orig;
	@try {
		NSString *bundleID = nil;
		if (currentDisplay && [currentDisplay respondsToSelector:@selector(bundleIdentifier)]) {
			bundleID = [currentDisplay bundleIdentifier];
		}
		update_stealth_mode_for_display(bundleID);
	}
	@catch (NSException *e) {
	}
}

- (void)_shutdownWithOptions:(id)options
{
	if (should_enter_deep_hibernation()) {
		enter_deep_hibernation();
		return;
	}
	%orig;
}

- (void)_handlePhysicalButtonEvent:(id)event
{
	if (gInDeepHibernation) {
		return; // Suppress screen wakeup on physical buttons while hibernating
	}
	%orig;
}

%end

@interface FBSystemService : NSObject
@end

%hook FBSystemService

- (void *)openApplication:(NSString *)bundleIdentifier withOptions:(id)options originator:(id)originator requestID:(void *)requestID completion:(void *)completion
{
	@try {
		if (bundleIdentifier && is_stealth_bundle_id(bundleIdentifier)) {
			update_stealth_mode_for_display(bundleIdentifier);
		}
	}
	@catch (NSException *e) {
	}
	return %orig;
}

- (void)shutdownWithOptions:(id)options
{
	if (should_enter_deep_hibernation()) {
		enter_deep_hibernation();
		return;
	}
	%orig;
}

%end

%hook SBBacklightController

- (void)setBacklightFactor:(float)factor
{
	if (gInDeepHibernation) {
		%orig(0.0f);
		return;
	}
	%orig(factor);
}

%end

%hook SBLockScreenManager

- (void)wakeUpScreenForReason:(id)reason
{
	if (gInDeepHibernation) {
		return;
	}
	%orig;
}

%end

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
@end

%hook SBApplication

- (void)willActivate
{
	%orig;
	@try {
		NSString *bundleID = [self bundleIdentifier];
		if (bundleID && is_stealth_bundle_id(bundleID)) {
			update_stealth_mode_for_display(bundleID);
		}
	}
	@catch (NSException *e) {
	}
}

- (void)didActivate
{
	%orig;
	@try {
		NSString *bundleID = [self bundleIdentifier];
		if (bundleID && is_stealth_bundle_id(bundleID)) {
			update_stealth_mode_for_display(bundleID);
		}
	}
	@catch (NSException *e) {
	}
}

%end

%hook FBSApplicationLibrary

- (id)applicationInfoForBundleIdentifier:(NSString *)bundleIdentifier
{
	id result = %orig;
	if (gStealthVarJbHidden) {
		if (result && [result respondsToSelector:@selector(executableURL)]) {
			NSURL *execURL = [result performSelector:@selector(executableURL)];
			if (execURL) {
				const char *p = execURL.path.fileSystemRepresentation;
				if (strstr(p, "/procursus/") || strstr(p, "/var/jb/")) {
					return nil;
				}
			}
		}
	}
	return result;
}

%end

%hookf(int, fcntl, int fildes, int cmd, ...) {
	if (cmd == F_SETPROTECTIONCLASS) {
		char filePath[PATH_MAX];
		if (fcntl(fildes, F_GETPATH, filePath) != -1) {
			// Skip setting protection class on jailbreak apps, this doesn't work and causes snapshots to not be saved correctly
			if (string_has_prefix(filePath, JBROOT_PATH_CSTRING("/var/mobile/Library/SplashBoard/Snapshots"))) {
				return 0;
			}
		}
	}

	va_list a;
	va_start(a, cmd);
	const char *arg1 = va_arg(a, void *);
	const void *arg2 = va_arg(a, void *);
	const void *arg3 = va_arg(a, void *);
	const void *arg4 = va_arg(a, void *);
	const void *arg5 = va_arg(a, void *);
	const void *arg6 = va_arg(a, void *);
	const void *arg7 = va_arg(a, void *);
	const void *arg8 = va_arg(a, void *);
	const void *arg9 = va_arg(a, void *);
	const void *arg10 = va_arg(a, void *);
	va_end(a);
	return %orig(fildes, cmd, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10);
}

void springboardInit(void)
{
	%init();

	// Battery monitoring for SafeShutdown / Deep Hibernation
	[[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];

	[[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceBatteryStateDidChangeNotification
													  object:nil
													   queue:[NSOperationQueue mainQueue]
												  usingBlock:^(NSNotification *note) {
		UIDeviceBatteryState state = [UIDevice currentDevice].batteryState;
		if (gInDeepHibernation && (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull)) {
			exit_deep_hibernation();
		}
	}];

	[[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceBatteryLevelDidChangeNotification
													  object:nil
													   queue:[NSOperationQueue mainQueue]
												  usingBlock:^(NSNotification *note) {
		if (should_enter_deep_hibernation() && !gInDeepHibernation) {
			enter_deep_hibernation();
		}
	}];
}
