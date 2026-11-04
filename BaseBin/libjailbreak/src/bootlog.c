#include "bootlog.h"
#include "font_8x16.h"
#include "endorphin_logo.h"
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
#include "jbroot.h"
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

static bool read_bool_from_plist(const char *path, const char *key1, const char *key2)
{
    if (!path) return false;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;

    struct stat s = {0};
    if (fstat(fd, &s) != 0 || s.st_size <= 0) {
        close(fd);
        return false;
    }

    void *addr = mmap(NULL, s.st_size, PROT_READ, MAP_FILE | MAP_PRIVATE, fd, 0);
    if (addr == MAP_FAILED) {
        close(fd);
        return false;
    }

    bool val = false;
    xpc_object_t dict = xpc_create_from_plist(addr, s.st_size);
    munmap(addr, s.st_size);
    close(fd);

    if (dict) {
        if (key1) {
            xpc_object_t obj = xpc_dictionary_get_value(dict, key1);
            if (obj && xpc_get_type(obj) == XPC_TYPE_BOOL) {
                val = xpc_bool_get_value(obj);
            }
        }
        if (!val && key2) {
            xpc_object_t obj2 = xpc_dictionary_get_value(dict, key2);
            if (obj2 && xpc_get_type(obj2) == XPC_TYPE_BOOL) {
                val = xpc_bool_get_value(obj2);
            }
        }
        xpc_release(dict);
    }
    return val;
}

bool is_verbose_boot_enabled(void)
{
    if (read_bool_from_plist(JBROOT_PATH("/basebin/config.plist"), "VerboseBoot", "verboseLogsEnabled")) {
        return true;
    }
    if (read_bool_from_plist("/var/mobile/Library/Preferences/com.opa334.Dopamine.plist", "verboseLogsEnabled", "VerboseBoot")) {
        return true;
    }
    return false;
}

#define ANIM_NUM_BLOCKS 7

static inline bool is_in_rounded_rect(int px, int py, int rx, int ry, int rw, int rh, int r)
{
    if (px < rx || px >= rx + rw || py < ry || py >= ry + rh) {
        return false;
    }
    if (r <= 0) return true;

    int dx = 0, dy = 0;
    if (px < rx + r) {
        dx = (rx + r) - px;
    } else if (px >= rx + rw - r) {
        dx = px - (rx + rw - 1 - r);
    } else {
        return true;
    }

    if (py < ry + r) {
        dy = (ry + r) - py;
    } else if (py >= ry + rh - r) {
        dy = py - (ry + rh - 1 - r);
    } else {
        return true;
    }

    return (dx * dx + dy * dy) <= (r * r);
}

static void draw_embedded_endorphin_logo(struct drawctx *ctx, int rot, int vw, int vh, int center_y)
{
    if (!ctx || !ctx->base) return;

    int logo_w = ENDORPHIN_LOGO_WIDTH;
    int logo_h = ENDORPHIN_LOGO_HEIGHT;

    int start_x = (vw - logo_w) / 2;
    int start_y = center_y;

    uint32_t logo_color = 0xFFF1F5F9;

    for (int y = 0; y < logo_h; y++) {
        for (int x = 0; x < logo_w; x++) {
            int bit_idx = y * logo_w + x;
            int byte_idx = bit_idx / 8;
            int bit_offset = 7 - (bit_idx % 8);
            if (g_endorphin_logo_bitmap[byte_idx] & (1 << bit_offset)) {
                draw_pixel_raw(ctx, start_x + x, start_y + y, logo_color, rot);
            }
        }
    }
}

static inline uint32_t lerp_color(uint32_t c1, uint32_t c2, float t)
{
    if (t <= 0.0f) return c1;
    if (t >= 1.0f) return c2;

    int a1 = (c1 >> 24) & 0xFF, a2 = (c2 >> 24) & 0xFF;
    int r1 = (c1 >> 16) & 0xFF, r2 = (c2 >> 16) & 0xFF;
    int g1 = (c1 >> 8)  & 0xFF, g2 = (c2 >> 8)  & 0xFF;
    int b1 = c1         & 0xFF, b2 = c2         & 0xFF;

    int a = (int)(a1 + (float)(a2 - a1) * t);
    int r = (int)(r1 + (float)(r2 - r1) * t);
    int g = (int)(g1 + (float)(g2 - g1) * t);
    int b = (int)(b1 + (float)(b2 - b1) * t);

    if (a < 0) a = 0; else if (a > 255) a = 255;
    if (r < 0) r = 0; else if (r > 255) r = 255;
    if (g < 0) g = 0; else if (g > 255) g = 255;
    if (b < 0) b = 0; else if (b > 255) b = 255;

    return ((uint32_t)a << 24) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
}

