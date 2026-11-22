#!/bin/busybox sh
# FideBookOS stage0: find the FideBookOS volume (USB stick or NVMe/eMMC/SATA install), show the graphical
# boot menu, mount the OS erofs images, create dm devices, and switch_root to Android init.
export PATH=/bin:/sbin
/bin/busybox --install -s /bin
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t tmpfs -o mode=0755 tmpfs /dev
mkdir -p -m 1777 /tmp
# Device nodes BEFORE any redirect so /dev/null is always a character device (1:3), never a regular file.
mknod -m 600 /dev/console c 5 1; mknod -m 600 /dev/kmsg c 1 11; mknod -m 666 /dev/null c 1 3
mknod -m 620 /dev/tty0 c 4 0; mknod -m 620 /dev/tty1 c 4 1
echo "1 1 1 1" > /proc/sys/kernel/printk 2>/dev/null || true
exec </dev/console >/dev/console 2>&1
log() { echo "<7>fidebook-stage0: $*" > /dev/kmsg; }
shell() {
  log "DROPPING TO SHELL ($1). type 'exit' to continue boot."
  setsid cttyhack sh </dev/tty1 >/dev/tty1 2>&1
}
fail() { log "FATAL: $*"; shell "failure"; }

log "=== FideBookOS 1.25 boot, kernel $(uname -r) ==="
mdev -s
mknod -m 660 /dev/loop-control c 10 237 2>/dev/null
for i in $(seq 0 15); do mknod -m 660 /dev/loop$i b 7 $i 2>/dev/null; done
mkdir -p -m 0755 /dev/socket /dev/block /dev/pts /dev/dm-user /dev/mapper /dev/input /dev/dri
mknod -m 600 /dev/mapper/control c 10 236; mknod -m 600 /dev/device-mapper c 10 236

