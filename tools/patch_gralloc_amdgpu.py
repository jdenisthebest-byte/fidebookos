#!/usr/bin/env python3
"""Let Google's vendor gralloc (libminigbm_gralloc.so, minigbm statically linked) allocate buffers on an AMD GPU
or under CPU SwiftShader.

  patch_gralloc_amdgpu.py [--keep-ab24] IN OUT

THIS is the library that matters for graphics (gralloc.minigbm.so, mapper.minigbm.so and the allocator service all link it; the
separate /vendor/lib64/libgbm.so is only used by the camera and video-codec HALs, see patch_libgbm_amdgpu.py).

1. minigbm backend ("komeda\\0" -> "amdgpu\\0"):
   minigbm picks a backend by comparing the DRM driver name (drmGetVersion) with a chain of string literals (inlined drv_get_backend,
   .text 0xc4c0..0xc710); each branch loads the matching `struct backend`. Google's build has no amdgpu backend, so gralloc fails on a
   Ryzen laptop. Eight backends (komeda, radeon, nouveau, vkms, ...) are the *same* generic linear dumb-buffer one (identical init
   0xef30 / bo_create_with_modifiers 0xf040: every render/texture format linear, drv_dumb_bo_create_ex). The "komeda" one (ARM Mali
   display processor, never on x86) has a 7-byte string literal "komeda\\0": it is rewritten to "amdgpu\\0", so the comparison chain and
   that backend's name both say "amdgpu". Dumb buffers are allowed on render nodes (DRM_RENDER_ALLOW in kernel 6.18's drm_ioctl.c), so
   cros_gralloc's render-node-first search (renderD128..) works.

2. CPU-lockable buffers ("pastel\\0" -> "intel\\0\\0"):
   cros_gralloc_driver::init sets a "software renderer" flag when the property ro.hardware.vulkan contains "lvp" or "pastel"
   (drv_get_os_option + strstr, .text 0x17326..0x1737d; Google's own hook for SwiftShader/lavapipe, whose vulkan.pastel.so the image
   does not ship). cros_gralloc_driver::lock (0x19140) refuses CPU access to a buffer that was not allocated with CPU usage unless that
   flag is set, so rewriting "pastel\\0" to "intel\\0\\0" sets the flag for ro.hardware.vulkan=intel (which hook.sh keeps), allowing
   both CPU Vulkan (SwiftShader) and mixed CPU/GPU AHardwareBuffer_lockPlanes access on linear amdgpu dumb buffers.

3. YV12 chroma stride alignment on RADV (32 -> 512):
   drv_dumb_bo_create_ex sizes a DRM_FORMAT_YVU420_ANDROID dumb buffer from the width aligned to 32 and lets amdgpu pick the pitch
   (256-byte multiples); drv_bo_from_format_and_padding then makes the chroma stride pitch/2. RADV can only import a linear plane whose
   pitch is a multiple of 256 (GFX9+), so e.g. 1280 wide gives a 640 chroma pitch and the import fails (SurfaceFlinger then aborts on
   "Failed to create a valid texture ... format:842094169"). The width is aligned to 512 instead, so pitch/2 is a multiple of 256.
   The 8 bytes at 0xe4a7 (add r12d,0x1f; and r12d,-32) become `call cave` + nop; the cave is 14 int3 bytes of padding at 0xe422:
   add r12d,0x1ff; and r12w,0xfe00; ret.

4. KMS scanout pixel format (--keep-ab24 vs default XB24):
   cros_gralloc_convert_format maps HAL_PIXEL_FORMAT_RGBA_8888 (1) to DRM_FORMAT_ABGR8888 ('AB24' = 0x34324241) at 0x1a303.
   - On AMD amdgpu (universal planes natively support AB24/XB24/AR24/XR24), pass `--keep-ab24` (produces libminigbm_gralloc.amdgpu.so)
     so RGBA_8888 surfaces preserve true 8-bit alpha metadata ('AB24') for hardware RADV Vulkan + SurfaceFlinger composition.
   - On older Intel GPUs (Gen <= 8 Broadwell/Haswell/Ivy Bridge/Sandy Bridge) and universal SwiftShader fallback (produces
     libminigbm_gralloc.swr.so), omit `--keep-ab24`: 'AB24' is rewritten to 'XB24' (0x34324258 = DRM_FORMAT_XBGR8888) so legacy i915
     primary planes do not reject drmModeAddFB2WithModifiers with -EINVAL (-22).

Only applied to the exact original (sha256 pinned): the offsets are into one specific build.
"""
import hashlib
import sys

