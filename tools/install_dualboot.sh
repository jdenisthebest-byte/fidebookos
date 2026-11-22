#!/bin/sh
# tools/install_dualboot.sh: Non-Destructive Persistent Dual-Boot Installer for FideBookOS 1.25
# Installs FideBookOS on a target disk alongside existing Windows / Linux installations.
# Usage: sudo tools/install_dualboot.sh --target /dev/sdX [options]
set -eu
export PATH="$PATH:/usr/sbin:/sbin"
export LC_ALL=C

ROOT=$(cd "$(dirname "$0")/.." && pwd)
U=$ROOT/usb
TARGET_DISK=""
EFI_PART=""
SYS_SIZE="10G"
META_SIZE="64M"
DATA_SIZE="64G"
REFORMAT=0
DRY_RUN=0
AUTO_TAILOR=0
ALLOW_INTERNAL=0
ALLOW_ROOT=0

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo $0 --target <disk> [options]

Options:
  --target <disk>        Target disk device (e.g. /dev/sda, /dev/sdb). REQUIRED.
  --efi-part <part>      EFI partition to use (default: auto-detected).
  --sys-size <size>      Size of FIDESYS partition (default: 10G).
  --meta-size <size>     Size of FIDE_META partition (default: 64M).
  --data-size <size>     Size of FIDE_DATA partition (default: 64G).
  --reformat             Re-format existing FideBookOS partitions.
  --allow-internal       Allow targeting internal NVMe drives (/dev/nvme*).
  --allow-root           Allow targeting the disk holding the active root filesystem.
  --dry-run              Simulate operations without writing changes.
  -h, --help             Show this help message.
EOF
  exit "${1:-1}"
}

need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"; case "$2" in -*) die "$1 requires a value (got $2)";; esac; }
while [ $# -gt 0 ]; do
  case "$1" in
    --target) need_value "$@"; TARGET_DISK="$2"; shift 2;;
    --efi-part) need_value "$@"; EFI_PART="$2"; shift 2;;
    --sys-size) need_value "$@"; SYS_SIZE="$2"; shift 2;;
    --meta-size) need_value "$@"; META_SIZE="$2"; shift 2;;
    --data-size) need_value "$@"; DATA_SIZE="$2"; shift 2;;
    --reformat) REFORMAT=1; shift;;
    --allow-internal) ALLOW_INTERNAL=1; shift;;
    --allow-root) ALLOW_ROOT=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -a|--auto|--host) AUTO_TAILOR=1; shift;;
    -h|--help) usage 0;;
    *) die "Unknown argument: $1";;
  esac
done

