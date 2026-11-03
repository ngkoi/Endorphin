#include <spawn.h>
#include <strings.h>
#include "../systemhook/src/common/common.h"
#include "../systemhook/src/common/envbuf.h"
#include "boomerang.h"
#include "crashreporter.h"
#include "update.h"
#include "respring_protection.h"
#include <libjailbreak/util.h>
#include <libjailbreak/bootlog.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <litehook.h>
#include "jbserver/jbserver_local.h"
#include "hookd_provider.h"
extern char **environ;

void abort_with_reason(uint32_t reason_namespace, uint64_t reason_code, const char *reason_string, uint64_t reason_flags);

extern int systemwide_trust_file_by_path(const char *path);
extern int platform_set_process_debugged(uint64_t pid, bool fullyDebugged);
extern void systemwide_domain_set_enabled(bool enabled);

#define LOG_PROCESS_LAUNCHES 0

extern bool gInEarlyBoot;
extern bool gFreeBootLogoBeforeBackboardd;
void draw_boot_logo(const char *bootLogoPath);
void free_boot_logo(void);

static bool string_contains_nocase(const char *haystack, const char *needle)
{
	if (!haystack || !needle) return false;
	size_t hlen = strlen(haystack);
	size_t nlen = strlen(needle);
	if (nlen > hlen) return false;
	for (size_t i = 0; i <= hlen - nlen; i++) {
		if (strncasecmp(&haystack[i], needle, nlen) == 0) {
			return true;
		}
	}
	return false;
}

static bool is_stealth_xpcproxy_target(const char *arg)
{
	if (!arg) return false;

	xpc_object_t stealthModeObj = jbuserconfig_get_value("StealthMode");
	bool stealthEnabled = true;
	if (stealthModeObj && xpc_get_type(stealthModeObj) == XPC_TYPE_BOOL) {
		stealthEnabled = xpc_bool_get_value(stealthModeObj);
	}

	if (stealthEnabled) {
		xpc_object_t stealthApps = jbuserconfig_get_value("StealthApps");
		if (stealthApps && xpc_get_type(stealthApps) == XPC_TYPE_ARRAY) {
			size_t count = xpc_array_get_count(stealthApps);
			for (size_t i = 0; i < count; i++) {
				const char *entry = xpc_array_get_string(stealthApps, i);
				if (entry && string_contains_nocase(arg, entry)) {
					return true;
				}
			}
		}
	}

	const char *fallbackTargets[] = {
		"vn.com.vneid",
		"com.mbmobile",
		"VNID",
		"MB Bank",
		"shopee",
		"ShopeeVN",
		"com.beeasy.shopee.vn"
	};
	for (size_t i = 0; i < sizeof(fallbackTargets) / sizeof(fallbackTargets[0]); i++) {
		if (string_contains_nocase(arg, fallbackTargets[i])) {
			return true;
		}
	}

	return false;
}

void early_boot_done(void)
{
	gInEarlyBoot = false;
}

void ensure_fakelib_mounted(void)
{
	struct statfs fsb;
	if (statfs("/usr/lib", &fsb) != 0) return;
	if (strcmp(fsb.f_mntonname, "/usr/lib") != 0) {
		systemwide_domain_set_enabled(true);

		// The jailbreak server is not reachable at this point in the launchd lifecycle
		// So we need to host our own, just so that jbctl can talk to it
		mach_port_t serverPort = jbserver_local_start();
		jbctl_earlyboot(serverPort, "internal", "fakelib", "mount", NULL);
		jbserver_local_stop();

		// Note down that the jailbreak was hidden
		// So that after the userspace reboot, we can unmount fakelib again
		setenv("DOPAMINE_IS_HIDDEN", "1", true);
	}
}

int __posix_spawn_orig_wrapper(pid_t *restrict pid, const char *restrict path,
					   struct _posix_spawn_args_desc *desc,
					   char *const argv[restrict],
					   char *const envp[restrict])
{
	// we need to disable the crash reporter during the orig call
	// otherwise the child process inherits the exception ports
	// and this would trip jailbreak detections
	crashreporter_pause();	
	int r = __posix_spawn_inline(pid, path, desc, argv, envp);
	crashreporter_resume();

	return r;
}