static inline uint32_t get_glossy_blue_pixel(int y_in_block, int block_h, int x_in_block, int block_w)
{
    if (y_in_block == 0) return 0xFFD9EBFF; // Top soft highlight
    if (y_in_block == block_h - 1) return 0xFF0E2B80; // Bottom rim
    if (x_in_block == 0 || x_in_block == block_w - 1) return 0xFF1543B1; // Side border

    float rel = (float)(y_in_block - 1) / (float)(block_h - 3);
    if (rel < 0.20f) {
        float t = rel / 0.20f;
        return lerp_color(0xFF3880E7, 0xFF1576FC, t);
    } else if (rel < 0.45f) {
        float t = (rel - 0.20f) / 0.25f;
        return lerp_color(0xFF1576FC, 0xFF0362F1, t);
    } else if (rel < 0.75f) {
        float t = (rel - 0.45f) / 0.30f;
        return lerp_color(0xFF0362F1, 0xFF104CC5, t);
    } else {
        float t = (rel - 0.75f) / 0.25f;
        return lerp_color(0xFF104CC5, 0xFF1543B1, t);
    }
}

static inline uint32_t get_glossy_green_pixel(int y_in_block, int block_h, int x_in_block, int block_w)
{
    if (y_in_block == 0) return 0xFFDBFEE0; // Top soft highlight
    if (y_in_block == block_h - 1) return 0xFF156B34; // Bottom rim
    if (x_in_block == 0 || x_in_block == block_w - 1) return 0xFF2E9955; // Side border

    float rel = (float)(y_in_block - 1) / (float)(block_h - 3);
    if (rel < 0.20f) {
        float t = rel / 0.20f;
        return lerp_color(0xFF80E189, 0xFF6AEA69, t);
    } else if (rel < 0.45f) {
        float t = (rel - 0.20f) / 0.25f;
        return lerp_color(0xFF6AEA69, 0xFF74EA4D, t);
    } else if (rel < 0.75f) {
        float t = (rel - 0.45f) / 0.30f;
        return lerp_color(0xFF74EA4D, 0xFF42D27B, t);
    } else {
        float t = (rel - 0.75f) / 0.25f;
        return lerp_color(0xFF42D27B, 0xFF2DB865, t);
    }
}

static void draw_glossy_block(struct drawctx *ctx, int bx1, int by1, int block_w, int block_h, int clip_x1, int clip_x2, int rot, bool is_green)
{
    int corner_r = 4;
    for (int y = 0; y < block_h; y++) {
        int py = by1 + y;
        for (int x = 0; x < block_w; x++) {
            int px = bx1 + x;
            if (px < clip_x1 || px > clip_x2) continue;
            if (!is_in_rounded_rect(px, py, bx1, by1, block_w, block_h, corner_r)) continue;

            uint32_t color = is_green ?
                get_glossy_green_pixel(y, block_h, x, block_w) :
                get_glossy_blue_pixel(y, block_h, x, block_w);
            draw_pixel_raw(ctx, px, py, color, rot);
        }
    }
}