# Validate before any device access; do not silently reinterpret malformed sizes.
normalize_size() {
  python3 - "$1" "$2" <<'PY'
import re, sys
m = re.fullmatch(r'([0-9]+)([MGT]?)', sys.argv[1])
if not m or not 0 < int(m[1]) <= 16777216:
    sys.exit('ERROR: size must be a positive integer with optional M/G/T suffix')
n, unit = int(m[1]), m[2] or 'G'
mib = n * {'M': 1, 'G': 1024, 'T': 1048576}[unit]
if not int(sys.argv[2]) <= mib <= 16777216:
    sys.exit(f'ERROR: size must be between {sys.argv[2]} MiB and 16 TiB')
print(f'{n}{unit}')
PY
}
command -v python3 >/dev/null 2>&1 || die "python3 is required"
SYS_SIZE=$(normalize_size "$SYS_SIZE" 1024)
META_SIZE=$(normalize_size "$META_SIZE" 32)
DATA_SIZE=$(normalize_size "$DATA_SIZE" 1024)
[ -n "$TARGET_DISK" ] || usage 1
[ -b "$TARGET_DISK" ] || die "$TARGET_DISK is not a valid block device."
TARGET_DISK=$(readlink -f "$TARGET_DISK")
[ "$(lsblk -dn -o TYPE "$TARGET_DISK")" = disk ] || die "--target must be a whole disk, not a partition or loop device."
[ "$(id -u)" -eq 0 ] || die "The physical-disk installer requires root; the offline image builder does not."

ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
ROOT_DEV=${ROOT_DEV%%\[*}
if [ -n "$ROOT_DEV" ] && lsblk -snrpo NAME "$ROOT_DEV" 2>/dev/null | grep -Fxq "$TARGET_DISK"; then
  [ $ALLOW_ROOT -eq 1 ] || die "$TARGET_DISK holds your active host root filesystem ($ROOT_DEV). Pass --allow-root if intentional."
fi

_d=${TARGET_DISK##*/}
if [ "$(cat /sys/block/$_d/removable 2>/dev/null)" != 1 ] && ! readlink -f "/sys/block/$_d" 2>/dev/null | grep -q '/usb[0-9]'; then
  [ $ALLOW_INTERNAL -eq 1 ] || die "$TARGET_DISK is an internal disk. Pass --allow-internal to confirm."
fi

say "Target disk: $TARGET_DISK"

[ "$(lsblk -dn -o PTTYPE "$TARGET_DISK")" = gpt ] || die "Dual-boot installation requires an existing GPT disk."
if [ -z "$EFI_PART" ]; then
  EFI_PART=$(lsblk -nrpo PATH,PARTTYPE "$TARGET_DISK" | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1; exit}')
fi
[ -n "$EFI_PART" ] && [ -b "$EFI_PART" ] || die "Could not identify EFI partition on $TARGET_DISK. Specify with --efi-part."
EFI_PART=$(readlink -f "$EFI_PART")
[ "$(lsblk -dn -o PKNAME "$EFI_PART")" = "${TARGET_DISK##*/}" ] || die "EFI partition must belong to $TARGET_DISK."
[ "$(lsblk -dn -o PARTTYPE "$EFI_PART" | tr 'A-F' 'a-f')" = c12a7328-f81f-11d2-ba4b-00a0c93ec93b ] || die "$EFI_PART is not an EFI system partition."
say "EFI partition: $EFI_PART (only EFI/fidebookos will be changed)"

# New partitions have a GPT PARTLABEL, but no filesystem LABEL until after mkfs.
find_named_part() {
  lsblk -nrpo PATH,LABEL,PARTLABEL "$TARGET_DISK" | awk -v label="$1" '$2==label || $3==label {print $1}'
}
SYS_PART=$(find_named_part FIDESYS)
META_PART=$(find_named_part FIDE_META)
DATA_PART=$(find_named_part FIDE_DATA)
for _part in "$SYS_PART" "$META_PART" "$DATA_PART"; do
  case "$_part" in *'
'*) die "Duplicate FideBookOS partition names on $TARGET_DISK; refusing an ambiguous target.";; esac
done
if [ -n "$SYS_PART$META_PART$DATA_PART" ] && { [ -z "$SYS_PART" ] || [ -z "$META_PART" ] || [ -z "$DATA_PART" ]; }; then
  die "Partial/existing FideBookOS layout detected. Refusing to allocate or format over it; use the USB updater."
fi

if [ -n "$SYS_PART" ] && [ -n "$META_PART" ] && [ -n "$DATA_PART" ]; then
  say "Found existing FideBookOS partitions on $TARGET_DISK:"
  echo "  FIDESYS:   $SYS_PART"
  echo "  FIDE_META: $META_PART"
  echo "  FIDE_DATA: $DATA_PART"
  ALREADY_PARTITIONED=1
else
  ALREADY_PARTITIONED=0
fi

# Finish all offline input checks before confirmation, partitioning or formatting.
FILES="hook.sh oobe_apply.sh optimize.sh aidiag.sh play_diagnostics.sh native_zygote.sh early_patch.sh hwdetect.sh install.sh apex_patch.sh fidebook.cfg crossystem bootdisk.img libkm_compat.so system_ext_manifest.xml soft_gk"
DIRS="branding firmware patched audio installer kmod modules surface ksu"
for helper in user_context.sh boot_policy.sh; do
  if [ -f "$U/$helper" ] || grep -Fq "$helper" "$U/hook.sh" "$U/optimize.sh" "$U/oobe_apply.sh"; then FILES="$FILES $helper"; fi
done
require_file() { [ -s "$1" ] && [ -r "$1" ] || die "missing, empty or unreadable required payload: $1"; }
for f in $FILES; do require_file "$U/$f"; done
for d in $DIRS; do
  [ -d "$U/$d" ] && [ -n "$(find "$U/$d" -type f -print -quit)" ] || die "missing or empty payload directory: $U/$d"
done
PAYLOAD_FILES="patched/MANIFEST audio/gen_config.sh audio/mixdiag.sh audio/audio_default.xml audio/fidebook-hda-pch/audio_config.xml audio/fidebook-hda-pch/mixer_paths.xml installer/bin/sfdisk installer/bin/mkfs.fat installer/bin/mke2fs installer/bin/e2fsck installer/bin/partx installer/bin/blkid installer/bin/fidebook-gui installer/lib/ld-musl-x86_64.so.1 ksu/install.sh ksu/ksud ksu/manager.apk surface/iptsd-run.sh surface/surface-camera.sh surface/sleep-guard.sh branding/bootanimation.zip branding/wallpaper.jpg branding/app/FideBookSetup.apk branding/app/FideBookVisualSettings.apk branding/overlays/FideBookLauncherOverlay.apk branding/overlays/FideBookSettingsOverlay.apk branding/overlays/FideBookGlassFrameworkOverlay.apk branding/overlays/FideBookGlassLauncherOverlay.apk branding/overlays/FideBookGlassSystemUIOverlay.apk"
for f in $PAYLOAD_FILES; do require_file "$U/$f"; done
[ -n "$(find "$U/modules" -name modules.dep -type f -print -quit)" ] || die "missing modules.dep in $U/modules"
while read -r kind target hash payload rest; do
  case "$kind" in early|bind|apex)
    [ -n "$payload" ] && [ -z "$rest" ] || die "malformed patched/MANIFEST entry: $kind $target"
    case "/$payload/" in *'/../'*|*'/./'*|*'//'*) die "unsafe patched/MANIFEST payload: $payload";; esac
    require_file "$U/$payload";;
  esac
