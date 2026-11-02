#include "bootlog.h"
#include "font_8x16.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/time.h>
#include <time.h>

#define MAX_SAVED_LINES 32
#define MAX_LINE_LEN    160

extern CGFloat get_main_screen_rotation(void);

struct boot_console {
    bool active;
    struct drawctx *ctx;
    bool own_ctx;
    int rotation;

    int virt_w;
    int virt_h;

    int x_start;
    int y_start;
    int x_end;
    int y_end;

    int font_scale;
    int char_w;
    int char_h;
    int line_step;

    int cols;
    int max_lines;

    int total_lines;
    char lines[MAX_SAVED_LINES][MAX_LINE_LEN];
    uint32_t line_colors[MAX_SAVED_LINES];
};

static struct boot_console g_console = { 0 };
static pthread_mutex_t g_console_mutex = PTHREAD_MUTEX_INITIALIZER;

static inline void draw_pixel_raw(struct drawctx *ctx, int x, int y, uint32_t color, int rot)
{
    int phys_x = x;
    int phys_y = y;
    int w = (int)ctx->size.width;
    int h = (int)ctx->size.height;

    switch (rot) {
        case 90:
            phys_x = w - 1 - y;
            phys_y = x;
            break;
        case 180:
            phys_x = w - 1 - x;
            phys_y = h - 1 - y;
            break;
        case 270:
            phys_x = y;
            phys_y = h - 1 - x;
            break;
        default:
            break;
    }

    if (phys_x >= 0 && phys_x < w && phys_y >= 0 && phys_y < h) {
        uint32_t *p = (uint32_t *)((uint8_t *)ctx->base + phys_y * ctx->bytesPerRow + phys_x * 4);
        *p = color;
    }
}

static void fill_rect_virt(struct boot_console *con, int x1, int y1, int x2, int y2, uint32_t color)
{
    if (!con->ctx || !con->ctx->base) return;
    for (int y = y1; y <= y2; y++) {
        for (int x = x1; x <= x2; x++) {
            draw_pixel_raw(con->ctx, x, y, color, con->rotation);
        }
    }
}

static void draw_char_virt(struct boot_console *con, int x, int y, char c, uint32_t color, int scale)
{
    uint8_t ch = (uint8_t)c;
    const uint8_t *glyph = g_font_8x16[ch];

    for (int gy = 0; gy < 16; gy++) {
        uint8_t row_bits = glyph[gy];
        if (row_bits == 0) continue;
        for (int gx = 0; gx < 8; gx++) {
            if (row_bits & (1 << (7 - gx))) {
                for (int sy = 0; sy < scale; sy++) {
                    for (int sx = 0; sx < scale; sx++) {
                        draw_pixel_raw(con->ctx, x + gx * scale + sx, y + gy * scale + sy, color, con->rotation);
                    }
                }
            }
        }
    }
}

static void draw_string_virt(struct boot_console *con, int x, int y, const char *str, uint32_t color, int scale)
{
    int cx = x;
    int cw = 8 * scale;
    while (*str) {
        if (*str == '\n') break;
        draw_char_virt(con, cx, y, *str, color, scale);
        cx += cw;
        str++;
    }
}

static void console_render_locked(void)
{
    struct boot_console *con = &g_console;
    if (!con->active || !con->ctx || !con->ctx->base) return;

    // 1. Fill console box with sleek dark background (0xFF0C1017)
    fill_rect_virt(con, con->x_start - 6, con->y_start - 6, con->x_end + 6, con->y_end + 6, 0xFF0C1017);

    // 2. Draw accent divider line at top edge (Cyan 0xFF38BDF8)
    fill_rect_virt(con, con->x_start - 6, con->y_start - 8, con->x_end + 6, con->y_start - 7, 0xFF38BDF8);

    // 3. Draw subtle title above the line
    int title_scale = 1;
    draw_string_virt(con, con->x_start, con->y_start - 24, "-- Endorphin Console --", 0xFF94A3B8, title_scale);

    // 4. Render active lines
    int visible_lines = con->total_lines < con->max_lines ? con->total_lines : con->max_lines;
    for (int i = 0; i < visible_lines; i++) {
        int line_y = con->y_start + i * con->line_step;
        draw_string_virt(con, con->x_start, line_y, con->lines[i], con->line_colors[i], con->font_scale);
    }

    // 5. Present to screen
    drawctx_update(con->ctx);
}

