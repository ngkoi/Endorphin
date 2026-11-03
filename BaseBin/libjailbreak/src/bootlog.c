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
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <libjailbreak/jbroot.h>
#include <xpc/xpc.h>
#include <xpc_private.h>

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

struct boot_anim {
    bool active;
    struct drawctx *ctx;
    bool own_ctx;
    int rotation;
    int virt_w;
    int virt_h;
    pthread_t thread;
    volatile bool running;
};

static struct boot_anim g_anim = { 0 };
static pthread_mutex_t g_anim_mutex = PTHREAD_MUTEX_INITIALIZER;

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

    fill_rect_virt(con, con->x_start - 6, con->y_start - 6, con->x_end + 6, con->y_end + 6, 0xFF0C1017);
    fill_rect_virt(con, con->x_start - 6, con->y_start - 8, con->x_end + 6, con->y_start - 7, 0xFF38BDF8);

    int title_scale = 1;
    draw_string_virt(con, con->x_start, con->y_start - 24, "-- Endorphin Console --", 0xFF94A3B8, title_scale);

    int visible_lines = con->total_lines < con->max_lines ? con->total_lines : con->max_lines;
    for (int i = 0; i < visible_lines; i++) {
        int line_y = con->y_start + i * con->line_step;
        draw_string_virt(con, con->x_start, line_y, con->lines[i], con->line_colors[i], con->font_scale);
    }

    drawctx_update(con->ctx);
}

bool is_verbose_boot_enabled(void)
{
    const char *configPath = JBROOT_PATH("/basebin/config.plist");
    int fd = open(configPath, O_RDONLY);
    if (fd >= 0) {
        struct stat s = {0};
        if (fstat(fd, &s) == 0 && s.st_size > 0) {
            void *addr = mmap(NULL, s.st_size, PROT_READ, MAP_FILE | MAP_PRIVATE, fd, 0);
            if (addr != MAP_FAILED) {
                xpc_object_t dict = xpc_create_from_plist(addr, s.st_size);
                munmap(addr, s.st_size);
                close(fd);
                if (dict) {
                    bool verbose = false;
                    xpc_object_t vObj = xpc_dictionary_get_value(dict, "VerboseBoot");
                    if (vObj && xpc_get_type(vObj) == XPC_TYPE_BOOL) {
                        verbose = xpc_bool_get_value(vObj);
                    }
                    if (!verbose) {
                        xpc_object_t vlObj = xpc_dictionary_get_value(dict, "verboseLogsEnabled");
                        if (vlObj && xpc_get_type(vlObj) == XPC_TYPE_BOOL) {
                            verbose = xpc_bool_get_value(vlObj);
                        }
                    }
                    xpc_release(dict);
                    return verbose;
                }
            }
        }
        close(fd);
    }
    return false;
}