done < "$U/patched/MANIFEST"
require_file "$U/out/BOOTX64.EFI"
require_file "$ROOT/kernel/out/busybox"
[ "$AUTO_TAILOR" = 0 ] || require_file "$ROOT/tools/detect_hardware.sh"
SUPER=
for s in "$ROOT/build" "$ROOT/dist"; do
  if [ -s "$s/super.img" ] && [ -s "$s/super.layout" ]; then SUPER=$s; break; fi
done
if [ -z "$SUPER" ]; then
  P=$ROOT/lapis/parts
  for n in system_a vendor_a product_a system_ext_a system_dlkm_a vendor_dlkm_a; do require_file "$P/$n.img"; done
  require_file "$U/make_super.py"
fi
for req in mount umount mountpoint findmnt mkfs.vfat mkfs.ext4; do command -v "$req" >/dev/null 2>&1 || die "missing host tool: $req"; done
[ "$ALREADY_PARTITIONED" = 1 ] || command -v sgdisk >/dev/null 2>&1 || die "sgdisk is required to partition $TARGET_DISK non-destructively."
if [ "$DRY_RUN" = 1 ]; then
  say "[DRY RUN] Target: $TARGET_DISK; existing layout=$ALREADY_PARTITIONED; reformat=$REFORMAT"
  say "[DRY RUN] Requested sizes: FIDESYS=$SYS_SIZE, FIDE_META=$META_SIZE, FIDE_DATA=$DATA_SIZE. No writes or mounts."
  exit 0
fi
say "Disk $TARGET_DISK:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTTYPENAME "$TARGET_DISK"
DSERIAL=$(lsblk -dno SERIAL "$TARGET_DISK" | sed 's/^ *//; s/ *$//')
[ -n "$DSERIAL" ] || die "Cannot read the hardware serial of $TARGET_DISK; refusing to write."
if [ "$ALREADY_PARTITIONED" = 0 ]; then
  echo "This adds FIDESYS ($SYS_SIZE), FIDE_META ($META_SIZE) and FIDE_DATA ($DATA_SIZE) in unallocated space."
elif [ "$REFORMAT" = 1 ]; then
  echo "WARNING: --reformat ERASES ALL FideBookOS apps, settings and files on $SYS_PART, $META_PART and $DATA_PART."
else
  echo "This updates the existing FideBookOS system; /data and /metadata will NOT be formatted."