int bootlog_init(struct drawctx *ctx, const char *bootLogoPath)
{
    pthread_mutex_lock(&g_console_mutex);

    if (g_console.active && g_console.ctx) {
        pthread_mutex_unlock(&g_console_mutex);
        return 0;
    }

    bool own = false;
    if (!ctx) {
        ctx = drawctx_init();
        if (!ctx) {
            pthread_mutex_unlock(&g_console_mutex);
            return -1;
        }
        own = true;
    }

    if (!ctx->inited || !ctx->base) {
        if (own) drawctx_free(ctx);
        pthread_mutex_unlock(&g_console_mutex);
        return -2;
    }

    // Draw boot logo first if provided
    if (bootLogoPath && access(bootLogoPath, R_OK) == 0) {
        drawctx_draw_image_path(ctx, bootLogoPath);
    }

    int rot = (int)get_main_screen_rotation();
    int vw = (rot == 90 || rot == 270) ? (int)ctx->size.height : (int)ctx->size.width;
    int vh = (rot == 90 || rot == 270) ? (int)ctx->size.width : (int)ctx->size.height;

    struct boot_console *con = &g_console;
    memset(con, 0, sizeof(*con));

    con->active = true;
    con->ctx = ctx;
    con->own_ctx = own;
    con->rotation = rot;
    con->virt_w = vw;
    con->virt_h = vh;

    // Option 1: Top 52% is logo, lower 48% is scrolling console
    con->x_start = (int)(vw * 0.05);
    con->x_end   = (int)(vw * 0.95);
    con->y_start = (int)(vh * 0.53);
    con->y_end   = (int)(vh * 0.94);

    // Font scaling: 2x on modern retina screens (char 16x32)
    con->font_scale = (vw >= 640) ? 2 : 1;
    con->char_w = 8 * con->font_scale;
    con->char_h = 16 * con->font_scale;
    con->line_step = con->char_h + 4;

    con->cols = (con->x_end - con->x_start) / con->char_w;
    if (con->cols > (MAX_LINE_LEN - 1)) con->cols = MAX_LINE_LEN - 1;

    con->max_lines = (con->y_end - con->y_start) / con->line_step;
    if (con->max_lines > MAX_SAVED_LINES) con->max_lines = MAX_SAVED_LINES;
    if (con->max_lines < 4) con->max_lines = 4;

    con->total_lines = 0;

    pthread_mutex_unlock(&g_console_mutex);

    // Create / truncate /var/tmp/boot.log
    FILE *f = fopen("/var/tmp/boot.log", "w");
    if (f) {
        fprintf(f, "=== Endorphin Boot Session Started ===\n");
        fclose(f);
    }

    bootlog_printf(BOOTLOG_COLOR_CYAN, "[*] Endorphin 3.x verbose boot initialized");
    return 0;
}

void bootlog_printf(uint32_t color, const char *fmt, ...)
{
    char buf[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    // Write to /var/tmp/boot.log
    FILE *f = fopen("/var/tmp/boot.log", "a");
    if (f) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct tm tm_info;
        localtime_r(&tv.tv_sec, &tm_info);
        char tmbuf[32];
        strftime(tmbuf, sizeof(tmbuf), "%H:%M:%S", &tm_info);
        fprintf(f, "[%s.%03d] %s\n", tmbuf, (int)(tv.tv_usec / 1000), buf);
        fclose(f);
    }

    pthread_mutex_lock(&g_console_mutex);

    struct boot_console *con = &g_console;
    if (!con->active || !con->ctx || !con->ctx->base) {
        pthread_mutex_unlock(&g_console_mutex);
        return;
    }

    // Truncate to console width
    if ((int)strlen(buf) > con->cols) {
        buf[con->cols] = '\0';
    }

    int target_idx = 0;
    if (con->total_lines < con->max_lines) {
        target_idx = con->total_lines;
        con->total_lines++;
    } else {
        // Scroll up
        memmove(&con->lines[0], &con->lines[1], sizeof(con->lines[0]) * (con->max_lines - 1));
        memmove(&con->line_colors[0], &con->line_colors[1], sizeof(con->line_colors[0]) * (con->max_lines - 1));
        target_idx = con->max_lines - 1;
    }

    strncpy(con->lines[target_idx], buf, MAX_LINE_LEN - 1);
    con->lines[target_idx][MAX_LINE_LEN - 1] = '\0';
    con->line_colors[target_idx] = color;

    console_render_locked();

    pthread_mutex_unlock(&g_console_mutex);
}

void bootlog_info(const char *fmt, ...)
{
    char buf[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    bootlog_printf(BOOTLOG_COLOR_WHITE, "[*] %s", buf);
}

void bootlog_success(const char *fmt, ...)
{
    char buf[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    bootlog_printf(BOOTLOG_COLOR_GREEN, "[+] %s", buf);
}

void bootlog_warn(const char *fmt, ...)
{
    char buf[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    bootlog_printf(BOOTLOG_COLOR_YELLOW, "[!] %s", buf);
}

void bootlog_error(const char *fmt, ...)
{
    char buf[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    bootlog_printf(BOOTLOG_COLOR_RED, "[-] %s", buf);
}

struct drawctx *bootlog_get_drawctx(void)
{
    return g_console.ctx;
}

void bootlog_free(void)
{
    pthread_mutex_lock(&g_console_mutex);
    if (g_console.active) {
        if (g_console.ctx && g_console.own_ctx) {
            drawctx_free(g_console.ctx);
        }
        memset(&g_console, 0, sizeof(g_console));
    }
    pthread_mutex_unlock(&g_console_mutex);
}
