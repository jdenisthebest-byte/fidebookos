#!/usr/bin/env python3
"""Generate FideBookOS 1.25 visual branding assets, 60 FPS motion-blur bootanimation.zip,
embedded C RGBA logo header for the graphical installer, and signed Android RRO overlay APKs:
  1. Static branding RROs (isStatic=true, priority=9999):
       - FideBookLauncherOverlay.apk (replaces Dock Google "G" with 4-color Google-gradient "F")
       - FideBookSettingsOverlay.apk (replaces Settings About/Google emblems across all DPIs & sw600dp)
  2. Live-toggleable Liquid Glass RROs (mutable isStatic=false, priority=9999):
       - FideBookGlassFrameworkOverlay.apk (Control Center & Shade glass panel carrier + GPU blur unlock)
       - FideBookGlassLauncherOverlay.apk  (Taskbar & App Menu Liquid Glass carrier + crystal rim stroke)
       - FideBookGlassSystemUIOverlay.apk  (Control Center blurred shade + 26dp rounded glass radii)

Note: Uses a transient ephemeral signing key in /tmp during APK packaging so no private keys
are ever stored in the repository.
"""
import base64
import hashlib
import io
import math
import os
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "usb" / "branding"
OVERLAY_DIR = OUT_DIR / "overlays"

SRC_LOGO_CANDIDATES = [
    OUT_DIR / "fidebookos-logo-source.png",
]
SRC_WALL_CANDIDATES = [
    OUT_DIR / "wallpaper.jpg",
]