fi
echo "Kernel destination: $EFI_PART/EFI/fidebookos/BOOTX64.EFI. Other EFI loaders are preserved."
echo "When GRUB is present a menu entry may be added to /etc/grub.d/40_custom."
printf 'To continue type the serial number (%s) exactly: ' "$DSERIAL"
read -r _a || die "Cancelled. Nothing was written to $TARGET_DISK."
[ "$_a" = "$DSERIAL" ] || die "Cancelled. Nothing was written to $TARGET_DISK."

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fidebook-dualboot.XXXXXX")
MNT_SYS=; MNT_EFI=
cleanup() {
  _cleanup_busy=0
  for _cleanup_mount in "$MNT_EFI" "$MNT_SYS"; do
    [ -n "$_cleanup_mount" ] || continue
    if mountpoint -q "$_cleanup_mount"; then
      if ! umount "$_cleanup_mount"; then
        printf 'WARNING: leaving mounted workspace intact: %s\n' "$_cleanup_mount" >&2
        _cleanup_busy=1
        continue
      fi
    fi
    rmdir "$_cleanup_mount" 2>/dev/null || true
  done
  # Never recursively delete a workspace that still contains a mounted filesystem.
  if [ "$_cleanup_busy" = 0 ]; then rm -rf "$WORK"; fi
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -z "$SUPER" ]; then
  say "Building super.img offline before changing $TARGET_DISK ..."
  python3 "$U/make_super.py" "$WORK/super.img" "$WORK/super.layout" \
    system_a="$P/system_a.img" vendor_a="$P/vendor_a.img" product_a="$P/product_a.img" \
    system_ext_a="$P/system_ext_a.img" system_dlkm_a="$P/system_dlkm_a.img" vendor_dlkm_a="$P/vendor_dlkm_a.img"
  SUPER=$WORK
fi

if [ $ALREADY_PARTITIONED -eq 0 ]; then
  say "Creating FideBookOS partitions non-destructively into unallocated free space..."
  sgdisk \
    -n 0:0:+"$SYS_SIZE"  -t 0:0700 -c 0:"FIDESYS" \
    -n 0:0:+"$META_SIZE" -t 0:8300 -c 0:"FIDE_META" \
    -n 0:0:+"$DATA_SIZE" -t 0:8300 -c 0:"FIDE_DATA" \
    "$TARGET_DISK" || die "sgdisk failed to create partitions. Check free space on $TARGET_DISK."
  partprobe "$TARGET_DISK" 2>/dev/null || sleep 2

  SYS_PART=$(find_named_part FIDESYS)
  META_PART=$(find_named_part FIDE_META)
  DATA_PART=$(find_named_part FIDE_DATA)
  [ -b "$SYS_PART" ] && [ -b "$META_PART" ] && [ -b "$DATA_PART" ] || die "Could not resolve newly created GPT partitions on $TARGET_DISK"
fi

if [ $ALREADY_PARTITIONED -eq 0 ] || [ $REFORMAT -eq 1 ]; then
  for _part in "$SYS_PART" "$META_PART" "$DATA_PART"; do
    [ "$(lsblk -dn -o PKNAME "$_part")" = "${TARGET_DISK##*/}" ] || die "Partition $_part is not on $TARGET_DISK."
    [ -z "$(findmnt -rn -S "$_part")" ] || die "Refusing to format mounted partition $_part."
  done
  say "Formatting partitions ($SYS_PART, $META_PART, $DATA_PART)..."
  mkfs.vfat -F 32 -n FIDESYS "$SYS_PART"
  mkfs.ext4 -F -L FIDE_META "$META_PART"
  mkfs.ext4 -F -m 0 -O verity -L FIDE_DATA "$DATA_PART"
fi

MNT_SYS=$(mktemp -d "$WORK/system.XXXXXX")
mount "$SYS_PART" "$MNT_SYS"

