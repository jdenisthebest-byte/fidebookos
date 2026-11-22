#!/bin/sh
# Build the FideBookOS kernel (6.18.21-fidebook): AOSP android17-6.18 + hardware/ISA patches + KernelSU
# + MT7902 Bluetooth (13d3:3594) + out-of-tree MT7902 PCIe Wi-Fi (mt7902e.ko), in the gbos-kbuild container.
#
#   sh kernel/build_kernel.sh [BASE_CONFIG] [JOBS]
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
JOBS=${2:-$(nproc)}
VOL=gbos-ksrc
C=/build/inputs/clang-r584948c
MT7902_SRC="${MT7902_SRC:-$ROOT/../mt7902_driver/mt7902/src}"

BASE=${1:-}
W=$(mktemp -d "${TMPDIR:-/tmp}/kcfg.XXXXXX"); trap 'rm -rf "$W"' EXIT
if [ -z "$BASE" ]; then
  BASE=$W/base.config
  python3 "$ROOT/tools/extract_ikconfig.py" "$ROOT/usb/out/BOOTX64.EFI" > "$BASE" \
    || { echo "no base config: pass one, or extract it with tools/extract_ikconfig.py"; exit 1; }
  echo "base config: extracted from $(basename "$ROOT/usb/out/BOOTX64.EFI")"
else
  echo "base config: $BASE"
fi

MT_MOUNT=""
if [ -d "$MT7902_SRC" ]; then
  MT7902_ABS=$(cd "$MT7902_SRC" && pwd)
  MT_MOUNT="-v $MT7902_ABS:/mt7902_src:ro,z"
  echo "mt7902 Wi-Fi source: $MT7902_ABS"
fi

docker run --rm -i --network none --platform linux/amd64 \
  -v "$VOL":/build -v "$ROOT":/host:ro,z -v "$W":/cfg:z $MT_MOUNT \
  gbos-kbuild bash -s <<EOF
set -e
export PATH=$C/bin:\$PATH LD_LIBRARY_PATH=$C/lib:\${LD_LIBRARY_PATH:-}
git config --global --add safe.directory /build/inputs/KernelSU
git config --global --add safe.directory /build/src
mkdir -p /build/out

if [ -f /host/usb/out/BOOTX64.EFI ]; then
  prev=\$(grep -a -m1 -o '#[0-9]\+ ' /host/usb/out/BOOTX64.EFI | head -1 | tr -dc '0-9')
  [ -n "\$prev" ] && echo "\$prev" > /build/out/.version && echo "kernel build number: #\$((prev + 1))"
fi

cd /build/src
: > .scmversion
if ! grep -q 'srctree/.scmversion' scripts/setlocalversion; then
  sed -i 's|^\\tif ! head=\\\$(git rev-parse --verify HEAD 2>/dev/null); then|\\tif test -e "\\\$srctree/.scmversion" \\|\\| ! head=\\\$(git rev-parse --verify HEAD 2>/dev/null); then|' scripts/setlocalversion
fi
grep -q 'srctree/.scmversion' scripts/setlocalversion || { echo "setlocalversion patch did not apply" >&2; exit 1; }

# 1. Ensure all kernel patches are applied without needlessly bumping mtimes on unchanged files
export P=/host/kernel/isa_emu_patch
grep -q 'isa_emu_handle_ud(regs)' arch/x86/kernel/traps.c || sh \$P/apply.sh
grep -q 'CONFIG_MEMFD_ASHMEM_SHIM' mm/shmem.c || P=/host/kernel/ashmem_shim sh /host/kernel/ashmem_shim/apply.sh
for s in i915_color_pipeline i915_edp_colorspace i915_edp_no_colorspace i915_edp_full_range \
         i915_ignore_gamma debug_selinux surface_sl7_sam alc269_hp_envy13_aq mt7902_bt; do
  sh \$P/\$s.sh > /dev/null
done
python3 \$P/sdw_sl7.py /build/src > /dev/null
[ -L drivers/kernelsu ] && grep -q 'CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=1' drivers/kernelsu/Kbuild \
  || { P=/host/kernel/kernelsu sh /host/kernel/kernelsu/apply.sh | tail -2; }

# 2. Configure 6.18.21-fidebook
cp /cfg/base.config /build/out/.config
python3 /host/kernel/configure_whl.py --generic /build/out/.config /build/out/.config.new
cp /build/out/.config.new /build/out/.config
/build/src/scripts/config --file /build/out/.config \
  --set-str CMDLINE "\$(tr -d '\r\n' < /host/kernel/isa_emu_patch/generic_cmdline.txt)" \
  --set-str INITRAMFS_SOURCE ""