def load_or_draw_google_f(size=512):
    """Extract clean transparent RGBA Google-gradient 'F' icon from generated artwork
    (or render high-precision vector fallback if building on another machine)."""
    src_img = None
    chosen_p = None
    for p in SRC_LOGO_CANDIDATES:
        if p.exists():
            src_img = Image.open(p).convert("RGB")
            chosen_p = p
            break

    if src_img is not None:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        if chosen_p != OUT_DIR / "fidebookos-logo-source.png":
            src_img.resize((512, 512), Image.Resampling.LANCZOS).save(OUT_DIR / "fidebookos-logo-source.png")
        im = src_img.resize((size * 2, size * 2), Image.Resampling.LANCZOS)
        px = im.load()
        w, h = im.size
        bg_r, bg_g, bg_b = px[8, 8]
        alpha = Image.new("L", (w, h), 0)
        apx = alpha.load()
        rgb_out = Image.new("RGB", (w, h), (0, 0, 0))
        opx = rgb_out.load()
        for y in range(h):
            for x in range(w):
                r, g, b = px[x, y]
                dist = max(abs(r - bg_r), abs(g - bg_g), abs(b - bg_b))
                if dist <= 18:
                    a = 0
                elif dist >= 46:
                    a = 255
                else:
                    a = int((dist - 18) * 255 / 28)
                apx[x, y] = a
                if a > 0:
                    scale = 255.0 / max(a, 64)
                    nr = min(255, max(0, int((r - bg_r * (1.0 - a / 255.0)) * min(scale, 1.35))))
                    ng = min(255, max(0, int((g - bg_g * (1.0 - a / 255.0)) * min(scale, 1.35))))
                    nb = min(255, max(0, int((b - bg_b * (1.0 - a / 255.0)) * min(scale, 1.35))))
                    opx[x, y] = (nr, ng, nb)
        alpha = alpha.filter(ImageFilter.GaussianBlur(radius=1.0))
        rgba = Image.merge("RGBA", (*rgb_out.split(), alpha))
        bbox = rgba.getbbox()
        if bbox:
            cropped = rgba.crop(bbox)
            cw, ch = cropped.size
            target_h = int(size * 0.82)
            target_w = max(1, int(cw * (target_h / ch)))
            cropped = cropped.resize((target_w, target_h), Image.Resampling.LANCZOS)
            canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            canvas.paste(cropped, ((size - target_w) // 2, (size - target_h) // 2), cropped)
            return canvas

    ss = size * 4
    mask = Image.new("L", (ss, ss), 0)
    md = ImageDraw.Draw(mask)
    rx0, ry0 = int(ss * 0.25), int(ss * 0.14)
    stem_w = int(ss * 0.17)
    bar_h = int(ss * 0.16)
    rad = int(ss * 0.06)
    md.rounded_rectangle([rx0, ry0, rx0 + stem_w, int(ss * 0.86)], radius=rad, fill=255)
    md.rounded_rectangle([rx0, ry0, int(ss * 0.77), ry0 + bar_h], radius=rad, fill=255)
    mid_y = int(ss * 0.45)
    md.rounded_rectangle([rx0, mid_y, int(ss * 0.68), mid_y + bar_h], radius=rad, fill=255)
    grad = Image.new("RGB", (ss, ss))
    gd = ImageDraw.Draw(grad)
    gd.rectangle([0, 0, ss // 2, ss // 2], fill=(66, 133, 244))
    gd.rectangle([ss // 2, 0, ss, ss // 2], fill=(234, 67, 53))
    gd.rectangle([ss // 2, ss // 2, ss, ss], fill=(251, 188, 5))
    gd.rectangle([0, ss // 2, ss // 2, ss], fill=(52, 168, 83))
    grad = grad.filter(ImageFilter.GaussianBlur(radius=ss * 0.18))
    out = Image.merge("RGBA", (*grad.split(), mask))
    return out.resize((size, size), Image.Resampling.LANCZOS)


def pick_font(size, bold=False):
    candidates = [
        "/usr/share/fonts/google-noto/NotoSans-SemiBold.ttf" if bold else "/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/google-noto/NotoSans-Bold.ttf",
        "/usr/share/fonts/google-noto/NotoSans-Medium.ttf",
        "/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/abattis-cantarell-fonts/Cantarell-VF.otf",
    ]
    for c in candidates:
        if os.path.exists(c):
            return ImageFont.truetype(c, size)
    return ImageFont.load_default()


def directional_motion_blur(img, dx, dy, samples=9):
    """Apply smooth directional velocity motion blur along vector (dx, dy)."""
    if abs(dx) < 0.8 and abs(dy) < 0.8:
        return img
    acc = None
    weight_sum = 0.0
    for i in range(samples):
        t = (i / (samples - 1)) - 0.5
        ox = int(round(dx * t))
        oy = int(round(dy * t))
        shifted = ImageChops.offset(img, ox, oy)
        d = ImageDraw.Draw(shifted)
        w, h = shifted.size
        if ox > 0:
            d.rectangle([0, 0, ox, h], fill=(0, 0, 0, 0))
        elif ox < 0:
            d.rectangle([w + ox, 0, w, h], fill=(0, 0, 0, 0))
        if oy > 0:
            d.rectangle([0, 0, w, oy], fill=(0, 0, 0, 0))
        elif oy < 0:
            d.rectangle([0, h + oy, w, h], fill=(0, 0, 0, 0))
        w_i = 1.0 - 0.55 * abs(t * 2.0)
        if acc is None:
            acc = shifted.copy()
            weight_sum = w_i
        else:
            alpha = w_i / (weight_sum + w_i)
            acc = Image.blend(acc, shifted, alpha)
            weight_sum += w_i
    return acc


def build_bootanimation(logo_rgba, out_zip):
    """Render 1920x1080 @ 60 FPS motion-blur bootanimation.zip (STORE uncompressed)."""
    W, H = 1920, 1080
    BG = (7, 9, 15)
    logo_sz = 236
    logo = logo_rgba.resize((logo_sz, logo_sz), Image.Resampling.LANCZOS)
    aura_base = logo.resize((360, 360), Image.Resampling.BILINEAR).filter(ImageFilter.GaussianBlur(radius=52))

    font_brand = pick_font(54, bold=True)
    word_layer = Image.new("RGBA", (640, 96), (0, 0, 0, 0))
    wd = ImageDraw.Draw(word_layer)
    txt = "FideBookOS"
    tb = wd.textbbox((0, 0), txt, font=font_brand)
    tw, th = tb[2] - tb[0], tb[3] - tb[1]
    tx = (640 - tw) // 2
    ty = (96 - th) // 2 - tb[1]
    prefix = "FideBook"
    suffix = "OS"
    pb = wd.textbbox((0, 0), prefix, font=font_brand)
    pw = pb[2] - pb[0]
    wd.text((tx, ty), prefix, font=font_brand, fill=(244, 247, 255, 255))
    wd.text((tx + pw + 2, ty), suffix, font=font_brand, fill=(108, 168, 255, 255))

    cx, cy = W // 2, H // 2 - 42
    word_y = cy + logo_sz // 2 + 28

    streaks = [
        ((-520, -240), (66, 133, 244)),
        ((520, -220),  (234, 67, 53)),
        ((480, 220),   (251, 188, 5)),
        ((-480, 240),  (52, 168, 83)),
    ]

    frames_part0 = []
    N0 = 60
    for i in range(N0):
        u = i / (N0 - 1)
        frame = Image.new("RGB", (W, H), BG)
        if u < 0.68:
            su = min(1.0, u / 0.56)
            ease = 1.0 - pow(1.0 - su, 3.2)
            vel = max(0.0, (1.0 - su) * 95.0)
            streak_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            sd = ImageDraw.Draw(streak_layer)
            fade = int(235 * math.sin(min(1.0, u / 0.68) * math.pi))
            for (sx, sy), col in streaks:
                px_pos = int(cx + sx * (1.0 - ease))
                py_pos = int(cy + sy * (1.0 - ease))
                r = int(38 - 14 * ease)
                sd.ellipse([px_pos - r, py_pos - r, px_pos + r, py_pos + r], fill=(*col, fade))
            streak_layer = streak_layer.filter(ImageFilter.GaussianBlur(radius=14))
            streak_layer = directional_motion_blur(streak_layer, vel, vel * 0.42, samples=7)
            frame.paste(streak_layer, (0, 0), streak_layer)

        if u >= 0.22:
            lu = min(1.0, (u - 0.22) / 0.58)
            spring = 1.0 - math.exp(-5.5 * lu) * math.cos(5.2 * lu)
            sc = max(0.25, min(1.12, 0.55 + 0.45 * spring))
            lw = int(logo_sz * sc)
            lh = int(logo_sz * sc)
            cur_logo = logo.resize((lw, lh), Image.Resampling.LANCZOS)
            l_alpha = min(1.0, (u - 0.22) / 0.28)
            if l_alpha < 1.0:
                a = cur_logo.getchannel("A").point(lambda v, f=l_alpha: int(v * f))
                cur_logo.putalpha(a)
            blur_amt = max(0.0, (1.0 - lu) * 44.0)
            if blur_amt > 1.5:
                pad = 80
                tmp = Image.new("RGBA", (lw + pad * 2, lh + pad * 2), (0, 0, 0, 0))
                tmp.paste(cur_logo, (pad, pad), cur_logo)
                tmp = directional_motion_blur(tmp, blur_amt, 0.0, samples=7)
                frame.paste(tmp, (cx - lw // 2 - pad, cy - lh // 2 - pad), tmp)
            else:
                aura_op = min(0.58, lu * 0.58)
                aura_cur = aura_base.copy()
                aura_cur.putalpha(aura_cur.getchannel("A").point(lambda v, f=aura_op: int(v * f)))
                frame.paste(aura_cur, (cx - 180, cy - 180), aura_cur)
                frame.paste(cur_logo, (cx - lw // 2, cy - lh // 2), cur_logo)

        if u >= 0.42:
            wu = min(1.0, (u - 0.42) / 0.52)
            wease = 1.0 - pow(1.0 - wu, 3.0)
            wx_off = int((1.0 - wease) * 76)
            wblur = (1.0 - wease) * 42.0
            wl = word_layer.copy()
            wl.putalpha(wl.getchannel("A").point(lambda v, f=wease: int(v * f)))
            if wblur > 1.2:
                wl = directional_motion_blur(wl, wblur, 0.0, samples=7)
            frame.paste(wl, (cx - 320 + wx_off, word_y), wl)

        buf = io.BytesIO()
        frame.save(buf, format="PNG", compress_level=1)
        frames_part0.append(buf.getvalue())

    frames_part1 = []
    N1 = 60
    for i in range(N1):
        phase = (2.0 * math.pi * i) / N1
        frame = Image.new("RGB", (W, H), BG)
        aura_op = 0.50 + 0.16 * math.sin(phase)
        aura_cur = aura_base.copy()
        aura_cur.putalpha(aura_cur.getchannel("A").point(lambda v, f=aura_op: int(v * f)))
        frame.paste(aura_cur, (cx - 180, cy - 180), aura_cur)
        frame.paste(logo, (cx - logo_sz // 2, cy - logo_sz // 2), logo)
        frame.paste(word_layer, (cx - 320, word_y), word_layer)

        bar_w, bar_h = 180, 4
        bx0 = cx - bar_w // 2
        by0 = word_y + 84
        pill = Image.new("RGBA", (bar_w + 80, 32), (0, 0, 0, 0))
        pd = ImageDraw.Draw(pill)
        pd.rounded_rectangle([40, 14, 40 + bar_w, 14 + bar_h], radius=2, fill=(38, 46, 68, 220))
        comet_x = 40 + int((bar_w - 48) * (0.5 + 0.5 * math.sin(phase)))
        cols = [(66, 133, 244), (234, 67, 53), (251, 188, 5), (52, 168, 83)]
        cidx = (i * 4 // N1) % 4
        ncidx = (cidx + 1) % 4
        frac = ((i * 4) % N1) / N1
        cc = tuple(int(cols[cidx][k] * (1 - frac) + cols[ncidx][k] * frac) for k in range(3))
        comet = Image.new("RGBA", (bar_w + 80, 32), (0, 0, 0, 0))
        cd = ImageDraw.Draw(comet)
        cd.rounded_rectangle([comet_x, 13, comet_x + 48, 19], radius=3, fill=(*cc, 255))
        vel_x = math.cos(phase) * 24.0
        comet = directional_motion_blur(comet, vel_x, 0.0, samples=7)
        pill = Image.alpha_composite(pill, comet)
        frame.paste(pill, (bx0 - 40, by0 - 14), pill)

        buf = io.BytesIO()
        frame.save(buf, format="PNG", compress_level=1)
        frames_part1.append(buf.getvalue())

    with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_STORED) as zf:
        zf.writestr("desc.txt", "1920 1080 60\np 1 0 part0\np 0 0 part1\n")
        for idx, data in enumerate(frames_part0):
            zf.writestr(f"part0/{idx:04d}.png", data)
        for idx, data in enumerate(frames_part1):
            zf.writestr(f"part1/{idx:04d}.png", data)


def write_c_logo_header(logo_rgba, out_h):
    """Export 72x72 RGBA array for the static graphical installer (fidebook-gui)."""
    im = logo_rgba.resize((72, 72), Image.Resampling.LANCZOS)
    raw = im.tobytes()
    lines = [
        "/* Auto-generated by tools/build_fidebook_branding.py: 72x72 RGBA Google-gradient 'F' emblem */",
        "#ifndef FIDEBOOK_LOGO_RGBA_H",
        "#define FIDEBOOK_LOGO_RGBA_H",
        "#include <stdint.h>",
        "#define FIDEBOOK_LOGO_W 72",
        "#define FIDEBOOK_LOGO_H 72",
        "static const uint8_t fidebook_logo_rgba[72 * 72 * 4] = {",
    ]
    for i in range(0, len(raw), 24):
        chunk = ", ".join(f"0x{b:02x}" for b in raw[i:i + 24])
        lines.append(f"    {chunk},")
    lines += ["};", "#endif"]
    out_h.write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# Binary AXML + Multi-Type/Multi-Config resources.arsc + APK v2/v1 Signer
# ---------------------------------------------------------------------------

TYPE_STRING = 0x03
TYPE_FLOAT = 0x04
TYPE_DIMENSION = 0x05
TYPE_INT_DEC = 0x10
TYPE_BOOL = 0x12
TYPE_COLOR_ARGB8 = 0x1C

CONFIG_DENSITY = 0x0100
CONFIG_UI_MODE = 0x0200
CONFIG_VERSION = 0x0400
CONFIG_SMALLEST_SCREEN_SIZE = 0x0800


def encode_utf16_string_pool(strings):
    """Build a valid Android ResStringPool (UTF-16LE, RES_STRING_POOL_TYPE = 0x0001)."""
    blobs = []
    offsets = []
    cur = 0
    for s in strings:
        u16 = s.encode("utf-16le")
        char_len = len(s)
        b = struct.pack("<H", char_len) + u16 + b"\x00\x00"
        offsets.append(cur)
        blobs.append(b)
        cur += len(b)
    str_data = b"".join(blobs)
    while len(str_data) % 4 != 0:
        str_data += b"\x00"
    hdr_size = 28
    strings_start = hdr_size + 4 * len(strings)
    total_size = strings_start + len(str_data)
    hdr = struct.pack(
        "<HHIIIIII",
        0x0001,
        hdr_size,
        total_size,
        len(strings),
        0,
        0,
        strings_start,
        0,
    )
    return hdr + b"".join(struct.pack("<I", o) for o in offsets) + str_data


def make_res_config(density=0, sdk=0, ui_mode=0, sw_dp=0):
    """Build exact 64-byte Android ResTable_config matching AOSP ResourceTypes.h offsets:
      - size:                   offset 0  (uint32 = 64)
      - density:                offset 14 (uint16: 0=default, 160..480=mdpi..xxhdpi, 0xFFFE=anydpi)
      - sdkVersion:             offset 24 (uint16)
      - uiMode:                 offset 29 (uint8:  0x00=default, 0x20=UI_MODE_NIGHT_YES)
      - smallestScreenWidthDp:  offset 30 (uint16: e.g. 600 for sw600dp)
    """
    cfg = bytearray(64)
    struct.pack_into("<I", cfg, 0, 64)
    struct.pack_into("<H", cfg, 14, density & 0xFFFF)
    struct.pack_into("<H", cfg, 24, sdk & 0xFFFF)
    cfg[29] = ui_mode & 0xFF
    struct.pack_into("<H", cfg, 30, sw_dp & 0xFFFF)
    return bytes(cfg)


def val_bool(v):
    return (TYPE_BOOL, 0xFFFFFFFF if v else 0)


def val_color(argb_u32):
    return (TYPE_COLOR_ARGB8, argb_u32 & 0xFFFFFFFF)


def val_dp(dp_float):
    """Encode dimension in COMPLEX_UNIT_DIP (1)."""
    if abs(dp_float - round(dp_float)) < 1e-4:
        # COMPLEX_RADIX_23p0 = 0
        return (TYPE_DIMENSION, ((int(round(dp_float)) & 0xFFFFFF) << 8) | 0x01)
    # COMPLEX_RADIX_16p7 = 1 (scale by 128)
    mant = int(round(dp_float * 128.0)) & 0xFFFFFF
    return (TYPE_DIMENSION, (mant << 8) | (1 << 4) | 0x01)


def val_file(rel_path):
    return (TYPE_STRING, rel_path)


def build_rro_manifest_axml(package_name, target_package, label, priority=9999, is_static=True):
    """Build binary AndroidManifest.xml for static or live-toggleable RRO overlays."""
    ANDROID_NS = "http://schemas.android.com/apk/res/android"
    attr_defs = [
        ("label", 0x01010001),
        ("hasCode", 0x0101000c),
        ("priority", 0x0101001c),
        ("targetPackage", 0x01010021),
        ("minSdkVersion", 0x0101020c),
        ("versionCode", 0x0101021b),
        ("versionName", 0x0101021c),
        ("targetSdkVersion", 0x01010270),
        ("isStatic", 0x0101055a),
    ]
    strings = [name for name, _ in attr_defs] + [
        ANDROID_NS,
        "android",
        "manifest",
        "package",
        package_name,
        "1.25",
        "uses-sdk",
        "overlay",
        "application",
        label,
        target_package,
    ]
    idx = {s: i for i, s in enumerate(strings)}
    spool = encode_utf16_string_pool(strings)

    res_ids = [rid for _, rid in attr_defs]
    res_map = struct.pack("<HHI", 0x0180, 8, 8 + 4 * len(res_ids)) + b"".join(
        struct.pack("<I", r) for r in res_ids
    )

    def ns_start(prefix, uri, line=1):
        return struct.pack("<HHIIII", 0x0100, 16, 24, line, 0xFFFFFFFF, idx[prefix]) + struct.pack("<I", idx[uri])

    def ns_end(prefix, uri, line=1):
        return struct.pack("<HHIIII", 0x0101, 16, 24, line, 0xFFFFFFFF, idx[prefix]) + struct.pack("<I", idx[uri])

    def start_elem(name, attrs, line=1):
        body = b""
        for ans, aname, raw, dtype, dval in attrs:
            ns_i = idx[ans] if ans is not None else -1
            nm_i = idx[aname]
            rw_i = idx[raw] if raw is not None else -1
            body += struct.pack("<iiiHBBI", ns_i, nm_i, rw_i, 8, 0, dtype, dval & 0xFFFFFFFF)
        total = 36 + len(body)
        hdr = struct.pack(
            "<HHIIIiiHHHHHH",
            0x0102, 16, total, line, 0xFFFFFFFF,
            -1, idx[name], 0x14, 0x14, len(attrs), 0, 0, 0,
        )
        return hdr + body

    def end_elem(name, line=1):
        return struct.pack("<HHIIIii", 0x0103, 16, 24, line, 0xFFFFFFFF, -1, idx[name])

    overlay_attrs = [
        (ANDROID_NS, "priority", None, TYPE_INT_DEC, priority),
        (ANDROID_NS, "targetPackage", target_package, TYPE_STRING, idx[target_package]),
    ]
    if is_static:
        overlay_attrs.append((ANDROID_NS, "isStatic", None, TYPE_BOOL, 0xFFFFFFFF))

    chunks = [
        spool,
        res_map,
        ns_start("android", ANDROID_NS, 2),
        start_elem(
            "manifest",
            [
                (ANDROID_NS, "versionCode", None, TYPE_INT_DEC, 125),
                (ANDROID_NS, "versionName", "1.25", TYPE_STRING, idx["1.25"]),
                (None, "package", package_name, TYPE_STRING, idx[package_name]),
            ],
            2,
        ),
        start_elem(
            "uses-sdk",
            [
                (ANDROID_NS, "minSdkVersion", None, TYPE_INT_DEC, 34),
                (ANDROID_NS, "targetSdkVersion", None, TYPE_INT_DEC, 37),
            ],
            3,
        ),
        end_elem("uses-sdk", 3),
        start_elem("overlay", overlay_attrs, 4),
        end_elem("overlay", 4),
        start_elem(
            "application",
            [
                (ANDROID_NS, "label", label, TYPE_STRING, idx[label]),
                (ANDROID_NS, "hasCode", None, TYPE_BOOL, 0),
            ],
            5,
        ),
        end_elem("application", 5),
        end_elem("manifest", 6),
        ns_end("android", ANDROID_NS, 6),
    ]
    payload = b"".join(chunks)
    return struct.pack("<HHI", 0x0003, 8, 8 + len(payload)) + payload


def build_general_arsc(package_name, type_defs):
    """Build uncompressed multi-type, multi-config Android ResTable (resources.arsc).
    type_defs: list of (type_name, key_names, spec_flags, [(cfg_bytes, {key: (dtype, val_or_str)}), ...])
    """
    global_strings = []
    g_idx = {}

    def intern_global(s):
        if s not in g_idx:
            g_idx[s] = len(global_strings)
            global_strings.append(s)
        return g_idx[s]

    type_names = [tname for tname, _, _, _ in type_defs]
    all_keys = []
    key_idx = {}
    for _, knames, _, cfgs in type_defs:
        for k in knames:
            if k not in key_idx:
                key_idx[k] = len(all_keys)
                all_keys.append(k)
        for _, kv in cfgs:
            for _, (dt, dv) in kv.items():
                if dt == TYPE_STRING:
                    intern_global(dv)

    g_pool = encode_utf16_string_pool(global_strings)
    type_pool = encode_utf16_string_pool(type_names)
    key_pool = encode_utf16_string_pool(all_keys)

    type_chunks = []
    for t_zero_idx, (_, knames, spec_flags, cfgs) in enumerate(type_defs):
        tid = t_zero_idx + 1
        n = len(knames)
        typespec = (
            struct.pack("<HHIBBH", 0x0202, 16, 16 + 4 * n, tid, 0, 0)
            + struct.pack("<I", n)
            + (struct.pack("<I", spec_flags) * n)
        )
        type_chunks.append(typespec)

        for cfg_bytes, kv in cfgs:
            assert len(cfg_bytes) == 64
            type_hdr_sz = 20 + 64
            entries_start = type_hdr_sz + 4 * n
            entry_blobs = []
            entry_offsets = []
            cur = 0
            for k in knames:
                if k not in kv:
                    entry_offsets.append(0xFFFFFFFF)
                    continue
                dt, dv = kv[k]
                raw_val = g_idx[dv] if dt == TYPE_STRING else (dv & 0xFFFFFFFF)
                entry_offsets.append(cur)
                eb = struct.pack("<HHI", 8, 0, key_idx[k]) + struct.pack("<HBBI", 8, 0, dt, raw_val)
                entry_blobs.append(eb)
                cur += len(eb)
            type_total = entries_start + cur
            tchunk = (
                struct.pack("<HHIBBHII", 0x0201, type_hdr_sz, type_total, tid, 0, 0, n, entries_start)
                + cfg_bytes
                + b"".join(struct.pack("<I", o) for o in entry_offsets)
                + b"".join(entry_blobs)
            )
            type_chunks.append(tchunk)

    pkg_hdr_sz = 288
    pkg_name_u16 = package_name.encode("utf-16le")[:254].ljust(256, b"\x00")
    type_strs_off = pkg_hdr_sz
    key_strs_off = type_strs_off + len(type_pool)
    pkg_body = type_pool + key_pool + b"".join(type_chunks)
    pkg_total = pkg_hdr_sz + len(pkg_body)
    pkg_hdr = (
        struct.pack("<HHI", 0x0200, pkg_hdr_sz, pkg_total)
        + struct.pack("<I", 0x7F)
        + pkg_name_u16
        + struct.pack("<IIIII", type_strs_off, len(type_names), key_strs_off, len(all_keys), 0)
    )
    pkg_chunk = pkg_hdr + pkg_body
    table_total = 12 + len(g_pool) + len(pkg_chunk)
    return struct.pack("<HHII", 0x0002, 12, table_total, 1) + g_pool + pkg_chunk


def merkle_sha256_apk_v2(sections):
    """Compute Android APK Signature Scheme v2 SHA-256 content digest over 1 MiB chunks."""
    CHUNK_SZ = 1024 * 1024
    chunk_digests = []
    for sec in sections:
        pos = 0
        n = len(sec)
        while pos < n:
            part = sec[pos:pos + CHUNK_SZ]
            h = hashlib.sha256()
            h.update(b"\xa5")
            h.update(struct.pack("<I", len(part)))
            h.update(part)
            chunk_digests.append(h.digest())
            pos += CHUNK_SZ
    top = hashlib.sha256()
    top.update(b"\x5a")
    top.update(struct.pack("<I", len(chunk_digests)))
    for d in chunk_digests:
        top.update(d)
    return top.digest()


def lp_bytes(b):
    return struct.pack("<I", len(b)) + b


def sign_apk_v1_and_v2(entries, out_apk, key_pem, cert_der, cert_pem):
    """Package aligned ZIP (with 4-byte aligned uncompressed resources.arsc), sign with v1 + APK Signature Scheme v2."""
    mf_lines = ["Manifest-Version: 1.0", "Created-By: FideBookOS Builder 1.25", ""]
    sf_body_blocks = []
    for name, data, _ in entries:
        d_b64 = base64.b64encode(hashlib.sha256(data).digest()).decode()
        block = f"Name: {name}\r\nSHA-256-Digest: {d_b64}\r\n\r\n"
        mf_lines.append(block.rstrip("\r\n"))
        mf_lines.append("")
        sf_d = base64.b64encode(hashlib.sha256(block.encode()).digest()).decode()
        sf_body_blocks.append(f"Name: {name}\r\nSHA-256-Digest: {sf_d}\r\n\r\n")
    manifest_mf = ("\r\n".join(mf_lines).rstrip("\r\n") + "\r\n\r\n").encode()
    mf_main_d = base64.b64encode(hashlib.sha256(manifest_mf).digest()).decode()
    cert_sf = (
        f"Signature-Version: 1.0\r\nCreated-By: FideBookOS Builder 1.25\r\nSHA-256-Digest-Manifest: {mf_main_d}\r\n\r\n"
        + "".join(sf_body_blocks)
    ).encode()
    cert_rsa = subprocess.check_output(
        [
            "openssl", "cms", "-sign", "-binary", "-noattr", "-outform", "DER",
            "-md", "sha256", "-signer", str(cert_pem), "-inkey", str(key_pem),
        ],
        input=cert_sf,
    )

    all_entries = list(entries) + [
        ("META-INF/MANIFEST.MF", manifest_mf, zipfile.ZIP_DEFLATED),
        ("META-INF/CERT.SF", cert_sf, zipfile.ZIP_DEFLATED),
        ("META-INF/CERT.RSA", cert_rsa, zipfile.ZIP_DEFLATED),
    ]

    raw_buf = io.BytesIO()
    with zipfile.ZipFile(raw_buf, "w") as zf:
        for name, data, comp in all_entries:
            zi = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = comp
            zi.create_system = 3
            zi.external_attr = 0o644 << 16
            if comp == zipfile.ZIP_STORED:
                cur_off = raw_buf.tell()
                header_len = 30 + len(name.encode("utf-8"))
                pad = (4 - ((cur_off + header_len) % 4)) % 4
                zi.extra = b"\x00" * pad
            zf.writestr(zi, data)
    zip_bytes = raw_buf.getvalue()

    with zipfile.ZipFile(io.BytesIO(zip_bytes), "r") as zcheck:
        for zi in zcheck.infolist():
            if zi.filename == "resources.arsc":
                data_off = zi.header_offset + 30 + len(zi.filename.encode()) + len(zi.extra)
                assert data_off % 4 == 0, f"resources.arsc unaligned: {data_off}"

    eocd_off = zip_bytes.rfind(b"PK\x05\x06")
    assert eocd_off > 0
    cd_size, cd_off = struct.unpack_from("<II", zip_bytes, eocd_off + 12)
    before_cd = zip_bytes[:cd_off]
    cd_bytes = zip_bytes[cd_off:eocd_off]
    eocd_bytes = bytearray(zip_bytes[eocd_off:])
    struct.pack_into("<I", eocd_bytes, 16, cd_off)

    content_digest = merkle_sha256_apk_v2([before_cd, cd_bytes, bytes(eocd_bytes)])
    digests_seq = lp_bytes(lp_bytes(struct.pack("<I", 0x0103) + lp_bytes(content_digest)))
    certs_seq = lp_bytes(lp_bytes(cert_der))
    additional_attrs = lp_bytes(b"")
    signed_data = digests_seq + certs_seq + additional_attrs

    sig_bytes = subprocess.check_output(
        ["openssl", "dgst", "-sha256", "-sign", str(key_pem)],
        input=signed_data,
    )
    pub_der = subprocess.check_output(
        ["openssl", "pkey", "-in", str(key_pem), "-pubout", "-outform", "DER"]
    )
    signatures_seq = lp_bytes(lp_bytes(struct.pack("<I", 0x0103) + lp_bytes(sig_bytes)))
    signer = lp_bytes(lp_bytes(signed_data) + signatures_seq + lp_bytes(pub_der))
    v2_value = lp_bytes(signer)
    pair = struct.pack("<QI", 4 + len(v2_value), 0x7109871A) + v2_value
    pad_need = (8 - (len(pair) % 8)) % 8
    if pad_need:
        pad_val_len = (8 - (12 % 8) + pad_need) % 8
        pair += struct.pack("<QI", 4 + pad_val_len, 0x42726577) + (b"\x00" * pad_val_len)

    block_size_field = len(pair) + 8 + 16
    apk_sig_block = (
        struct.pack("<Q", block_size_field)
        + pair
        + struct.pack("<Q", block_size_field)
        + b"APK Sig Block 42"
    )
    assert len(apk_sig_block) % 8 == 0

    new_cd_off = cd_off + len(apk_sig_block)
    final_eocd = bytearray(zip_bytes[eocd_off:])
    struct.pack_into("<I", final_eocd, 16, new_cd_off)
    out_apk.write_bytes(before_cd + apk_sig_block + cd_bytes + bytes(final_eocd))


def png_bytes_of(im):
    b = io.BytesIO()
    im.save(b, format="PNG", optimize=True)
    return b.getvalue()


def make_scaled_f_png(logo_rgba, dp_box, dp_glyph, scale):
    """Render crisp Google-gradient 'F' PNG at exact pixel dimensions for an explicit numeric DPI scale."""
    box_px = max(16, int(round(dp_box * scale)))
    glyph_px = max(12, int(round(dp_glyph * scale)))
    g = logo_rgba.resize((glyph_px, glyph_px), Image.Resampling.LANCZOS)
    if box_px == glyph_px:
        return png_bytes_of(g)
    canvas = Image.new("RGBA", (box_px, box_px), (0, 0, 0, 0))
    canvas.paste(g, ((box_px - glyph_px) // 2, (box_px - glyph_px) // 2), g)
    return png_bytes_of(canvas)


def build_google_f_vector_axml(dp_box=24, dp_glyph=24):
    """Build binary Android VectorDrawable XML (<vector>) for our 4-color Google-gradient 'F' emblem.
    - Uses infinite-resolution <path> arcs in Google Red (#EA4335), Yellow (#FBBC05), Green (#34A853),
      and Blue (#4285F4), centered in dp_box x dp_box.
    - Sets android:tintMode='multiply' (14) so IconButtonView's white foreground tint (#FFFFFFFF)
      multiplies by 1.0 and preserves all 4 Google colors cleanly, and NEVER triggers BitmapFactory's
      density=0xFFFE 1x1-pixel scaling bug."""
    ANDROID_NS = "http://schemas.android.com/apk/res/android"
    # Attribute resource IDs MUST be sorted in ascending order inside AXML elements!
    attr_defs = [
        ("height", 0x01010155),
        ("width", 0x01010159),
        ("tintMode", 0x01010401),
        ("viewportWidth", 0x01010402),
        ("viewportHeight", 0x01010403),
        ("fillColor", 0x01010404),
        ("pathData", 0x01010405),
    ]

    sc = dp_glyph / 24.0
    ox = (dp_box - dp_glyph) / 2.0
    oy = (dp_box - dp_glyph) / 2.0

    def tx(x):
        return f"{ox + x * sc:.2f}".rstrip("0").rstrip(".")

    def ty(y):
        return f"{oy + y * sc:.2f}".rstrip("0").rstrip(".")

    def tr(r):
        return f"{r * sc:.2f}".rstrip("0").rstrip(".")

    # 4 seamless overlapping rounded Google-Sans 'F' segments in 24x24 design space:
    #   1. Lower vertical stem  (Google Green  #34A853)
    #   2. Upper-mid stem       (Google Yellow #FBBC05)
    #   3. Middle crossbar      (Google Blue   #4285F4)
    #   4. Top bar & corner     (Google Red    #EA4335)
    p_green = (
        f"M{tx(5.6)},{ty(12.2)} H{tx(9.6)} V{ty(19.0)} "
        f"A{tr(2.0)},{tr(2.0)} 0 0 1 {tx(5.6)},{ty(19.0)} Z"
    )
    p_yellow = f"M{tx(5.6)},{ty(6.2)} H{tx(9.6)} V{ty(12.7)} H{tx(5.6)} Z"
    p_blue = (
        f"M{tx(9.2)},{ty(10.2)} H{tx(14.7)} "
        f"A{tr(1.9)},{tr(1.9)} 0 0 1 {tx(14.7)},{ty(14.0)} H{tx(9.2)} Z"
    )
    p_red = (
        f"M{tx(5.6)},{ty(6.9)} V{ty(5.2)} "
        f"A{tr(2.2)},{tr(2.2)} 0 0 1 {tx(7.8)},{ty(3.0)} H{tx(16.65)} "
        f"A{tr(1.95)},{tr(1.95)} 0 0 1 {tx(16.65)},{ty(6.9)} Z"
    )

    segments = [
        (0xFF34A853, p_green),
        (0xFFFBBC05, p_yellow),
        (0xFF4285F4, p_blue),
        (0xFFEA4335, p_red),
    ]

    strings = [name for name, _ in attr_defs] + [
        ANDROID_NS,
        "android",
        "vector",
        "path",
    ] + [pdata for _, pdata in segments]
    idx = {s: i for i, s in enumerate(strings)}
    spool = encode_utf16_string_pool(strings)
    res_map = struct.pack("<HHI", 0x0180, 8, 8 + 4 * len(attr_defs)) + b"".join(
        struct.pack("<I", rid) for _, rid in attr_defs
    )

    def ns_chunk(ctype, prefix, uri, line=1):
        return struct.pack("<HHIIII", ctype, 16, 24, line, 0xFFFFFFFF, idx[prefix]) + struct.pack("<I", idx[uri])

    def start_elem(name, attrs, line=1):
        body = b""
        for ans, aname, raw, dtype, dval in attrs:
            ns_i = idx[ans] if ans is not None else -1
            nm_i = idx[aname]
            rw_i = idx[raw] if raw is not None else -1
            body += struct.pack("<iiiHBBI", ns_i, nm_i, rw_i, 8, 0, dtype, dval & 0xFFFFFFFF)
        total = 36 + len(body)
        hdr = struct.pack(
            "<HHIIIiiHHHHHH",
            0x0102, 16, total, line, 0xFFFFFFFF,
            -1, idx[name], 0x14, 0x14, len(attrs), 0, 0, 0,
        )
        return hdr + body

    def end_elem(name, line=1):
        return struct.pack("<HHIIIii", 0x0103, 16, 24, line, 0xFFFFFFFF, -1, idx[name])

    _, dim_val = val_dp(float(dp_box))
    vp_bits, = struct.unpack("<I", struct.pack("<f", float(dp_box)))

    chunks = [
        spool,
        res_map,
        ns_chunk(0x0100, "android", ANDROID_NS, 1),
        start_elem(
            "vector",
            [
                (ANDROID_NS, "height", None, TYPE_DIMENSION, dim_val),
                (ANDROID_NS, "width", None, TYPE_DIMENSION, dim_val),
                (ANDROID_NS, "tintMode", None, TYPE_INT_DEC, 14),  # PorterDuff.Mode.MULTIPLY
                (ANDROID_NS, "viewportWidth", None, TYPE_FLOAT, vp_bits),
                (ANDROID_NS, "viewportHeight", None, TYPE_FLOAT, vp_bits),
            ],
            2,
        ),
    ]
    for ln_off, (col_argb, pdata) in enumerate(segments):
        chunks.append(
            start_elem(
                "path",
                [
                    (ANDROID_NS, "fillColor", None, TYPE_COLOR_ARGB8, col_argb),
                    (ANDROID_NS, "pathData", pdata, TYPE_STRING, idx[pdata]),
                ],
                3 + ln_off,
            )
        )
        chunks.append(end_elem("path", 3 + ln_off))
    chunks.append(end_elem("vector", 8))
    chunks.append(ns_chunk(0x0101, "android", ANDROID_NS, 8))
    payload = b"".join(chunks)
    return struct.pack("<HHI", 0x0003, 8, 8 + len(payload)) + payload


def build_multi_dpi_icon_rro(out_apk, pkg_name, target_pkg, label, icon_dp_specs, include_sw600,
                             logo_rgba, key_pem, cert_der, cert_pem, extra_colors=None):
    """Build static branding RRO APK using true <vector> XML drawables for default/anydpi-v24/sw600dp
    and explicit numeric-DPI PNGs for mdpi..xxhdpi (NEVER putting .png in density=0xFFFE)."""
    manifest_axml = build_rro_manifest_axml(pkg_name, target_pkg, label, priority=9999, is_static=True)
    zip_files = [("AndroidManifest.xml", manifest_axml, zipfile.ZIP_DEFLATED)]
    seen_paths = set()

    # kind="xml" emits infinite-DPI <vector> AXML; numeric kind emits crisp raster PNG at explicit DPI.
    buckets = [
        ("drawable",            make_res_config(density=0),              "xml"),
        ("drawable-mdpi-v4",    make_res_config(density=160, sdk=4),     1.0),
        ("drawable-hdpi-v4",    make_res_config(density=240, sdk=4),     1.5),
        ("drawable-xhdpi-v4",   make_res_config(density=320, sdk=4),     2.0),
        ("drawable-xxhdpi-v4",  make_res_config(density=480, sdk=4),     3.0),
        ("drawable-anydpi-v24", make_res_config(density=0xFFFE, sdk=24), "xml"),
    ]
    if include_sw600:
        buckets.append(("drawable-sw600dp-v13",        make_res_config(density=0, sdk=13, sw_dp=600),      "xml"))
        buckets.append(("drawable-sw600dp-anydpi-v24", make_res_config(density=0xFFFE, sdk=24, sw_dp=600), "xml"))

    key_names = [name for name, _, _ in icon_dp_specs]
    cfgs = []
    png_cache = {}
    vec_cache = {}
    for dir_tag, cfg_bytes, kind in buckets:
        kv = {}
        for name, dp_box, dp_glyph in icon_dp_specs:
            if kind == "xml":
                vk = (dp_box, dp_glyph)
                if vk not in vec_cache:
                    vec_cache[vk] = build_google_f_vector_axml(dp_box, dp_glyph)
                rel = f"res/{dir_tag}/{name}.xml"
                kv[name] = val_file(rel)
                if rel not in seen_paths:
                    seen_paths.add(rel)
                    zip_files.append((rel, vec_cache[vk], zipfile.ZIP_DEFLATED))
            else:
                ck = (dp_box, dp_glyph, kind)
                if ck not in png_cache:
                    png_cache[ck] = make_scaled_f_png(logo_rgba, dp_box, dp_glyph, kind)
                rel = f"res/{dir_tag}/{name}.png"
                kv[name] = val_file(rel)
                if rel not in seen_paths:
                    seen_paths.add(rel)
                    zip_files.append((rel, png_cache[ck], zipfile.ZIP_STORED))
        cfgs.append((cfg_bytes, kv))

    flags = CONFIG_DENSITY | CONFIG_VERSION | (CONFIG_SMALLEST_SCREEN_SIZE if include_sw600 else 0)
    type_defs = [("drawable", key_names, flags, cfgs)]
    if extra_colors:
        ckeys = list(extra_colors.keys())
        type_defs.append(("color", ckeys, 0, [(make_res_config(), {k: val_color(v) for k, v in extra_colors.items()})]))
    arsc = build_general_arsc(pkg_name, type_defs)
    zip_files.insert(0, ("resources.arsc", arsc, zipfile.ZIP_STORED))
    sign_apk_v1_and_v2(zip_files, out_apk, key_pem, cert_der, cert_pem)


def build_value_rro(out_apk, pkg_name, target_pkg, label, type_defs, is_static,
                    key_pem, cert_der, cert_pem):
    """Build value-only RRO APK (bool, color, dimen) with optional day/night configurations."""
    manifest_axml = build_rro_manifest_axml(pkg_name, target_pkg, label, priority=9999, is_static=is_static)
    arsc = build_general_arsc(pkg_name, type_defs)
    zip_files = [
        ("resources.arsc", arsc, zipfile.ZIP_STORED),
        ("AndroidManifest.xml", manifest_axml, zipfile.ZIP_DEFLATED),
    ]
    sign_apk_v1_and_v2(zip_files, out_apk, key_pem, cert_der, cert_pem)


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    OVERLAY_DIR.mkdir(parents=True, exist_ok=True)

    print("1. Extracting crisp anti-aliased Google-gradient 'F' emblem...")
    logo_rgba = load_or_draw_google_f(512)
    logo_rgba.save(OUT_DIR / "fidebookos-logo-alpha.png")
    dark_logo = Image.new("RGB", (512, 512), (7, 9, 15))
    dark_logo.paste(logo_rgba, (0, 0), logo_rgba)
    dark_logo.save(OUT_DIR / "fidebookos-logo.png")

    print("2. Exporting 72x72 C RGBA header for fidebook-gui graphical installer...")
    write_c_logo_header(logo_rgba, REPO / "tools" / "fidebook_logo_rgba.h")

    print("3. Preparing 1920x1080 FideBookOS Google-gradient silk wallpaper...")
    wall_src = None
    for wp in SRC_WALL_CANDIDATES:
        if wp.exists():
            wall_src = Image.open(wp).convert("RGB")
            break
    if wall_src is None:
        wall_src = Image.new("RGB", (1920, 1080), (7, 9, 15))
    wall_1080 = wall_src.resize((1920, 1080), Image.Resampling.LANCZOS)
    wall_1080.save(OUT_DIR / "wallpaper.jpg", format="JPEG", quality=94, subsampling=0)

    boot_zip = OUT_DIR / "bootanimation.zip"
    if "--force" in sys.argv or not boot_zip.exists() or boot_zip.stat().st_size < 100000:
        print("4. Rendering 60 FPS motion-blur bootanimation.zip (1920x1080)...")
        build_bootanimation(logo_rgba, boot_zip)
    else:
        print("4. Keeping existing 60 FPS motion-blur bootanimation.zip...")

    print("5. Building & signing static 'F' Branding RROs + live-toggleable Liquid Glass RROs...")
    cfg_default = make_res_config()
    cfg_night = make_res_config(sdk=8, ui_mode=0x20)

    with tempfile.TemporaryDirectory() as td:
        td_p = Path(td)
        key_pem = td_p / "key.pem"
        cert_pem = td_p / "cert.pem"
        cert_der = td_p / "cert.der"
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(key_pem), "-out", str(cert_pem),
                "-days", "10000", "-subj", "/CN=FideBookOS",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["openssl", "x509", "-in", str(cert_pem), "-outform", "DER", "-out", str(cert_der)],
            check=True,
        )
        c_der_bytes = cert_der.read_bytes()

        # 5a. Static Taskbar & Launcher "F" Emblem Overlay (<vector> anydpi-v24 + multi-DPI + white multiply tint)
        build_multi_dpi_icon_rro(
            OVERLAY_DIR / "FideBookLauncherOverlay.apk",
            "org.fidebookos.launcher.overlay",
            "com.google.android.apps.nexuslauncher",
            "FideBookOS 1.25 Dock & Launcher Branding",
            [
                ("ic_taskbar_all_apps_search_button_expressive_theme", 24, 24),
                ("ic_taskbar_minimal_state_all_apps_search_button_expressive_theme", 24, 24),
                ("ic_taskbar_all_apps_search_button", 44, 24),
                ("ic_super_g_color_24", 24, 24),
                ("ic_super_g_dynamic_24", 24, 24),
            ],
            False,
            logo_rgba,
            key_pem,
            c_der_bytes,
            cert_pem,
            extra_colors={"taskbar_all_apps_button_icon_tint": 0xFFFFFFFF},
        )

        # 5b. Static Settings About/Google "F" Emblem Overlay (<vector> anydpi-v24 + sw600dp + multi-DPI)
        build_multi_dpi_icon_rro(
            OVERLAY_DIR / "FideBookSettingsOverlay.apk",
            "org.fidebookos.settings.overlay",
            "com.android.settings",
            "FideBookOS 1.25 Settings Branding",
            [
                ("ic_homepage_about", 24, 24),
                ("ic_homepage_about_desktop", 24, 24),
                ("ic_settings_about_device", 24, 24),
                ("ic_settings_about_device_filled", 24, 24),
                ("ic_settings_about_device_filled_desktop", 24, 24),
                ("ic_settings_about_device_expressive", 24, 24),
                ("ic_settings_about_device_expressive_desktop", 24, 24),
                ("ic_logo_google", 24, 24),
                ("ic_logo_google_expressive", 24, 24),
                ("googleg_standard_color_18", 18, 18),
                ("googleg_disabled_color_18", 18, 18),
            ],
            True,
            logo_rgba,
            key_pem,
            c_der_bytes,
            cert_pem,
        )

        # 5c. Mutable Liquid Glass Framework Overlay (Control Center panel + inner Quick Settings tiles & cards)
        build_value_rro(
            OVERLAY_DIR / "FideBookGlassFrameworkOverlay.apk",
            "org.fidebookos.glass.framework",
            "android",
            "FideBookOS 1.25 Liquid Glass (Framework)",
            [
                (
                    "bool",
                    ["config_sf_slowBlur"],
                    0,
                    [(cfg_default, {"config_sf_slowBlur": val_bool(False)})],
                ),
                (
                    "color",
                    [
                        "shade_panel_bg_color",
                        "shade_panel_fg_color",
                        "shade_panel_scrim_color",
                        "shade_panel_fallback",
                        "system_surface_effect_0_light",
                        "system_surface_effect_0_dark",
                        "system_surface_effect_0_fallback_light",
                        "system_surface_effect_0_fallback_dark",
                        "system_surface_effect_1_light",
                        "system_surface_effect_1_dark",
                        "system_under_surface_light",
                        "system_under_surface_dark",
                    ],
                    CONFIG_UI_MODE | CONFIG_VERSION,
                    [
                        (
                            cfg_default,
                            {
                                "shade_panel_bg_color": val_color(0x22EEF5FF),
                                "shade_panel_fg_color": val_color(0x28FFFFFF),
                                "shade_panel_scrim_color": val_color(0x08040810),
                                "shade_panel_fallback": val_color(0x22EEF5FF),
                                "system_surface_effect_0_light": val_color(0x36D4E4FF),
                                "system_surface_effect_0_dark": val_color(0x3438568A),
                                "system_surface_effect_0_fallback_light": val_color(0x36D4E4FF),
                                "system_surface_effect_0_fallback_dark": val_color(0x3438568A),
                                "system_surface_effect_1_light": val_color(0x26F4F8FF),
                                "system_surface_effect_1_dark": val_color(0x241A2438),
                                "system_under_surface_light": val_color(0x1EE4EEFF),
                                "system_under_surface_dark": val_color(0x1E0A101C),
                            },
                        ),
                        (
                            cfg_night,
                            {
                                "shade_panel_bg_color": val_color(0x26101828),
                                "shade_panel_fg_color": val_color(0x22DCE8FF),
                                "shade_panel_scrim_color": val_color(0x0A040810),
                                "shade_panel_fallback": val_color(0x26101828),
                            },
                        ),
                    ],
                ),
            ],
            False,
            key_pem,
            c_der_bytes,
            cert_pem,
        )

        # 5d. Mutable Liquid Glass Launcher Overlay (Taskbar signature RGB carrier + App Menu glass carrier)
        build_value_rro(
            OVERLAY_DIR / "FideBookGlassLauncherOverlay.apk",
            "org.fidebookos.glass.launcher",
            "com.google.android.apps.nexuslauncher",
            "FideBookOS 1.25 Liquid Glass (Taskbar & App Menu)",
            [
                (
                    "bool",
                    ["reduce_workspace_blur_usage"],
                    0,
                    [(cfg_default, {"reduce_workspace_blur_usage": val_bool(False)})],
                ),
                (
                    "color",
                    [
                        "taskbar_background",
                        "taskbar_background_dark",
                        "taskbar_stroke",
                        "blur_shade_panel_bg",
                        "blur_shade_panel_fallback",
                        "blur_shade_panel_fg",
                    ],
                    CONFIG_UI_MODE | CONFIG_VERSION,
                    [
                        (
                            cfg_default,
                            {
                                "taskbar_background": val_color(0x34EBF3FF),
                                "taskbar_background_dark": val_color(0x36111927),
                                "taskbar_stroke": val_color(0x96FFFFFF),
                                "blur_shade_panel_bg": val_color(0x22EBF3FF),
                                "blur_shade_panel_fallback": val_color(0x22EBF3FF),
                                "blur_shade_panel_fg": val_color(0x28FFFFFF),
                            },
                        ),
                        (
                            cfg_night,
                            {
                                "taskbar_background": val_color(0x36111927),
                                "taskbar_background_dark": val_color(0x36111927),
                                "taskbar_stroke": val_color(0x78DCE8FF),
                                "blur_shade_panel_bg": val_color(0x26111927),
                                "blur_shade_panel_fallback": val_color(0x26111927),
                                "blur_shade_panel_fg": val_color(0x22DCE8FF),
                            },
                        ),
                    ],
                ),
                (
                    "dimen",
                    ["persistent_taskbar_corner_radius", "transient_taskbar_stroke_width"],
                    0,
                    [
                        (
                            cfg_default,
                            {
                                "persistent_taskbar_corner_radius": val_dp(22.0),
                                "transient_taskbar_stroke_width": val_dp(1.5),
                            },
                        )
                    ],
                ),
            ],
            False,
            key_pem,
            c_der_bytes,
            cert_pem,
        )

        # 5e. Mutable Liquid Glass SystemUI Overlay (Optical 2dp micro-polish instead of heavy 32dp blur)
        build_value_rro(
            OVERLAY_DIR / "FideBookGlassSystemUIOverlay.apk",
            "org.fidebookos.glass.systemui",
            "com.android.systemui",
            "FideBookOS 1.25 Liquid Glass (Control Center)",
            [
                (
                    "bool",
                    ["config_supportBlurredWallpaper", "config_translucentStandalonePowerMenu"],
                    0,
                    [
                        (
                            cfg_default,
                            {
                                "config_supportBlurredWallpaper": val_bool(True),
                                "config_translucentStandalonePowerMenu": val_bool(True),
                            },
                        )
                    ],
                ),
                (
                    "color",
                    ["shade_panel_fallback", "notification_scrim_base", "notification_scrim_fallback"],
                    CONFIG_UI_MODE | CONFIG_VERSION,
                    [
                        (
                            cfg_default,
                            {
                                "shade_panel_fallback": val_color(0x22EEF5FF),
                                "notification_scrim_base": val_color(0x22EEF5FF),
                                "notification_scrim_fallback": val_color(0x22EEF5FF),
                            },
                        ),
                        (
                            cfg_night,
                            {
                                "shade_panel_fallback": val_color(0x26101828),
                                "notification_scrim_base": val_color(0x26101828),
                                "notification_scrim_fallback": val_color(0x26101828),
                            },
                        ),
                    ],
                ),
                (
                    "dimen",
                    [
                        "min_window_blur_radius",
                        "max_window_blur_radius",
                        "max_shade_window_blur_radius",
                        "notification_scrim_corner_radius",
                    ],
                    0,
                    [
                        (
                            cfg_default,
                            {
                                "min_window_blur_radius": val_dp(0.0),
                                "max_window_blur_radius": val_dp(2.0),
                                "max_shade_window_blur_radius": val_dp(3.0),
                                "notification_scrim_corner_radius": val_dp(26.0),
                            },
                        )
                    ],
                ),
            ],
            False,
            key_pem,
            c_der_bytes,
            cert_pem,
        )

    print("Branding & Liquid Glass RRO build complete:")
    for f in sorted(OUT_DIR.rglob("*")):
        if f.is_file():
            print(f"  {f.relative_to(REPO)} ({f.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
