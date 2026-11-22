#!/bin/sh
# Execute tools/radv-android/test_radv_hw.c against the actual Android NDK-built vulkan.radv.so binary
# directly on this machine's physical AMD Radeon GPU (/dev/dri/renderD128) at native Zen 2 speed.
#
# Why a lightweight bionic-to-glibc loader shim is used on the Fedora host:
# Google's Android 17 system_a.img linker64/libc.so uses Alder Lake AVX-VNNI/GFNI instructions that gbOS86's
# kernel emulates via kernel/isa_emu_patch (#UD trap), whereas a stock Fedora host kernel does not.
# Because x86_64 Android bionic and x86_64 Linux glibc share identical struct sizes and layouts for
# pthread_mutex_t (40), pthread_cond_t (48), pthread_rwlock_t (56), pthread_barrier_t (32), mtx_t (40),
# cnd_t (48), struct stat (144), and %fs:0x28 stack protector, providing the 14 Android stub symbols
# (with an 88-byte x86_64 setjmp/longjmp) lets glibc dlopen() and execute the exact Android vulkan.radv.so
# machine code directly against /dev/dri/renderD128!
#
#   sh tools/radv-android/run_hw_test.sh [VULKAN_HAL_SO] [--allow-single-queue]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
HAL_SO=${1:-$REPO/usb/patched/vulkan.radv.so}
HAL_SO=$(cd "$(dirname "$HAL_SO")" && pwd)/$(basename "$HAL_SO")
EXTRA_FLAG=${2:-}

[ -c /dev/dri/renderD128 ] || { echo "SKIP: /dev/dri/renderD128 not present on this host"; exit 0; }
[ -f "$HAL_SO" ] || { echo "FAIL: HAL binary not found: $HAL_SO"; exit 1; }

docker run --rm --network none \
  --device /dev/dri/renderD128:/dev/dri/renderD128 \
  -v gbos-swsr:/w:ro \
  -v "$REPO":/repo:ro \
  -v "$HAL_SO":/hal_under_test.so:ro \
  -e EXTRA_FLAG="$EXTRA_FLAG" \
  gbos-radvbuild sh -ec '
    mkdir -p /tmp/build /tmp/lib
    cat > /tmp/build/shader.comp << "GLSL"
#version 450
layout(local_size_x = 64) in;
layout(constant_id = 0) const uint SPEC_XOR = 0u;
layout(set = 0, binding = 0) buffer Buf { uint data[]; };
layout(push_constant) uniform PC { uint mul_v; uint add_v; } pc;
void main() {
    uint idx = gl_GlobalInvocationID.x;
    data[idx] = (data[idx] * pc.mul_v + pc.add_v) ^ SPEC_XOR;
}
GLSL
    glslangValidator -V --vn test_radv_comp_spv /tmp/build/shader.comp -o /tmp/build/test_radv_spirv.h >/dev/null

    # Build Android bionic stub libraries (libhardware.so, liblog.so, libnativewindow.so, libsync.so)
    cat > /tmp/build/bionic_shim.c << "SHIM"
#define _GNU_SOURCE
#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char *program_invocation_short_name;

int *__errno(void) { return __errno_location(); }
const char *getprogname(void) { return program_invocation_short_name ? program_invocation_short_name : "test_radv_hw"; }
void android_set_abort_message(const char *msg) { (void)msg; }
int __system_property_get(const char *name, char *value) {
    (void)name;
    if (value) value[0] = 0;
    return 0;
}
int __android_log_write(int prio, const char *tag, const char *text) {
    (void)prio; (void)tag; (void)text;
    return 0;
}
void __assert2(const char *file, int line, const char *func, const char *expr) {
    fprintf(stderr, "bionic assert failed: %s:%d (%s): %s\n", file, line, func, expr);
    abort();
}

/* Bionic __sF[0..2] compatibility: 152 bytes per entry on x86_64 bionic */
unsigned char __sF[3 * 152];

/* Stubs for libhardware, libsync, libnativewindow */
int hw_get_module(const char *id, const void **module) { (void)id; (void)module; return -ENOENT; }
int sync_merge(const char *name, int fd1, int fd2) { (void)name; (void)fd1; (void)fd2; return -ENOSYS; }
void AHardwareBuffer_acquire(void *b) { (void)b; }
void AHardwareBuffer_release(void *b) { (void)b; }
int AHardwareBuffer_allocate(const void *d, void **o) { (void)d; (void)o; return -ENOSYS; }
void AHardwareBuffer_describe(const void *b, void *d) { (void)b; (void)d; }
const void *AHardwareBuffer_getNativeHandle(const void *b) { (void)b; return NULL; }

