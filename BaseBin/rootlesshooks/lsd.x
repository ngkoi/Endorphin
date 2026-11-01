#import <Foundation/Foundation.h>
#import <libjailbreak/util.h>
#import <libroot.h>
#import <objc/runtime.h>

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static NSString *bundle_id_for_pid(pid_t pid)
{
	if (pid <= 1) return nil;
	char path[PATH_MAX];
	if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;

	NSString *pathStr = [NSString stringWithUTF8String:path];
	NSRange range = [pathStr rangeOfString:@".app/"];
	if (range.location == NSNotFound) {
		range = [pathStr rangeOfString:@".app"];
		if (range.location == NSNotFound) return nil;
	}
	NSString *appDir = [pathStr substringToIndex:range.location + 4];
	NSString *infoPlistPath = [appDir stringByAppendingPathComponent:@"Info.plist"];
	NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
	if (infoDict) {
		return infoDict[@"CFBundleIdentifier"];
	}
	return nil;
}

#define PID_CACHE_SIZE 64
static struct {
	pid_t pid;
	BOOL is_stealth;
	NSTimeInterval timestamp;
} g_pid_stealth_cache[PID_CACHE_SIZE];

static BOOL is_pid_stealth(pid_t pid)
{
	if (pid <= 1) return NO;

	NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
	size_t idx = (size_t)pid % PID_CACHE_SIZE;
	if (g_pid_stealth_cache[idx].pid == pid && (now - g_pid_stealth_cache[idx].timestamp < 3.0)) {
		return g_pid_stealth_cache[idx].is_stealth;
	}

	static NSDictionary *config = nil;
	static NSTimeInterval lastCheck = 0;
	if (now - lastCheck > 2.0 || !config) {
		lastCheck = now;
		config = [NSDictionary dictionaryWithContentsOfFile:JBROOT_PATH_NSSTRING(@"/basebin/config.plist")];
	}

	BOOL stealth = NO;
	NSNumber *stealthMode = config[@"StealthMode"];
	if (!stealthMode || [stealthMode boolValue]) {
		NSArray *stealthApps = config[@"StealthApps"];
		if (stealthApps && stealthApps.count > 0) {
			NSString *bundleID = bundle_id_for_pid(pid);
			if (bundleID && [stealthApps containsObject:bundleID]) {
				stealth = YES;
			}
		}
	}

	g_pid_stealth_cache[idx].pid = pid;
	g_pid_stealth_cache[idx].is_stealth = stealth;
	g_pid_stealth_cache[idx].timestamp = now;

	return stealth;
}

@interface LSApplicationProxy : NSObject
+ (id)applicationProxyForIdentifier:(id)arg1;
- (NSURL *)bundleURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (LSApplicationWorkspace *)defaultWorkspace;
- (NSArray *)applicationsAvailableForHandlingURLScheme:(NSString *)scheme;
@end

static BOOL is_jailbreak_bundle_path(const char *path)
{
	if (!path) return NO;
	if (strstr(path, "/private/preboot/") && strstr(path, "/procursus/")) return YES;
	if (strstr(path, "/var/jb/")) return YES;
	if (strstr(path, "/var/containers/Bundle/Application/") && (strstr(path, "TrollStore") || strstr(path, "Santander"))) return YES;
	return NO;
}

static BOOL is_jailbreak_url_scheme(NSString *scheme)
{
	if (!scheme || scheme.length == 0) return NO;
	NSString *s = [scheme lowercaseString];
	static NSSet *knownSchemes = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		knownSchemes = [[NSSet alloc] initWithObjects:
			@"sileo", @"zbra", @"cydia", @"filza", @"undecimus",
			@"santander", @"activator", @"shoebox", @"installer",
			@"postbox", @"apt-repo", @"dpkg", @"ssh", @"sftp",
			@"db-install", @"amethyst", @"checkra1n", @"substitute",
			@"ellekit", @"trollstore", @"apple-magnifier", nil];
	});
	if ([knownSchemes containsObject:s]) return YES;

	Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
	if (wsClass && [wsClass respondsToSelector:@selector(defaultWorkspace)]) {
		LSApplicationWorkspace *ws = [wsClass defaultWorkspace];
		if ([ws respondsToSelector:@selector(applicationsAvailableForHandlingURLScheme:)]) {
			NSArray *apps = [ws applicationsAvailableForHandlingURLScheme:s];
			for (id app in apps) {
				if ([app respondsToSelector:@selector(bundleURL)]) {
					NSURL *bundleURL = [app performSelector:@selector(bundleURL)];
					if (bundleURL && is_jailbreak_bundle_path(bundleURL.path.fileSystemRepresentation)) {
						return YES;
					}
				}
			}
		}
	}
	return NO;
}

%group URLHooks

static const void *kBlockSchemeTagKey = &kBlockSchemeTagKey;

%hook _LSURLOverride
- (id)initWithOriginalURL:(NSURL *)url
{
	NSNumber *tag = objc_getAssociatedObject(url, kBlockSchemeTagKey);
	if (tag && tag.boolValue) {
		return nil;
	}
	return %orig;
}
%end