# Ensure /dev/fb0 and /dev/input/event* exist early for the FideBookOS Graphical Boot Menu
if [ ! -c /dev/fb0 ] && [ -f /sys/class/graphics/fb0/dev ]; then
  _fb=$(cat /sys/class/graphics/fb0/dev)
  mknod -m 0660 /dev/fb0 c ${_fb%:*} ${_fb#*:} 2>/dev/null || true
fi
for _ev in /sys/class/input/event*; do
  [ -f "$_ev/dev" ] || continue
  _en=${_ev##*/}; _ed=$(cat "$_ev/dev")
  [ -c "/dev/input/$_en" ] || mknod -m 0660 "/dev/input/$_en" c ${_ed%:*} ${_ed#*:} 2>/dev/null || true
done
for _c in /sys/class/drm/card[0-9]*; do
  [ -f "$_c/dev" ] || continue
  _cn=${_c##*/}; _cd=$(cat "$_c/dev")
  [ -c "/dev/dri/$_cn" ] || mknod -m 0660 "/dev/dri/$_cn" c ${_cd%:*} ${_cd#*:} 2>/dev/null || true
done

modprobe -q sdhci-pci 2>/dev/null && log "sdhci-pci loaded (eMMC/SD controller)"
modprobe -q rtsx_pci_sdmmc 2>/dev/null && log "rtsx_pci_sdmmc loaded (Realtek SD card reader)"

# Find the FideBookOS volume: USB stick (LABEL=FIDEBOOK) or internal SSD install (LABEL=FIDESYS).
log "waiting for LABEL=FIDEBOOK (USB) or LABEL=FIDESYS (SSD) ..."
STICK=; SYS=; n=0
for i in $(seq 1 60); do
  mdev -s
  STICK=$(findfs LABEL=FIDEBOOK 2>/dev/null)
  SYS=$(findfs LABEL=FIDESYS 2>/dev/null)
  [ -n "$STICK" ] && break
  [ -n "$SYS" ] && { n=$((n+1)); [ $n -ge 6 ] && break; }
  sleep 1
done
[ -n "$STICK$SYS" ] || fail "no FIDEBOOK (USB) or FIDESYS (SSD) volume after 60s (block devices: $(ls /sys/class/block | tr '\n' ' '))"
mkdir -p /fidebook
DEV=$STICK; FROM=stick; SELMODE=

boot_menu() {
  def=1; [ -n "$SYS" ] && def=3
  mt=${MENU_T:-15}
  # Refresh input devices in case USB keyboard/mouse enumerated during disk wait
  for _ev in /sys/class/input/event*; do
    [ -f "$_ev/dev" ] || continue
    _en=${_ev##*/}; _ed=$(cat "$_ev/dev")
    [ -c "/dev/input/$_en" ] || mknod -m 0660 "/dev/input/$_en" c ${_ed%:*} ${_ed#*:} 2>/dev/null || true
  done
  if [ -x /bin/fidebook-gui ] && [ ! -f /a11y/active ]; then
    if [ -n "$SYS" ]; then
      c=$(/bin/fidebook-gui menu "$def" "$mt" "FideBookOS" "Select how you want to start FideBookOS 1.25" \
          "Try FideBookOS Live|Run directly from this USB drive (nothing on your laptop is modified)" \
          "Install or Update FideBookOS|Launch the FideBookOS Graphical Installer" \
          "Boot Installed FideBookOS|Start FideBookOS from your internal SSD") && gui_ok=1 || gui_ok=0
    else
      c=$(/bin/fidebook-gui menu "$def" "$mt" "FideBookOS" "Select how you want to start FideBookOS 1.25" \
          "Try FideBookOS Live|Run directly from this USB drive (nothing on your laptop is modified)" \
          "Install FideBookOS|Launch the FideBookOS Graphical Installer") && gui_ok=1 || gui_ok=0
    fi
    if [ "$gui_ok" = 1 ] && [ -n "$c" ]; then
      case "$c" in 1|2) ;; 3) [ -n "$SYS" ] || c=$def;; *) c=$def;; esac
      log "graphical boot menu: choice $c (default $def)"
      CHOICE=$c
      return 0
    fi
  fi
  chvt 1 2>/dev/null; clear > /dev/tty1 2>/dev/null
  sleep 1
  while read -t 1 -r _junk < /dev/tty1 2>/dev/null; do :; done
  {
    echo; echo "   FideBookOS 1.25"; echo "   ---------------"; echo
    echo "   1) Try FideBookOS live from this USB (nothing is saved)"
    echo "   2) Install or update FideBookOS on this laptop's internal SSD"
    [ -n "$SYS" ] && echo "   3) Boot the installed FideBookOS"
    echo; printf "   Choose 1-%s [default %s in %s s]: " "$([ -n "$SYS" ] && echo 3 || echo 2)" $def $mt
  } > /dev/tty1
  c=; read -t $mt -r c < /dev/tty1; echo > /dev/tty1
  case "$c" in 1|2) ;; 3) [ -n "$SYS" ] || c=$def;; *) c=$def;; esac
  log "boot menu: choice $c (default $def)"
  CHOICE=$c
}

if [ -n "$STICK" ]; then
  CFGMODE=; MENU_T=
  mount -t vfat -o ro $STICK /fidebook 2>/dev/null && {
    CFGMODE=$(sed -n 's/^MODE=//p' /fidebook/fidebook/fidebook.cfg 2>/dev/null | tail -1)
    grep -q '^BOOT_FROM=stick' /fidebook/fidebook/fidebook.cfg 2>/dev/null && CFGMODE=live
    if [ -f /fidebook/fidebook/a11y/start.sh ] && ! grep -q '^A11Y=0' /fidebook/fidebook/fidebook.cfg 2>/dev/null; then
      mkdir -p /a11y && cp -a /fidebook/fidebook/a11y/. /a11y/ 2>/dev/null
      MENU_T=$(sed -n 's/^A11Y_MENU_TIMEOUT=\([0-9][0-9]*\)$/\1/p' /fidebook/fidebook/fidebook.cfg 2>/dev/null | tail -1); MENU_T=${MENU_T:-60}
    fi
    umount /fidebook
  }
  [ -f /a11y/start.sh ] && { log "a11y: starting the screen reader"; . /a11y/start.sh; [ -f /a11y/active ] || MENU_T=; }
  case "$CFGMODE" in
    install) CHOICE=2;;
    live) CHOICE=1;;
    boot) if [ -n "$SYS" ]; then CHOICE=3; else CHOICE=1; fi;;
    *) boot_menu;;
  esac
  case "$CHOICE" in
    1) SELMODE=boot;;
    2) SELMODE=install;;
    3) DEV=$SYS; FROM=nvme;;
  esac
elif [ -n "$SYS" ]; then
  DEV=$SYS; FROM=nvme
