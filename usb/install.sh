# FideBookOS Graphical & Accessible Installer/Updater for NVMe, eMMC, and SATA internal drives.
# Sourced by stage0 for boot menu choice 2 (or fidebook.cfg MODE=install), with the USB stick mounted at /fidebook ($G=/fidebook/fidebook).
#
# Clean-install partition layout:
#   p1 FIDE_EFI    512 MiB FAT32, EFI system partition: EFI/BOOT/BOOTX64.EFI
#   p2 FIDESYS       8 GiB FAT32: fidebook/ OS payload (super.img, hook.sh, branding, firmware, modules, ...)
#   p3 FIDE_META    64 MiB ext4 : Android /metadata
#   p4 FIDE_DATA    rest   ext4 : Android /data
#
# Safety rule: Nothing is erased until the user types the target drive's exact hardware serial number on the laptop keyboard.

I=$G/installer
tool() { $I/lib/ld-musl-x86_64.so.1 --library-path $I/lib $I/bin/"$@"; }
TTY=/dev/tty1
SPEECH=0; [ -f /a11y/active ] && SPEECH=1

GUI=
for _gp in /bin/fidebook-gui $I/bin/fidebook-gui; do
  [ -x "$_gp" ] && GUI="$_gp" && break
done
CONFIRM_CMDLINE=$(sed -n 's/.*fidebook_install_confirm=\([^ ]*\).*/\1/p' /proc/cmdline)
USE_GUI=0
[ -n "$GUI" ] && [ "$SPEECH" = 0 ] && [ -z "$CONFIRM_CMDLINE" ] && USE_GUI=1

PROG_STATE=/tmp/fidebook_progress.state
PROG_PID=

gui_progress_start() {
  [ "$USE_GUI" = 1 ] || return 0
  [ -n "$PROG_PID" ] && kill -0 "$PROG_PID" 2>/dev/null && return 0
  printf '2\n%s\n%s\n' "${1:-Preparing installation...}" "${2:-Initializing FideBookOS installer}" > "$PROG_STATE"
  "$GUI" progress "$PROG_STATE" &
  PROG_PID=$!
}

gui_progress_update() {
  # $1=pct (0..100), $2=heading, $3=detail
  [ -n "$PROG_PID" ] && kill -0 "$PROG_PID" 2>/dev/null || return 0
  printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$PROG_STATE.tmp" && mv -f "$PROG_STATE.tmp" "$PROG_STATE"
}

gui_progress_stop() {
  if [ -n "$PROG_PID" ] && kill -0 "$PROG_PID" 2>/dev/null; then
    printf '%s\nDone\n\n' "${1:-DONE}" > "$PROG_STATE.tmp" && mv -f "$PROG_STATE.tmp" "$PROG_STATE"
    wait "$PROG_PID" 2>/dev/null || kill "$PROG_PID" 2>/dev/null || true
  fi
  PROG_PID=
}

say() {
  if [ -z "$PROG_PID" ] || ! kill -0 "$PROG_PID" 2>/dev/null; then
    case "$*" in ======*) [ $SPEECH = 1 ] || echo "$*" > $TTY;; *) echo "$*" > $TTY;; esac
  fi
  _uptime_s=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
  echo "[${_uptime_s}s] $*" >> $L/install.log
}

ask() { printf '%s' "$1" > $TTY; read -r REPLY < $TTY; echo "$1$REPLY" >> $L/install.log; }

halt_here() {
  gui_progress_stop ERROR
  say ""
  say "$1"
  if [ "$USE_GUI" = 1 ]; then
    "$GUI" message error "FideBookOS Installer" "$1" "Log saved to fidebook/logs/boot-$N/install.log" "Reboot Now" || true
  else
    ask "Press Enter to reboot (or turn off power now): "
  fi
  sync
  reboot -f
  # A failed reboot must never fall through into partitioning after cancellation.
  exit 1
}

save_logs() {
  mkdir -p $L/nvme-logs
  for b in $(ls $1/logs 2>/dev/null | sort -t- -k2 -n | tail -n ${2:-3}); do
    say "  $b"
    (cd $1/logs && find $b -type d) | while read d; do mkdir -p $L/nvme-logs/$d; done
    (cd $1/logs && find $b -type f) | while read f; do
      cp $1/logs/$f $L/nvme-logs/$f 2>/dev/null || dd if=$1/logs/$f of=$L/nvme-logs/$f bs=4k conv=noerror,sync 2>/dev/null
    done
  done
  sync
}

die() { halt_here "INSTALL FAILED: $*"; }
check() { cmp -s "$1" "$2" || die "verify failed: $2"; echo "ok $2" >> $L/install.log; }

STAMPED="super.img firmware modules"
stamp_of() { _l=$(find "$G/$1" -type f -exec stat -c '%n %s %Y' {} + 2>/dev/null | sort); [ -n "$_l" ] || return 1; printf '%s\n' "$_l" | sha256sum | cut -d' ' -f1; }
stamp_same() { [ -z "$UPDATE_FULL" ] && [ -f /mnt/nsys/fidebook/.stamps/$1 ] && _s=$(stamp_of $1) && [ "$(cat /mnt/nsys/fidebook/.stamps/$1)" = "$_s" ]; }
stamp_save() { _s=$(stamp_of $1) && mkdir -p /mnt/nsys/fidebook/.stamps && printf '%s\n' "$_s" > /mnt/nsys/fidebook/.stamps/$1; }
is_skipped() { case " $SKIP " in *" $1 "*) return 0;; esac; return 1; }

write_installed_cfg() {
  grep -v -e '^MODE=' -e '^ACTION=' $G/fidebook.cfg > /mnt/nsys/fidebook/fidebook.cfg
  echo 'MODE=boot' >> /mnt/nsys/fidebook/fidebook.cfg
}

echo "1 1 1 1" > /proc/sys/kernel/printk 2>/dev/null || true
dmesg -n 1 2>/dev/null || true
chvt 1 2>/dev/null
[ "$USE_GUI" = 1 ] || clear > $TTY 2>/dev/null
say "=============================================================="
say " FideBookOS 1.25 Installer"
say "=============================================================="