// Windows XP Boot Animation Worker
static void *bootanim_worker(void *arg)
{
    struct boot_anim *anim = (struct boot_anim *)arg;
    struct drawctx *ctx = anim->ctx;
    int rot = anim->rotation;
    int vw = anim->virt_w;
    int vh = anim->virt_h;

    int track_w = (int)(vw * 0.58);
    int track_h = (vw >= 640) ? 22 : 14;
    int track_x = (vw - track_w) / 2;
    int track_y = (int)(vh * 0.70);
    int border_thickness = (vw >= 640) ? 2 : 1;

    int inner_x = track_x + border_thickness;
    int inner_y = track_y + border_thickness;
    int inner_w = track_w - 2 * border_thickness;
    int inner_h = track_h - 2 * border_thickness;

    int block_w = (vw >= 640) ? 12 : 8;
    int block_gap = (vw >= 640) ? 3 : 2;
    int block_h = inner_h - 4;
    int block_y1 = inner_y + 2;
    int block_y2 = block_y1 + block_h - 1;
    int group_w = 3 * block_w + 2 * block_gap;

    // Draw initial outer border
    for (int y = track_y; y < track_y + track_h; y++) {
        for (int x = track_x; x < track_x + track_w; x++) {
            draw_pixel_raw(ctx, x, y, 0xFF334155, rot);
        }
    }

    // Draw initial inner track background
    for (int y = inner_y; y < inner_y + inner_h; y++) {
        for (int x = inner_x; x < inner_x + inner_w; x++) {
            draw_pixel_raw(ctx, x, y, 0xFF050811, rot);
        }
    }
    drawctx_update(ctx);

    int pos = -group_w;
    int step = (vw >= 640) ? 5 : 3;

    while (anim->running) {
        // Redraw inner track background
        for (int y = inner_y; y < inner_y + inner_h; y++) {
            for (int x = inner_x; x < inner_x + inner_w; x++) {
                draw_pixel_raw(ctx, x, y, 0xFF050811, rot);
            }
        }

        // Draw 3 light-blue square blocks
        for (int i = 0; i < 3; i++) {
            int bx1 = inner_x + pos + i * (block_w + block_gap);
            int bx2 = bx1 + block_w - 1;

            if (bx2 < inner_x || bx1 >= inner_x + inner_w) {
                continue;
            }

            int clip_x1 = bx1 < inner_x ? inner_x : bx1;
            int clip_x2 = bx2 >= inner_x + inner_w ? (inner_x + inner_w - 1) : bx2;

            for (int by = block_y1; by <= block_y2; by++) {
                for (int bx = clip_x1; bx <= clip_x2; bx++) {
                    draw_pixel_raw(ctx, bx, by, 0xFF38BDF8, rot); // Light blue
                }
            }
        }

        drawctx_update(ctx);
        usleep(30000); // ~33 FPS

        pos += step;
        if (pos >= inner_w) {
            pos = -group_w;
        }
    }

    return NULL;
}

void bootanim_start(struct drawctx *ctx)
{
    pthread_mutex_lock(&g_anim_mutex);
    if (g_anim.active) {
        pthread_mutex_unlock(&g_anim_mutex);
        return;
    }

    int rot = (int)get_main_screen_rotation();
    int vw = (rot == 90 || rot == 270) ? (int)ctx->size.height : (int)ctx->size.width;
    int vh = (rot == 90 || rot == 270) ? (int)ctx->size.width : (int)ctx->size.height;

    g_anim.active = true;
    g_anim.ctx = ctx;
    g_anim.own_ctx = false;
    g_anim.rotation = rot;
    g_anim.virt_w = vw;
    g_anim.virt_h = vh;
    g_anim.running = true;

    pthread_create(&g_anim.thread, NULL, bootanim_worker, &g_anim);
    pthread_mutex_unlock(&g_anim_mutex);
}

void bootanim_finish(void)
{
    pthread_mutex_lock(&g_anim_mutex);
    if (!g_anim.active || !g_anim.running) {
        pthread_mutex_unlock(&g_anim_mutex);
        return;
    }

    g_anim.running = false;
    pthread_mutex_unlock(&g_anim_mutex);

    pthread_join(g_anim.thread, NULL);

    pthread_mutex_lock(&g_anim_mutex);
    struct drawctx *ctx = g_anim.ctx;
    if (ctx && ctx->base) {
        int rot = g_anim.rotation;
        int vw = g_anim.virt_w;
        int vh = g_anim.virt_h;

        int track_w = (int)(vw * 0.58);
        int track_h = (vw >= 640) ? 22 : 14;
        int track_x = (vw - track_w) / 2;
        int track_y = (int)(vh * 0.70);
        int border_thickness = (vw >= 640) ? 2 : 1;

        int inner_x = track_x + border_thickness;
        int inner_y = track_y + border_thickness;
        int inner_w = track_w - 2 * border_thickness;
        int inner_h = track_h - 2 * border_thickness;

        int block_w = (vw >= 640) ? 12 : 8;
        int block_gap = (vw >= 640) ? 3 : 2;
        int block_h = inner_h - 4;
        int block_y1 = inner_y + 2;
        int block_y2 = block_y1 + block_h - 1;

        // Clear inner track
        for (int y = inner_y; y < inner_y + inner_h; y++) {
            for (int x = inner_x; x < inner_x + inner_w; x++) {
                draw_pixel_raw(ctx, x, y, 0xFF050811, rot);
            }
        }

        // Fill entire track with green square blocks (0xFF22C55E)
        int cur_x = inner_x + 2;
        while (cur_x + block_w <= inner_x + inner_w - 2) {
            for (int by = block_y1; by <= block_y2; by++) {
                for (int bx = cur_x; bx < cur_x + block_w; bx++) {
                    draw_pixel_raw(ctx, bx, by, 0xFF22C55E, rot);
                }
            }
            cur_x += block_w + block_gap;
        }

        drawctx_update(ctx);
    }
    pthread_mutex_unlock(&g_anim_mutex);

    // Hold complete screen for 350ms
    usleep(350000);
}