fi
log "found FideBookOS volume on $FROM at $DEV (stick=${STICK:-none} nvme=${SYS:-none})"
mount -t vfat -o rw,flush,umask=000 $DEV /fidebook || fail "mount $DEV failed"
G=/fidebook/fidebook
cp /bin/busybox /fidebook/busybox 2>/dev/null

# Boot-numbered log directory
N=1; while [ -e $G/logs/boot-$N ]; do N=$((N+1)); done
L=$G/logs/boot-$N; mkdir -p $L
log "logging to volume: fidebook/logs/boot-$N/kmsg.log"

# Config file (edit from any computer)
SHELL_AT=none; LOAD_I915=auto; LOAD_WIFI=0; EXTRA_SLEEP=0; MODE=boot; DEBUG_TELEMETRY=0
[ -f $G/fidebook.cfg ] && . $G/fidebook.cfg && log "loaded fidebook.cfg: MODE=$MODE DEBUG_TELEMETRY=${DEBUG_TELEMETRY:-0}"
[ -n "$SELMODE" ] && MODE=$SELMODE
[ "$FROM" = stick ] && [ -f $G/fidebook.cfg ] && grep -q '^MODE=live' $G/fidebook.cfg 2>/dev/null && sed -i 's/^MODE=live/MODE=ask/' $G/fidebook.cfg 2>/dev/null || true
case "$MODE" in install) ;; *) MODE=boot;; esac
[ $FROM = nvme ] && MODE=boot

# Start continuous kmsg logger; in production mode (DEBUG_TELEMETRY=0) avoid aggressive 5s global sync wear
( exec 3</dev/kmsg; while /fidebook/busybox cat <&3 >> $L/kmsg.log || /fidebook/busybox sleep 2; do :; done ) &
if [ "${DEBUG_TELEMETRY:-0}" = 1 ]; then
  ( while /fidebook/busybox sleep 5; do /fidebook/busybox sync; done ) &
fi

# Hardware inventory
{
  echo "== cmdline"; cat /proc/cmdline
  echo "== cpu"; grep -m1 'model name' /proc/cpuinfo; grep -m1 '^flags' /proc/cpuinfo
  echo "== mem"; head -3 /proc/meminfo
  echo "== pci (slot class vendor:device driver)"
  for d in /sys/bus/pci/devices/*; do
    drv=$(readlink $d/driver 2>/dev/null); echo "${d##*/} $(cat $d/class) $(cat $d/vendor):$(cat $d/device) ${drv##*/}"
  done
  echo "== block"; ls -l /sys/class/block/
  echo "== fb/drm"; ls /sys/class/graphics /sys/class/drm 2>&1
  echo "== video4linux"; ls -l /sys/class/video4linux 2>&1
} > $L/hw.txt 2>&1
mount -t pstore pstore /sys/fs/pstore 2>/dev/null && cp -r /sys/fs/pstore $L/pstore-prev 2>/dev/null
log "hardware inventory written (hw.txt)"

[ "$SHELL_AT" = early ] && shell "SHELL_AT=early"

# Universal dynamic hardware bring-up via modalias coldplugging
if [ "$HWDETECT" != 0 ] && [ -f $G/hwdetect.sh ] && [ -d $G/modules/lib/modules ]; then
  . $G/hwdetect.sh
  fidebook_hwdetect 5
elif [ "$LOAD_I915" = 1 ]; then
  log "modprobe i915"
  modprobe i915 && log "i915 loaded" || log "i915 load FAILED rc=$?"
  sleep 2; mdev -s
fi

# Install to SSD instead of booting
if [ "$MODE" = install ]; then
  [ -f $G/install.sh ] || fail "MODE=install but fidebook/install.sh is missing"
  log "MODE=install: running fidebook/install.sh"; . $G/install.sh
  fail "install.sh returned"
fi

