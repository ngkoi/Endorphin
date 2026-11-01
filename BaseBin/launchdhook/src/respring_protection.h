#ifndef RESPRING_PROTECTION_H
#define RESPRING_PROTECTION_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Check if a process to be spawned is SpringBoard
bool is_springboard_process(const char *path, char *const argv[]);

// Check if Safe Mode should be enforced for this SpringBoard launch
bool respring_protection_should_safemode(const char *path, char *const argv[]);

// Record that SpringBoard has successfully been spawned and start survival timer
void respring_protection_did_spawn_springboard(void);

// Initialize notification listeners (keybag first unlock, unlock events)
void initRespringProtection(void);

#ifdef __cplusplus
}
#endif

#endif // RESPRING_PROTECTION_H