ORIG_SHA = 'd48536951fd0e9643e71a5c8843e90833ce3e212e182782185470e2fbbfad673'
KOMEDA = 0x50b7          # .rodata literal compared at 0xc549 and pointed to by backend_komeda.name (file 0x1c238)
ALIGN_SITE = 0xe4a7      # drv_dumb_bo_create_ex, YVU420_ANDROID: add r12d,0x1f; and r12d,-32 (width in r12)
CAVE = 0xe422            # int3 padding before drv_dumb_bo_create_ex
PASTEL = 0x51af          # .rodata literal strstr()'d against ro.hardware.vulkan at 0x17364 (its only reference)
RGBA8888_SITE = 0x1a304  # cros_gralloc_convert_format: mov $0x34324241, %eax (b'AB24' -> b'XB24')


def main():
    args = sys.argv[1:]
    keep_ab24 = False
    if args and args[0] == '--keep-ab24':
        keep_ab24 = True
        args = args[1:]
    if len(args) != 2:
        sys.exit('usage: patch_gralloc_amdgpu.py [--keep-ab24] IN OUT')
    src, dst = args[0], args[1]
    d = bytearray(open(src, 'rb').read())
    if hashlib.sha256(d).hexdigest() != ORIG_SHA:
        sys.exit('unexpected libminigbm_gralloc.so (sha256 differs from the build this patch was made for)')
    assert d[KOMEDA:KOMEDA + 7] == b'komeda\0' and d[KOMEDA - 1] == 0
    assert b'amdgpu' not in d
    d[KOMEDA:KOMEDA + 7] = b'amdgpu\0'
    assert d[PASTEL:PASTEL + 7] == b'pastel\0' and d[PASTEL - 1] == 0 and d.count(b'pastel') == 1
    d[PASTEL:PASTEL + 7] = b'intel\0\0'
    assert d[ALIGN_SITE:ALIGN_SITE + 8] == bytes.fromhex('4183c41f4183e4e0')
    assert d[CAVE:CAVE + 14] == b'\xcc' * 14
    rel = (CAVE - (ALIGN_SITE + 5)) & 0xffffffff
    d[ALIGN_SITE:ALIGN_SITE + 8] = b'\xe8' + rel.to_bytes(4, 'little') + b'\x0f\x1f\x00'
    d[CAVE:CAVE + 14] = bytes.fromhex('4181c4ff010000' '664181e400fe' 'c3')
    assert d[RGBA8888_SITE:RGBA8888_SITE + 4] == b'AB24'
    assert d[RGBA8888_SITE - 1] == 0xb8
    if not keep_ab24:
        d[RGBA8888_SITE:RGBA8888_SITE + 4] = b'XB24'
        fmt_msg = 'RGBA_8888 mapped to DRM_FORMAT_XBGR8888 (XB24) for legacy Intel/universal KMS scanout'
    else:
        fmt_msg = 'RGBA_8888 kept as native DRM_FORMAT_ABGR8888 (AB24) for AMD universal planes'
    open(dst, 'wb').write(d)
    print('patched: generic linear backend answers to DRM driver "amdgpu"; software-renderer flag set by ro.hardware.vulkan=intel; '
          f'YV12 dumb-buffer width aligned to 512; {fmt_msg}')


if __name__ == '__main__':
    main()
