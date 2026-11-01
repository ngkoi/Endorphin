#import <Foundation/Foundation.h>
#import "respring_protection.h"
#import <libjailbreak/libjailbreak.h>
#import <notify.h>
#import <time.h>
#import <sys/time.h>
#import <sys/stat.h>

#define RESPRING_LOOP_THRESHOLD 3
#define RESPRING_LOOP_WINDOW_SEC 60
#define UNLOCK_PROBATION_WINDOW_SEC 45
#define UNLOCK_CRASH_THRESHOLD 2
#define STABILITY_TIMEOUT_SEC 60

static time_t g_sb_spawns[RESPRING_LOOP_THRESHOLD] = {0};
static int g_sb_spawn_count = 0;

static time_t g_last_unlock_time = 0;
static int g_unlock_crash_strikes = 0;
static bool g_safemode_active = false;
static dispatch_source_t g_stability_timer = NULL;

static void log_guard(NSString *msg)
{
	NSLog(@"[EndorphinGuard] %@", msg);
	const char *logPath = "/var/tmp/endorphin_guard.log";
	FILE *f = fopen(logPath, "a");
	if (f) {
		time_t now = time(NULL);
		char timeBuf[64];
		strftime(timeBuf, sizeof(timeBuf), "%Y-%m-%d %H:%M:%S", localtime(&now));
		fprintf(f, "[%s] %s\n", timeBuf, [msg UTF8String]);
		fclose(f);
	}
}

bool is_springboard_process(const char *path, char *const argv[])
{
	if (!path) return false;

	if (!strcmp(path, "/usr/libexec/xpcproxy")) {
		if (argv && argv[0] && argv[1]) {
			if (!strcmp(argv[1], "com.apple.SpringBoard")) {
				return true;
			}
		}
	}
	else if (!strcmp(path, "/System/Library/CoreServices/SpringBoard.app/SpringBoard")) {
		return true;
	}

	return false;
}

static void cancel_stability_timer(void)
{
	if (g_stability_timer) {
		dispatch_source_cancel(g_stability_timer);
		g_stability_timer = NULL;
	}
}

static void reset_protection_state(void)
{
	g_sb_spawn_count = 0;
	memset(g_sb_spawns, 0, sizeof(g_sb_spawns));
	g_unlock_crash_strikes = 0;
	g_safemode_active = false;

	const char *flagPath = JBROOT_PATH("/basebin/.safemode_active");
	if (flagPath && !access(flagPath, F_OK)) {
		unlink(flagPath);
	}

	log_guard(@"SpringBoard reached stability (>60s). Loop protection counters reset.");
}

static void show_safemode_alert(void)
{
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		// Wait 4 seconds for SpringBoard and notification servers to be fully ready
		sleep(4);

		const char *uialertPath = JBROOT_PATH("/usr/bin/uialert");
		if (access(uialertPath, X_OK) == 0) {
			const char *body = "Respring loop detected! Tweaks have been temporarily disabled to protect your device.\n\nPlease open Sileo/Zebra to remove faulty tweaks, or tap Restart to exit Safe Mode.";
			log_guard(@"Displaying Safe Mode UI Alert to user...");
			int ret = exec_cmd(uialertPath, "-b", body, "-p", "OK", "-s", "Restart SpringBoard", "⚠️ Endorphin Safe Mode", NULL);
			if (ret == 1) { // User clicked "Restart SpringBoard"
				log_guard(@"User tapped Restart SpringBoard from Safe Mode alert. Resetting and triggering sbreload...");
				reset_protection_state();
				const char *sbreload = JBROOT_PATH("/usr/bin/sbreload");
				if (access(sbreload, X_OK) == 0) {
					exec_cmd(sbreload, NULL);
				}
			}
		}
	});
}