# Refresh input event nodes for graphical mouse/touchpad/keyboard navigation
mkdir -p /dev/input
for _ev in /sys/class/input/event*; do
  [ -f "$_ev/dev" ] || continue
  _en=${_ev##*/}; _ed=$(cat "$_ev/dev")
  [ -c "/dev/input/$_en" ] || mknod -m 0660 "/dev/input/$_en" c ${_ed%:*} ${_ed#*:} 2>/dev/null || true
done

STICKDISK=$(basename $(readlink -f /sys/class/block/${DEV##*/}/..))
EFIPART=$(tool sfdisk -d /dev/$STICKDISK 2>/dev/null | awk 'toupper($0) ~ /TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ {print $1; exit}')
[ -b "$EFIPART" ] || EFIPART=$(findfs LABEL=FIDE_EFI 2>/dev/null)
[ -b "$EFIPART" ] || EFIPART=$(findfs LABEL=EFI 2>/dev/null)
[ -b "$EFIPART" ] || EFIPART=/dev/$(ls /sys/class/block/$STICKDISK | grep -m1 "^${STICKDISK}p\?1$")
mkdir -p /mnt/stickefi && mount -t vfat -o ro $EFIPART /mnt/stickefi 2>/dev/null \
  || die "cannot mount the USB drive's EFI partition ($EFIPART)"
KERNEL=""
for k in /mnt/stickefi/EFI/fidebookos/BOOTX64.EFI /mnt/stickefi/EFI/BOOT/BOOTX64.EFI /fidebook/EFI/BOOT/BOOTX64.EFI $G/../EFI/BOOT/BOOTX64.EFI; do
  [ -f "$k" ] && KERNEL="$k" && break
done
[ -f "$KERNEL" ] || die "missing EFI/BOOT/BOOTX64.EFI on the USB EFI partition"
mkdir -p /tmp && cp "$KERNEL" /tmp/BOOTX64.EFI && KERNEL=/tmp/BOOTX64.EFI
umount /mnt/stickefi 2>/dev/null || true

FILES="super.img super.layout hook.sh oobe_apply.sh optimize.sh aidiag.sh play_diagnostics.sh native_zygote.sh early_patch.sh hwdetect.sh install.sh apex_patch.sh crossystem bootdisk.img libkm_compat.so system_ext_manifest.xml soft_gk"
DIRS="firmware patched branding audio installer kmod modules surface ksu"
for helper in user_context.sh boot_policy.sh; do
  if [ -f "$G/$helper" ] || grep -Fq "$helper" "$G/hook.sh" "$G/optimize.sh" "$G/oobe_apply.sh"; then FILES="$FILES $helper"; fi
done
[ ! -d "$G/a11y" ] || DIRS="$DIRS a11y"
PAYLOAD_FILES="patched/MANIFEST audio/gen_config.sh audio/mixdiag.sh audio/audio_default.xml audio/fidebook-hda-pch/audio_config.xml audio/fidebook-hda-pch/mixer_paths.xml installer/bin/sfdisk installer/bin/mkfs.fat installer/bin/mke2fs installer/bin/e2fsck installer/bin/partx installer/bin/blkid installer/bin/fidebook-gui installer/lib/ld-musl-x86_64.so.1 ksu/install.sh ksu/ksud ksu/manager.apk surface/iptsd-run.sh surface/surface-camera.sh surface/sleep-guard.sh branding/bootanimation.zip branding/wallpaper.jpg branding/app/FideBookSetup.apk branding/app/FideBookVisualSettings.apk branding/overlays/FideBookLauncherOverlay.apk branding/overlays/FideBookSettingsOverlay.apk branding/overlays/FideBookGlassFrameworkOverlay.apk branding/overlays/FideBookGlassLauncherOverlay.apk branding/overlays/FideBookGlassSystemUIOverlay.apk"
validate_payload() {
  for f in $FILES fidebook.cfg; do [ -s "$G/$f" ] && [ -r "$G/$f" ] || die "missing, empty or unreadable fidebook/$f on the USB drive"; done
  for d in $DIRS; do [ -d "$G/$d" ] && [ -n "$(find "$G/$d" -type f | head -n 1)" ] || die "missing or empty fidebook/$d/ on the USB drive"; done
  for f in $PAYLOAD_FILES; do [ -s "$G/$f" ] || die "missing required runtime payload fidebook/$f"; done
  [ -n "$(find "$G/modules" -name modules.dep -type f | head -n 1)" ] || die "missing modules.dep on the USB drive"
  while read -r kind target hash payload rest; do
    case "$kind" in early|bind|apex)
      [ -n "$payload" ] && [ -z "$rest" ] || die "malformed patched/MANIFEST entry: $kind $target"
      case "/$payload/" in *'/../'*|*'/./'*|*'//'*) die "unsafe patched/MANIFEST payload: $payload";; esac
      [ -s "$G/$payload" ] || die "missing patched/MANIFEST payload fidebook/$payload";;
    esac
  done < "$G/patched/MANIFEST"
  [ -s /fidebook/busybox ] || die "missing busybox on the USB drive"
  tool sfdisk --version > /dev/null 2>&1 || die "partitioning tools in fidebook/installer/ failed to execute"
}
case "${ACTION:-}" in ''|install|update|logs) ;; *) die "invalid ACTION=$ACTION (expected install, update or logs)";; esac

internal_efi() {
  [ -b "$1" ] || return 0
  _d=/dev/$(basename "$(readlink -f /sys/class/block/$(basename $1)/..)")
  # Never fall back to a globally-labelled ESP: that could be the installer stick
  # or another OS disk. Only the disk containing this FIDESYS may supply its ESP.
  _e=$(tool sfdisk -d $_d 2>/dev/null | awk 'toupper($0) ~ /TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ {print $1; exit}')
  echo "$_e"
}

NSYS=$(findfs LABEL=FIDESYS 2>/dev/null)
NEFI=$(internal_efi $NSYS)
NDATA=$(findfs LABEL=FIDE_DATA 2>/dev/null)

if [ -z "$ACTION" ] && [ -n "$NSYS" ]; then
  if [ "$USE_GUI" = 1 ]; then
    REPLY=$("$GUI" menu 1 0 "FideBookOS Installer" "Existing FideBookOS installation detected on internal SSD" \
      "Update Existing FideBookOS|Keep all apps, accounts & files; update OS, kernel & drivers" \
      "Clean Reinstall|Erase internal drive and install FideBookOS fresh (serial required)" \
      "Save Diagnostic Logs Only|Copy last 3 boot logs to USB without modifying SSD" \
      "Cancel & Reboot|Exit installer without making any changes") || REPLY=4
  else
    say "Found an existing FideBookOS install on the internal disk."
    say "  1) Update it: keep apps, accounts and settings; save its logs to this USB"
    say "  2) Reinstall: ERASE the disk and install from scratch"
    say "  3) Only save its logs to this USB (nothing on the disk is changed)"
    say "  anything else: cancel"
    ask "choice> "
  fi
  case "$REPLY" in 1) ACTION=update;; 2) ACTION=install;; 3) ACTION=logs;; *) halt_here "Cancelled. Nothing was written.";; esac