# Android partitions (super.img or separate erofs images)
mkdir -p /new /dev/block/by-name
dmctl() { LD_LIBRARY_PATH=/system/lib64/bootstrap:/system/lib64 chroot /new /system/bin/bootstrap/linker64 /system/bin/dmctl "$@"; }
target() { case $1 in system_a) echo /new;; *) echo /new/${1%_a};; esac; }
if [ -f $G/super.img ] && [ -f $G/super.layout ]; then
  log "using super.img (dynamic partitions)"
  losetup -r /dev/loop7 $G/super.img || fail "losetup super.img failed"
  mknod -m 600 /dev/block/loop7 b 7 7 2>/dev/null; ln -sf /dev/block/loop7 /dev/block/by-name/super
  i=0
  while read n start len; do
    t=$(target $n); mkdir -p $t 2>/dev/null
    losetup -r -o $((start * 512)) /dev/loop$i $G/super.img && mount -t erofs -o ro /dev/loop$i $t \
      && log "mounted $n (super @ sector $start) -> $t" || { log "mount $n FAILED"; [ $n = system_a ] && fail "system mount failed"; }
    i=$((i+1))
  done < $G/super.layout
  mount --bind /dev /new/dev; mount --bind /proc /new/proc; mount --bind /sys /new/sys
  while read n start len; do
    dmctl create $n -ro linear 0 $len /dev/block/loop7 $start >/dev/null 2>&1
    log "dmctl $n = super[$start +$len] rc=$?"
  done < $G/super.layout
else
  log "no super.img, using separate partition images"
  i=0
  for n in system_a vendor_a product_a system_ext_a system_dlkm_a vendor_dlkm_a; do
    t=$(target $n); mkdir -p $t 2>/dev/null
    losetup -r /dev/loop$i $G/$n.img && mount -t erofs -o ro /dev/loop$i $t \
      && log "mounted $n -> $t" || { log "mount $n FAILED"; [ $n = system_a ] && fail "system mount failed"; }
    i=$((i+1))
  done
  mount --bind /dev /new/dev; mount --bind /proc /new/proc; mount --bind /sys /new/sys
  i=8
  for n in system_a vendor_a product_a system_ext_a; do
    losetup -r /dev/loop$i $G/$n.img; sz=$(cat /sys/block/loop$i/size)
    dmctl create $n -ro linear 0 $sz /dev/loop$i 0 >/dev/null 2>&1
    log "dmctl $n on loop$i ($sz sectors) rc=$?"
    i=$((i+1))
  done
fi
umount /new/sys; umount /new/proc; umount /new/dev
mdev -s

[ -f $G/hook.sh ] && { log "running fidebook/hook.sh"; . $G/hook.sh; }

[ "$SHELL_AT" = pre_android ] && shell "SHELL_AT=pre_android (Android root at /new)"

# /data and /metadata: persistent ext4 partitions on SSD install, else tmpfs in Live USB mode
DATA=; META=
find_part() {
  _p=$(findfs LABEL=$1 2>/dev/null); [ -n "$_p" ] && { echo "$_p"; return; }
  _pd=$(basename "$(readlink -f /sys/class/block/$(basename $DEV)/.. 2>/dev/null)" 2>/dev/null)
  for _u in /sys/class/block/*/uevent; do
    grep -qx "PARTNAME=$1" $_u 2>/dev/null || continue
    _n=${_u%/uevent}; _n=${_n##*/}
    [ "$(basename "$(readlink -f /sys/class/block/$_n/.. 2>/dev/null)" 2>/dev/null)" = "$_pd" ] && [ -b /dev/$_n ] && { echo /dev/$_n; return; }
  done
}
if [ $FROM = nvme ]; then
  DATA=$(find_part FIDE_DATA); META=$(find_part FIDE_META)
  [ -n "$DATA" ] && log "data partition: $DATA" || log "data partition: none (FIDE_DATA not found)"
  if [ -n "$DATA" ] && [ -z "$META" ] && [ -f $G/metadata.img ]; then
    if losetup /dev/loop12 $G/metadata.img 2>/dev/null; then META=/dev/loop12; log "metadata: image $G/metadata.img on loop12"
    else log "metadata: losetup of $G/metadata.img FAILED"; fi
  fi
fi
e2fsck_p() { [ -x $G/installer/bin/e2fsck ] && $G/installer/lib/ld-musl-x86_64.so.1 --library-path $G/installer/lib $G/installer/bin/e2fsck -p "$1" >> $L/fsck.txt 2>&1; log "e2fsck -p $1 rc=$?"; }
if [ -n "$DATA" ] && [ -n "$META" ]; then
  e2fsck_p $META; e2fsck_p $DATA
  mount -t ext4 -o noatime,nosuid,nodev $META /new/metadata && log "metadata: ext4 $META" \
    || { log "metadata ext4 mount FAILED, using tmpfs"; mount -t tmpfs tmpfs /new/metadata; }
  if mount -t ext4 -o noatime,nosuid,nodev $DATA /new/data; then
    log "data: ext4 $DATA ($(df -h /new/data | awk 'NR==2{print $4}') free)"
    [ -e /new/data/.fidebook_init ] || { chown 1000:1000 /new/data; chmod 0771 /new/data; : > /new/data/.fidebook_init; }
  else
    log "data ext4 mount FAILED, using tmpfs"; mount -t tmpfs -o mode=0771 tmpfs /new/data
  fi