say "Copying FideBookOS system files to $SYS_PART (FIDESYS)..."
mkdir -p "$MNT_SYS/EFI/BOOT" "$MNT_SYS/fidebook/logs"
cp "$U/out/BOOTX64.EFI" "$MNT_SYS/EFI/BOOT/BOOTX64.EFI"
cp "$ROOT/kernel/out/busybox" "$MNT_SYS/busybox"
cp "$U/installer/bin/fidebook-gui" "$MNT_SYS/fidebook-gui"
for f in $FILES; do
  # An in-place system update must not reset the installed user's configuration.
  if [ "$f" = fidebook.cfg ] && [ "$ALREADY_PARTITIONED" = 1 ] && [ "$REFORMAT" = 0 ] && [ -s "$MNT_SYS/fidebook/$f" ]; then continue; fi
  cp "$U/$f" "$MNT_SYS/fidebook/$f"
done
for d in $DIRS; do
  mkdir -p "$MNT_SYS/fidebook/$d"
  cp -RL "$U/$d/." "$MNT_SYS/fidebook/$d/"
done
[ ! -d "$U/a11y" ] || { mkdir -p "$MNT_SYS/fidebook/a11y"; cp -RL "$U/a11y/." "$MNT_SYS/fidebook/a11y/"; }
say "Copying $SUPER/super.img ..."
cp "$SUPER/super.img" "$MNT_SYS/fidebook/super.img"
cp "$SUPER/super.layout" "$MNT_SYS/fidebook/super.layout"
sed '/^MODE=/d; /^ACTION=/d' "$MNT_SYS/fidebook/fidebook.cfg" > "$WORK/config"
printf '\nMODE=boot\n' >> "$WORK/config"
cp "$WORK/config" "$MNT_SYS/fidebook/fidebook.cfg"

if [ "$AUTO_TAILOR" = 1 ]; then
  . "$ROOT/tools/detect_hardware.sh"
  detect_host_hardware
  say "Tailoring fidebook.cfg for host hardware: $DETECTED_DEVICE_MODEL ..."
  apply_hardware_config "$MNT_SYS/fidebook/fidebook.cfg"
fi

MNT_EFI=$(mktemp -d "$WORK/efi.XXXXXX")
mount "$EFI_PART" "$MNT_EFI"
mkdir -p "$MNT_EFI/EFI/fidebookos"
cp "$U/out/BOOTX64.EFI" "$MNT_EFI/EFI/fidebookos/BOOTX64.EFI"
cmp -s "$U/out/BOOTX64.EFI" "$MNT_EFI/EFI/fidebookos/BOOTX64.EFI" || die "EFI kernel verification failed"
say "Installed FideBookOS UEFI kernel to $EFI_PART -> EFI/fidebookos/BOOTX64.EFI"
umount "$MNT_EFI" && rmdir "$MNT_EFI"
MNT_EFI=

if command -v efibootmgr >/dev/null 2>&1 && [ -d /sys/firmware/efi/efivars ]; then
  EFI_NUM=$(echo "$EFI_PART" | grep -o '[0-9]*$')
  EFI_DISK=$(echo "$EFI_PART" | sed -E 's/p?[0-9]+$//')
  if ! efibootmgr 2>/dev/null | grep -q "FideBookOS"; then
    say "Registering 'FideBookOS' in motherboard UEFI NVRAM..."
    efibootmgr -c -d "$EFI_DISK" -p "$EFI_NUM" -L "FideBookOS" -l '\EFI\fidebookos\BOOTX64.EFI' >/dev/null 2>&1 || true
  fi
fi

if [ -d /etc/grub.d ] && command -v update-grub >/dev/null 2>&1; then
  SYS_UUID=$(blkid -s UUID -o value "$SYS_PART" 2>/dev/null || true)
  if [ -n "$SYS_UUID" ] && ! grep -q "FideBookOS" /etc/grub.d/40_custom 2>/dev/null; then
    say "Adding FideBookOS dual-boot menu entry to /etc/grub.d/40_custom..."
    cat <<GRUB_EOF >> /etc/grub.d/40_custom

menuentry "FideBookOS 1.25" --class android --class gnu-linux --class os {
    insmod part_gpt
    insmod fat
    search --no-floppy --fs-uuid --set=root $SYS_UUID
    chainloader /EFI/BOOT/BOOTX64.EFI
}
GRUB_EOF
    update-grub || true
  fi
fi

sync
say "FideBookOS 1.25 persistent dual-boot installation complete!"
echo "Reboot and select FideBookOS from GRUB or your UEFI boot menu (F12)."