fi

if [ "$ACTION" = logs ]; then
  [ -n "$NSYS" ] || die "no FideBookOS install found (FIDESYS missing)"
  mkdir -p /mnt/nsys
  mount -t vfat -o ro $NSYS /mnt/nsys || die "mount FIDESYS failed"
  [ -d /mnt/nsys/fidebook/logs ] || die "installed system has no fidebook/logs"
  gui_progress_start "Saving Diagnostic Logs..." "Copying recent SSD logs to USB"
  save_logs /mnt/nsys/fidebook ${LOG_BOOTS:-3}
  umount /mnt/nsys; sync
  gui_progress_stop DONE
  log "install: logs saved"; sync
  if [ "$USE_GUI" = 1 ]; then
    "$GUI" message done "Logs Saved" "Saved to fidebook/logs/boot-$N/nvme-logs on USB." "Remove USB drive and press Enter to power off." "Power Off" || true
  else
    say "Logs saved. Remove the USB stick and turn the laptop back on."
    ask "Press Enter to power off. "
  fi
  poweroff -f
fi

# Log recovery above remains available even with an incomplete installer payload.
# Update/install must have every startup dependency before changing the installed OS.
validate_payload

if [ "${ACTION:-install}" = update ]; then
  NSYS=$(findfs LABEL=FIDESYS 2>/dev/null)
  NEFI=$(internal_efi $NSYS)
  [ -n "$NSYS" ] && [ -n "$NEFI" ] || die "no FideBookOS install found (FIDESYS/EFI missing)"
  mkdir -p /mnt/nsys /mnt/nefi
  mount -t vfat -o noatime $NSYS /mnt/nsys || die "mount FIDESYS failed"
  mount -t vfat $NEFI /mnt/nefi || die "mount EFI failed"
  SHARED_EFI=0; [ -f /mnt/nefi/EFI/fidebookos/BOOTX64.EFI ] && SHARED_EFI=1
  [ "$NEFI" = "$(findfs LABEL=FIDE_EFI 2>/dev/null)" ] || [ $SHARED_EFI = 1 ] || die "$NEFI is not a FideBookOS EFI partition; nothing was changed"
  gui_progress_start "Updating FideBookOS..." "Backing up recent logs & preserving /data"
  save_logs /mnt/nsys/fidebook 3
  SKIP=""
  _fi=0
  for f in $FILES; do
    _fi=$((_fi + 1))
    gui_progress_update $((10 + _fi * 3)) "Updating System Files..." "Checking $f"
    case " $STAMPED " in *" $f "*) if stamp_same $f; then SKIP="$SKIP $f"; say "  $f unchanged, skipped"; continue; fi;; esac
    cmp -s $G/$f /mnt/nsys/fidebook/$f || { say "  $f"; cp $G/$f /mnt/nsys/fidebook/$f || die "copy $f failed"; }
  done
  _di=0
  for d in $DIRS; do
    _di=$((_di + 1))
    gui_progress_update $((45 + _di * 4)) "Updating Drivers & Branding..." "Syncing $d/"
    case " $STAMPED " in *" $d "*) if stamp_same $d; then SKIP="$SKIP $d"; say "  $d/ unchanged, skipped"; continue; fi;; esac
    say "  $d/"; rm -rf /mnt/nsys/fidebook/$d; (cd "$G" && tar -cf - "$d") | (cd /mnt/nsys/fidebook && tar -xf -) || cp -r "$G/$d" /mnt/nsys/fidebook/ || die "copy $d/ failed"
  done
  gui_progress_update 85 "Updating Bootloader & Kernel..." "Installing BOOTX64.EFI"
  if [ $SHARED_EFI = 1 ]; then
    cmp -s $KERNEL /mnt/nefi/EFI/fidebookos/BOOTX64.EFI || cp $KERNEL /mnt/nefi/EFI/fidebookos/BOOTX64.EFI || die "copy kernel failed"
  else
    cmp -s $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI || cp $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI || die "copy kernel failed"
  fi
  mkdir -p /mnt/nsys/EFI/BOOT
  cp "$KERNEL" /mnt/nsys/EFI/BOOT/BOOTX64.EFI || die "copy FIDESYS kernel failed"
  cp /fidebook/busybox /mnt/nsys/busybox || die "copy busybox failed"
  cp "$G/installer/bin/fidebook-gui" /mnt/nsys/fidebook-gui || die "copy graphical installer failed"
  write_installed_cfg
  sync; echo 3 > /proc/sys/vm/drop_caches
  gui_progress_update 92 "Verifying Integrity..." "Checking installed files against source"
  if [ $SHARED_EFI = 1 ]; then check $KERNEL /mnt/nefi/EFI/fidebookos/BOOTX64.EFI; else check $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI; fi
  check "$KERNEL" /mnt/nsys/EFI/BOOT/BOOTX64.EFI
  check /fidebook/busybox /mnt/nsys/busybox
  check "$G/installer/bin/fidebook-gui" /mnt/nsys/fidebook-gui
  for f in $FILES; do is_skipped $f || check $G/$f /mnt/nsys/fidebook/$f; done
  for d in $DIRS; do is_skipped $d && continue; (cd $G && find $d -type f) | while read f; do check $G/$f /mnt/nsys/fidebook/$f; done || exit 1; done || die "verify failed"
  for i in $STAMPED; do stamp_save $i || true; done
  umount /mnt/nefi /mnt/nsys /mnt/stickefi 2>/dev/null || true; sync
  gui_progress_stop DONE
  log "install: update complete"; sync
  if [ "$USE_GUI" = 1 ]; then
    "$GUI" message done "FideBookOS Updated!" "Your apps and files were preserved." "Remove the USB drive and press Enter to power off." "Power Off" || true
  else
    say "Update done. Remove the USB stick and turn the laptop back on."
    ask "Press Enter to power off. "
  fi
  poweroff -f
