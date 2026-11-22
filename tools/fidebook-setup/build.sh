#!/bin/sh
# Build FideBookOS 1.25 Material 3 Setup Wizard (FideBookSetup.apk) and
# Native Settings "Liquid Glass & Motion" Screen (FideBookVisualSettings.apk) 100% offline.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
mkdir -p "$HERE/out"

docker run --rm --network none -v gbos-swsr:/work -v "$ROOT":/repo:z gbos-radvbuild:latest bash -c "
  set -e
  CXX=/work/android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android35-clang++
  STRIP=/work/android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip
  READELF=/work/android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf

  \$CXX -std=c++20 -O2 -fPIC -shared -static-libstdc++ -Wall -Wextra -Werror \
    -Wl,-z,max-page-size=16384 -Wl,-soname,libfidebook_setup.so \
    /repo/tools/fidebook-setup/fidebook_setup.cpp \
    -llog -landroid \
    -o /repo/tools/fidebook-setup/out/libfidebook_setup.so
  \$STRIP --strip-unneeded /repo/tools/fidebook-setup/out/libfidebook_setup.so

  \$CXX -std=c++20 -O2 -fPIC -shared -static-libstdc++ -Wall -Wextra -Werror \
    -Wl,-z,max-page-size=16384 -Wl,-soname,libfidebook_visual.so \
    /repo/tools/fidebook-setup/fidebook_visual.cpp \
    -llog -landroid \
    -o /repo/tools/fidebook-setup/out/libfidebook_visual.so
  \$STRIP --strip-unneeded /repo/tools/fidebook-setup/out/libfidebook_visual.so

  for so in /repo/tools/fidebook-setup/out/libfidebook_setup.so /repo/tools/fidebook-setup/out/libfidebook_visual.so; do
    if \$READELF -d \"\$so\" | grep -q 'libc++_shared.so'; then
      echo \"FAIL: \$so still depends on libc++_shared.so!\" >&2
      exit 1
    fi
  done

  chown $(id -u):$(id -g) /repo/tools/fidebook-setup/out/libfidebook_setup.so /repo/tools/fidebook-setup/out/libfidebook_visual.so
"

python3 "$HERE/build_setup_apk.py"
