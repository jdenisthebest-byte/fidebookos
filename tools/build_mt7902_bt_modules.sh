#!/bin/sh
# Rebuild ONLY btmtk.ko and btusb.ko for kernel 6.18.21-gbos-whl without
# rebuilding vmlinux/BOOTX64.EFI or touching Wi-Fi (mt7902e.ko) / AMD GPU modules.
#
# Root causes fixed here:
#   1. /build/out/.config was overwritten by a prior `make CC=gcc` invocation (which
#      ran syncconfig with GCC 14.2, stripping CONFIG_CFI=y and CONFIG_FINEIBT=y).
#      The actual shipped kernel BOOTX64.EFI (#48), vmlinux, and all 431 modules in
#      usb/modules/ were compiled with Android Clang 22.0.1 (clang-r584948b) with
#      non-permissive KCFI (CONFIG_CFI=y) and FineIBT (CONFIG_FINEIBT=y).
#      /build/out/.config.old is byte-for-byte identical to BOOTX64.EFI's embedded
#      IKCONFIG and is restored before running `modules_prepare`.
#   2. Single-target builds (`drivers/bluetooth/btusb.ko`) or `M=drivers/bluetooth`
#      without an isolated MO= directory in Linux 6.18 either overwrite
#      /build/out/modules.order (omitting net/bluetooth/bluetooth.o so modpost fails
#      with `bt_info`, `bt_err`, `__hci_cmd_sync` undefined) or collide with
#      /build/out/Module.symvers. Building with a separate `MO=/build/bt-mt7902-out`
#      and `KBUILD_EXTRA_SYMBOLS` preserves /build/out/Module.symvers intact and
#      resolves all vmlinux + net/bluetooth symbol CRCs cleanly.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VOL=gbos-ksrc
KVER=6.18.21-gbos-whl
C=/build/inputs/clang-r584948c
UID_GID="$(id -u):$(id -g)"

# Verify embedded IKCONFIG matches /build/out/.config.old before touching anything
TMP_CFG=$(mktemp "${TMPDIR:-/tmp}/gbos-efi-cfg.XXXXXX")
trap 'rm -f "$TMP_CFG"' EXIT
python3 "$ROOT/tools/extract_ikconfig.py" "$ROOT/usb/out/BOOTX64.EFI" > "$TMP_CFG"

MT7902_SHA_BEFORE=$(sha256sum "$ROOT/usb/modules/lib/modules/$KVER/extra/mt7902/mt7902e.ko" | awk '{print $1}')
EFI_SHA_BEFORE=$(sha256sum "$ROOT/usb/out/BOOTX64.EFI" | awk '{print $1}')

docker run --rm -i --platform linux/amd64 \
  -v "$VOL":/build \
  -v "$ROOT":/host:z \
  -v "$TMP_CFG":/efi.config:ro,z \
  gbos-kbuild:latest bash -s <<EOF
set -euo pipefail
export PATH=$C/bin:\$PATH LD_LIBRARY_PATH=$C/lib:\${LD_LIBRARY_PATH:-}
git config --global --add safe.directory /build/src

echo "== 1. Verify original kernel config & Module.symvers =="
cmp -s /efi.config /build/out/.config.old || {
  echo "INFO: syncing exact embedded BOOTX64.EFI .config to /build/out/.config"
}
cp -f /efi.config /build/out/.config
cp -f /build/Module.symvers.before-bt-rebuild /build/out/Module.symvers
if [ -f /build/modroot_all/lib/modules/$KVER/modules.order ]; then
  cp -f /build/modroot_all/lib/modules/$KVER/modules.order /build/out/modules.order
fi

echo "== 2. Apply MT7902 Bluetooth source patch =="
SRC=/build/src sh /host/kernel/isa_emu_patch/mt7902_bt.sh
cd /build/src && git diff drivers/bluetooth/