// Windows XP Boot Animation Worker
static void *bootanim_worker(void *arg)
{
    struct boot_anim *anim = (struct boot_anim *)arg;
    struct drawctx *ctx = anim->ctx;
    int rot = anim->rotation;
    int vw = anim->virt_w;
    int vh = anim->virt_h;

    int track_w = (int)(vw * 0.72);
    int track_h = (vw >= 1000) ? 54 : ((vw >= 640) ? 42 : 28);
    int track_x = (vw - track_w) / 2;
    int track_y = (int)(vh * 0.54);
    int border_thickness = 3;

    int inner_x = track_x + border_thickness;
    int inner_y = track_y + border_thickness;
    int inner_w = track_w - 2 * border_thickness;
    int inner_h = track_h - 2 * border_thickness;

    int block_w = (vw >= 1000) ? 28 : ((vw >= 640) ? 22 : 16);
    int block_gap = (vw >= 1000) ? 6 : ((vw >= 640) ? 4 : 3);
    int block_h = inner_h - 6;
    int block_y1 = inner_y + 3;
    int group_w = ANIM_NUM_BLOCKS * block_w + (ANIM_NUM_BLOCKS - 1) * block_gap;

    int track_radius = 6;
    int inner_radius = 4;

    // Draw outer rounded frame with recessed shading
    for (int y = track_y; y < track_y + track_h; y++) {
        for (int x = track_x; x < track_x + track_w; x++) {
            if (!is_in_rounded_rect(x, y, track_x, track_y, track_w, track_h, track_radius)) continue;
            if (is_in_rounded_rect(x, y, inner_x, inner_y, inner_w, inner_h, inner_radius)) {
                draw_pixel_raw(ctx, x, y, 0xFF050811, rot);
            } else {
                if (y == track_y || y == track_y + 1) {
                    draw_pixel_raw(ctx, x, y, 0xFF475569, rot);
                } else if (y >= track_y + track_h - 2) {
                    draw_pixel_raw(ctx, x, y, 0xFF64748B, rot);
                } else if (x == track_x || x == track_x + 1) {
                    draw_pixel_raw(ctx, x, y, 0xFF334155, rot);
                } else {
                    draw_pixel_raw(ctx, x, y, 0xFF475569, rot);
                }
            }
        }
    }
    drawctx_update(ctx);

    int pos = -group_w;
    int step = (vw >= 1000) ? 22 : ((vw >= 640) ? 16 : 12);

    while (anim->running) {
        // Redraw inner track background
        for (int y = inner_y; y < inner_y + inner_h; y++) {
            for (int x = inner_x; x < inner_x + inner_w; x++) {
                if (is_in_rounded_rect(x, y, inner_x, inner_y, inner_w, inner_h, inner_radius)) {
                    draw_pixel_raw(ctx, x, y, 0xFF050811, rot);
                }
            }
        }

        // Draw glossy light-blue rounded blocks
        for (int i = 0; i < ANIM_NUM_BLOCKS; i++) {
            int bx1 = inner_x + pos + i * (block_w + block_gap);
            int bx2 = bx1 + block_w - 1;

            if (bx2 < inner_x || bx1 >= inner_x + inner_w) {
                continue;
            }

            int clip_x1 = bx1 < inner_x ? inner_x : bx1;
            int clip_x2 = bx2 >= inner_x + inner_w ? (inner_x + inner_w - 1) : bx2;

            draw_glossy_block(ctx, bx1, block_y1, block_w, block_h, clip_x1, clip_x2, rot, false);
        }

        drawctx_update(ctx);
        usleep(15000); // ~66 FPS

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

        int track_w = (int)(vw * 0.72);
        int track_h = (vw >= 1000) ? 54 : ((vw >= 640) ? 42 : 28);
        int track_x = (vw - track_w) / 2;
        int track_y = (int)(vh * 0.54);
        int border_thickness = 3;

        int inner_x = track_x + border_thickness;
        int inner_y = track_y + border_thickness;
        int inner_w = track_w - 2 * border_thickness;
        int inner_h = track_h - 2 * border_thickness;

        int block_w = (vw >= 1000) ? 28 : ((vw >= 640) ? 22 : 16);
        int block_gap = (vw >= 1000) ? 6 : ((vw >= 640) ? 4 : 3);
        int block_h = inner_h - 6;
        int block_y1 = inner_y + 3;
        int inner_radius = 4;

        // Clear inner track
        for (int y = inner_y; y < inner_y + inner_h; y++) {
            for (int x = inner_x; x < inner_x + inner_w; x++) {
                if (is_in_rounded_rect(x, y, inner_x, inner_y, inner_w, inner_h, inner_radius)) {
                    draw_pixel_raw(ctx, x, y, 0xFF050811, rot);
                }
            }
        }

        // Fill entire track with glossy green blocks
        int cur_x = inner_x + 3;
        while (cur_x + block_w <= inner_x + inner_w - 3) {
            draw_glossy_block(ctx, cur_x, block_y1, block_w, block_h, inner_x, inner_x + inner_w - 1, rot, true);
            cur_x += block_w + block_gap;
        }

        drawctx_update(ctx);
    }
    pthread_mutex_unlock(&g_anim_mutex);

    // Hold complete screen for 450ms
    usleep(450000);
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

    // Clear whole framebuffer to black
    if (ctx && ctx->base) {
        memset(ctx->base, 0, ctx->size.height * ctx->bytesPerRow);
    }

    int rot = (int)get_main_screen_rotation();
    int vw = (rot == 90 || rot == 270) ? (int)ctx->size.height : (int)ctx->size.width;
    int vh = (rot == 90 || rot == 270) ? (int)ctx->size.width : (int)ctx->size.height;

    // Draw Endorphin boot logo: if custom user image specified, use it; otherwise draw crisp embedded logo
    int logo_y = (int)(vh * 0.54) - 120;
    if (logo_y < 40) logo_y = 40;

    bool custom_drawn = false;
    if (bootLogoPath && strcmp(bootLogoPath, JBROOT_PATH("/basebin/bootlogo.jp2")) != 0 && access(bootLogoPath, R_OK) == 0) {
        if (drawctx_draw_image_path(ctx, bootLogoPath) == 0) {
            custom_drawn = true;
        }
    }

    if (!custom_drawn) {
        draw_embedded_endorphin_logo(ctx, rot, vw, vh, logo_y);
    }
    drawctx_update(ctx);

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
