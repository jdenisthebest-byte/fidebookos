#!/bin/sh
# Unit tests for FideBookOS hardware-aware USB Bluetooth initialization (usb/hwdetect.sh).
# Runs under both host /bin/sh and stage0's busybox ash.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/fidebook-bt-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

PASS=0
ok() { PASS=$((PASS + 1)); echo "  PASS: $1"; }

run_suite() {
  echo "== Running Bluetooth init tests under $* =="
  "$@" -s "$ROOT" "$T" <<'SUITE'
set -eu
ROOT="$1"
BASE="$2"
rm -rf "$BASE/case"*

# Case 1: MediaTek MT7902 13d3:3594 with outdated stage0 btusb loaded -> unloads stale btusb,
#         unblocks rfkill, loads btmtk BEFORE btusb, verifies firmware, detects Device setup.
C="$BASE/case1"
mkdir -p "$C/sys/bus/usb/devices/1-2" "$C/sys/bus/usb/devices/1-2:1.0" "$C/sys/class/bluetooth/hci0" \
         "$C/sys/class/rfkill/rfkill0" "$C/sys/module/btusb" \
         "$C/fidebook/firmware/mediatek" "$C/fidebook/kmod" "$C/modroot/kernel/drivers/bluetooth"
echo "13d3" > "$C/sys/bus/usb/devices/1-2/idVendor"
echo "3594" > "$C/sys/bus/usb/devices/1-2/idProduct"
echo "ef"   > "$C/sys/bus/usb/devices/1-2/bDeviceClass"
echo "e0"   > "$C/sys/bus/usb/devices/1-2:1.0/bInterfaceClass"
echo "01"   > "$C/sys/bus/usb/devices/1-2:1.0/bInterfaceSubClass"
echo "01"   > "$C/sys/bus/usb/devices/1-2:1.0/bInterfaceProtocol"
echo "bluetooth" > "$C/sys/class/rfkill/rfkill0/type"
echo "1"         > "$C/sys/class/rfkill/rfkill0/soft"
: > "$C/sys/class/bluetooth/hci0/reset"
echo "OLD_STALE_SRCVER" > "$C/sys/module/btusb/srcversion"
printf 'btusb 16384 0 - Live 0x0\n' > "$C/proc_modules"
: > "$C/modroot/modules.dep"
cp "$ROOT/usb/kmod/btusb.ko" "$C/modroot/kernel/drivers/bluetooth/btusb.ko"
cp "$ROOT/usb/kmod/btmtk.ko" "$C/modroot/kernel/drivers/bluetooth/btmtk.ko"
echo "fwdata" > "$C/fidebook/firmware/mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin"
: > "$C/fwpath"
: > "$C/events.log"
: > "$C/fidebook.log"

G="$C/fidebook"
SYSFS="$C/sys"
PROC_MODULES="$C/proc_modules"
MODROOT="$C/modroot"
KVER_OVERRIDE="6.18.21-fidebook"
FIDEBOOK_FWPATH_OVERRIDE="$C/fwpath"
SLEEP_CMD=":"
log() { echo "$*" >> "$C/fidebook.log"; }
mock_modinfo() { echo "DA439E4151201D91CDBF78D"; }
mock_rmmod() {
  echo "rmmod:$1" >> "$C/events.log"
  grep -v "^$1 " "$C/proc_modules" > "$C/proc_modules.tmp" || true
  mv "$C/proc_modules.tmp" "$C/proc_modules"
}
mock_modprobe() {
  shift
  m=$(echo "$1" | tr '-' '_')
  echo "modprobe:$m" >> "$C/events.log"
  echo "$m 16384 0 - Live 0x0" >> "$C/proc_modules"
  [ "$m" = "btusb" ] && echo "DA439E4151201D91CDBF78D" > "$C/sys/module/btusb/srcversion"
  return 0
}
mock_dmesg() { echo "[    3.120000] Bluetooth: hci0: Device setup in 2763314 usecs"; }
MODINFO_CMD=mock_modinfo
RMMOD_CMD=mock_rmmod
MODPROBE_CMD=mock_modprobe
DMESG_CMD=mock_dmesg

. "$ROOT/usb/hwdetect.sh"

scan_out=$(fidebook_bt_usb_scan)
[ "$scan_out" = "13d3:3594:mtk7902" ] || { echo "unexpected scan: $scan_out" >&2; exit 1; }

fidebook_bt_init 2

grep -q '^rmmod:btusb$' "$C/events.log" || { echo "stale btusb was not unloaded" >&2; exit 1; }
ln_mtk=$(grep -n '^modprobe:btmtk$' "$C/events.log" | head -1 | cut -d: -f1)
ln_usb=$(grep -n '^modprobe:btusb$' "$C/events.log" | head -1 | cut -d: -f1)
[ -n "$ln_mtk" ] && [ -n "$ln_usb" ] && [ "$ln_mtk" -lt "$ln_usb" ] || { echo "btmtk did not load before btusb: $(cat "$C/events.log")" >&2; exit 1; }
[ "$(cat "$C/sys/class/rfkill/rfkill0/soft")" = "0" ] || { echo "rfkill was not unblocked" >&2; exit 1; }
[ "$(cat "$C/fwpath")" = "$C/fidebook/firmware" ] || { echo "firmware path not configured" >&2; exit 1; }
grep -q 'MT7902 firmware verified' "$C/fidebook.log" || { echo "MT7902 firmware check missing" >&2; exit 1; }
grep -q 'bt: ready (hci0): hci0: Device setup in 2763314 usecs' "$C/fidebook.log" || { echo "ready log missing: $(cat "$C/fidebook.log")" >&2; exit 1; }

ev_before=$(wc -l < "$C/events.log")
fidebook_bt_init 2
ev_after=$(wc -l < "$C/events.log")
[ "$ev_before" = "$ev_after" ] || { echo "duplicate module load occurred on second call!" >&2; exit 1; }

# Case 2: Intel 8087:0aaa compatibility preserved
C2="$BASE/case2"
mkdir -p "$C2/sys/bus/usb/devices/1-7" "$C2/sys/class/bluetooth/hci0" "$C2/sys/module/btusb" \
         "$C2/fidebook/firmware/intel" "$C2/modroot/kernel/drivers/bluetooth"
echo "8087" > "$C2/sys/bus/usb/devices/1-7/idVendor"
echo "0aaa" > "$C2/sys/bus/usb/devices/1-7/idProduct"
: > "$C2/proc_modules"; : > "$C2/modroot/modules.dep"; : > "$C2/events.log"; : > "$C2/fidebook.log"; : > "$C2/fwpath"
G="$C2/fidebook"; SYSFS="$C2/sys"; PROC_MODULES="$C2/proc_modules"; MODROOT="$C2/modroot"; FIDEBOOK_FWPATH_OVERRIDE="$C2/fwpath"
FIDEBOOK_BT_SETUP_DONE=""
mock_modprobe2() { shift; m=$(echo "$1" | tr '-' '_'); echo "modprobe:$m" >> "$C2/events.log"; echo "$m 1 0 - Live 0" >> "$C2/proc_modules"; }
mock_dmesg2() { echo "[    2.500000] Bluetooth: hci0: Firmware loaded in 1450123 usecs"; }
MODPROBE_CMD=mock_modprobe2
DMESG_CMD=mock_dmesg2
log() { echo "$*" >> "$C2/fidebook.log"; }

[ "$(fidebook_bt_usb_scan)" = "8087:0aaa:intel" ] || { echo "Intel scan failed" >&2; exit 1; }
fidebook_bt_init 2
grep -q '^modprobe:btintel$' "$C2/events.log" || { echo "btintel not loaded" >&2; exit 1; }
grep -q '^modprobe:btusb$' "$C2/events.log" || { echo "btusb not loaded for Intel" >&2; exit 1; }
grep -q 'Firmware loaded in 1450123 usecs' "$C2/fidebook.log" || { echo "Intel firmware loaded log missing" >&2; exit 1; }

# Case 3: Firmware initialization error detection
C3="$BASE/case3"
mkdir -p "$C3/sys/bus/usb/devices/1-2" "$C3/sys/class/bluetooth/hci0" "$C3/fidebook/firmware" "$C3/modroot"
echo "13d3" > "$C3/sys/bus/usb/devices/1-2/idVendor"
echo "3594" > "$C3/sys/bus/usb/devices/1-2/idProduct"
: > "$C3/proc_modules"; : > "$C3/modroot/modules.dep"; : > "$C3/fidebook.log"; : > "$C3/fwpath"
G="$C3/fidebook"; SYSFS="$C3/sys"; PROC_MODULES="$C3/proc_modules"; MODROOT="$C3/modroot"; FIDEBOOK_FWPATH_OVERRIDE="$C3/fwpath"
FIDEBOOK_BT_SETUP_DONE=""
mock_modprobe3() { shift; m=$(echo "$1" | tr '-' '_'); echo "$m 1 0 - Live 0" >> "$C3/proc_modules"; }
mock_dmesg3() { echo "[    4.100000] Bluetooth: hci0: Failed to set up firmware (-2)"; }
MODPROBE_CMD=mock_modprobe3
DMESG_CMD=mock_dmesg3
log() { echo "$*" >> "$C3/fidebook.log"; }

if fidebook_bt_init 1; then
  echo "expected fidebook_bt_init to return non-zero on firmware error" >&2
  exit 1
fi
grep -q 'bt: ERROR: MT7902 firmware missing' "$C3/fidebook.log" || { echo "missing firmware pre-check not logged" >&2; exit 1; }
grep -q 'bt: ERROR during firmware/controller init.*Failed to set up firmware (-2)' "$C3/fidebook.log" || { echo "dmesg firmware error not logged" >&2; exit 1; }
SUITE
}

run_suite /bin/sh
ok "host /bin/sh: MT7902 13d3:3594, stale btusb replacement, btmtk-before-btusb order, rfkill unblock, dedup, Intel 8087:0aaa, error detection"

if [ -x "$ROOT/kernel/out/busybox" ]; then
  run_suite "$ROOT/kernel/out/busybox" sh
  ok "stage0 busybox ash: all Bluetooth initialization checks pass"
fi

echo "BT_INIT_TEST_PASS ($PASS suites)"
