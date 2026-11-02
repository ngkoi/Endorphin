#ifndef BOOTLOG_H
#define BOOTLOG_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "display.h"

#ifdef __cplusplus
extern "C" {
#endif

// Terminal Colors (0xAARRGGBB in Little Endian BGRA)
#define BOOTLOG_COLOR_WHITE   0xFFFFFFFF
#define BOOTLOG_COLOR_GREEN   0xFF4ADE80
#define BOOTLOG_COLOR_RED     0xFFF43F5E
#define BOOTLOG_COLOR_YELLOW  0xFFFBBF24
#define BOOTLOG_COLOR_CYAN    0xFF38BDF8
#define BOOTLOG_COLOR_GRAY    0xFF94A3B8

// Initialize on-screen boot console
// If bootLogoPath is provided, draws the boot logo in upper area first
int bootlog_init(struct drawctx *ctx, const char *bootLogoPath);

// Print formatted message to on-screen console and /var/tmp/boot.log
void bootlog_printf(uint32_t color, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

// Convenience log functions
void bootlog_info(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void bootlog_success(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void bootlog_warn(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void bootlog_error(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// Get active draw context
struct drawctx *bootlog_get_drawctx(void);

// Free boot console resources (called before backboardd takes screen)
void bootlog_free(void);

#ifdef __cplusplus
}
#endif

#endif // BOOTLOG_H