fi

if ! ls /sys/block | grep -q '^mmcblk'; then
  KVER=$(uname -r)
  KMOD="$G/modules/lib/modules/$KVER"
  [ -d "$KMOD" ] || KMOD="$G/modules/lib/modules/${KVER}+"
  [ -d "$KMOD" ] || KMOD="$G/modules/lib/modules/${KVER%+}"
  [ -f "$KMOD/modules.dep" ] && ! mountpoint -q /lib/modules 2>/dev/null && mount --bind "$G/modules/lib/modules" /lib/modules 2>/dev/null
  modprobe -q sdhci-pci 2>/dev/null && log "install: sdhci-pci loaded"
fi

is_sata() { case "$(readlink -f /sys/block/$1 2>/dev/null)" in */ata[0-9]*/host*) return 0;; esac; return 1; }
fast_disks() {
  for n in $(ls /sys/block | grep -E '^(nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$'); do
    [ "$n" = "$STICKDISK" ] && continue
    case $n in mmcblk*) [ "$(cat /sys/block/$n/device/type 2>/dev/null)" = MMC ] || continue;; esac
    echo $n
  done
}
sata_disks() {
  for n in $(ls /sys/block | grep -E '^sd[a-z]+$'); do
    [ "$n" = "$STICKDISK" ] && continue
    is_sata $n && echo $n
  done
}
internal_disks() {
  _f=$(fast_disks)
  _s=$(sata_disks)
  _all=""
  for _d in $_f $_s; do _all="$_all $_d"; done
  # The installer medium is never an implicit fallback installation target.
  echo "$_all" | sed 's/^[ \t]*//; s/[ \t]*$//'
}

for i in 1 2 3 4 5 6 7 8 9 10; do mdev -s; [ -n "$(internal_disks)" ] && break; sleep 1; done
set -- $(internal_disks)
[ $# -ge 1 ] || [ -n "$INSTALL_DISK" ] || die "no internal NVMe, eMMC, or SATA disk found"
if [ -n "$INSTALL_DISK" ]; then
  case " $(internal_disks) " in *" $INSTALL_DISK "*) set -- $INSTALL_DISK;; *) die "INSTALL_DISK=$INSTALL_DISK is not available ($(internal_disks))";; esac
elif [ $# -gt 1 ]; then
  if [ "$USE_GUI" = 1 ]; then
    set -- $(internal_disks)
    _d1=$1; _d2=$2
    _s1=$(( $(cat /sys/block/$_d1/size 2>/dev/null || echo 0) * 512 / 1000000000 ))
    _m1=$(cat /sys/block/$_d1/device/model 2>/dev/null || cat /sys/block/$_d1/device/name 2>/dev/null || echo "$_d1")
    _s2=$(( $(cat /sys/block/$_d2/size 2>/dev/null || echo 0) * 512 / 1000000000 ))
    _m2=$(cat /sys/block/$_d2/device/model 2>/dev/null || cat /sys/block/$_d2/device/name 2>/dev/null || echo "$_d2")
    _sel=$("$GUI" menu 1 0 "Select Target Drive" "Choose where to install FideBookOS" \
      "/dev/$_d1 (${_s1} GB)|$(echo $_m1 | sed 's/^ *//; s/ *$//')" \
      "/dev/$_d2 (${_s2} GB)|$(echo $_m2 | sed 's/^ *//; s/ *$//')" \
      "Cancel Installation|Exit without modifying any drive") || _sel=3
    case "$_sel" in 1|2) ;; *) halt_here "Cancelled. Nothing was written.";; esac
    set -- $(internal_disks)
    if [ "$_sel" = 1 ]; then set -- "$1"; else set -- "$2"; fi
  else
    say "Available disks for installation:"
    _idx=1
    for _d in $*; do
      _sz=$(( $(cat /sys/block/$_d/size 2>/dev/null || echo 0) * 512 / 1000000000 ))
      _lbl=$(cat /sys/block/$_d/device/model 2>/dev/null || cat /sys/block/$_d/device/name 2>/dev/null || echo "$_d")
      say "  $_idx) /dev/$_d (${_sz} GB - $(echo $_lbl | sed 's/^ *//; s/ *$//'))"
      _idx=$((_idx + 1))
    done
    ask "Choose target disk [1-$#, default: 1]: "
    _sel=${REPLY:-1}
    case "$_sel" in ''|*[!0-9]*) halt_here "Invalid disk selection. Nothing was written.";; esac
    [ "${#_sel}" -le 3 ] && [ "$_sel" -ge 1 ] && [ "$_sel" -le $# ] || halt_here "Invalid disk selection. Nothing was written."
    _idx=1
    for _d in "$@"; do
      if [ "$_idx" -eq "$_sel" ]; then set -- "$_d"; break; fi
      _idx=$((_idx + 1))
    done
  fi
fi

T=$1; TD=/dev/$T
CTRL=/sys/block/$T/device
case $T in
  mmcblk*)
    KIND=eMMC
    MODEL="$(cat $CTRL/name 2>/dev/null | sed 's/ *$//') (eMMC)"
    SERIAL=$(cat $CTRL/serial 2>/dev/null | sed 's/^ *//; s/ *$//')
    case "$SERIAL" in ''|0|0x0|0x00000000) SERIAL=$(cat $CTRL/cid 2>/dev/null | sed 's/ //g');; esac;;
  sd*)
    KIND=SATA
    case "$(readlink -f /sys/block/$T 2>/dev/null)" in *"/usb"*) KIND=USB;; esac
    MODEL="$(cat $CTRL/vendor 2>/dev/null | sed 's/ *$//') $(cat $CTRL/model 2>/dev/null | sed 's/ *$//')"
    SERIAL=$(tail -c +5 $CTRL/vpd_pg80 2>/dev/null | tr -d '\000' | tr -c '[:print:]' ' ' | sed 's/^ *//; s/ *$//')
    if [ -z "$SERIAL" ]; then
      WWID=$(cat $CTRL/wwid 2>/dev/null | sed 's/^ *//; s/ *$//')
      case "$WWID" in
        t10.ATA*) _r=$(printf '%s' "${WWID#t10.ATA}" | sed 's/^ *//; s/ *$//'); SERIAL=$(printf '%s' "$_r" | awk '{print $NF}'); MODEL="ATA $(printf '%s' "$_r" | sed 's/ *[^ ]*$//')";;
        *) SERIAL=$WWID;;
      esac
    fi
    if [ -z "$SERIAL" ]; then
      for _sfile in "$CTRL/../../serial" "$CTRL/../../../serial" "$CTRL/../../../../serial"; do
        [ -f "$_sfile" ] && SERIAL=$(cat "$_sfile" 2>/dev/null | sed 's/^ *//; s/ *$//') && [ -n "$SERIAL" ] && break
      done
    fi
    [ -n "$SERIAL" ] || SERIAL=$(tool blkid -s PTUUID -o value /dev/$T 2>/dev/null || true)
    [ -n "$SERIAL" ] || SERIAL="DISK-$T"
    ;;
  *)
    KIND=NVMe
    MODEL=$(cat $CTRL/model 2>/dev/null | sed 's/ *$//'); SERIAL=$(cat $CTRL/serial 2>/dev/null | sed 's/^ *//; s/ *$//');;
