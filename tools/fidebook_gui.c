/*
 * fidebook-gui: Static zero-dependency Linux framebuffer/KMS graphical UI for FideBookOS
 * stage0 boot menu and graphical OS installer.
 *
 * Supports:
 *   - /dev/fb0 (32bpp & 16bpp at any resolution) with automatic /dev/dri/card* KMS dumb-buffer fallback
 *   - Full keyboard (arrows, numbers, Shift/alphanumeric for NVMe serial confirmation, Enter, Esc)
 *   - USB mouse (EV_REL) and laptop I2C/PS2 precision touchpads (EV_ABS delta tracking + tap/click)
 *   - Automatic exit code 2 fallback when /a11y/active (Speakup blind screen reader) or headless serial
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "fidebook_logo_rgba.h"

/* Minimal DRM/KMS ioctl structs for fallback when /dev/fb0 is absent */
struct fb_drm_mode_card_res {
    uint64_t fb_id_ptr, crtc_id_ptr, connector_id_ptr, encoder_id_ptr;
    uint32_t count_fbs, count_crtcs, count_connectors, count_encoders;
    uint32_t min_width, max_width, min_height, max_height;
};
struct fb_drm_mode_modeinfo {
    uint32_t clock;
    uint16_t hdisplay, hsync_start, hsync_end, htotal, hskew;
    uint16_t vdisplay, vsync_start, vsync_end, vtotal, vscan;
    uint32_t vrefresh, flags, type;
    char name[32];
};
struct fb_drm_mode_get_connector {
    uint64_t encoders_ptr, modes_ptr, props_ptr, prop_values_ptr;
    uint32_t count_modes, count_props, count_encoders;
    uint32_t encoder_id, connector_id, connector_type, connector_type_id;
    uint32_t connection, mm_width, mm_height, subpixel, pad;
};
struct fb_drm_mode_get_encoder {
    uint32_t encoder_id, encoder_type, crtc_id, possible_crtcs, possible_clones;
};
struct fb_drm_mode_create_dumb {
    uint32_t height, width, bpp, flags, handle, pitch;
    uint64_t size;
};
struct fb_drm_mode_map_dumb {
    uint32_t handle, pad;
    uint64_t offset;
};
struct fb_drm_mode_fb_cmd {
    uint32_t fb_id, width, height, pitch, bpp, depth, handle;
};
struct fb_drm_mode_crtc {
    uint64_t set_connectors_ptr;
    uint32_t count_connectors, crtc_id, fb_id, x, y, gamma_size, mode_valid;
    struct fb_drm_mode_modeinfo mode;
};
struct fb_drm_mode_fb_dirty_cmd {
    uint32_t fb_id, flags, color, num_clips;
    uint64_t clips_ptr;
};

#define IOCTL_DRM_GETRESOURCES _IOWR('d', 0xA0, struct fb_drm_mode_card_res)
#define IOCTL_DRM_GETCRTC      _IOWR('d', 0xA1, struct fb_drm_mode_crtc)
#define IOCTL_DRM_SETCRTC      _IOWR('d', 0xA2, struct fb_drm_mode_crtc)
#define IOCTL_DRM_GETENCODER   _IOWR('d', 0xA6, struct fb_drm_mode_get_encoder)
#define IOCTL_DRM_GETCONNECTOR _IOWR('d', 0xA7, struct fb_drm_mode_get_connector)
#define IOCTL_DRM_ADDFB        _IOWR('d', 0xAE, struct fb_drm_mode_fb_cmd)
#define IOCTL_DRM_DIRTYFB      _IOWR('d', 0xB1, struct fb_drm_mode_fb_dirty_cmd)
#define IOCTL_DRM_CREATE_DUMB  _IOWR('d', 0xB2, struct fb_drm_mode_create_dumb)
#define IOCTL_DRM_MAP_DUMB     _IOWR('d', 0xB3, struct fb_drm_mode_map_dumb)