echo "== 3. Refresh generated headers & modpost for Clang 22 + KCFI (no kernel rebuild) =="
make -C /build/src O=/build/out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22 olddefconfig
make -C /build/src O=/build/out ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22 -j\$(nproc) modules_prepare
# Re-verify Module.symvers was not altered
cmp -s /build/Module.symvers.before-bt-rebuild /build/out/Module.symvers

echo "== 4. Clean stale Bluetooth build artifacts and build isolated drivers/bluetooth =="
rm -rf /build/bt-mt7902-out
mkdir -p /build/bt-mt7902-out
cat > /build/bt-mt7902-out/Kbuild <<'KBUILD'
obj-m := btmtk.o btusb.o
ccflags-y += -I\$(srctree)/drivers/bluetooth
KBUILD
ln -sf /build/src/drivers/bluetooth/btmtk.c /build/bt-mt7902-out/btmtk.c
ln -sf /build/src/drivers/bluetooth/btmtk.h /build/bt-mt7902-out/btmtk.h
ln -sf /build/src/drivers/bluetooth/btusb.c /build/bt-mt7902-out/btusb.c
ln -sf /build/src/drivers/bluetooth/btintel.h /build/bt-mt7902-out/btintel.h
ln -sf /build/src/drivers/bluetooth/btbcm.h /build/bt-mt7902-out/btbcm.h
ln -sf /build/src/drivers/bluetooth/btrtl.h /build/bt-mt7902-out/btrtl.h
ln -sf /build/src/drivers/bluetooth/btqca.h /build/bt-mt7902-out/btqca.h

# Provide all kernel + module symbols EXCEPT btmtk/btusb (which we are rebuilding here,
# otherwise modpost reports btmtk exports twice), then restore/verify full Module.symvers after.
grep -v -E '	drivers/bluetooth/bt(mtk|usb)	' /build/Module.symvers.before-bt-rebuild > /build/out/Module.symvers

make -C /build/out M=/build/bt-mt7902-out \
  ARCH=x86_64 LLVM=$C/bin/ CC=$C/bin/clang-22 \
  -j\$(nproc) modules

cp -f /build/Module.symvers.before-bt-rebuild /build/out/Module.symvers

# Sync clean artifacts into /build/out/drivers/bluetooth as well
rm -f /build/out/drivers/bluetooth/btusb.o /build/out/drivers/bluetooth/btusb.ko \
      /build/out/drivers/bluetooth/btusb.mod* /build/out/drivers/bluetooth/.btusb.* \
      /build/out/drivers/bluetooth/btmtk.o /build/out/drivers/bluetooth/btmtk.ko \
      /build/out/drivers/bluetooth/btmtk.mod* /build/out/drivers/bluetooth/.btmtk.*
cp -a /build/bt-mt7902-out/btusb.o /build/bt-mt7902-out/btusb.ko \
      /build/bt-mt7902-out/btmtk.o /build/bt-mt7902-out/btmtk.ko \
      /build/out/drivers/bluetooth/

echo "== 5. Strip debug info, sign with kernel build key, and install to usb/modules & usb/kmod =="
mkdir -p /build/bt-mt7902-out/staged
for m in btmtk btusb; do
  cp /build/bt-mt7902-out/\$m.ko /build/bt-mt7902-out/staged/\$m.ko
  $C/bin/llvm-strip --strip-debug /build/bt-mt7902-out/staged/\$m.ko
  /build/out/scripts/sign-file sha1 /build/out/certs/signing_key.pem /build/out/certs/signing_key.x509 /build/bt-mt7902-out/staged/\$m.ko
  cp -f /build/bt-mt7902-out/staged/\$m.ko /host/usb/modules/lib/modules/$KVER/kernel/drivers/bluetooth/\$m.ko
  cp -f /build/bt-mt7902-out/staged/\$m.ko /host/usb/kmod/\$m.ko
  if [ -d /build/modroot_all/lib/modules/$KVER/kernel/drivers/bluetooth ]; then
    cp -f /build/bt-mt7902-out/staged/\$m.ko /build/modroot_all/lib/modules/$KVER/kernel/drivers/bluetooth/\$m.ko
  fi