esac
SIZE=$(( $(cat /sys/block/$T/size) * 512 )); GB=$(( SIZE / 1000000000 ))
[ -n "$SERIAL" ] || die "cannot read the serial number of $T"
[ $GB -ge 24 ] || die "$T is only ${GB} GB; FideBookOS needs at least 24 GB"

say "=============================================================="
say " Target Disk: $TD ($KIND) - $MODEL (${GB} GB)"
say "   Serial: $SERIAL"
[ $SPEECH = 1 ] && say "   Serial, one character at a time: $(printf '%s' "$SERIAL" | sed 's/./&, /g')"
say "=============================================================="

CURRENT_PARTS=$(ls /sys/block/$T | grep "^${T}p\?[0-9]")
INSTALL_MODE=clean
free_mb=0
if [ -n "$CURRENT_PARTS" ]; then
  part_sectors=0
  for p in $CURRENT_PARTS; do
    sz_sec=$(cat /sys/block/$T/$p/size 2>/dev/null || echo 0)
    part_sectors=$(( part_sectors + sz_sec ))
  done
  tot_sec=$(cat /sys/block/$T/size 2>/dev/null || echo 0)
  free_sec=$(( tot_sec - part_sectors ))
  [ $free_sec -gt 0 ] && free_mb=$(( free_sec / 2048 ))
  free_gb=$(( free_mb / 1024 ))

  case "$FIDEBOOK_INSTALL_MODE" in
    dualboot|clean) REPLY=$FIDEBOOK_INSTALL_MODE; say "(mode from fidebook.cfg: $REPLY)";;
    *)
      if [ "$USE_GUI" = 1 ]; then
        REPLY=$("$GUI" menu 1 0 "FideBookOS Graphical Installer" "Target: $TD ($MODEL, ${GB} GB, ~${free_gb} GB unallocated)" \
          "Dual-Boot alongside existing OS (Recommended)|Install into ~${free_gb} GB unallocated free space; keep Windows/Linux intact" \
          "Clean Install — Erase Entire Drive|Wipe all partitions on $TD and dedicate full ${GB} GB to FideBookOS" \
          "Try FideBookOS Live Desktop Instead|Boot into FideBookOS Live session in RAM without touching $TD" \
          "Cancel & Reboot|Exit installer safely without writing to disk") || REPLY=4
      else
        say "Choose Installation Mode:"
        say "  1) Dual-Boot (Recommended): Keep existing OS; install into free space (~${free_gb} GB)"
        say "  2) Full clean install: ERASE ENTIRE DISK ($TD)"
        say "  3) Start Live Desktop"
        say "  anything else: Cancel"
        ask "choice [1/2/3]> "
      fi
      ;;
  esac
  case "$REPLY" in
    1|dualboot|dual-boot) INSTALL_MODE=dualboot;;
    2|clean|erase) INSTALL_MODE=clean;;
    3|live)
      sed -i 's/^MODE=.*/MODE=live/' $G/fidebook.cfg 2>/dev/null || true
      sync; reboot -f;;
    *) halt_here "Cancelled. Nothing was written to $TD.";;
  esac
fi

if [ "$INSTALL_MODE" = clean ]; then
  [ "$T" = "$STICKDISK" ] && halt_here "Cannot clean-erase the USB installer media ($TD)."
  if [ -n "$CONFIRM_CMDLINE" ]; then
    REPLY=$CONFIRM_CMDLINE; say "(serial taken from QEMU kernel cmdline: $REPLY)"
  elif [ "$USE_GUI" = 1 ]; then
    REPLY=$("$GUI" serial "$TD ($KIND) - $MODEL (${GB} GB)" \
      "WARNING: ALL PARTITIONS AND FILES ON $TD WILL BE PERMANENTLY ERASED!" "$SERIAL") || REPLY=""
  else
    say "EVERYTHING ON THIS DISK WILL BE ERASED."
    say "To continue, type the serial number ($SERIAL) exactly as shown:"
    ask "serial> "
  fi
  [ "$REPLY" = "$SERIAL" ] || halt_here "Cancelled. Nothing was written to $TD."

  gui_progress_start "Partitioning & Formatting $TD..." "Creating FideBookOS GPT layout"
  if [ -n "$NSYS" ] && mkdir -p /mnt/oldsys && mount -t vfat -o ro $NSYS /mnt/oldsys 2>/dev/null; then
    mkdir -p $L/nvme-logs
    for b in $(ls /mnt/oldsys/fidebook/logs 2>/dev/null | sort -t- -k2 -n | tail -3); do cp -r /mnt/oldsys/fidebook/logs/$b $L/nvme-logs/ 2>/dev/null; done
    umount /mnt/oldsys
  fi

  say "Erasing and partitioning $TD ..."
  for p in $(ls /sys/block/$T | grep "^${T}p\?[0-9]"); do umount /dev/$p 2>/dev/null; done
  dd if=/dev/zero of=$TD bs=1M count=16 conv=fsync 2>/dev/null
  dd if=/dev/zero of=$TD bs=1M count=16 seek=$(( SIZE / 1048576 - 16 )) conv=fsync 2>/dev/null
  tool sfdisk --wipe always --wipe-partitions always $TD >> $L/install.log 2>&1 <<EOF || die "sfdisk failed"