%hook _LSCanOpenURLManager

- (void *)getIsURL:(NSURL *)url alwaysCheckable:(BOOL *)pCheckable hasHandler:(BOOL *)pHasHandler
{
	BOOL _checkable = NO;
	BOOL _hasHandler = NO;
	void *result = %orig(url, &_checkable, &_hasHandler);

	if (_checkable || _hasHandler) {
		NSNumber *tag = objc_getAssociatedObject(url, kBlockSchemeTagKey);
		if (tag && tag.boolValue) {
			_hasHandler = NO;
			_checkable = NO;
		}
	}

	if (pCheckable) *pCheckable = _checkable;
	if (pHasHandler) *pHasHandler = _hasHandler;
	return result;
}

- (BOOL)canOpenURL:(NSURL *)url publicSchemes:(BOOL)ispublic privateSchemes:(BOOL)isprivate XPCConnection:(NSXPCConnection *)connection error:(NSError **)perror
{
	BOOL blocked = NO;
	if (connection) {
		pid_t pid = connection.processIdentifier;
		if (is_pid_stealth(pid)) {
			if (is_jailbreak_url_scheme(url.scheme)) {
				objc_setAssociatedObject(url, kBlockSchemeTagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				blocked = YES;
			}
		}
	}

	BOOL ret = %orig;
	if (blocked) {
		return NO;
	}
	return ret;
}

%end

@interface _LSDOpenClient : NSObject
@property (retain, readonly) NSXPCConnection *XPCConnection;
@end

%hook _LSDOpenClient

- (void)openApplicationWithIdentifier:(NSString *)identifier options:(id)options useClientProcessHandle:(BOOL)useClientProcessHandle completionHandler:(void (^)(BOOL, NSError *))completionHandler
{
	if (self.XPCConnection) {
		pid_t pid = self.XPCConnection.processIdentifier;
		if (is_pid_stealth(pid)) {
			LSApplicationProxy *appProxy = [NSClassFromString(@"LSApplicationProxy") applicationProxyForIdentifier:identifier];
			if (appProxy && [appProxy respondsToSelector:@selector(bundleURL)]) {
				NSURL *bURL = [appProxy performSelector:@selector(bundleURL)];
				if (bURL && is_jailbreak_bundle_path(bURL.path.fileSystemRepresentation)) {
					if (completionHandler) {
						completionHandler(NO, [NSError errorWithDomain:NSOSStatusErrorDomain code:-10814 userInfo:nil]);
					}
					return;
				}
			}
		}
	}
	%orig;
}

- (void)openURL:(NSURL *)url fileHandle:(id)fileHandle options:(id)options completionHandler:(void (^)(BOOL, NSError *))completionHandler
{
	if (self.XPCConnection) {
		pid_t pid = self.XPCConnection.processIdentifier;
		if (is_pid_stealth(pid)) {
			if (is_jailbreak_url_scheme(url.scheme)) {
				if (completionHandler) {
					completionHandler(NO, [NSError errorWithDomain:NSOSStatusErrorDomain code:-10814 userInfo:nil]);
				}
				return;
			}
		}
	}
	%orig;
}

- (void)openURL:(NSURL *)url options:(id)options completionHandler:(void (^)(BOOL, NSError *))completionHandler
{
	if (self.XPCConnection) {
		pid_t pid = self.XPCConnection.processIdentifier;
		if (is_pid_stealth(pid)) {
			if (is_jailbreak_url_scheme(url.scheme)) {
				if (completionHandler) {
					completionHandler(NO, [NSError errorWithDomain:NSOSStatusErrorDomain code:-10814 userInfo:nil]);
				}
				return;
			}
		}
	}
	%orig;
}

%end

%end // %group URLHooks

%hookf(NSURL *, _LSGetInboxURLForBundleIdentifier, NSString *bundleIdentifier)
{
	NSURL *origURL = %orig;
	if (![bundleIdentifier hasPrefix:@"com.apple"] && [origURL.path hasPrefix:@"/var/mobile/Library/Application Support/Containers/"]) {
		return [NSURL fileURLWithPath:JBROOT_PATH_NSSTRING(origURL.path)];
	}
	return origURL;
}

%hookf(int, _LSServer_RebuildApplicationDatabases)
{
	int r = %orig;

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		// Ensure jailbreak apps are readded to icon cache after the system reloads it
		// A bit hacky, but works
		const char *uicachePath = JBROOT_PATH_CSTRING("/usr/bin/uicache");
		if (!access(uicachePath, F_OK)) {
			exec_cmd(uicachePath, "-a", NULL);
		}
	});

	return r;
}

void lsdInit(void)
{
	MSImageRef coreServicesImage = MSGetImageByName("/System/Library/Frameworks/CoreServices.framework/CoreServices");
	if (coreServicesImage) {
		%init(_LSGetInboxURLForBundleIdentifier = MSFindSymbol(coreServicesImage, "__LSGetInboxURLForBundleIdentifier"),
		  _LSServer_RebuildApplicationDatabases = MSFindSymbol(coreServicesImage, "__LSServer_RebuildApplicationDatabases"));
	}
	%init(URLHooks);
}
