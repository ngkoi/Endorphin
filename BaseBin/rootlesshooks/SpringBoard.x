#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/objc.h>
#import <libroot.h>
#import <fcntl.h>
#import <libjailbreak/jbclient_xpc.h>

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

static BOOL is_stealth_bundle_id(NSString *bundleID)
{
	if (!bundleID || bundleID.length == 0) return NO;

	static NSDictionary *config = nil;
	static NSTimeInterval lastCheck = 0;
	NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
	if (now - lastCheck > 2.0 || !config) {
		lastCheck = now;
		config = [NSDictionary dictionaryWithContentsOfFile:JBROOT_PATH_NSSTRING(@"/basebin/config.plist")];
	}

	NSNumber *stealthMode = config[@"StealthMode"];
	if (stealthMode && ![stealthMode boolValue]) return NO;

	NSArray *stealthApps = config[@"StealthApps"];
	if (!stealthApps) return NO;

	return [stealthApps containsObject:bundleID];
}

static BOOL gStealthVarJbHidden = NO;

static void set_stealth_var_jb_hidden(BOOL hidden)
{
	if (gStealthVarJbHidden != hidden) {
		gStealthVarJbHidden = hidden;
		jbclient_systemwide_set_stealth_mode(hidden);
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

		if (bundleID && is_stealth_bundle_id(bundleID)) {
			set_stealth_var_jb_hidden(YES);
		} else {
			set_stealth_var_jb_hidden(NO);
		}
	}
	@catch (NSException *e) {
	}
}

%end

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
@end

%hook SBApplication

- (void)didActivate
{
	%orig;
	@try {
		NSString *bundleID = [self bundleIdentifier];
		if (bundleID && is_stealth_bundle_id(bundleID)) {
			set_stealth_var_jb_hidden(YES);
		} else {
			set_stealth_var_jb_hidden(NO);
		}
	}
	@catch (NSException *e) {
	}
}

- (void)didDeactivate
{
	%orig;
	@try {
		NSString *bundleID = [self bundleIdentifier];
		if (bundleID && is_stealth_bundle_id(bundleID)) {
			set_stealth_var_jb_hidden(NO);
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
}