/* 88-byte x86_64 setjmp/longjmp matching Android bionic jmp_buf size (8 * 8 = 64 bytes used) */
__asm__(
".global setjmp\n"
".type setjmp, @function\n"
"setjmp:\n"
"  movq %rbx, 0(%rdi)\n"
"  movq %rbp, 8(%rdi)\n"
"  movq %r12, 16(%rdi)\n"
"  movq %r13, 24(%rdi)\n"
"  movq %r14, 32(%rdi)\n"
"  movq %r15, 40(%rdi)\n"
"  leaq 8(%rsp), %rdx\n"
"  movq %rdx, 48(%rdi)\n"
"  movq (%rsp), %rdx\n"
"  movq %rdx, 56(%rdi)\n"
"  xorl %eax, %eax\n"
"  ret\n"
".global longjmp\n"
".type longjmp, @function\n"
"longjmp:\n"
"  movl %esi, %eax\n"
"  testl %eax, %eax\n"
"  jnz 1f\n"
"  incl %eax\n"
"1:\n"
"  movq 0(%rdi), %rbx\n"
"  movq 8(%rdi), %rbp\n"
"  movq 16(%rdi), %r12\n"
"  movq 24(%rdi), %r13\n"
"  movq 32(%rdi), %r14\n"
"  movq 40(%rdi), %r15\n"
"  movq 48(%rdi), %rsp\n"
"  jmp *56(%rdi)\n"
);
SHIM
    gcc -O2 -fPIC -shared /tmp/build/bionic_shim.c -lpthread -lm -ldl -Wl,-soname,libhardware.so -o /tmp/lib/libhardware.so
    for s in liblog.so libnativewindow.so libsync.so; do
      gcc -O2 -fPIC -shared -x c /dev/null -Wl,-soname,$s -o /tmp/lib/$s
    done

    # Strip @LIBC* ELF DT_VERNEED / DT_VERSYM tags on a temp copy so glibc resolves POSIX symbols directly
    python3 - /hal_under_test.so /tmp/lib/vulkan.radv.test.so << "PY"
import struct, sys
data = bytearray(open(sys.argv[1], "rb").read())
e_phoff = struct.unpack_from("<Q", data, 32)[0]
e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
e_shoff = struct.unpack_from("<Q", data, 40)[0]
e_shentsize, e_shnum = struct.unpack_from("<HH", data, 58)
PT_DYNAMIC = 2
DT_VERSYM = 0x6ffffff0
DT_VERNEED = 0x6ffffffe
DT_VERNEEDNUM = 0x6fffffff
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    p_type = struct.unpack_from("<I", data, off)[0]
    if p_type == PT_DYNAMIC:
        p_offset, _, _, p_filesz = struct.unpack_from("<QQQQ", data, off + 8)
        for d_off in range(p_offset, p_offset + p_filesz, 16):
            d_tag, d_val = struct.unpack_from("<QQ", data, d_off)
            if d_tag == 0:
                break
            if d_tag in (DT_VERSYM, DT_VERNEED, DT_VERNEEDNUM):
                # Turn into harmless DT_DEBUG/DT_IGNORE-equivalent: use DT_RPATH-safe no-op tag 0x6ffffffa? No: compact dynamic array!
                pass
        # Compact out DT_VERSYM, DT_VERNEED, DT_VERNEEDNUM and map DT_ANDROID_RELR* -> standard ELF DT_RELR*
        RELR_MAP = {0x6fffe000: 36, 0x6fffe001: 35, 0x6fffe003: 37}
        entries = []
        for d_off in range(p_offset, p_offset + p_filesz, 16):
            d_tag, d_val = struct.unpack_from("<QQ", data, d_off)
            if d_tag == 0:
                break
            if d_tag not in (DT_VERSYM, DT_VERNEED, DT_VERNEEDNUM):
                entries.append((RELR_MAP.get(d_tag, d_tag), d_val))
        entries.append((0, 0))
        while len(entries) * 16 < p_filesz:
            entries.append((0, 0))
        for idx, (t, v) in enumerate(entries):
            struct.pack_into("<QQ", data, p_offset + idx * 16, t, v)
SHT_GNU_verneed = 0x6ffffffe
SHT_GNU_versym = 0x6fffffff
for i in range(e_shnum):
    off = e_shoff + i * e_shentsize
    sh_type = struct.unpack_from("<I", data, off + 4)[0]
    if sh_type in (SHT_GNU_verneed, SHT_GNU_versym):
        struct.pack_into("<I", data, off + 4, 1)  # SHT_PROGBITS
open(sys.argv[2], "wb").write(data)
PY
    chmod 0755 /tmp/lib/vulkan.radv.test.so

    A=/w/aosp
    gcc -O2 -Wall \
      -I/tmp/build \
      -I/w/mesa/include \
      -I$A/libhardware/include -I$A/libhardware/include_all \
      -I$A/core/libcutils/include -I$A/core/libsync/include -I$A/core/libsystem/include \
      -I$A/core/libutils/include -I$A/core/liblog/include \
      -I$A/native/libs/nativewindow/include -I$A/native/vulkan/include \
      /repo/tools/radv-android/test_radv_hw.c \
      /tmp/lib/libhardware.so -Wl,-rpath,/tmp/lib -ldl -lpthread -lm \
      -o /tmp/build/test_radv_hw

    ln -sf /lib/x86_64-linux-gnu/libz.so.1 /tmp/lib/libz.so
    ln -sf /lib/x86_64-linux-gnu/libc.so.6 /tmp/lib/libc.so
    ln -sf /lib/x86_64-linux-gnu/libm.so.6 /tmp/lib/libm.so
    ln -sf /lib/x86_64-linux-gnu/libdl.so.2 /tmp/lib/libdl.so

    LD_LIBRARY_PATH=/tmp/lib /tmp/build/test_radv_hw /tmp/lib/vulkan.radv.test.so $EXTRA_FLAG
'