label: gpt
size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="FIDE_EFI"
size=8GiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="FIDESYS"
size=64MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="FIDE_META"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="FIDE_DATA"
EOF
  blockdev --rereadpt $TD 2>/dev/null; sleep 2; mdev -s
  case $T in *[0-9]) P=${TD}p;; *) P=$TD;; esac
  for i in 1 2 3 4; do [ -b $P$i ] || { sleep 2; mdev -s; }; [ -b $P$i ] || die "partition $P$i did not appear"; done
  tool sfdisk -l $TD >> $L/install.log 2>&1

  gui_progress_update 8 "Formatting FideBookOS Partitions..." "FAT32 EFI/System + ext4 Metadata/Data"
  say "Formatting ..."
  tool mkfs.fat -F 32 -n FIDE_EFI ${P}1 >> $L/install.log 2>&1 || die "mkfs FIDE_EFI failed"
  tool mkfs.fat -F 32 -n FIDESYS ${P}2 >> $L/install.log 2>&1 || die "mkfs FIDESYS failed"
  NODISCARD=; [ -n "$CONFIRM_CMDLINE" ] && NODISCARD="-E nodiscard"
  tool mke2fs -F -q -t ext4 $NODISCARD -L FIDE_META ${P}3 >> $L/install.log 2>&1 || die "mkfs FIDE_META failed"
  tool mke2fs -F -q -t ext4 $NODISCARD -L FIDE_DATA -m 0 -O verity ${P}4 >> $L/install.log 2>&1 || die "mkfs FIDE_DATA failed"
  tool e2fsck -fn ${P}3 >> $L/install.log 2>&1 || die "fsck FIDE_META failed"
  tool e2fsck -fn ${P}4 >> $L/install.log 2>&1 || die "fsck FIDE_DATA failed"
  TARGET_EFI=${P}1
  TARGET_SYS=${P}2
else
  say "Dual-boot on $TD (existing partitions are kept) ..."
  [ -z "$(findfs LABEL=FIDESYS 2>/dev/null)$(findfs LABEL=FIDE_DATA 2>/dev/null)" ] \
    || die "a FideBookOS install already exists: choose Update or Clean Install"
  tool sfdisk -d $TD 2>/dev/null | grep -q '^label: gpt' || die "dual-boot requires a GPT disk ($TD)"
  TARGET_EFI=$(tool sfdisk -d $TD 2>/dev/null | awk 'toupper($0) ~ /TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ {print $1; exit}')
  # An ESP on another disk (especially the USB stick) must never be selected.
  [ -n "$TARGET_EFI" ] && [ -b "$TARGET_EFI" ] || die "no EFI system partition found on $TD"
  mkdir -p /mnt/nefi
  mount -t vfat -o ro $TARGET_EFI /mnt/nefi || die "cannot mount EFI partition $TARGET_EFI"
  efi_free_kb=$(df -k /mnt/nefi | awk 'NR==2{print $4}'); umount /mnt/nefi
  [ "${efi_free_kb:-0}" -ge 45000 ] || die "EFI partition $TARGET_EFI needs at least 45 MB free"
  [ $free_mb -ge 17000 ] || die "only $(( free_mb / 1024 )) GB unallocated on $TD; dual-boot needs >= 17 GB free space"

  if [ -n "$CONFIRM_CMDLINE" ]; then
    REPLY=$CONFIRM_CMDLINE
  elif [ "$USE_GUI" = 1 ]; then
    REPLY=$("$GUI" serial "$TD ($KIND) - Dual-Boot in $(( free_mb / 1024 )) GB free space" \
      "Existing Windows/Linux partitions are preserved. Type drive serial to confirm:" "$SERIAL") || REPLY=""
  else
    say "Type the serial number ($SERIAL) to confirm adding FIDESYS + FIDE_DATA in unallocated space:"
    ask "serial> "
  fi
  [ "$REPLY" = "$SERIAL" ] || halt_here "Cancelled. Nothing was written to $TD."

  gui_progress_start "Creating Dual-Boot Partitions..." "Allocating FIDESYS (8 GiB) + FIDE_DATA in free space"
  tool sfdisk --force --no-reread --append $TD >> $L/install.log 2>&1 <<EOF || die "sfdisk failed to append dual-boot partitions"
