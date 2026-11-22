#!/bin/sh
# Build the optimized Android RADV HAL (x86_64-v3) with the cached NDK toolchain.
# Usage: build.sh [OUT_DIR] | --check-deps | --shaders-only [OUT_DIR]
#
# OFFLINE by default: cached image, complete pinned source objects, NDK and Meson
# fallback archives are checked BEFORE any checkout/reset/clean. All containers
# use --network none unless the caller explicitly sets ALLOW_DOWNLOADS=1 after
# obtaining permission. Missing cache entries fail, never silently go online.
# KEEP_BUILD=1 retains the incremental Mesa build. Normal builds intentionally
# reset/clean the cached Mesa and libdrm source trees; --check-deps does not.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECK_ONLY=0
case "${1:-}" in
    --help)
        sed -n '2,10p' "$0"
        exit 0 ;;
    --shaders-only)
        shift
        exec sh "$HERE/build_shaders.sh" "$@" ;;
    --check-deps)
        CHECK_ONLY=1
        shift ;;
    --*) echo "Unknown option: $1" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "Usage: $0 [OUT_DIR] | --check-deps | --shaders-only [OUT_DIR]" >&2; exit 2; }
ALLOW_DOWNLOADS=${ALLOW_DOWNLOADS:-0}
case "$ALLOW_DOWNLOADS" in 0|1) ;; *) echo "ALLOW_DOWNLOADS must be 0 or 1" >&2; exit 2 ;; esac
if [ "$CHECK_ONLY" = 1 ] && [ "$ALLOW_DOWNLOADS" = 1 ]; then
    echo "--check-deps is read-only and offline; unset ALLOW_DOWNLOADS." >&2
    exit 2
fi
IMAGE=${RADV_BUILD_IMAGE:-gbos-radvbuild}
CACHE=${RADV_BUILD_CACHE:-gbos-swsr}
OUT=${1:-$HERE/../../build/radv}
mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)
command -v docker >/dev/null 2>&1 || { echo "Docker is required; no downloads attempted." >&2; exit 1; }
if ! docker image inspect "$IMAGE" >/dev/null 2>&1 || [ "${REBUILD_IMAGE:-0}" = 1 ]; then
    if [ "$ALLOW_DOWNLOADS" != 1 ]; then
        echo "Cached image $IMAGE is missing or REBUILD_IMAGE was requested. Offline build stopped before source changes. Provision the cache separately, or explicitly opt in with ALLOW_DOWNLOADS=1 after permission." >&2
        exit 1
    fi
    docker build --platform linux/amd64 -q -t "$IMAGE" - <<'DOCKERFILE' >/dev/null