/* Built-in crisp 8x16 ASCII bitmap font (printable ASCII 32..126) */
static const uint8_t font8x16[95][16] = {
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* ' ' */
    {0x00,0x00,0x18,0x3c,0x3c,0x3c,0x18,0x18,0x18,0x00,0x18,0x18,0x00,0x00,0x00,0x00}, /* ! */
    {0x00,0x66,0x66,0x66,0x24,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* " */
    {0x00,0x00,0x00,0x6c,0x6c,0xfe,0x6c,0x6c,0x6c,0xfe,0x6c,0x6c,0x00,0x00,0x00,0x00}, /* # */
    {0x18,0x18,0x7c,0xc6,0xc2,0xc0,0x7c,0x06,0x06,0x86,0xc6,0x7c,0x18,0x18,0x00,0x00}, /* $ */
    {0x00,0x00,0x00,0x00,0xc2,0xc6,0x0c,0x18,0x30,0x60,0xc6,0x86,0x00,0x00,0x00,0x00}, /* % */
    {0x00,0x00,0x38,0x6c,0x6c,0x38,0x76,0xdc,0xcc,0xcc,0xcc,0x76,0x00,0x00,0x00,0x00}, /* & */
    {0x00,0x30,0x30,0x30,0x60,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* ' */
    {0x00,0x00,0x0c,0x18,0x30,0x30,0x30,0x30,0x30,0x30,0x18,0x0c,0x00,0x00,0x00,0x00}, /* ( */
    {0x00,0x00,0x30,0x18,0x0c,0x0c,0x0c,0x0c,0x0c,0x0c,0x18,0x30,0x00,0x00,0x00,0x00}, /* ) */
    {0x00,0x00,0x00,0x00,0x00,0x66,0x3c,0xff,0x3c,0x66,0x00,0x00,0x00,0x00,0x00,0x00}, /* * */
    {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x7e,0x18,0x18,0x00,0x00,0x00,0x00,0x00,0x00}, /* + */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x18,0x30,0x00,0x00,0x00}, /* , */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xfe,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* - */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x00}, /* . */
    {0x00,0x00,0x00,0x00,0x02,0x06,0x0c,0x18,0x30,0x60,0xc0,0x80,0x00,0x00,0x00,0x00}, /* / */
    {0x00,0x00,0x7c,0xc6,0xce,0xde,0xf6,0xe6,0xc6,0xc6,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* 0 */
    {0x00,0x00,0x18,0x38,0x78,0x18,0x18,0x18,0x18,0x18,0x18,0x7e,0x00,0x00,0x00,0x00}, /* 1 */
    {0x00,0x00,0x7c,0xc6,0x06,0x0c,0x18,0x30,0x60,0xc0,0xc6,0xfe,0x00,0x00,0x00,0x00}, /* 2 */
    {0x00,0x00,0x7c,0xc6,0x06,0x06,0x3c,0x06,0x06,0x06,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* 3 */
    {0x00,0x00,0x0c,0x1c,0x3c,0x6c,0xcc,0xfe,0x0c,0x0c,0x0c,0x1e,0x00,0x00,0x00,0x00}, /* 4 */
    {0x00,0x00,0xfe,0xc0,0xc0,0xc0,0xfc,0x06,0x06,0x06,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* 5 */
    {0x00,0x00,0x38,0x60,0xc0,0xc0,0xfc,0xc6,0xc6,0xc6,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* 6 */
    {0x00,0x00,0xfe,0xc6,0x06,0x06,0x0c,0x18,0x30,0x30,0x30,0x30,0x00,0x00,0x00,0x00}, /* 7 */
    {0x00,0x00,0x7c,0xc6,0xc6,0xc6,0x7c,0xc6,0xc6,0xc6,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* 8 */
    {0x00,0x00,0x7c,0xc6,0xc6,0xc6,0x7e,0x06,0x06,0x06,0x0c,0x78,0x00,0x00,0x00,0x00}, /* 9 */
    {0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x00,0x00}, /* : */
    {0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x18,0x18,0x30,0x00,0x00,0x00,0x00}, /* ; */
    {0x00,0x00,0x00,0x06,0x0c,0x18,0x30,0x60,0x30,0x18,0x0c,0x06,0x00,0x00,0x00,0x00}, /* < */
    {0x00,0x00,0x00,0x00,0x00,0x7e,0x00,0x00,0x7e,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* = */
    {0x00,0x00,0x00,0x60,0x30,0x18,0x0c,0x06,0x0c,0x18,0x30,0x60,0x00,0x00,0x00,0x00}, /* > */
    {0x00,0x00,0x7c,0xc6,0xc6,0x0c,0x18,0x18,0x18,0x00,0x18,0x18,0x00,0x00,0x00,0x00}, /* ? */
    {0x00,0x00,0x7c,0xc6,0xc6,0xde,0xde,0xde,0xdc,0xc0,0xc0,0x7c,0x00,0x00,0x00,0x00}, /* @ */
    {0x00,0x00,0x10,0x38,0x6c,0xc6,0xc6,0xfe,0xc6,0xc6,0xc6,0xc6,0x00,0x00,0x00,0x00}, /* A */
    {0x00,0x00,0xfc,0x66,0x66,0x66,0x7c,0x66,0x66,0x66,0x66,0xfc,0x00,0x00,0x00,0x00}, /* B */
    {0x00,0x00,0x3c,0x66,0xc2,0xc0,0xc0,0xc0,0xc0,0xc2,0x66,0x3c,0x00,0x00,0x00,0x00}, /* C */
    {0x00,0x00,0xf8,0x6c,0x66,0x66,0x66,0x66,0x66,0x66,0x6c,0xf8,0x00,0x00,0x00,0x00}, /* D */
    {0x00,0x00,0xfe,0x66,0x62,0x68,0x78,0x68,0x60,0x62,0x66,0xfe,0x00,0x00,0x00,0x00}, /* E */
    {0x00,0x00,0xfe,0x66,0x62,0x68,0x78,0x68,0x60,0x60,0x60,0xf0,0x00,0x00,0x00,0x00}, /* F */
    {0x00,0x00,0x3c,0x66,0xc2,0xc0,0xc0,0xde,0xc6,0xc6,0x66,0x3a,0x00,0x00,0x00,0x00}, /* G */
    {0x00,0x00,0xc6,0xc6,0xc6,0xc6,0xfe,0xc6,0xc6,0xc6,0xc6,0xc6,0x00,0x00,0x00,0x00}, /* H */
    {0x00,0x00,0x3c,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x3c,0x00,0x00,0x00,0x00}, /* I */
    {0x00,0x00,0x1e,0x0c,0x0c,0x0c,0x0c,0x0c,0xcc,0xcc,0xcc,0x78,0x00,0x00,0x00,0x00}, /* J */
    {0x00,0x00,0xe6,0x66,0x6c,0x6c,0x78,0x78,0x6c,0x66,0x66,0xe6,0x00,0x00,0x00,0x00}, /* K */
    {0x00,0x00,0xf0,0x60,0x60,0x60,0x60,0x60,0x60,0x62,0x66,0xfe,0x00,0x00,0x00,0x00}, /* L */
    {0x00,0x00,0xc6,0xee,0xfe,0xfe,0xd6,0xc6,0xc6,0xc6,0xc6,0xc6,0x00,0x00,0x00,0x00}, /* M */
    {0x00,0x00,0xc6,0xe6,0xf6,0xfe,0xde,0xce,0xc6,0xc6,0xc6,0xc6,0x00,0x00,0x00,0x00}, /* N */
    {0x00,0x00,0x7c,0xc6,0xc6,0xc6,0xc6,0xc6,0xc6,0xc6,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* O */
    {0x00,0x00,0xfc,0x66,0x66,0x66,0x7c,0x60,0x60,0x60,0x60,0xf0,0x00,0x00,0x00,0x00}, /* P */
    {0x00,0x00,0x7c,0xc6,0xc6,0xc6,0xc6,0xc6,0xc6,0xd6,0xde,0x7c,0x0c,0x0e,0x00,0x00}, /* Q */
    {0x00,0x00,0xfc,0x66,0x66,0x66,0x7c,0x6c,0x66,0x66,0x66,0xe6,0x00,0x00,0x00,0x00}, /* R */
    {0x00,0x00,0x7c,0xc6,0xc6,0x60,0x38,0x0c,0x06,0xc6,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* S */
    {0x00,0x00,0x7e,0x7e,0x5a,0x18,0x18,0x18,0x18,0x18,0x18,0x3c,0x00,0x00,0x00,0x00}, /* T */
    {0x00,0x00,0xc6,0xc6,0xc6,0xc6,0xc6,0xc6,0xc6,0xc6,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* U */
    {0x00,0x00,0xc6,0xc6,0xc6,0xc6,0xc6,0xc6,0xc6,0x6c,0x38,0x10,0x00,0x00,0x00,0x00}, /* V */
    {0x00,0x00,0xc6,0xc6,0xc6,0xc6,0xd6,0xd6,0xfe,0xee,0xc6,0x82,0x00,0x00,0x00,0x00}, /* W */
    {0x00,0x00,0xc6,0xc6,0x6c,0x7c,0x38,0x38,0x7c,0x6c,0xc6,0xc6,0x00,0x00,0x00,0x00}, /* X */
    {0x00,0x00,0x66,0x66,0x66,0x66,0x3c,0x18,0x18,0x18,0x18,0x3c,0x00,0x00,0x00,0x00}, /* Y */
    {0x00,0x00,0xfe,0xc6,0x86,0x0c,0x18,0x30,0x60,0xc2,0xc6,0xfe,0x00,0x00,0x00,0x00}, /* Z */
    {0x00,0x00,0x3c,0x30,0x30,0x30,0x30,0x30,0x30,0x30,0x30,0x3c,0x00,0x00,0x00,0x00}, /* [ */
    {0x00,0x00,0x00,0x80,0xc0,0xe0,0x70,0x38,0x1c,0x0e,0x06,0x02,0x00,0x00,0x00,0x00}, /* \ */
    {0x00,0x00,0x3c,0x0c,0x0c,0x0c,0x0c,0x0c,0x0c,0x0c,0x0c,0x3c,0x00,0x00,0x00,0x00}, /* ] */
    {0x10,0x38,0x6c,0xc6,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* ^ */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xff,0x00,0x00}, /* _ */
    {0x30,0x30,0x18,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* ` */
    {0x00,0x00,0x00,0x00,0x00,0x78,0x0c,0x7c,0xcc,0xcc,0xcc,0x76,0x00,0x00,0x00,0x00}, /* a */
    {0x00,0x00,0xe0,0x60,0x60,0x78,0x6c,0x66,0x66,0x66,0x66,0x7c,0x00,0x00,0x00,0x00}, /* b */
    {0x00,0x00,0x00,0x00,0x00,0x7c,0xc6,0xc0,0xc0,0xc0,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* c */
    {0x00,0x00,0x1c,0x0c,0x0c,0x3c,0x6c,0xcc,0xcc,0xcc,0xcc,0x76,0x00,0x00,0x00,0x00}, /* d */
    {0x00,0x00,0x00,0x00,0x00,0x7c,0xc6,0xfe,0xc0,0xc0,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* e */
    {0x00,0x00,0x38,0x6c,0x64,0x60,0xf0,0x60,0x60,0x60,0x60,0xf0,0x00,0x00,0x00,0x00}, /* f */
    {0x00,0x00,0x00,0x00,0x00,0x76,0xcc,0xcc,0xcc,0x7c,0x0c,0xcc,0x78,0x00,0x00,0x00}, /* g */
    {0x00,0x00,0xe0,0x60,0x60,0x6c,0x76,0x66,0x66,0x66,0x66,0xe6,0x00,0x00,0x00,0x00}, /* h */
    {0x00,0x00,0x18,0x18,0x00,0x38,0x18,0x18,0x18,0x18,0x18,0x3c,0x00,0x00,0x00,0x00}, /* i */
    {0x00,0x00,0x06,0x06,0x00,0x0e,0x06,0x06,0x06,0x06,0x06,0x66,0x66,0x3c,0x00,0x00}, /* j */
    {0x00,0x00,0xe0,0x60,0x60,0x66,0x6c,0x78,0x78,0x6c,0x66,0xe6,0x00,0x00,0x00,0x00}, /* k */
    {0x00,0x00,0x38,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x3c,0x00,0x00,0x00,0x00}, /* l */
    {0x00,0x00,0x00,0x00,0x00,0xec,0xfe,0xd6,0xd6,0xd6,0xd6,0xc6,0x00,0x00,0x00,0x00}, /* m */
    {0x00,0x00,0x00,0x00,0x00,0xdc,0x66,0x66,0x66,0x66,0x66,0x66,0x00,0x00,0x00,0x00}, /* n */
    {0x00,0x00,0x00,0x00,0x00,0x7c,0xc6,0xc6,0xc6,0xc6,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* o */
    {0x00,0x00,0x00,0x00,0x00,0xdc,0x66,0x66,0x66,0x7c,0x60,0x60,0xf0,0x00,0x00,0x00}, /* p */
    {0x00,0x00,0x00,0x00,0x00,0x76,0xcc,0xcc,0xcc,0x7c,0x0c,0x0c,0x1e,0x00,0x00,0x00}, /* q */
    {0x00,0x00,0x00,0x00,0x00,0xdc,0x76,0x66,0x60,0x60,0x60,0xf0,0x00,0x00,0x00,0x00}, /* r */
    {0x00,0x00,0x00,0x00,0x00,0x7c,0xc6,0x60,0x38,0x0c,0xc6,0x7c,0x00,0x00,0x00,0x00}, /* s */
    {0x00,0x00,0x10,0x30,0x30,0xfc,0x30,0x30,0x30,0x30,0x36,0x1c,0x00,0x00,0x00,0x00}, /* t */
    {0x00,0x00,0x00,0x00,0x00,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc,0x76,0x00,0x00,0x00,0x00}, /* u */
    {0x00,0x00,0x00,0x00,0x00,0xc6,0xc6,0xc6,0xc6,0x6c,0x38,0x10,0x00,0x00,0x00,0x00}, /* v */
    {0x00,0x00,0x00,0x00,0x00,0xc6,0xc6,0xd6,0xd6,0xfe,0xee,0x6c,0x00,0x00,0x00,0x00}, /* w */
    {0x00,0x00,0x00,0x00,0x00,0xc6,0x6c,0x38,0x38,0x38,0x6c,0xc6,0x00,0x00,0x00,0x00}, /* x */
    {0x00,0x00,0x00,0x00,0x00,0xc6,0xc6,0xc6,0xc6,0x7e,0x06,0x0c,0xf8,0x00,0x00,0x00}, /* y */
    {0x00,0x00,0x00,0x00,0x00,0xfe,0xcc,0x18,0x30,0x60,0xc6,0xfe,0x00,0x00,0x00,0x00}, /* z */
    {0x00,0x00,0x0e,0x18,0x18,0x18,0x70,0x18,0x18,0x18,0x18,0x0e,0x00,0x00,0x00,0x00}, /* { */
    {0x00,0x00,0x18,0x18,0x18,0x18,0x00,0x18,0x18,0x18,0x18,0x18,0x00,0x00,0x00,0x00}, /* | */
    {0x00,0x00,0x70,0x18,0x18,0x18,0x0e,0x18,0x18,0x18,0x18,0x70,0x00,0x00,0x00,0x00}, /* } */
    {0x00,0x00,0x76,0xdc,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* ~ */
};

struct disp_ctx {
    int fd;
    int is_drm;
    uint32_t drm_fb_id;
    uint32_t width, height, stride_bytes, bpp;
    uint32_t r_off, g_off, b_off;
    size_t map_size;
    uint8_t *vram;
    uint32_t *back; /* Always 32-bit 0x00RRGGBB in RAM */
};

struct input_dev {
    int fd;
    int has_abs;
    int abs_min_x, abs_max_x;
    int abs_min_y, abs_max_y;
    int touching;
    int prev_ax, prev_ay;
    int cur_ax, cur_ay;
    int have_prev;
};

#define MAX_IN_DEVS 24
static struct input_dev g_indevs[MAX_IN_DEVS];
static int g_nindevs = 0;
static int g_shift = 0, g_caps = 0;
static int g_mouse_x = -1, g_mouse_y = -1;
static int g_mouse_visible = 0;

static uint64_t mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000ULL);
}

static int disp_open(struct disp_ctx *d) {
    memset(d, 0, sizeof(*d));
    d->fd = -1;
    if (access("/a11y/active", F_OK) == 0)
        return -1; /* Let Speakup screen reader use plain text mode */

    int fd = open("/dev/fb0", O_RDWR | O_CLOEXEC);
    if (fd >= 0) {
        struct fb_var_screeninfo vi;
        struct fb_fix_screeninfo fi;
        if (ioctl(fd, FBIOGET_VSCREENINFO, &vi) == 0 &&
            ioctl(fd, FBIOGET_FSCREENINFO, &fi) == 0 &&
            vi.xres >= 640 && vi.yres >= 480 &&
            (vi.bits_per_pixel == 32 || vi.bits_per_pixel == 16)) {
            size_t sz = fi.smem_len ? fi.smem_len : (size_t)fi.line_length * vi.yres;
            uint8_t *m = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (m != MAP_FAILED) {
                d->fd = fd;
                d->width = vi.xres;
                d->height = vi.yres;
                d->stride_bytes = fi.line_length;
                d->bpp = vi.bits_per_pixel;
                d->r_off = vi.red.offset;
                d->g_off = vi.green.offset;
                d->b_off = vi.blue.offset;
                d->map_size = sz;
                d->vram = m;
                d->back = calloc((size_t)d->width * d->height, sizeof(uint32_t));
                if (d->back) {
                    int tty = open("/dev/tty1", O_WRONLY | O_CLOEXEC);
                    if (tty >= 0) {
                        ssize_t wr = write(tty, "\033[?25l", 6);
                        (void)wr;
                        close(tty);
                    }
                    return 0;
                }
                munmap(m, sz);
            }
        }
        close(fd);
    }

    /* Fallback: DRM/KMS dumb buffer on /dev/dri/card0..card3 */
    for (int ci = 0; ci < 4; ci++) {
        char path[32];
        snprintf(path, sizeof(path), "/dev/dri/card%d", ci);
        fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd < 0) continue;
        struct fb_drm_mode_card_res res = {0};
        if (ioctl(fd, IOCTL_DRM_GETRESOURCES, &res) != 0 || res.count_connectors == 0 || res.count_crtcs == 0) {
            close(fd);
            continue;
        }
        uint32_t conns[32] = {0}, crtcs[32] = {0}, encs[32] = {0}, fbs[32] = {0};
        if (res.count_connectors > 32) res.count_connectors = 32;
        if (res.count_crtcs > 32) res.count_crtcs = 32;
        if (res.count_encoders > 32) res.count_encoders = 32;
        if (res.count_fbs > 32) res.count_fbs = 32;
        res.connector_id_ptr = (uint64_t)(uintptr_t)conns;
        res.crtc_id_ptr = (uint64_t)(uintptr_t)crtcs;
        res.encoder_id_ptr = (uint64_t)(uintptr_t)encs;
        res.fb_id_ptr = (uint64_t)(uintptr_t)fbs;
        if (ioctl(fd, IOCTL_DRM_GETRESOURCES, &res) != 0) { close(fd); continue; }

        for (uint32_t k = 0; k < res.count_connectors; k++) {
            struct fb_drm_mode_get_connector conn = {0};
            conn.connector_id = conns[k];
            if (ioctl(fd, IOCTL_DRM_GETCONNECTOR, &conn) != 0 || conn.connection != 1 || conn.count_modes == 0)
                continue;
            struct fb_drm_mode_modeinfo modes[64];
            uint32_t c_encs[16];
            uint32_t props[64];
            uint64_t pvals[64];
            if (conn.count_modes > 64) conn.count_modes = 64;
            if (conn.count_encoders > 16) conn.count_encoders = 16;
            if (conn.count_props > 64) conn.count_props = 64;
            conn.modes_ptr = (uint64_t)(uintptr_t)modes;
            conn.encoders_ptr = (uint64_t)(uintptr_t)c_encs;
            conn.props_ptr = (uint64_t)(uintptr_t)props;
            conn.prop_values_ptr = (uint64_t)(uintptr_t)pvals;
            if (ioctl(fd, IOCTL_DRM_GETCONNECTOR, &conn) != 0 || conn.count_modes == 0)
                continue;

            uint32_t crtc_id = crtcs[0];
            if (conn.encoder_id) {
                struct fb_drm_mode_get_encoder enc = {.encoder_id = conn.encoder_id};
                if (ioctl(fd, IOCTL_DRM_GETENCODER, &enc) == 0 && enc.crtc_id)
                    crtc_id = enc.crtc_id;
            }
            struct fb_drm_mode_modeinfo mode = modes[0];
            struct fb_drm_mode_create_dumb cd = {.width = mode.hdisplay, .height = mode.vdisplay, .bpp = 32};
            if (ioctl(fd, IOCTL_DRM_CREATE_DUMB, &cd) != 0) continue;
            struct fb_drm_mode_fb_cmd fbcmd = {
                .width = cd.width, .height = cd.height, .pitch = cd.pitch,
                .bpp = 32, .depth = 24, .handle = cd.handle,
            };
            if (ioctl(fd, IOCTL_DRM_ADDFB, &fbcmd) != 0) continue;
            struct fb_drm_mode_map_dumb md = {.handle = cd.handle};
            if (ioctl(fd, IOCTL_DRM_MAP_DUMB, &md) != 0) continue;
            uint8_t *m = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)md.offset);
            if (m == MAP_FAILED) continue;

            struct fb_drm_mode_crtc crtc = {
                .set_connectors_ptr = (uint64_t)(uintptr_t)&conn.connector_id,
                .count_connectors = 1,
                .crtc_id = crtc_id,
                .fb_id = fbcmd.fb_id,
                .mode_valid = 1,
                .mode = mode,
            };
            if (ioctl(fd, IOCTL_DRM_SETCRTC, &crtc) == 0) {
                d->fd = fd;
                d->is_drm = 1;
                d->drm_fb_id = fbcmd.fb_id;
                d->width = cd.width;
                d->height = cd.height;
                d->stride_bytes = cd.pitch;
                d->bpp = 32;
                d->r_off = 16; d->g_off = 8; d->b_off = 0;
                d->map_size = cd.size;
                d->vram = m;
                d->back = calloc((size_t)d->width * d->height, sizeof(uint32_t));
                if (d->back) return 0;
                munmap(m, cd.size);
            }
        }
        close(fd);
    }
    return -1;
}

static void disp_close(struct disp_ctx *d) {
    if (d->back) free(d->back);
    if (d->vram && d->vram != MAP_FAILED) munmap(d->vram, d->map_size);
    if (d->fd >= 0) close(d->fd);
    int tty = open("/dev/tty1", O_WRONLY | O_CLOEXEC);
    if (tty >= 0) {
        ssize_t wr = write(tty, "\033[?25h", 6);
        (void)wr;
        close(tty);
    }
}

static void disp_present(struct disp_ctx *d) {
    if (d->bpp == 32 && d->r_off == 16 && d->g_off == 8 && d->b_off == 0) {
        for (uint32_t y = 0; y < d->height; y++) {
            memcpy(d->vram + (size_t)y * d->stride_bytes,
                   d->back + (size_t)y * d->width,
                   (size_t)d->width * 4);
        }
    } else if (d->bpp == 32) {
        for (uint32_t y = 0; y < d->height; y++) {
            uint32_t *dst = (uint32_t *)(d->vram + (size_t)y * d->stride_bytes);
            const uint32_t *src = d->back + (size_t)y * d->width;
            for (uint32_t x = 0; x < d->width; x++) {
                uint32_t c = src[x];
                uint32_t r = (c >> 16) & 0xff, g = (c >> 8) & 0xff, b = c & 0xff;
                dst[x] = (r << d->r_off) | (g << d->g_off) | (b << d->b_off);
            }
        }
    } else if (d->bpp == 16) {
        for (uint32_t y = 0; y < d->height; y++) {
            uint16_t *dst = (uint16_t *)(d->vram + (size_t)y * d->stride_bytes);
            const uint32_t *src = d->back + (size_t)y * d->width;
            for (uint32_t x = 0; x < d->width; x++) {
                uint32_t c = src[x];
                dst[x] = (uint16_t)((((c >> 19) & 0x1f) << 11) | (((c >> 10) & 0x3f) << 5) | ((c >> 3) & 0x1f));
            }
        }
    }
    if (d->is_drm) {
        struct fb_drm_mode_fb_dirty_cmd dirty = {.fb_id = d->drm_fb_id};
        ioctl(d->fd, IOCTL_DRM_DIRTYFB, &dirty);
    }
}

/* Drawing primitives */
static inline void put_px(struct disp_ctx *d, int x, int y, uint32_t rgb) {
    if ((unsigned)x < d->width && (unsigned)y < d->height)
        d->back[(size_t)y * d->width + x] = rgb;
}

static inline uint32_t blend_rgb(uint32_t bg, uint32_t fg, uint8_t alpha) {
    uint32_t inv = 255 - alpha;
    uint32_t r = (((bg >> 16) & 0xff) * inv + ((fg >> 16) & 0xff) * alpha) / 255;
    uint32_t g = (((bg >> 8) & 0xff) * inv + ((fg >> 8) & 0xff) * alpha) / 255;
    uint32_t b = ((bg & 0xff) * inv + (fg & 0xff) * alpha) / 255;
    return (r << 16) | (g << 8) | b;
}

static void fill_rect(struct disp_ctx *d, int x, int y, int w, int h, uint32_t rgb) {
    int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int x1 = (x + w) > (int)d->width ? (int)d->width : (x + w);
    int y1 = (y + h) > (int)d->height ? (int)d->height : (y + h);
    for (int py = y0; py < y1; py++) {
        uint32_t *row = d->back + (size_t)py * d->width;
        for (int px = x0; px < x1; px++) row[px] = rgb;
    }
}

static void fill_round_rect(struct disp_ctx *d, int x, int y, int w, int h, int r, uint32_t rgb) {
    if (r <= 0) { fill_rect(d, x, y, w, h, rgb); return; }
    for (int py = y; py < y + h; py++) {
        if ((unsigned)py >= d->height) continue;
        int dy = 0;
        if (py < y + r) dy = (y + r - 1) - py;
        else if (py >= y + h - r) dy = py - (y + h - r);
        for (int px = x; px < x + w; px++) {
            if ((unsigned)px >= d->width) continue;
            int dx = 0;
            if (px < x + r) dx = (x + r - 1) - px;
            else if (px >= x + w - r) dx = px - (x + w - r);
            if (dx > 0 && dy > 0) {
                int dist2 = dx * dx + dy * dy;
                if (dist2 > r * r) continue;
                if (dist2 > (r - 1) * (r - 1)) {
                    uint32_t cur = d->back[(size_t)py * d->width + px];
                    d->back[(size_t)py * d->width + px] = blend_rgb(cur, rgb, 128);
                    continue;
                }
            }
            d->back[(size_t)py * d->width + px] = rgb;
        }
    }
}

static void stroke_round_rect(struct disp_ctx *d, int x, int y, int w, int h, int r, int thick, uint32_t border_rgb, uint32_t fill_rgb) {
    fill_round_rect(d, x, y, w, h, r, border_rgb);
    fill_round_rect(d, x + thick, y + thick, w - 2 * thick, h - 2 * thick, r > thick ? r - thick : 0, fill_rgb);
}

static uint32_t google_grad_color(float t) {
    static const uint8_t stops[4][3] = {
        {66, 133, 244},  /* Google Blue */
        {234, 67, 53},   /* Google Red */
        {251, 188, 5},   /* Google Yellow */
        {52, 168, 83},   /* Google Green */
    };
    if (t <= 0.0f) return (66 << 16) | (133 << 8) | 244;
    if (t >= 1.0f) return (52 << 16) | (168 << 8) | 83;
    float s = t * 3.0f;
    int idx = (int)s;
    if (idx > 2) idx = 2;
    float f = s - idx;
    uint32_t r = (uint32_t)(stops[idx][0] * (1.0f - f) + stops[idx + 1][0] * f);
    uint32_t g = (uint32_t)(stops[idx][1] * (1.0f - f) + stops[idx + 1][1] * f);
    uint32_t b = (uint32_t)(stops[idx][2] * (1.0f - f) + stops[idx + 1][2] * f);
    return (r << 16) | (g << 8) | b;
}

static void fill_google_gradient_bar(struct disp_ctx *d, int x, int y, int w, int h, float progress) {
    int fill_w = (int)(w * progress);
    if (fill_w <= 0) return;
    if (fill_w > w) fill_w = w;
    for (int px = 0; px < fill_w; px++) {
        uint32_t col = google_grad_color((float)px / (float)(w > 1 ? w - 1 : 1));
        for (int py = 0; py < h; py++) {
            put_px(d, x + px, y + py, col);
        }
    }
}

static void draw_logo(struct disp_ctx *d, int cx, int top_y) {
    int x0 = cx - FIDEBOOK_LOGO_W / 2;
    for (int y = 0; y < FIDEBOOK_LOGO_H; y++) {
        for (int x = 0; x < FIDEBOOK_LOGO_W; x++) {
            const uint8_t *p = &fidebook_logo_rgba[(y * FIDEBOOK_LOGO_W + x) * 4];
            uint8_t a = p[3];
            if (a == 0) continue;
            int sx = x0 + x, sy = top_y + y;
            if ((unsigned)sx < d->width && (unsigned)sy < d->height) {
                uint32_t fg = ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | p[2];
                uint32_t bg = d->back[(size_t)sy * d->width + sx];
                d->back[(size_t)sy * d->width + sx] = blend_rgb(bg, fg, a);
            }
        }
    }
}

static void draw_char(struct disp_ctx *d, int x, int y, char c, int scale, uint32_t rgb) {
    unsigned uc = (unsigned char)c;
    if (uc < 32 || uc > 126) uc = '?';
    const uint8_t *glyph = font8x16[uc - 32];
    for (int row = 0; row < 16; row++) {
        uint8_t bits = glyph[row];
        if (!bits) continue;
        for (int col = 0; col < 8; col++) {
            if (bits & (0x80 >> col)) {
                for (int sy = 0; sy < scale; sy++)
                    for (int sx = 0; sx < scale; sx++)
                        put_px(d, x + col * scale + sx, y + row * scale + sy, rgb);
            }
        }
    }
}

static void draw_text(struct disp_ctx *d, int x, int y, const char *s, int scale, uint32_t rgb) {
    int adv = 8 * scale + (scale > 1 ? 1 : 0);
    for (int i = 0; s[i]; i++)
        draw_char(d, x + i * adv, y, s[i], scale, rgb);
}

static int text_width(const char *s, int scale) {
    int len = (int)strlen(s);
    if (len == 0) return 0;
    int adv = 8 * scale + (scale > 1 ? 1 : 0);
    return len * adv;
}

static void draw_text_center(struct disp_ctx *d, int cx, int y, const char *s, int scale, uint32_t rgb) {
    draw_text(d, cx - text_width(s, scale) / 2, y, s, scale, rgb);
}

static void draw_cursor(struct disp_ctx *d) {
    if (!g_mouse_visible || g_mouse_x < 0 || g_mouse_y < 0) return;
    static const char *cur_bmp[16] = {
        "X...............",
        "XX..............",
        "X#X.............",
        "X##X............",
        "X###X...........",
        "X####X..........",
        "X#####X.........",
        "X######X........",
        "X#######X.......",
        "X########X......",
        "X#####XXXXX.....",
        "X##X##X.........",
        "X#X.X##X........",
        "XX..X##X........",
        "X....X##X.......",
        ".....XX.........",
    };
    for (int y = 0; y < 16; y++) {
        for (int x = 0; x < 16; x++) {
            char ch = cur_bmp[y][x];
            if (ch == 'X') put_px(d, g_mouse_x + x, g_mouse_y + y, 0x07090F);
            else if (ch == '#') put_px(d, g_mouse_x + x, g_mouse_y + y, 0xFFFFFF);
        }
    }
}

/* Input handling (/dev/input/event*) */
static void input_open_all(struct disp_ctx *d) {
    g_nindevs = 0;
    g_mouse_x = (int)d->width / 2;
    g_mouse_y = (int)d->height / 2;
    DIR *dir = opendir("/dev/input");
    if (!dir) return;
    struct dirent *de;
    while ((de = readdir(dir)) != NULL && g_nindevs < MAX_IN_DEVS) {
        if (strncmp(de->d_name, "event", 5) != 0) continue;
        char p[300];
        snprintf(p, sizeof(p), "/dev/input/%s", de->d_name);
        int fd = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        struct input_dev *id = &g_indevs[g_nindevs++];
        memset(id, 0, sizeof(*id));
        id->fd = fd;
        struct input_absinfo ax = {0}, ay = {0};
        if (ioctl(fd, EVIOCGABS(ABS_X), &ax) == 0 && ioctl(fd, EVIOCGABS(ABS_Y), &ay) == 0 &&
            ax.maximum > ax.minimum && ay.maximum > ay.minimum) {
            id->has_abs = 1;
            id->abs_min_x = ax.minimum; id->abs_max_x = ax.maximum;
            id->abs_min_y = ay.minimum; id->abs_max_y = ay.maximum;
        }
    }
    closedir(dir);
}

static void input_close_all(void) {
    for (int i = 0; i < g_nindevs; i++) close(g_indevs[i].fd);
    g_nindevs = 0;
}

static char keycode_to_ascii(uint16_t code, int shift, int caps) {
    int upper = shift ^ caps;
    switch (code) {
        case KEY_1: return shift ? '!' : '1';
        case KEY_2: return shift ? '@' : '2';
        case KEY_3: return shift ? '#' : '3';
        case KEY_4: return shift ? '$' : '4';
        case KEY_5: return shift ? '%' : '5';
        case KEY_6: return shift ? '^' : '6';
        case KEY_7: return shift ? '&' : '7';
        case KEY_8: return shift ? '*' : '8';
        case KEY_9: return shift ? '(' : '9';
        case KEY_0: return shift ? ')' : '0';
        case KEY_MINUS: return shift ? '_' : '-';
        case KEY_EQUAL: return shift ? '+' : '=';
        case KEY_DOT:   return shift ? '>' : '.';
        case KEY_SLASH: return shift ? '?' : '/';
        case KEY_SPACE: return ' ';
        case KEY_KP0: return '0'; case KEY_KP1: return '1'; case KEY_KP2: return '2';
        case KEY_KP3: return '3'; case KEY_KP4: return '4'; case KEY_KP5: return '5';
        case KEY_KP6: return '6'; case KEY_KP7: return '7'; case KEY_KP8: return '8';
        case KEY_KP9: return '9'; case KEY_KPMINUS: return '-'; case KEY_KPDOT: return '.';
        case KEY_Q: return upper ? 'Q' : 'q'; case KEY_W: return upper ? 'W' : 'w';
        case KEY_E: return upper ? 'E' : 'e'; case KEY_R: return upper ? 'R' : 'r';
        case KEY_T: return upper ? 'T' : 't'; case KEY_Y: return upper ? 'Y' : 'y';
        case KEY_U: return upper ? 'U' : 'u'; case KEY_I: return upper ? 'I' : 'i';
        case KEY_O: return upper ? 'O' : 'o'; case KEY_P: return upper ? 'P' : 'p';
        case KEY_A: return upper ? 'A' : 'a'; case KEY_S: return upper ? 'S' : 's';
        case KEY_D: return upper ? 'D' : 'd'; case KEY_F: return upper ? 'F' : 'f';
        case KEY_G: return upper ? 'G' : 'g'; case KEY_H: return upper ? 'H' : 'h';
        case KEY_J: return upper ? 'J' : 'j'; case KEY_K: return upper ? 'K' : 'k';
        case KEY_L: return upper ? 'L' : 'l'; case KEY_Z: return upper ? 'Z' : 'z';
        case KEY_X: return upper ? 'X' : 'x'; case KEY_C: return upper ? 'C' : 'c';
        case KEY_V: return upper ? 'V' : 'v'; case KEY_B: return upper ? 'B' : 'b';
        case KEY_N: return upper ? 'N' : 'n'; case KEY_M: return upper ? 'M' : 'm';
        default: return 0;
    }
}

struct ui_event {
    int any_activity;
    int key;       /* Linux KEY_* on press/repeat */
    char ch;       /* Translated ASCII if printable */
    int clicked;   /* Left mouse / touchpad click */
    int moved;     /* Pointer moved */
};

static void input_poll(struct disp_ctx *d, int timeout_ms, struct ui_event *out) {
    memset(out, 0, sizeof(*out));
    if (g_nindevs == 0) {
        usleep((useconds_t)timeout_ms * 1000);
        return;
    }
    struct pollfd pfds[MAX_IN_DEVS];
    for (int i = 0; i < g_nindevs; i++) {
        pfds[i].fd = g_indevs[i].fd;
        pfds[i].events = POLLIN;
        pfds[i].revents = 0;
    }
    if (poll(pfds, (nfds_t)g_nindevs, timeout_ms) <= 0)
        return;

    for (int i = 0; i < g_nindevs; i++) {
        if (!(pfds[i].revents & POLLIN)) continue;
        struct input_dev *id = &g_indevs[i];
        struct input_event ev;
        while (read(id->fd, &ev, sizeof(ev)) == sizeof(ev)) {
            if (ev.type == EV_KEY) {
                if (ev.code == KEY_LEFTSHIFT || ev.code == KEY_RIGHTSHIFT) {
                    g_shift = (ev.value != 0);
                } else if (ev.code == KEY_CAPSLOCK && ev.value == 1) {
                    g_caps ^= 1;
                } else if (ev.code == BTN_TOUCH) {
                    id->touching = (ev.value != 0);
                    if (!id->touching) id->have_prev = 0;
                } else if (ev.code == BTN_LEFT || ev.code == BTN_TOOL_DOUBLETAP) {
                    if (ev.value == 1) {
                        g_mouse_visible = 1;
                        out->clicked = 1;
                        out->any_activity = 1;
                    }
                } else if (ev.value == 1 || ev.value == 2) {
                    out->any_activity = 1;
                    out->key = ev.code;
                    out->ch = keycode_to_ascii(ev.code, g_shift, g_caps);
                }
            } else if (ev.type == EV_REL) {
                if (ev.code == REL_X) {
                    g_mouse_x += ev.value;
                    g_mouse_visible = 1; out->moved = 1; out->any_activity = 1;
                } else if (ev.code == REL_Y) {
                    g_mouse_y += ev.value;
                    g_mouse_visible = 1; out->moved = 1; out->any_activity = 1;
                }
            } else if (ev.type == EV_ABS && id->has_abs) {
                if (ev.code == ABS_X || ev.code == ABS_MT_POSITION_X) id->cur_ax = ev.value;
                else if (ev.code == ABS_Y || ev.code == ABS_MT_POSITION_Y) id->cur_ay = ev.value;
            } else if (ev.type == EV_SYN && ev.code == SYN_REPORT && id->has_abs && id->touching) {
                if (id->have_prev) {
                    int span_x = id->abs_max_x - id->abs_min_x;
                    int span_y = id->abs_max_y - id->abs_min_y;
                    if (span_x > 0 && span_y > 0) {
                        int dx = ((id->cur_ax - id->prev_ax) * (int)d->width * 3) / (span_x * 2);
                        int dy = ((id->cur_ay - id->prev_ay) * (int)d->height * 3) / (span_y * 2);
                        if (dx != 0 || dy != 0) {
                            g_mouse_x += dx; g_mouse_y += dy;
                            g_mouse_visible = 1; out->moved = 1; out->any_activity = 1;
                        }
                    }
                }
                id->prev_ax = id->cur_ax;
                id->prev_ay = id->cur_ay;
                id->have_prev = 1;
            }
            if (g_mouse_x < 0) g_mouse_x = 0;
            if (g_mouse_y < 0) g_mouse_y = 0;
            if (g_mouse_x >= (int)d->width) g_mouse_x = (int)d->width - 1;
            if (g_mouse_y >= (int)d->height) g_mouse_y = (int)d->height - 1;
        }
    }
}

static void draw_header(struct disp_ctx *d, const char *title, const char *subtitle) {
    fill_rect(d, 0, 0, (int)d->width, (int)d->height, 0x07090F);
    int cx = (int)d->width / 2;
    int top = (int)d->height / 11;
    if (top < 28) top = 28;
    draw_logo(d, cx, top);
    draw_text_center(d, cx, top + 84, title, 2, 0xF4F7FF);
    if (subtitle && subtitle[0])
        draw_text_center(d, cx, top + 124, subtitle, 1, 0x8E9BB5);
}

/* Subcommand 1: menu <default_1based> <timeout_sec> <title> <subtitle> <opt1> [opt2...]
 * Each <opt> is "Heading|Description". Prints 1-based choice to stdout. */
static int cmd_menu(struct disp_ctx *d, int argc, char **argv) {
    if (argc < 5) return 2;
    int def_idx = atoi(argv[0]) - 1;
    int timeout_sec = atoi(argv[1]);
    const char *title = argv[2];
    const char *subtitle = argv[3];
    int nitems = argc - 4;
    if (nitems > 8) nitems = 8;
    if (def_idx < 0 || def_idx >= nitems) def_idx = 0;

    int sel = def_idx;
    int countdown_active = (timeout_sec > 0);
    uint64_t t_start = mono_ms();
    uint64_t t_limit = (uint64_t)timeout_sec * 1000ULL;

    /* Flush any residual Enter pressed in UEFI menu */
    struct ui_event flush_ev;
    input_poll(d, 80, &flush_ev);

    int card_w = 660;
    if (card_w > (int)d->width - 60) card_w = (int)d->width - 60;
    int card_h = 74;
    int gap = 14;
    int cx = (int)d->width / 2;
    int cards_top = (int)d->height / 11 + 166;

    for (;;) {
        uint64_t elapsed = mono_ms() - t_start;
        if (countdown_active && elapsed >= t_limit) {
            printf("%d\n", sel + 1);
            return 0;
        }

        draw_header(d, title, subtitle);

        for (int i = 0; i < nitems; i++) {
            int x = cx - card_w / 2;
            int y = cards_top + i * (card_h + gap);
            int active = (i == sel);
            uint32_t border = active ? 0x4285F4 : 0x1E293B;
            uint32_t bg = active ? 0x131D33 : 0x0E1320;
            stroke_round_rect(d, x, y, card_w, card_h, 12, active ? 2 : 1, border, bg);

            /* Number pill */
            char num[4];
            snprintf(num, sizeof(num), "%d", i + 1);
            fill_round_rect(d, x + 18, y + 19, 36, 36, 8, active ? 0x4285F4 : 0x1B2436);
            draw_text_center(d, x + 36, y + 29, num, 1, active ? 0xFFFFFF : 0x94A3B8);

            char buf[256];
            snprintf(buf, sizeof(buf), "%s", argv[4 + i]);
            char *sep = strchr(buf, '|');
            const char *desc = "";
            if (sep) { *sep = '\0'; desc = sep + 1; }
            draw_text(d, x + 70, y + 17, buf, 1, 0xF8FAFC);
            if (desc[0])
                draw_text(d, x + 70, y + 41, desc, 1, active ? 0x93C5FD : 0x64748B);
        }

        int foot_y = cards_top + nitems * (card_h + gap) + 20;
        if (countdown_active) {
            float rem = 1.0f - (float)elapsed / (float)t_limit;
            int secs = (int)((t_limit - elapsed + 999) / 1000);
            char cmsg[96];
            snprintf(cmsg, sizeof(cmsg), "Auto-continuing with option %d in %d s  (Up/Down, 1-%d, or Click)",
                     sel + 1, secs, nitems);
            draw_text_center(d, cx, foot_y, cmsg, 1, 0x8E9BB5);
            fill_round_rect(d, cx - 220, foot_y + 26, 440, 6, 3, 0x1A2234);
            fill_google_gradient_bar(d, cx - 220, foot_y + 26, 440, 6, rem);
        } else {
            draw_text_center(d, cx, foot_y, "Use Up/Down Arrows, Number Keys, or Touchpad/Mouse + Enter", 1, 0x64748B);
        }

        draw_cursor(d);
        disp_present(d);

        struct ui_event ev;
        input_poll(d, 33, &ev);
        if (ev.any_activity) countdown_active = 0;

        if (ev.moved || ev.clicked) {
            for (int i = 0; i < nitems; i++) {
                int x = cx - card_w / 2;
                int y = cards_top + i * (card_h + gap);
                if (g_mouse_x >= x && g_mouse_x < x + card_w && g_mouse_y >= y && g_mouse_y < y + card_h) {
                    sel = i;
                    if (ev.clicked) {
                        printf("%d\n", sel + 1);
                        return 0;
                    }
                }
            }
        }
        if (ev.key == KEY_UP) sel = (sel + nitems - 1) % nitems;
        else if (ev.key == KEY_DOWN || ev.key == KEY_TAB) sel = (sel + 1) % nitems;
        else if (ev.key == KEY_ENTER || ev.key == KEY_KPENTER) {
            printf("%d\n", sel + 1);
            return 0;
        } else if (ev.ch >= '1' && ev.ch <= '0' + nitems) {
            printf("%d\n", ev.ch - '0');
            return 0;
        }
    }
}

/* Subcommand 2: serial <disk_desc> <warn_text> <expected_serial>
 * Enforces typing the exact hardware serial number on the laptop keyboard (no bypasses). */
static int cmd_serial(struct disp_ctx *d, int argc, char **argv) {
    if (argc < 3) return 2;
    const char *disk_desc = argv[0];
    const char *warn_text = argv[1];
    const char *expected = argv[2];

    char typed[96] = {0};
    int tlen = 0;
    int mismatch_flash = 0;
    int cx = (int)d->width / 2;
    int card_w = 680;
    if (card_w > (int)d->width - 60) card_w = (int)d->width - 60;

    struct ui_event flush_ev;
    input_poll(d, 80, &flush_ev);

    for (;;) {
        draw_header(d, "Confirm Target Drive", "Hardware write protection check");
        int y0 = (int)d->height / 11 + 166;
        int x0 = cx - card_w / 2;

        stroke_round_rect(d, x0, y0, card_w, 276, 14, 1, 0x263248, 0x0E1422);
        draw_text(d, x0 + 28, y0 + 22, "Target Disk:", 1, 0x94A3B8);
        draw_text(d, x0 + 138, y0 + 22, disk_desc, 1, 0xF8FAFC);
        draw_text(d, x0 + 28, y0 + 50, warn_text, 1, 0xFBBF24);

        draw_text(d, x0 + 28, y0 + 88, "Type this exact drive serial number to proceed:", 1, 0xCBD5E1);
        fill_round_rect(d, x0 + 28, y0 + 112, card_w - 56, 40, 8, 0x172136);
        draw_text_center(d, cx, y0 + 124, expected, 1, 0x60A5FA);

        int exact_match = (strcmp(typed, expected) == 0);
        uint32_t box_border = exact_match ? 0x34A853 : (mismatch_flash > 0 ? 0xEA4335 : 0x4285F4);
        stroke_round_rect(d, x0 + 28, y0 + 168, card_w - 56, 46, 8, 2, box_border, 0x070B14);

        char disp_in[104];
        int blink = ((mono_ms() / 450) & 1);
        snprintf(disp_in, sizeof(disp_in), "%s%s", typed, blink ? "_" : " ");
        draw_text(d, x0 + 44, y0 + 183, disp_in, 1, 0xFFFFFF);

        if (mismatch_flash > 0) {
            draw_text(d, x0 + 28, y0 + 228, "Serial does not match yet - check uppercase/lowercase & digits.", 1, 0xEA4335);
            mismatch_flash--;
        } else if (exact_match) {
            draw_text(d, x0 + 28, y0 + 228, "Serial verified! Press Enter or click Confirm to begin.", 1, 0x34A853);
        } else {
            draw_text(d, x0 + 28, y0 + 228, "Press Esc to cancel safely without touching the disk.", 1, 0x64748B);
        }

        /* Cancel & Confirm buttons */
        int btn_y = y0 + 296;
        stroke_round_rect(d, cx - 220, btn_y, 190, 44, 10, 1, 0x334155, 0x111827);
        draw_text_center(d, cx - 125, btn_y + 14, "Cancel (Esc)", 1, 0xCBD5E1);

        fill_round_rect(d, cx + 30, btn_y, 210, 44, 10, exact_match ? 0x34A853 : 0x1E293B);
        draw_text_center(d, cx + 135, btn_y + 14, "Confirm & Install", 1, exact_match ? 0xFFFFFF : 0x475569);

        draw_cursor(d);
        disp_present(d);

        struct ui_event ev;
        input_poll(d, 33, &ev);
        if (ev.key == KEY_ESC) return 1;
        if (ev.key == KEY_BACKSPACE && tlen > 0) {
            typed[--tlen] = '\0';
        } else if (ev.key == KEY_ENTER || ev.key == KEY_KPENTER) {
            if (exact_match) {
                printf("%s\n", typed);
                return 0;
            }
            mismatch_flash = 35;
        } else if (ev.ch >= 32 && ev.ch <= 126 && tlen < (int)sizeof(typed) - 2) {
            typed[tlen++] = ev.ch;
            typed[tlen] = '\0';
        }
        if (ev.clicked) {
            if (g_mouse_x >= cx - 220 && g_mouse_x < cx - 30 && g_mouse_y >= btn_y && g_mouse_y < btn_y + 44)
                return 1;
            if (g_mouse_x >= cx + 30 && g_mouse_x < cx + 240 && g_mouse_y >= btn_y && g_mouse_y < btn_y + 44) {
                if (exact_match) {
                    printf("%s\n", typed);
                    return 0;
                }
                mismatch_flash = 35;
            }
        }
    }
}

/* Subcommand 3: progress <state_file>
 * State file format (3 lines):
 *   <0..100 | DONE | ERROR>
 *   <Step Heading>
 *   <Detail Status Line>
 */
static int cmd_progress(struct disp_ctx *d, int argc, char **argv) {
    if (argc < 1) return 2;
    const char *state_path = argv[0];
    int cx = (int)d->width / 2;
    int card_w = 680;
    if (card_w > (int)d->width - 60) card_w = (int)d->width - 60;
    float shown_pct = 0.0f;

    for (;;) {
        char line1[64] = "0", step[160] = "Preparing FideBookOS installation...", detail[160] = "";
        FILE *f = fopen(state_path, "r");
        if (f) {
            if (fgets(line1, sizeof(line1), f)) line1[strcspn(line1, "\r\n")] = 0;
            if (fgets(step, sizeof(step), f))   step[strcspn(step, "\r\n")] = 0;
            if (fgets(detail, sizeof(detail), f)) detail[strcspn(detail, "\r\n")] = 0;
            fclose(f);
        }
        if (strcmp(line1, "DONE") == 0) return 0;
        if (strcmp(line1, "ERROR") == 0) return 1;

        float target = (float)atoi(line1) / 100.0f;
        if (target < 0.0f) target = 0.0f;
        if (target > 1.0f) target = 1.0f;
        shown_pct += (target - shown_pct) * 0.22f;
        if (target > shown_pct && target - shown_pct < 0.005f) shown_pct = target;

        draw_header(d, "Installing FideBookOS", "Do not power off or unplug your laptop");
        int y0 = (int)d->height / 11 + 178;
        int x0 = cx - card_w / 2;

        stroke_round_rect(d, x0, y0, card_w, 178, 14, 1, 0x1E293B, 0x0E1422);
        char pct_str[16];
        snprintf(pct_str, sizeof(pct_str), "%d%%", (int)(shown_pct * 100.0f + 0.5f));
        draw_text(d, x0 + 30, y0 + 30, step, 1, 0xF8FAFC);
        draw_text(d, x0 + card_w - 30 - text_width(pct_str, 1), y0 + 30, pct_str, 1, 0x60A5FA);

        fill_round_rect(d, x0 + 30, y0 + 68, card_w - 60, 14, 7, 0x1A2336);
        fill_google_gradient_bar(d, x0 + 30, y0 + 68, card_w - 60, 14, shown_pct > 0.02f ? shown_pct : 0.02f);

        if (detail[0])
            draw_text(d, x0 + 30, y0 + 108, detail, 1, 0x94A3B8);
        draw_text(d, x0 + 30, y0 + 136, "FideBookOS 1.25  •  Liquid Glass + Vulkan 1.4 + Wi-Fi/BT Ready", 1, 0x475569);

        disp_present(d);
        usleep(40000);
    }
}

/* Subcommand 4: message <done|error> <title> <line1> <line2> <button_text> */
static int cmd_message(struct disp_ctx *d, int argc, char **argv) {
    if (argc < 5) return 2;
    int is_err = (strcmp(argv[0], "error") == 0);
    const char *title = argv[1];
    const char *line1 = argv[2];
    const char *line2 = argv[3];
    const char *btn = argv[4];
    int cx = (int)d->width / 2;
    int card_w = 640;
    if (card_w > (int)d->width - 60) card_w = (int)d->width - 60;

    struct ui_event flush_ev;
    input_poll(d, 80, &flush_ev);

    for (;;) {
        draw_header(d, title, is_err ? "Action could not be completed" : "FideBookOS is ready to boot");
        int y0 = (int)d->height / 11 + 176;
        int x0 = cx - card_w / 2;
        uint32_t accent = is_err ? 0xEA4335 : 0x34A853;

        stroke_round_rect(d, x0, y0, card_w, 168, 14, 2, accent, 0x0E1422);
        draw_text_center(d, cx, y0 + 34, line1, 1, 0xF8FAFC);
        draw_text_center(d, cx, y0 + 64, line2, 1, 0x94A3B8);

        int btn_y = y0 + 104;
        fill_round_rect(d, cx - 120, btn_y, 240, 42, 10, accent);
        draw_text_center(d, cx, btn_y + 13, btn, 1, 0xFFFFFF);

        draw_cursor(d);
        disp_present(d);

        struct ui_event ev;
        input_poll(d, 33, &ev);
        if (ev.key == KEY_ENTER || ev.key == KEY_KPENTER || ev.key == KEY_ESC)
            return 0;
        if (ev.clicked && g_mouse_x >= cx - 120 && g_mouse_x < cx + 120 &&
            g_mouse_y >= btn_y && g_mouse_y < btn_y + 42)
            return 0;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    struct disp_ctx d;
    if (disp_open(&d) != 0)
        return 2; /* Fallback to text UI cleanly */

    input_open_all(&d);
    int rc = 2;
    const char *cmd = argv[1];
    if (strcmp(cmd, "menu") == 0)
        rc = cmd_menu(&d, argc - 2, argv + 2);
    else if (strcmp(cmd, "serial") == 0)
        rc = cmd_serial(&d, argc - 2, argv + 2);
    else if (strcmp(cmd, "progress") == 0)
        rc = cmd_progress(&d, argc - 2, argv + 2);
    else if (strcmp(cmd, "message") == 0)
        rc = cmd_message(&d, argc - 2, argv + 2);

    input_close_all();
    disp_close(&d);
    return rc;
}