void bootanim_free(void)
{
    pthread_mutex_lock(&g_anim_mutex);
    if (g_anim.active) {
        if (g_anim.running) {
            g_anim.running = false;
            pthread_mutex_unlock(&g_anim_mutex);
            pthread_join(g_anim.thread, NULL);
            pthread_mutex_lock(&g_anim_mutex);
        }
        if (g_anim.ctx && g_anim.own_ctx) {
            drawctx_free(g_anim.ctx);
        }
        memset(&g_anim, 0, sizeof(g_anim));
    }
    pthread_mutex_unlock(&g_anim_mutex);
}

int bootlog_init(struct drawctx *ctx, const char *bootLogoPath)
{
    bool own = false;
    if (!ctx) {
        ctx = drawctx_init();
        if (!ctx) {
            return -1;
        }
        own = true;
    }

    if (!ctx->inited || !ctx->base) {
        if (own) drawctx_free(ctx);
        return -2;
    }

    // Draw boot logo first if provided
    if (bootLogoPath && access(bootLogoPath, R_OK) == 0) {
        drawctx_draw_image_path(ctx, bootLogoPath);
    }

    // Create / truncate /var/tmp/boot.log
    FILE *f = fopen("/var/tmp/boot.log", "w");
    if (f) {
        fprintf(f, "=== Endorphin Boot Session Started ===\n");
        fclose(f);
    }

    if (is_verbose_boot_enabled()) {
        pthread_mutex_lock(&g_console_mutex);
        if (g_console.active && g_console.ctx) {
            pthread_mutex_unlock(&g_console_mutex);
            return 0;
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

        con->x_start = (int)(vw * 0.05);
        con->x_end   = (int)(vw * 0.95);
        con->y_start = (int)(vh * 0.53);
        con->y_end   = (int)(vh * 0.94);

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

        bootlog_printf(BOOTLOG_COLOR_CYAN, "[*] Endorphin 3.x verbose boot initialized");
    } else {
        // Windows XP Progress Bar Boot Animation
        pthread_mutex_lock(&g_anim_mutex);
        int rot = (int)get_main_screen_rotation();
        int vw = (rot == 90 || rot == 270) ? (int)ctx->size.height : (int)ctx->size.width;
        int vh = (rot == 90 || rot == 270) ? (int)ctx->size.width : (int)ctx->size.height;

        g_anim.active = true;
        g_anim.ctx = ctx;
        g_anim.own_ctx = own;
        g_anim.rotation = rot;
        g_anim.virt_w = vw;
        g_anim.virt_h = vh;
        g_anim.running = true;

        pthread_create(&g_anim.thread, NULL, bootanim_worker, &g_anim);
        pthread_mutex_unlock(&g_anim_mutex);
    }

    return 0;
}

void bootlog_printf(uint32_t color, const char *fmt, ...)
{
    char buf[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

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

    if ((int)strlen(buf) > con->cols) {
        buf[con->cols] = '\0';
    }

    int target_idx = 0;
    if (con->total_lines < con->max_lines) {
        target_idx = con->total_lines;
        con->total_lines++;
    } else {
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
    if (g_anim.active) return g_anim.ctx;
    return g_console.ctx;
}

void bootlog_free(void)
{
    if (g_anim.active) {
        bootanim_finish();
        bootanim_free();
        return;
    }

    pthread_mutex_lock(&g_console_mutex);
    if (g_console.active) {
        bootlog_printf(BOOTLOG_COLOR_GREEN, "[+] Boot complete, launching SpringBoard...");
        usleep(300000);
        if (g_console.ctx && g_console.own_ctx) {
            drawctx_free(g_console.ctx);
        }
        memset(&g_console, 0, sizeof(g_console));
    }
    pthread_mutex_unlock(&g_console_mutex);
}