bool respring_protection_should_safemode(const char *path, char *const argv[])
{
	if (!is_springboard_process(path, argv)) return false;

	// Check if RespringLoopGuard toggle is enabled (default: true)
	bool guardEnabled = true;
	NSString *configPath = [NSString stringWithUTF8String:JBROOT_PATH("/basebin/config.plist")];
	if ([[NSFileManager defaultManager] fileExistsAtPath:configPath]) {
		NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:configPath];
		if (cfg[@"RespringLoopGuard"] != nil) {
			guardEnabled = [cfg[@"RespringLoopGuard"] boolValue];
		}
	}
	if (!guardEnabled) return false;

	time_t now = time(NULL);

	// 1. Check for manual Safe Mode flag
	const char *manualFlag = JBROOT_PATH("/basebin/.force_safemode");
	if (manualFlag && !access(manualFlag, F_OK)) {
		log_guard(@"Manual Safe Mode flag detected. Forcing Safe Mode.");
		unlink(manualFlag);
		g_safemode_active = true;
		return true;
	}

	// 2. Check Post-Unlock Probation
	if (g_last_unlock_time > 0 && (now - g_last_unlock_time) <= UNLOCK_PROBATION_WINDOW_SEC) {
		g_unlock_crash_strikes++;
		log_guard([NSString stringWithFormat:@"SpringBoard crashed during unlock probation! Strike %d/%d (within %lds of unlock)",
		           g_unlock_crash_strikes, UNLOCK_CRASH_THRESHOLD, (long)(now - g_last_unlock_time)]);

		if (g_unlock_crash_strikes >= UNLOCK_CRASH_THRESHOLD) {
			log_guard(@"⚡ [ALERT] Post-Unlock crash loop detected! Activating Safe Mode protection.");
			g_safemode_active = true;
			return true;
		}
	}

	// 3. Check Sliding Window Respring Loop
	// Shift previous timestamps
	for (int i = 0; i < RESPRING_LOOP_THRESHOLD - 1; i++) {
		g_sb_spawns[i] = g_sb_spawns[i + 1];
	}
	g_sb_spawns[RESPRING_LOOP_THRESHOLD - 1] = now;
	g_sb_spawn_count++;

	if (g_sb_spawn_count >= RESPRING_LOOP_THRESHOLD) {
		time_t oldest = g_sb_spawns[0];
		if (oldest > 0 && (now - oldest) <= RESPRING_LOOP_WINDOW_SEC) {
			log_guard([NSString stringWithFormat:@"⚡ [ALERT] Rapid Respring Loop detected! (%d crashes in %lds). Activating Safe Mode.",
			           RESPRING_LOOP_THRESHOLD, (long)(now - oldest)]);
			g_safemode_active = true;
			return true;
		}
	}

	return g_safemode_active;
}

void respring_protection_did_spawn_springboard(void)
{
	cancel_stability_timer();

	if (g_safemode_active) {
		const char *flagPath = JBROOT_PATH("/basebin/.safemode_active");
		if (flagPath) {
			FILE *f = fopen(flagPath, "w");
			if (f) {
				fprintf(f, "1\n");
				fclose(f);
			}
		}
		show_safemode_alert();
	}

	// Schedule stability reset timer after 60 seconds
	dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	g_stability_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
	if (g_stability_timer) {
		dispatch_source_set_timer(g_stability_timer,
		                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(STABILITY_TIMEOUT_SEC * NSEC_PER_SEC)),
		                          DISPATCH_TIME_FOREVER, 1 * NSEC_PER_SEC);
		dispatch_source_set_event_handler(g_stability_timer, ^{
			reset_protection_state();
			cancel_stability_timer();
		});
		dispatch_resume(g_stability_timer);
	}
}

void initRespringProtection(void)
{
	int token = 0;
	dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

	// Listen for unlock events
	notify_register_dispatch("com.apple.springboard.hasUnlocked", &token, queue, ^(int t) {
		g_last_unlock_time = time(NULL);
		log_guard(@"Received device unlock event (com.apple.springboard.hasUnlocked).");
	});

	notify_register_dispatch("com.apple.mobile.keybagd.first_unlock", &token, queue, ^(int t) {
		g_last_unlock_time = time(NULL);
		log_guard(@"Received first unlock event (com.apple.mobile.keybagd.first_unlock).");
	});

	log_guard(@"Respring Loop Protection & Post-Unlock Probation initialized successfully.");
}