make -C /build/src O=/build/out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22 olddefconfig > /dev/null

# 3. Build bzImage + all in-tree modules
echo "== Building kernel 6.18.21-fidebook + in-tree modules =="
make -C /build/src O=/build/out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22 -j$JOBS bzImage modules

# 4. Install stripped + signed modules into /build/modroot_fidebook
rm -rf /build/modroot_fidebook
make -C /build/src O=/build/out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22 \
  modules_install INSTALL_MOD_PATH=/build/modroot_fidebook INSTALL_MOD_STRIP=1 > /dev/null

rel=\$(cat /build/out/include/config/kernel.release)
echo "kernel release: \$rel"

# 5. Build, strip & sign out-of-tree MT7902 PCIe Wi-Fi module (mt7902e.ko) against 6.18.21-fidebook
if [ -d /mt7902_src ]; then
  echo "== Building out-of-tree mt7902e.ko for \$rel =="
  rm -rf /build/mt7902-out
  mkdir -p /build/mt7902-out
  cp -a /mt7902_src/. /build/mt7902-out/
  make -C /build/out M=/build/mt7902-out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22 -j$JOBS modules
  mkdir -p /build/modroot_fidebook/lib/modules/\$rel/extra/mt7902
  cp /build/mt7902-out/mt7902e.ko /build/modroot_fidebook/lib/modules/\$rel/extra/mt7902/mt7902e.ko
  $C/bin/llvm-strip --strip-debug /build/modroot_fidebook/lib/modules/\$rel/extra/mt7902/mt7902e.ko
  sig_hash=\$(awk -F= '/^CONFIG_MODULE_SIG_HASH=/{gsub(/"/,"",\$2); print \$2}' /build/out/.config)
  [ -n "\$sig_hash" ] || sig_hash=sha1
  /build/out/scripts/sign-file "\$sig_hash" /build/out/certs/signing_key.pem /build/out/certs/signing_key.x509 \
    /build/modroot_fidebook/lib/modules/\$rel/extra/mt7902/mt7902e.ko
  depmod -a -b /build/modroot_fidebook "\$rel"
fi

# 6. Build stage0 initramfs (busybox + fidebook-gui + stage0_init.sh + early modules) and embed into bzImage
sh /host/kernel/make_stage0_initramfs.sh /build/modroot_fidebook /build/out/fidebook_stage0.cpio
/build/src/scripts/config --file /build/out/.config --set-str INITRAMFS_SOURCE /build/out/fidebook_stage0.cpio
make -C /build/src O=/build/out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22 olddefconfig > /dev/null
make -C /build/src O=/build/out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22 -j$JOBS bzImage
echo "BUILD OK (\$rel)"
EOF

# 7. Export BOOTX64.EFI, usb/modules/lib/modules/6.18.21-fidebook, and usb/kmod/*.ko
mkdir -p "$ROOT/usb/out" "$ROOT/usb/kmod"
docker run --rm -i --network none --platform linux/amd64 -v "$VOL":/build -v "$ROOT":/host:z gbos-kbuild bash -s <<EOF
set -e
cp /build/out/arch/x86/boot/bzImage /host/usb/out/BOOTX64.EFI
rm -rf /host/usb/modules
mkdir -p /host/usb/modules/lib
cp -a /build/modroot_fidebook/lib/modules /host/usb/modules/lib/
rm -f /host/usb/modules/lib/modules/*/build /host/usb/modules/lib/modules/*/source
rel=\$(cat /build/out/include/config/kernel.release)
[ -f /host/usb/modules/lib/modules/\$rel/modules.dep ] || { echo "module tree is not usb/modules/lib/modules/\$rel" >&2; exit 1; }
cat /build/out/Module.symvers /build/out/certs/signing_key.x509 | sha256sum | cut -d' ' -f1 > /host/usb/modules/lib/modules/\$rel/fidebook-build-id
for m in btusb btmtk btintel btrtl; do
  f=\$(find /build/modroot_fidebook/lib/modules/\$rel -name "\$m.ko" | head -1)
  [ -n "\$f" ] && cp "\$f" /host/usb/kmod/\$m.ko
done
chown -R $(id -u):$(id -g) /host/usb/modules /host/usb/kmod /host/usb/out/BOOTX64.EFI
EOF

echo "kernel:  usb/out/BOOTX64.EFI ($(wc -c < "$ROOT/usb/out/BOOTX64.EFI" | tr -d " ") bytes)"
echo "modules: $(find "$ROOT/usb/modules" -name '*.ko' | wc -l) in usb/modules/"