int __posix_spawn_hook(pid_t *restrict pid, const char *restrict path,
					   struct _posix_spawn_args_desc *desc,
					   char *const argv[restrict],
					   char *const envp[restrict])
{
	if (path) {
		char executablePath[1024];
		uint32_t bufsize = sizeof(executablePath);
		_NSGetExecutablePath(&executablePath[0], &bufsize);
		if (!strcmp(path, executablePath)) {
			// This spawn will perform a userspace reboot...
			// Instead of the ordinary hook, we want to reinsert this dylib
			// This has already been done in envp so we only need to call the original posix_spawn

			draw_boot_logo(JBROOT_PATH("/basebin/bootlogo.jp2"));
			gFreeBootLogoBeforeBackboardd = true;

			// We are back in "early boot" for the remainder of this launchd instance
			// Mainly so we don't lock up while spawning boomerang
			gInEarlyBoot = true;

			hookd_provider_teardown();

			// If the jailbreak is currently hidden, fakelib is not mounted
			// It needs to be mounted to regain launchd code execution after the userspace reboot
			ensure_fakelib_mounted();

#if LOG_PROCESS_LAUNCHES
			FILE *f = fopen("/var/mobile/launch_log.txt", "a");
			fprintf(f, "==== USERSPACE REBOOT ====\n");
			fclose(f);
#endif

			// Before the userspace reboot, we want to stash the primitives into boomerang
			bootlog_info("Stashing primitives into boomerang...");
			boomerang_stashPrimitives();
			bootlog_success("Primitives stashed");

			// Fix Xcode debugging being broken after the userspace reboot
			if (__builtin_available(iOS 17.0, *)) {
				unmount("/System/Developer", MNT_FORCE);
			}
			else {
				unmount("/Developer", MNT_FORCE);
			}

			// If there is a pending jailbreak update, apply it now
			const char *stagedJailbreakUpdate = getenv("STAGED_JAILBREAK_UPDATE");
			if (stagedJailbreakUpdate) {
				bootlog_info("Applying staged jailbreak update: %s", stagedJailbreakUpdate);
				int r = jbupdate_basebin(stagedJailbreakUpdate);
				if (r != 0) {
					char msg[1000];
					snprintf(msg, 1000, "Failed updating basebin (error %d).", r);
					bootlog_error("%s", msg);
					sleep(5);
					abort_with_reason(7, 1, msg, 0);
				}
				bootlog_success("Basebin updated successfully");
				unsetenv("STAGED_JAILBREAK_UPDATE");
			}

			// Always use environ instead of envp, as boomerang_stashPrimitives calls setenv
			// setenv / unsetenv can sometimes cause environ to get reallocated
			// In that case envp may point to garbage or be empty
			// Say goodbye to this process
			return __posix_spawn_orig_wrapper(pid, path, desc, argv, environ);
		}
	}

#if LOG_PROCESS_LAUNCHES
	if (path) {
		FILE *f = fopen("/var/mobile/launch_log.txt", "a");
		fprintf(f, "%s", path);
		int ai = 0;
		while (argv) {
			if (argv[ai]) {
				if (ai >= 1) {
					fprintf(f, " %s", argv[ai]);
				}
				ai++;
			}
			else {
				break;
			}
		}
		fprintf(f, "\n");
		fclose(f);

		// if (!strcmp(path, "/usr/libexec/xpcproxy")) {
		// 	const char *tmpBlacklist[] = {
		// 		"com.apple.logd"
		// 	};
		// 	size_t blacklistCount = sizeof(tmpBlacklist) / sizeof(tmpBlacklist[0]);
		// 	for (size_t i = 0; i < blacklistCount; i++)
		// 	{
		// 		if (!strcmp(tmpBlacklist[i], firstArg)) {
		// 			FILE *f = fopen("/var/mobile/launch_log.txt", "a");
		// 			fprintf(f, "blocked injection %s\n", firstArg);
		// 			fclose(f);
		// 			return __posix_spawn_orig_wrapper(pid, path, file_actions, desc, envp);
		// 		}
		// 	}
		// }
	}
#endif

	// We can't support injection into processes that get spawned before the launchd XPC server is up
	// (Technically we could but there is little reason to, since it requires additional work)
	if (gInEarlyBoot) {
		if (!strcmp(path, "/usr/libexec/xpcproxy")) {
			// The spawned process being xpcproxy indicates that the launchd XPC server is up
			// All processes spawned including this one should be injected into
			early_boot_done();
		}
		else {
			return __posix_spawn_orig_wrapper(pid, path, desc, argv, envp);
		}
	}

	// If we're drawing a boot logo, free up it's resources before backboardd starts
	if (gFreeBootLogoBeforeBackboardd) {
		if (!strcmp(path, "/usr/libexec/xpcproxy")) {
			if (argv[0]) {
				if (argv[1]) {
					if (!strcmp(argv[1], "com.apple.backboardd")) {
						bootlog_info("Starting backboardd, releasing boot console...");
						free_boot_logo();
						gFreeBootLogoBeforeBackboardd = false;
					}
				}
			}
		}
	}

	// Stealth Mode: Unlink /var/jb before spawning xpcproxy for stealth applications
	if (!strcmp(path, "/usr/libexec/xpcproxy")) {
		if (argv && argv[1] && is_stealth_xpcproxy_target(argv[1])) {
			unlink("/var/jb");
		}
	}

	bool isSB = is_springboard_process(path, argv);
	char **customEnvp = (char **)envp;
	bool freeEnvp = false;

	if (isSB) {
		bootlog_info("Spawning SpringBoard...");
		if (respring_protection_should_safemode(path, argv)) {
			bootlog_warn("Respring protection: enabling safe mode");
			customEnvp = envbuf_mutcopy((const char **)envp);
			envbuf_setenv(&customEnvp, "_SafeMode", "1");
			envbuf_setenv(&customEnvp, "_MSSafeMode", "1");
			freeEnvp = true;
		}
	}

	int ret = posix_spawn_hook_shared(pid, path, desc, argv, customEnvp, __posix_spawn_orig_wrapper, systemwide_trust_file_by_path, platform_set_process_debugged, jbsetting(jetsamMultiplier));

	if (isSB && ret == 0) {
		bootlog_success("SpringBoard spawned successfully");
		respring_protection_did_spawn_springboard();
	}

	if (freeEnvp) {
		envbuf_free(customEnvp);
	}

	return ret;
}

void initSpawnHooks(void)
{
	litehook_hook_function(__posix_spawn, __posix_spawn_hook);
}