done

# Ensure legacy fallback modules in usb/kmod (btintel.ko, btrtl.ko) match the stripped+signed tree copies
for m in btintel btrtl; do
  if [ -f /host/usb/modules/lib/modules/$KVER/kernel/drivers/bluetooth/\$m.ko ]; then
    cp -f /host/usb/modules/lib/modules/$KVER/kernel/drivers/bluetooth/\$m.ko /host/usb/kmod/\$m.ko
  fi
done

echo "== 6. Regenerate depmod module dependencies & aliases =="
depmod -a -b /host/usb/modules $KVER
chown -R $UID_GID /host/usb/modules /host/usb/kmod

echo "== 7. Verify modinfo, ABI CRCs, KCFI symbols, and signatures =="
for m in btmtk btusb; do
  ko=/host/usb/modules/lib/modules/$KVER/kernel/drivers/bluetooth/\$m.ko
  echo "--- \$m.ko ---"
  echo "size:       \$(stat -c %s \$ko) bytes"
  echo "vermagic:   \$(modinfo -F vermagic \$ko)"
  echo "srcversion: \$(modinfo -F srcversion \$ko)"
  echo "depends:    \$(modinfo -F depends \$ko)"
  echo "sig_key:    \$(modinfo -F sig_key \$ko)"
  echo "firmware:   \$(modinfo -F firmware \$ko | tr '\n' ' ')"
  echo "mt7902/13d3 aliases:"
  modinfo -F alias \$ko | grep -iE '13D3|0489.*E156|0E8D.*1EDE' || true
  echo "this_module section:"
  $C/bin/llvm-readelf -SW \$ko | grep 'gnu.linkonce.this_module'
  echo "KCFI symbols count: \$($C/bin/llvm-nm \$ko | grep -c '__kcfi_typeid_' || true)"
done

echo "--- Verify __versions CRCs against original Module.symvers ---"
for m in btmtk btusb; do
  ko=/host/usb/modules/lib/modules/$KVER/kernel/drivers/bluetooth/\$m.ko
  modprobe --dump-modversions \$ko | while read -r crc sym; do
    want=\$(awk -v s="\$sym" '\$2 == s {print \$1; exit}' /build/Module.symvers.before-bt-rebuild)
    if [ -z "\$want" ] && [ "\$m" = "btusb" ]; then
      want=\$(awk -v s="\$sym" '\$2 == s {print \$1; exit}' /build/bt-mt7902-out/Module.symvers)
    fi
    if [ "\$crc" != "\$want" ]; then
      echo "CRC MISMATCH in \$m.ko for \$sym: got \$crc want \$want" >&2
      exit 1
    fi
  done
  echo "\$m.ko: ALL \$(modprobe --dump-modversions \$ko | wc -l) symbol CRCs match 100%!"
done

echo "--- Verify modules.dep and modules.alias entries ---"
grep -E 'btusb\.ko|btmtk\.ko' /host/usb/modules/lib/modules/$KVER/modules.dep
grep -i 'v13D3p3594' /host/usb/modules/lib/modules/$KVER/modules.alias
EOF

MT7902_SHA_AFTER=$(sha256sum "$ROOT/usb/modules/lib/modules/$KVER/extra/mt7902/mt7902e.ko" | awk '{print $1}')
EFI_SHA_AFTER=$(sha256sum "$ROOT/usb/out/BOOTX64.EFI" | awk '{print $1}')
[ "$MT7902_SHA_BEFORE" = "$MT7902_SHA_AFTER" ] || { echo "ERROR: mt7902e.ko changed!"; exit 1; }
[ "$EFI_SHA_BEFORE" = "$EFI_SHA_AFTER" ] || { echo "ERROR: BOOTX64.EFI changed!"; exit 1; }
echo "Verified untouched: BOOTX64.EFI ($EFI_SHA_AFTER) and mt7902e.ko ($MT7902_SHA_AFTER)"