FROM --platform=linux/amd64 debian:trixie-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends curl ca-certificates unzip git ninja-build meson pkgconf bison flex \
    python3 python3-mako python3-yaml python3-packaging python3-ply glslang-tools spirv-tools xz-utils make file binutils build-essential cmake >/dev/null && rm -rf /var/lib/apt/lists/*
WORKDIR /w
DOCKERFILE
fi
if ! docker volume inspect "$CACHE" >/dev/null 2>&1; then
    if [ "$ALLOW_DOWNLOADS" != 1 ]; then
        echo "Cached volume $CACHE is missing. Offline build stopped before source changes; no downloads attempted." >&2
        exit 1
    fi
    docker volume create "$CACHE" >/dev/null
fi
NET_OPT=none
[ "$ALLOW_DOWNLOADS" = 0 ] || NET_OPT=bridge
CACHE_MODE=
[ "$CHECK_ONLY" = 0 ] || CACHE_MODE=:ro
docker run --rm -i --pull=never --network "$NET_OPT" --platform linux/amd64 \
    -e ALLOW_DOWNLOADS="$ALLOW_DOWNLOADS" -e CHECK_ONLY="$CHECK_ONLY" \
    -e KEEP_BUILD="${KEEP_BUILD:-0}" -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$CACHE":/w"$CACHE_MODE" -v "$HERE":/h:ro -v "$OUT":/out "$IMAGE" sh -eu <<'CONTAINER'
cd /w
NDK=/w/android-ndk-r30
MESA_TAG=b888682cba909c477f405e377cee881ca68e289d
DRM_TAG=libdrm-2.4.133
DRM_REF=cb4669afe87470752643f46c81bddb45b0db48e4
HARDWARE_REF=7e08958a6cbe2b02c9d80a66fba68fd8a864d73d
CORE_REF=a3b721a32242006b59cb12bd62c9133632af3a2d
NATIVE_REF=4f463a6b1de9198963dc6aff74154a504ba3f8f6
export NDK MESA_TAG DRM_TAG DRM_REF HARDWARE_REF CORE_REF NATIVE_REF
export GIT_TERMINAL_PROMPT=0
[ "$ALLOW_DOWNLOADS" = 1 ] || export GIT_NO_LAZY_FETCH=1

missing=0
for tool in curl unzip git ninja meson pkgconf bison flex python3 glslangValidator spirv-val cmake make file xz; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing cached build tool: $tool" >&2
        missing=1
    fi
done
[ "$missing" = 0 ] || { echo "Incomplete image; provision dependencies separately. No source checkout/reset performed." >&2; exit 1; }

# This bootstrap path is opt-in only. It is never reached by the default build.
if [ "$ALLOW_DOWNLOADS" = 1 ]; then
    if [ ! -d "$NDK" ]; then
        curl -fL --retry 5 -o ndk.zip https://dl.google.com/android/repository/android-ndk-r30-linux.zip
        echo "5107f898313790e449e87eee2183d9a20602dee9  ndk.zip" | sha1sum -c -
        unzip -q ndk.zip
    fi
    get() {
        n=$1; u=$2; ref=$3; shift 3
        if [ ! -d "$n/.git" ]; then
            [ ! -e "$n" ] || { echo "Refusing to overwrite non-git cache: $n" >&2; exit 1; }
            git init -q "$n"
            git -C "$n" remote add origin "$u"
            if [ "$#" -gt 0 ]; then
                git -C "$n" config core.sparseCheckout true
                for p in "$@"; do echo "/$p/" >> "$n/.git/info/sparse-checkout"; done
            fi
        fi
        git -C "$n" cat-file -e "$ref^{commit}" 2>/dev/null || git -C "$n" fetch -q --depth 1 origin "$ref"
    }
    mkdir -p aosp
    B=https://android.googlesource.com
    get aosp/libhardware "$B/platform/hardware/libhardware" "$HARDWARE_REF" include include_all
    get aosp/core "$B/platform/system/core" "$CORE_REF" libcutils/include libsync/include libsystem/include libutils/include liblog/include libvndksupport/include
    get aosp/native "$B/platform/frameworks/native" "$NATIVE_REF" libs/nativewindow/include libs/arect/include vulkan/include
    get mesa https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_TAG"
    get drm https://gitlab.freedesktop.org/mesa/drm.git "$DRM_REF"
    git -C drm rev-parse --verify "$DRM_TAG^{commit}" >/dev/null 2>&1 || git -C drm fetch -q --depth 1 origin tag "$DRM_TAG"
fi

# Check selected source blobs too: the presence of a partial clone or a commit
# alone does not prove an offline checkout can succeed. No reset/clean above.
python3 - <<'PY'
import configparser
import hashlib
import importlib
import os
import pathlib
import subprocess
import sys
import tempfile

errors = []
for module in ('mako', 'yaml', 'packaging', 'ply'):
    try:
        importlib.import_module(module)
    except ImportError:
        errors.append('Missing Python dependency: ' + module)

def git(repo, *args, data=None):
    return subprocess.run(['git', '--no-optional-locks', '-C', '/w/' + repo, *args],
                          input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout

def check_repo(repo, ref, paths=(), required=()):
    try:
        commit = git(repo, 'rev-parse', '--verify', ref + '^{commit}').decode().strip()
        entries = git(repo, 'ls-tree', '-r', '-z', commit, '--', *paths).split(b'\0')
        blobs = []
        files = set()
        for entry in entries:
            if not entry:
                continue
            info, name = entry.split(b'\t', 1)
            mode, kind, oid = info.split()
            if kind == b'blob':
                blobs.append(oid)
                files.add(name.decode())
        if not blobs:
            raise ValueError('no selected source blobs')
        missing = git(repo, 'cat-file', '--batch-check=%(objectname) %(objecttype)',
                      data=b'\n'.join(blobs) + b'\n').decode().splitlines()
        missing = [line for line in missing if not line.endswith(' blob')]
        if missing:
            raise ValueError('%d uncached source objects (first: %s)' % (len(missing), missing[0]))
        absent = set(required) - files
        if absent:
            raise ValueError('missing required pinned files: ' + ', '.join(sorted(absent)))
        print('CACHE_OK %s @ %s (%d selected blobs)' % (repo, commit, len(blobs)))
        return True
    except (subprocess.CalledProcessError, ValueError, OSError) as exc:
        errors.append('Incomplete pinned cache %s @ %s: %s' % (repo, ref, exc))
        return False

mesa_ok = check_repo('mesa', os.environ['MESA_TAG'], required=('meson.build', 'subprojects/expat.wrap'))
check_repo('drm', os.environ['DRM_REF'], required=('meson.build', 'amdgpu/amdgpu.h'))
try:
    if git('drm', 'rev-parse', os.environ['DRM_TAG'] + '^{commit}').decode().strip() != os.environ['DRM_REF']:
        errors.append('libdrm tag does not resolve to the pinned DRM_REF')
except subprocess.CalledProcessError:
    errors.append('Missing pinned libdrm tag: ' + os.environ['DRM_TAG'])
check_repo('aosp/libhardware', os.environ['HARDWARE_REF'], ('include', 'include_all'),
           ('include_all/hardware/hardware.h',))
check_repo('aosp/core', os.environ['CORE_REF'],
           ('libcutils/include', 'libsync/include', 'libsystem/include', 'libutils/include',
            'liblog/include', 'libvndksupport/include'),
           ('libcutils/include/cutils/native_handle.h', 'libsync/include/sync/sync.h',
            'libsystem/include/system/graphics.h'))
check_repo('aosp/native', os.environ['NATIVE_REF'],
           ('libs/nativewindow/include', 'libs/arect/include', 'vulkan/include'),
           ('libs/nativewindow/include/android/native_window.h', 'libs/arect/include/android/rect.h',
            'vulkan/include/hardware/hwvulkan.h', 'vulkan/include/vulkan/vk_android_native_buffer.h'))
ndk = pathlib.Path(os.environ['NDK'])
tc = ndk / 'toolchains/llvm/prebuilt/linux-x86_64'
try:
    if 'Pkg.Revision = 30.0.16248370' not in (ndk / 'source.properties').read_text().splitlines():
        errors.append('Cached NDK is not pinned r30 (30.0.16248370)')
except OSError:
    errors.append('Missing NDK r30 source.properties')
for name in ('x86_64-linux-android34-clang', 'x86_64-linux-android34-clang++',
             'llvm-ar', 'llvm-strip', 'ld.lld'):
    if not os.access(tc / 'bin' / name, os.X_OK):
        errors.append('Missing NDK tool: ' + name)
for name in ('libc.so', 'libm.so', 'libz.so'):
    if not (tc / 'sysroot/usr/lib/x86_64-linux-android/34' / name).is_file():
        errors.append('Missing NDK API 34 library: ' + name)
compiler = tc / 'bin/x86_64-linux-android34-clang++'
if os.access(compiler, os.X_OK):
    # Exercise the cached compiler, linker, C++ runtime, resource headers,
    # Android/Vulkan headers and API libraries without touching source trees.
    scratch = pathlib.Path('/tmp/opencode')
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='radv-preflight-', dir=scratch) as temporary:
        probe = pathlib.Path(temporary) / 'probe.cc'
        probe.write_text('#include <cstdint>\n#include <string>\n#include <android/native_window.h>\n'
                         '#include <android/hardware_buffer.h>\n#include <vulkan/vulkan.h>\n#include <vulkan/vulkan_android.h>\n'
                         '#include <zlib.h>\nint main() { VkExtent2D e{1, 1}; '
                         'std::string s(zlibVersion()); return int(s.size() + e.width); }\n')
        result = subprocess.run([str(compiler), '-O3', '-march=x86-64-v3', '-mtune=znver3',
                                 '-static-libstdc++', '-Wl,--icf=safe', '-Wl,--gc-sections',
                                 str(probe), '-lz', '-llog', '-landroid', '-o', str(probe.with_suffix('.elf'))],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode:
            errors.append('Cached NDK compile/link probe failed: ' + result.stdout.decode(errors='replace'))
        else:
            print('CACHE_OK NDK r30 API 34 C++/Vulkan/Android/zlib compile+link probe')
if mesa_ok and os.environ['ALLOW_DOWNLOADS'] != '1':
    # This configuration's one Meson wrap fallback. Check both pinned archives,
    # not just a directory name, before allowing the cached Mesa tree to reset.
    wrap = configparser.ConfigParser()
    wrap.read_string(git('mesa', 'show', os.environ['MESA_TAG'] + ':subprojects/expat.wrap').decode())
    for prefix in ('source', 'patch'):
        name = wrap['wrap-file'][prefix + '_filename']
        archive = pathlib.Path('/w/mesa/subprojects/packagecache') / name
        if not archive.is_file():
            errors.append('Missing cached Meson fallback archive: ' + str(archive))
        elif hashlib.sha256(archive.read_bytes()).hexdigest() != wrap['wrap-file'][prefix + '_hash']:
            errors.append('Pinned Meson archive checksum mismatch: ' + str(archive))
if errors:
    for message in errors:
        print('PRECHECK_FAIL: ' + message, file=sys.stderr)
    print('Stopped BEFORE checkout/reset/clean. Provision the complete cache separately; '
          'downloads require an explicit ALLOW_DOWNLOADS=1 opt-in after permission.', file=sys.stderr)
    sys.exit(1)
print('RADV_BUILD_CACHE_READY (no checkout/reset/clean performed by preflight)')
PY
[ "$CHECK_ONLY" = 0 ] || exit 0

# Invalid shader source also fails before destroying the previous patched tree.
SHADER_TOOL_MODE=host sh /h/build_shaders.sh /out/shaders
for spec in "aosp/libhardware:$HARDWARE_REF" "aosp/core:$CORE_REF" "aosp/native:$NATIVE_REF"; do
    git -C "${spec%%:*}" checkout -q -f "${spec#*:}"
done
git -C mesa checkout -q -f "$MESA_TAG"
git -C mesa clean -fdx -e subprojects/packagecache -e 'subprojects/expat-*'
git -C drm checkout -q -f "$DRM_REF"
git -C drm clean -fdx
A=/w/aosp
INC="$A/libhardware/include:$A/libhardware/include_all:$A/core/libcutils/include:$A/core/libsync/include:$A/core/libsystem/include:$A/core/libutils/include:$A/core/liblog/include:$A/core/libvndksupport/include:$A/native/libs/nativewindow/include:$A/native/libs/arect/include:$A/native/vulkan/include"
export CPLUS_INCLUDE_PATH=$INC C_INCLUDE_PATH=$INC
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
SDK=34
OPT_FLAGS='-O3 -march=x86-64-v3 -mtune=znver3 -ffunction-sections -fdata-sections'
LD_OPT_FLAGS='-Wl,-O3 -Wl,--icf=safe -Wl,--gc-sections'
cat > cross.txt <<EOF
[binaries]
ar = "$TC/llvm-ar"
c = ["$TC/x86_64-linux-android$SDK-clang", "-O3", "-march=x86-64-v3", "-mtune=znver3", "-ffunction-sections", "-fdata-sections", "-fno-exceptions", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables"]
cpp = ["$TC/x86_64-linux-android$SDK-clang++", "-O3", "-march=x86-64-v3", "-mtune=znver3", "-ffunction-sections", "-fdata-sections", "-fno-exceptions", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables", "-static-libstdc++"]
c_ld = "lld"
cpp_ld = "lld"
strip = "$TC/llvm-strip"
pkg-config = "pkgconf"
[host_machine]
system = "android"
cpu_family = "x86_64"
cpu = "x86_64"
endian = "little"
[properties]
needs_exe_wrapper = true
EOF
tr '\042' '\047' < cross.txt > cross.tmp
mv cross.tmp cross.txt
rm -rf /w/drm-b /w/sys
mkdir -p /w/sys
meson setup drm-b drm --cross-file cross.txt --buildtype=release -Doptimization=3 --prefix=/w/sys --libdir=lib --default-library=static \
    -Dintel=disabled -Dradeon=disabled -Damdgpu=enabled \
    -Dnouveau=disabled -Dvmwgfx=disabled -Dfreedreno=disabled -Dvc4=disabled -Detnaviv=disabled -Dexynos=disabled -Domap=disabled -Dtegra=disabled \
    -Dudev=false -Dcairo-tests=disabled -Dvalgrind=disabled -Dtests=false -Dman-pages=disabled -Dinstall-test-programs=false >/w/drm-setup.log 2>&1 || { tail -30 /w/drm-setup.log; exit 1; }
ninja -C drm-b install >/w/drm-build.log 2>&1 || { tail -30 /w/drm-build.log; exit 1; }
export PKG_CONFIG_PATH=/w/sys/lib/pkgconfig PKG_CONFIG_LIBDIR=/w/sys/lib/pkgconfig
cd mesa
cp /out/shaders/fidebook_mblur_spirv.h src/amd/vulkan/fidebook_mblur_spirv.h
cp /h/fidebook_mblur.h src/amd/vulkan/fidebook_mblur.h
cp /h/fidebook_liquid_glass.h src/amd/vulkan/fidebook_liquid_glass.h
python3 /h/patch_mesa.py
BUILD_KEY="$MESA_TAG-$DRM_TAG-fidebook-1.25"
if [ ! -f /w/mesa-build-key ] || [ "$(cat /w/mesa-build-key)" != "$BUILD_KEY" ]; then
    rm -rf /w/mesa-b
fi
[ "${KEEP_BUILD:-0}" = 1 ] || rm -rf /w/mesa-b
WRAP_OPT=--wrap-mode=nodownload
[ "$ALLOW_DOWNLOADS" = 0 ] || WRAP_OPT=--wrap-mode=default
[ -d /w/mesa-b ] || meson setup /w/mesa-b . "$WRAP_OPT" --cross-file /w/cross.txt --prefix=/w/mesa-out --buildtype=release -Doptimization=3 -Db_ndebug=true -Dstrip=true \
    -Dc_args="-I/w/sys/include -I/w/sys/include/libdrm $OPT_FLAGS" -Dcpp_args="-I/w/sys/include -I/w/sys/include/libdrm $OPT_FLAGS" \
    -Dc_link_args="$LD_OPT_FLAGS" -Dcpp_link_args="$LD_OPT_FLAGS" \
    -Dplatforms=android -Dandroid-stub=true -Dandroid-strict=false -Dplatform-sdk-version=$SDK -Dandroid-libbacktrace=disabled -Dcpp_rtti=false \
    -Dvulkan-drivers=amd -Dgallium-drivers= -Dllvm=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Degl=disabled -Dgbm=disabled -Dglx=disabled \
    -Dglvnd=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dshader-cache=enabled -Dbuild-tests=false -Dvulkan-layers= \
    -Dvideo-codecs= -Dgallium-va=disabled -Dxlib-lease=disabled -Dzstd=disabled -Dperfetto=false -Dmicrosoft-clc=disabled \
    -Dintel-rt=disabled -Dteflon=false -Dgallium-rusticl=false -Dtools= >/w/mesa-setup.log 2>&1 || { tail -60 /w/mesa-setup.log; exit 1; }
echo "$BUILD_KEY" > /w/mesa-build-key
ninja -C /w/mesa-b -j"$(nproc)" >/w/mesa-build.log 2>&1 || { tail -60 /w/mesa-build.log; exit 1; }
find /w/mesa-b -name libvulkan_radeon.so -exec ls -l {} \;
F=$(find /w/mesa-b -name libvulkan_radeon.so | head -n 1)
[ -n "$F" ] || { echo 'Mesa build produced no libvulkan_radeon.so' >&2; exit 1; }
"$TC/llvm-strip" --strip-unneeded -o /out/vulkan.radv.so "$F"
ls -l /out/vulkan.radv.so
sha256sum /out/vulkan.radv.so
CONTAINER