size=8GiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="FIDESYS"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="FIDE_DATA"
EOF
  tool partx -u $TD 2>/dev/null || partprobe $TD 2>/dev/null || blockdev --rereadpt $TD 2>/dev/null || true
  sleep 2; mdev -s
  for i in 1 2 3 4 5 6 7 8 9 10; do
    PT=$(tool sfdisk -d $TD 2>/dev/null)
    TARGET_SYS=$(echo "$PT" | awk '/name="FIDESYS"/ {print $1; exit}'); TARGET_DATA=$(echo "$PT" | awk '/name="FIDE_DATA"/ {print $1; exit}')
    for _tgt in "$TARGET_SYS" "$TARGET_DATA"; do
      [ -n "$_tgt" ] || continue
      _pname="${_tgt##*/}"
      if [ ! -b "$_tgt" ] && [ -f "/sys/block/$T/$_pname/dev" ]; then
        _mm=$(cat "/sys/block/$T/$_pname/dev" 2>/dev/null)
        [ -n "$_mm" ] && mknod "$_tgt" b ${_mm%:*} ${_mm#*:} 2>/dev/null || true
      fi
    done
    [ -b "$TARGET_SYS" ] && [ -b "$TARGET_DATA" ] && break
    tool partx -u $TD 2>/dev/null || partprobe $TD 2>/dev/null || true
    sleep 2; mdev -s
  done
  [ -n "$TARGET_SYS" ] && [ -b "$TARGET_SYS" ] || die "FIDESYS partition did not appear on $TD"
  [ -n "$TARGET_DATA" ] && [ -b "$TARGET_DATA" ] || die "FIDE_DATA partition did not appear on $TD"

  gui_progress_update 8 "Formatting Dual-Boot Partitions..." "Formatting FIDESYS and FIDE_DATA"
  tool mkfs.fat -F 32 -n FIDESYS $TARGET_SYS >> $L/install.log 2>&1 || die "mkfs FIDESYS failed"
  NODISCARD=; [ -n "$CONFIRM_CMDLINE" ] && NODISCARD="-E nodiscard"
  tool mke2fs -F -q -t ext4 $NODISCARD -L FIDE_DATA -m 0 -O verity $TARGET_DATA >> $L/install.log 2>&1 || die "mkfs FIDE_DATA failed"
  tool e2fsck -fn $TARGET_DATA >> $L/install.log 2>&1 || die "fsck FIDE_DATA failed"
fi

mkdir -p /mnt/nefi /mnt/nsys
mount -t vfat $TARGET_EFI /mnt/nefi || die "mount EFI failed"
mount -t vfat -o noatime $TARGET_SYS /mnt/nsys || die "mount FIDESYS failed"
mkdir -p /mnt/nsys/fidebook/logs
[ "$INSTALL_MODE" = dualboot ] || mkdir -p /mnt/nefi/EFI/BOOT

if [ -z "$(findfs LABEL=FIDE_META 2>/dev/null)" ] && [ ! -f /mnt/nsys/fidebook/metadata.img ]; then
  gui_progress_update 11 "Creating Metadata Volume..." "Initializing 64 MB ext4 metadata.img"
  dd if=/dev/zero of=/mnt/nsys/fidebook/metadata.img bs=1M count=64 2>/dev/null
  tool mke2fs -F -q -t ext4 -L FIDE_META /mnt/nsys/fidebook/metadata.img >> $L/install.log 2>&1
fi

copy_large_file() {
  _src="$1"; _dst="$2"; _label="$3"
  _tot=$(stat -c %s "$_src" 2>/dev/null || echo 1)
  _tot_mb=$(( _tot / 1048576 ))
  [ $_tot_mb -eq 0 ] && _tot_mb=1
  dd if="$_src" of="$_dst" bs=4M conv=fsync 2>/dev/null &
  _pid=$!
  _lastq=
  while kill -0 $_pid 2>/dev/null; do
    _cur=$(stat -c %s "$_dst" 2>/dev/null || echo 0)
    _pct=$(( _cur * 100 / _tot ))
    _cur_mb=$(( _cur / 1048576 ))
    gui_progress_update $((14 + _pct * 56 / 100)) "Installing FideBookOS System Image..." "${_cur_mb} / ${_tot_mb} MB (${_pct}%)"
    if [ $SPEECH = 1 ]; then
      [ "$((_pct / 10))" != "$_lastq" ] && { _lastq=$((_pct / 10)); echo "  $_label: $((_lastq * 10)) percent" > $TTY; }
    elif [ "$USE_GUI" = 0 ]; then
      printf "\r  %s: %3d%% (%d/%d MB)" "$_label" "$_pct" "$_cur_mb" "$_tot_mb" > $TTY
    fi
    sleep 1
  done
  wait $_pid || die "copy $_label failed"
  [ "$USE_GUI" = 0 ] && echo "" > $TTY
  echo "$_label: copied successfully" >> $L/install.log
}

gui_progress_update 13 "Installing Bootloader & Kernel..." "Writing BOOTX64.EFI"
say "Copying the kernel ..."
if [ "$INSTALL_MODE" = dualboot ]; then
  mkdir -p /mnt/nefi/EFI/fidebookos
  cp $KERNEL /mnt/nefi/EFI/fidebookos/BOOTX64.EFI || die "copy BOOTX64.EFI failed"
  [ -f "$G/Add-FideBookOS-to-Windows-BootMenu.bat" ] && cp "$G/Add-FideBookOS-to-Windows-BootMenu.bat" /mnt/nefi/EFI/fidebookos/ 2>/dev/null || true
else
  cp $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI || die "copy BOOTX64.EFI failed"
fi

say "Copying system image (super.img) ..."
copy_large_file "$G/super.img" "/mnt/nsys/fidebook/super.img" "System Image"

gui_progress_update 72 "Installing FideBookOS Configuration..." "Copying startup scripts & manifests"
say "Copying system configuration and scripts ..."
for f in $FILES; do
  [ "$f" = "super.img" ] && continue
  cp $G/$f /mnt/nsys/fidebook/$f || die "copy $f failed"
done

say "Copying hardware drivers, branding and firmware ..."
_tot_kb=$(du -sk $G/firmware $G/modules $G/ksu $G/patched $G/branding $G/installer $G/kmod $G/audio $G/surface 2>/dev/null | awk '{s+=$1} END {print s}')
[ -z "$_tot_kb" ] || [ "$_tot_kb" -le 0 ] && _tot_kb=1
_tot_mb=$(( _tot_kb / 1024 ))
[ $_tot_mb -le 0 ] && _tot_mb=1
_start_used=$(df -k /mnt/nsys 2>/dev/null | awk 'NR>1 {print $3}')
[ -z "$_start_used" ] && _start_used=0

( (cd "$G" && tar -cf - $DIRS) | (cd /mnt/nsys/fidebook && tar -xf -) ) &
_pid=$!
while kill -0 $_pid 2>/dev/null; do
  _cur_used=$(df -k /mnt/nsys 2>/dev/null | awk 'NR>1 {print $3}')
  _copied_kb=$(( _cur_used - _start_used ))
  [ $_copied_kb -lt 0 ] && _copied_kb=0
  _cur_mb=$(( _copied_kb / 1024 ))
  [ $_cur_mb -gt $_tot_mb ] && _cur_mb=$_tot_mb
  _pct=$(( _cur_mb * 100 / _tot_mb ))
  gui_progress_update $((74 + _pct * 16 / 100)) "Installing Drivers, Firmware & Branding..." "${_cur_mb} / ${_tot_mb} MB (${_pct}%)"
  sleep 1
done
wait $_pid || {
  for d in $DIRS; do cp -r "$G/$d" /mnt/nsys/fidebook/ || die "copy $d/ failed"; done
}

mkdir -p /mnt/nsys/EFI/BOOT
cp "$KERNEL" /mnt/nsys/EFI/BOOT/BOOTX64.EFI || die "copy FIDESYS kernel failed"
cp /fidebook/busybox /mnt/nsys/busybox || die "copy busybox failed"
cp "$G/installer/bin/fidebook-gui" /mnt/nsys/fidebook-gui || die "copy graphical installer failed"
write_installed_cfg
sync; echo 3 > /proc/sys/vm/drop_caches

gui_progress_update 92 "Verifying Installation Integrity..." "Re-reading installed files from disk"
say "Verifying installation integrity ..."
if [ "$INSTALL_MODE" = dualboot ]; then check $KERNEL /mnt/nefi/EFI/fidebookos/BOOTX64.EFI; else check $KERNEL /mnt/nefi/EFI/BOOT/BOOTX64.EFI; fi
check "$KERNEL" /mnt/nsys/EFI/BOOT/BOOTX64.EFI
check /fidebook/busybox /mnt/nsys/busybox
check "$G/installer/bin/fidebook-gui" /mnt/nsys/fidebook-gui
for f in $FILES; do
  if [ "$f" = "super.img" ]; then
    _sz_src=$(stat -c %s "$G/super.img" 2>/dev/null || echo 0)
    _sz_dst=$(stat -c %s "/mnt/nsys/fidebook/super.img" 2>/dev/null || echo 0)
    [ "$_sz_src" = "$_sz_dst" ] || die "verify failed: super.img size mismatch"
    cmp -n 33554432 "$G/super.img" "/mnt/nsys/fidebook/super.img" || die "verify failed: super.img header"
  else
    check $G/$f /mnt/nsys/fidebook/$f
  fi
done
for d in $DIRS; do
  _cnt_src=$(find "$G/$d" -type f | wc -l)
  _cnt_dst=$(find "/mnt/nsys/fidebook/$d" -type f | wc -l)
  [ "$_cnt_src" = "$_cnt_dst" ] || die "verify failed: $d file count mismatch"
done
for i in $STAMPED; do stamp_save $i || true; done

gui_progress_update 98 "Registering FideBookOS Boot Entry..." "Updating UEFI NVRAM / GRUB menu"
if [ -d /sys/firmware/efi ]; then
  mkdir -p /sys/firmware/efi/efivars 2>/dev/null || true
  modprobe -q efivarfs 2>/dev/null || true
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
  if [ -f "$I/bin/efibootmgr" ] && grep -q efivarfs /proc/mounts 2>/dev/null; then
    _efi_disk=$(echo "$TARGET_EFI" | sed -E 's/p?[0-9]+$//')
    _efi_part=$(echo "$TARGET_EFI" | grep -o '[0-9]*$')
    _loader='\EFI\fidebookos\BOOTX64.EFI'
    [ "$INSTALL_MODE" = clean ] && _loader='\EFI\BOOT\BOOTX64.EFI'
    tool efibootmgr -c -d "$_efi_disk" -p "$_efi_part" -L "FideBookOS" -l "$_loader" >> $L/install.log 2>&1 || true
  fi
fi

if [ "$INSTALL_MODE" = dualboot ]; then
  _esp_uuid=$(tool blkid $TARGET_EFI 2>/dev/null | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')
  [ -z "$_esp_uuid" ] && _esp_uuid=$(tool blkid -s UUID -o value $TARGET_EFI 2>/dev/null || true)
  for _p in $(ls /sys/block/$T | grep "^${T}p\?[0-9]"); do
    case "/dev/$_p" in "$TARGET_SYS"|"$TARGET_DATA"|"$TARGET_EFI") continue;; esac
    _mroot=$(mktemp -d)
    if mount /dev/$_p "$_mroot" 2>/dev/null || mount -t ext4 /dev/$_p "$_mroot" 2>/dev/null; then
      _grub_entry="
# FideBookOS Persistent
menuentry \"FideBookOS\" --class android --class os {
    insmod part_gpt
    insmod fat
    search --no-floppy --fs-uuid --set=root $_esp_uuid
    linux /EFI/fidebookos/BOOTX64.EFI quiet loglevel=3 fidebook_permissive ibt=off i8042.nopnp androidboot.setupwizard.mode=DISABLED usbcore.autosuspend=-1
}"
      for _gdir in "$_mroot/boot/grub" "$_mroot/boot/grub2" "$_mroot/grub" "$_mroot/grub2"; do
        if [ -d "$_gdir" ] && [ -f "$_gdir/grub.cfg" ]; then
          if grep -q "custom\.cfg" "$_gdir/grub.cfg" 2>/dev/null; then
            grep -q "FideBookOS" "$_gdir/custom.cfg" 2>/dev/null || printf "%s\n" "$_grub_entry" >> "$_gdir/custom.cfg"
          else
            grep -q "FideBookOS" "$_gdir/grub.cfg" 2>/dev/null || printf "%s\n" "$_grub_entry" >> "$_gdir/grub.cfg"
          fi
        fi
      done
      sync
      umount "$_mroot" 2>/dev/null || true
    fi
    rmdir "$_mroot" 2>/dev/null || true
  done
fi

umount /mnt/nefi /mnt/nsys /mnt/stickefi 2>/dev/null || true; sync
gui_progress_stop DONE
log "install: complete"; sync

if [ "$USE_GUI" = 1 ]; then
  REPLY=$("$GUI" menu 1 30 "FideBookOS Installed Successfully!" "Remove the USB installer drive before rebooting" \
    "Reboot into FideBookOS Now|Restart your laptop and launch FideBookOS 1.25" \
    "Power Off Laptop|Shut down cleanly now") || REPLY=1
else
  say "=============================================================="
  say " FideBookOS is successfully installed on $TD!"
  say "=============================================================="
  say "  1) Reboot into FideBookOS now [Default in 30 seconds]"
  say "  2) Power off system"
  while read -t 1 -r _junk < $TTY 2>/dev/null; do :; done
  printf 'Choose [1/2, default: 1]: ' > $TTY
  REPLY=; read -t 30 -r REPLY < $TTY 2>/dev/null || REPLY=1
fi

case "${REPLY:-1}" in
  2|poweroff|off) sync; sleep 1; poweroff -f ;;
  *) sync; sleep 1; reboot -f ;;
esac