else
  mount -t tmpfs -o mode=0771 tmpfs /new/data
  mount -t tmpfs tmpfs /new/metadata
  log "data/metadata: tmpfs (live session)"
fi
mount -t devpts devpts /dev/pts -o mode=0620,ptmxmode=0666 2>/dev/null
mknod -m 666 /dev/ptmx c 5 2 2>/dev/null; mknod -m 666 /dev/zero c 1 5 2>/dev/null
mknod -m 666 /dev/random c 1 8 2>/dev/null; mknod -m 666 /dev/urandom c 1 9 2>/dev/null

# Ensure DRM and V4L2 camera device nodes exist in /dev with proper permissions
mkdir -p -m 0755 /dev/dri
for _c in /sys/class/drm/card[0-9]* /sys/class/drm/renderD[0-9]*; do
  [ -f "$_c/dev" ] || continue
  _name=${_c##*/}; _dev=$(cat "$_c/dev")
  [ -c "/dev/dri/$_name" ] || mknod -m 0666 "/dev/dri/$_name" c ${_dev%:*} ${_dev#*:}
done
_prim=
for _s in /sys/class/drm/card*-*/status; do
  [ -f "$_s" ] || continue
  if grep -q '^connected' "$_s" 2>/dev/null; then
    _prim=${_s%/status}; _prim=${_prim##*/}; _prim=${_prim%%-*}; break
  fi
done
if [ -z "$_prim" ]; then
  for _c in /sys/class/drm/card[0-9]*; do
    case ${_c##*/} in card*-*) continue;; esac
    _drv=$(readlink "$_c/device/driver" 2>/dev/null); _drv=${_drv##*/}
    case "$_drv" in i915|xe|amdgpu|nouveau|radeon) _prim=${_c##*/}; break;; esac
  done
fi
if [ -n "$_prim" ] && [ "$_prim" != "card0" ] && [ -f "/sys/class/drm/$_prim/dev" ]; then
  _pdev=$(cat "/sys/class/drm/$_prim/dev")
  rm -f /dev/dri/card0
  mknod -m 0666 /dev/dri/card0 c ${_pdev%:*} ${_pdev#*:}
  log "primary display on $_prim ($_pdev), mapped to /dev/dri/card0"
fi
chmod 0666 /dev/dri/* 2>/dev/null || true

# Create V4L2 webcam & media controller device nodes (/dev/video*, /dev/media*)
for _v in /sys/class/video4linux/video*; do
  [ -f "$_v/dev" ] || continue
  _vn=${_v##*/}; _vd=$(cat "$_v/dev")
  [ -c "/dev/$_vn" ] || mknod -m 0666 "/dev/$_vn" c ${_vd%:*} ${_vd#*:} 2>/dev/null || true
done
for _m in /sys/bus/media/devices/media*; do
  [ -f "$_m/dev" ] || continue
  _mn=${_m##*/}; _md=$(cat "$_m/dev")
  [ -c "/dev/$_mn" ] || mknod -m 0666 "/dev/$_mn" c ${_md%:*} ${_md#*:} 2>/dev/null || true
done

[ "${EXTRA_SLEEP:-0}" -gt 0 ] 2>/dev/null && sleep $EXTRA_SLEEP
[ -f /a11y/stop.sh ] && . /a11y/stop.sh
dmesg > $L/stage0-dmesg.txt 2>&1
sync
mount --move /dev /new/dev; mount --move /proc /new/proc; mount --move /sys /new/sys
mount -t selinuxfs selinuxfs /new/sys/fs/selinux
for d in mnt debug_ramdisk second_stage_resources; do mount -t tmpfs -o mode=0755 tmpfs /new/$d; done
echo "<7>fidebook-stage0: switching root -> /system/bin/init selinux_setup" > /new/dev/kmsg
exec switch_root /new /system/bin/init selinux_setup
fail "switch_root failed"
