#!/bin/sh
# Build a FideBookOS USB/persistent GPT image using regular files only, entirely offline.
# No mount, loop device, root privileges, downloads, or physical-disk writes are needed.
set -eu
export PATH="$PATH:/usr/sbin:/sbin"
export LC_ALL=C TZ=UTC
umask 022
ROOT=$(cd "$(dirname "$0")/.." && pwd)
U=$ROOT/usb
P=$ROOT/lapis/parts
OUT="$ROOT/dist"
BUILD_TYPE=standard
DATA_GB=64
DATA_SIZE_SET=0
AUTO_TAILOR=0
CUSTOM_NAME=
OUTPUT_FILE=
POSITIONAL=
FORCE=0
CHECK_ONLY=0

say() { printf '== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<EOF
Usage: sh $0 [options] [OUT_DIR | FILE.img]
  --type standard|looper  Live/installer (default) or persistent ext4 /data image
  --data-size N          Looper /data size in GiB, integer 1..16384 (default: 64)
  --name NAME            Image basename, optionally ending in .img
  --output FILE.img, -o  Exact output filename (cannot be combined with --name/OUT_DIR)
  --force               Replace existing regular image/checksum/manifest files only
  --check               Check tools, inputs and output policy without building/writing
  --auto, -a, --host     Opt in to tailoring the copied config to this host
  -h, --help            Show this help

This tool never writes devices, even with --force. Existing files are protected by
 default. Temporary files are private and cleaned up on failure. SOURCE_DATE_EPOCH
may fix staged timestamps; .img.manifest records the exact packaged file hashes.
Identical output also depends on identical input assets and host filesystem tools.
EOF
}
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"; case "$2" in -*) die "$1 requires a value (got $2)";; esac; }
set_positional() { [ -z "$POSITIONAL" ] || die "only one output directory/filename is allowed"; [ -n "$1" ] || die "empty output path"; POSITIONAL=$1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --type=*) BUILD_TYPE=${1#*=};;
    --type) need_value "$@"; shift; BUILD_TYPE=$1;;
    --data-size=*) DATA_GB=${1#*=}; DATA_SIZE_SET=1;;
    --data-size) need_value "$@"; shift; DATA_GB=$1; DATA_SIZE_SET=1;;
    --name=*) CUSTOM_NAME=${1#*=}; [ -n "$CUSTOM_NAME" ] || die "--name requires a value";;
    --name) need_value "$@"; shift; CUSTOM_NAME=$1;;
    --output=*|-o=*) OUTPUT_FILE=${1#*=}; [ -n "$OUTPUT_FILE" ] || die "--output requires a value";;
    --output|-o) need_value "$@"; shift; OUTPUT_FILE=$1;;
    --force) FORCE=1;;
    --check) CHECK_ONLY=1;;
    -a|--auto|--host) AUTO_TAILOR=1;;
    -h|--help) usage; exit 0;;
    standard|looper|loopback) BUILD_TYPE=$1;;
    --) shift; [ "$#" -eq 1 ] || die "expected one output path after --"; set_positional "$1"; break;;
    -*) die "unknown option: $1";;
    *) set_positional "$1";;
  esac
  shift
done
case "$BUILD_TYPE" in standard|looper) ;; loopback) BUILD_TYPE=looper;; *) die "invalid build type: $BUILD_TYPE";; esac
case "$DATA_GB" in ''|*[!0-9]*) die "--data-size must be an integer in GiB (1..16384)";; esac
DATA_GB=$(printf '%s\n' "$DATA_GB" | sed 's/^0*//')
[ -n "$DATA_GB" ] && [ "${#DATA_GB}" -le 5 ] && [ "$DATA_GB" -le 16384 ] || die "--data-size must be in 1..16384 GiB"
[ "$BUILD_TYPE" = looper ] || [ "$DATA_SIZE_SET" = 0 ] || die "--data-size is only valid with --type looper"
[ -z "$OUTPUT_FILE" ] || { [ -z "$CUSTOM_NAME" ] && [ -z "$POSITIONAL" ]; } || die "--output cannot be combined with --name or an output path"
if [ -n "$POSITIONAL" ]; then
  case "$POSITIONAL" in *.img) [ -z "$CUSTOM_NAME" ] || die "a filename cannot be combined with --name"; OUTPUT_FILE=$POSITIONAL;; *) OUT=$POSITIONAL;; esac
fi
command -v python3 >/dev/null 2>&1 || die "missing required host tool: python3"
BUILD_EPOCH=${SOURCE_DATE_EPOCH:-$(date +%s)}
BUILD_DATE=$(python3 - "$BUILD_EPOCH" <<'PY'
import datetime, sys
s = sys.argv[1]
if not s.isascii() or not s.isdecimal() or not 315532800 <= int(s) <= 4354819199:
    sys.exit('ERROR: SOURCE_DATE_EPOCH must be an integer timestamp within FAT years 1980..2107')
print(datetime.datetime.fromtimestamp(int(s), datetime.timezone.utc).strftime('%Y%m%d'))
PY
)
export SOURCE_DATE_EPOCH=$BUILD_EPOCH
if [ -n "$OUTPUT_FILE" ]; then
  case "$OUTPUT_FILE" in *.img) ;; *) die "--output must end in .img";; esac
else
  if [ -n "$CUSTOM_NAME" ]; then
    CUSTOM_NAME=${CUSTOM_NAME%.img}
    case "$CUSTOM_NAME" in ''|.|..|*/*|*[!A-Za-z0-9._-]*) die "--name must be a simple image basename, not a path";; esac
  fi
  if [ -n "$CUSTOM_NAME" ]; then NAME=$CUSTOM_NAME
  elif [ "$BUILD_TYPE" = looper ]; then NAME=FideBookOS-1.25-looper-$BUILD_DATE
  else NAME=FideBookOS-1.25; fi
  OUTPUT_FILE=$OUT/$NAME.img
fi
# Resolve parent symlinks before mkdir/truncate. --force never permits a special file,
# symlink, hardlink, device-tree path, or overwriting the cached source super.img.
IMG=$(python3 - "$OUTPUT_FILE" "$FORCE" "$ROOT" <<'PY'
import os, pathlib, re, stat, sys
raw, force, root = sys.argv[1:]
p = pathlib.Path(raw)
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*\.img', p.name):
    sys.exit('ERROR: image basename must use letters, numbers, dot, underscore or dash, and end in .img')
p = p.parent.resolve() / p.name
r = pathlib.Path(root).resolve()
for forbidden in (pathlib.Path('/dev'), pathlib.Path('/proc'), pathlib.Path('/sys'), r/'usb', r/'lapis/parts', r/'kernel/out'):
    if p == forbidden or forbidden in p.parents:
        sys.exit(f'ERROR: unsafe output location: {p}')
if p in (r/'build/super.img', r/'dist/super.img'):
    sys.exit('ERROR: output must not replace the input super.img')
for dest in (p, pathlib.Path(str(p)+'.sha256'), pathlib.Path(str(p)+'.manifest')):
    if os.path.lexists(dest):
        st = dest.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            sys.exit(f'ERROR: output must not be a symlink, special file or hardlink: {dest}')
        if force != '1':
            sys.exit(f'ERROR: output already exists (use --force for regular files): {dest}')
print(p)
PY
)
OUT=$(dirname "$IMG")
NAME=$(basename "$IMG" .img)
for req in mkfs.fat mcopy mdir sfdisk truncate dd mktemp; do
  command -v "$req" >/dev/null 2>&1 || die "missing required host tool: $req"
done
if [ "$BUILD_TYPE" = looper ]; then
  for req in mke2fs dumpe2fs; do command -v "$req" >/dev/null 2>&1 || die "missing required host tool: $req"; done
fi

# Keep the required runtime set in sync with both installers. Missing payload is a
# broken release, not an optional feature silently omitted from an otherwise good image.
FILES="hook.sh oobe_apply.sh optimize.sh aidiag.sh play_diagnostics.sh native_zygote.sh early_patch.sh hwdetect.sh install.sh apex_patch.sh fidebook.cfg crossystem bootdisk.img libkm_compat.so system_ext_manifest.xml soft_gk"
DIRS="branding firmware patched audio installer kmod modules surface ksu"
# Platform/UI helpers are shipped whenever present, and required when referenced.
for helper in user_context.sh boot_policy.sh; do
  if [ -f "$U/$helper" ] || grep -Fq "$helper" "$U/hook.sh" "$U/optimize.sh" "$U/oobe_apply.sh"; then FILES="$FILES $helper"; fi
done
require_file() { [ -s "$1" ] && [ -r "$1" ] || die "missing, empty or unreadable required payload: $1"; }
for f in $FILES; do require_file "$U/$f"; done
for d in $DIRS; do
  [ -d "$U/$d" ] && [ -n "$(find "$U/$d" -type f -print -quit)" ] || die "missing or empty required payload directory: $U/$d"
done
PAYLOAD_FILES="patched/MANIFEST audio/gen_config.sh audio/mixdiag.sh audio/audio_default.xml audio/fidebook-hda-pch/audio_config.xml audio/fidebook-hda-pch/mixer_paths.xml installer/bin/sfdisk installer/bin/mkfs.fat installer/bin/mke2fs installer/bin/e2fsck installer/bin/partx installer/bin/blkid installer/bin/fidebook-gui installer/lib/ld-musl-x86_64.so.1 ksu/install.sh ksu/ksud ksu/manager.apk surface/iptsd-run.sh surface/surface-camera.sh surface/sleep-guard.sh branding/bootanimation.zip branding/wallpaper.jpg branding/app/FideBookSetup.apk branding/app/FideBookVisualSettings.apk branding/overlays/FideBookLauncherOverlay.apk branding/overlays/FideBookSettingsOverlay.apk branding/overlays/FideBookGlassFrameworkOverlay.apk branding/overlays/FideBookGlassLauncherOverlay.apk branding/overlays/FideBookGlassSystemUIOverlay.apk"
for f in $PAYLOAD_FILES; do require_file "$U/$f"; done
require_file "$U/out/BOOTX64.EFI"
require_file "$ROOT/kernel/out/busybox"
[ -n "$(find "$U/modules" -name modules.dep -type f -print -quit)" ] || die "missing modules.dep in $U/modules"
while read -r kind target hash payload rest; do
  case "$kind" in
    early|bind|apex)
      [ -n "$payload" ] && [ -z "$rest" ] || die "malformed patched/MANIFEST entry: $kind $target"
      case "/$payload/" in *'/../'*|*'/./'*|*'//'*) die "unsafe patched/MANIFEST payload: $payload";; esac
      require_file "$U/$payload";;
  esac
done < "$U/patched/MANIFEST"
if [ -d "$U/a11y" ]; then
  require_file "$U/a11y/start.sh"; require_file "$U/a11y/stop.sh"; require_file "$U/a11y/bin/espeakup"
fi
if [ "$AUTO_TAILOR" = 1 ]; then require_file "$ROOT/tools/detect_hardware.sh"; fi
SUPER=
for source in "$ROOT/build" "$ROOT/dist"; do
  if [ -s "$source/super.img" ] && [ -s "$source/super.layout" ]; then SUPER=$source; break; fi
done
if [ -z "$SUPER" ]; then
  for n in system_a vendor_a product_a system_ext_a system_dlkm_a vendor_dlkm_a; do require_file "$P/$n.img"; done
  require_file "$U/make_super.py"
fi
[ "$CHECK_ONLY" = 0 ] || { say "offline image preflight passed ($BUILD_TYPE): $IMG"; exit 0; }

mkdir -p "$OUT"
WORK=$(mktemp -d "$OUT/.$NAME.build.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
STAGE=$WORK/stage
WORKP=$WORK/parts
mkdir -p "$STAGE/efi/EFI/BOOT" "$STAGE/fidebook/fidebook/logs" "$STAGE/fidebook/EFI/BOOT" "$WORKP"
G=$STAGE/fidebook/fidebook
say "assembling required offline payload ($BUILD_TYPE)"
if [ -n "$SUPER" ]; then
  say "super.img: reusing $SUPER (no download or regeneration)"
  cp "$SUPER/super.img" "$G/super.img"
  cp "$SUPER/super.layout" "$G/super.layout"
else
  python3 "$U/make_super.py" "$G/super.img" "$G/super.layout" \
    system_a="$P/system_a.img" vendor_a="$P/vendor_a.img" product_a="$P/product_a.img" \
    system_ext_a="$P/system_ext_a.img" system_dlkm_a="$P/system_dlkm_a.img" vendor_dlkm_a="$P/vendor_dlkm_a.img"
fi
cp "$U/out/BOOTX64.EFI" "$STAGE/efi/EFI/BOOT/BOOTX64.EFI"
cp "$U/out/BOOTX64.EFI" "$STAGE/fidebook/EFI/BOOT/BOOTX64.EFI"
for f in $FILES; do cp "$U/$f" "$G/$f"; done
for d in $DIRS; do cp -RL "$U/$d" "$G/$d"; done
[ ! -d "$U/a11y" ] || cp -RL "$U/a11y" "$G/a11y"
if [ -f "$U/Add-FideBookOS-to-Windows-BootMenu.bat" ]; then
  cp "$U/Add-FideBookOS-to-Windows-BootMenu.bat" "$G/"
  cp "$U/Add-FideBookOS-to-Windows-BootMenu.bat" "$STAGE/fidebook/"
fi
cp "$ROOT/kernel/out/busybox" "$STAGE/fidebook/busybox"
cp "$U/installer/bin/fidebook-gui" "$STAGE/fidebook/fidebook-gui"
# Standard images always ask; never accidentally distribute a source config set to install.
MODE=ask; [ "$BUILD_TYPE" != looper ] || MODE=boot
sed '/^MODE=/d' "$G/fidebook.cfg" > "$WORK/config"
printf '\nMODE=%s\n' "$MODE" >> "$WORK/config"
mv "$WORK/config" "$G/fidebook.cfg"
if [ "$AUTO_TAILOR" = 1 ]; then
  . "$ROOT/tools/detect_hardware.sh"
  detect_host_hardware
  apply_hardware_config "$G/fidebook.cfg"
fi
cat > "$STAGE/fidebook/README.txt" <<EOF
FideBookOS 1.25 ($BUILD_TYPE image, MODE=$MODE).
Settings: fidebook/fidebook.cfg. Logs: fidebook/logs/boot-N/.
The standard image offers Live / Install or Update / Boot Installed System.
A looper image has persistent ext4 /metadata and fs-verity-capable /data ($DATA_GB GiB).
Installation requires the target drive's serial confirmation. No disk is written by this image builder.
EOF
# Hash relative payload paths (not private host paths), normalize FAT timestamps,
# and derive stable partition identifiers from content + layout + build timestamp.
python3 - "$STAGE" "$WORK" "$BUILD_TYPE" "$DATA_GB" "$BUILD_EPOCH" <<'PY'
import hashlib, os, pathlib, sys, uuid
stage, work = map(pathlib.Path, sys.argv[1:3])
kind, size, epoch = sys.argv[3:]
lines = [f'# FideBookOS payload; type={kind}; data_gib={size}; SOURCE_DATE_EPOCH={epoch}\n']
for p in sorted(stage.rglob('*')):
    if p.is_file():
        if p.stat().st_size >= 2**32:
            sys.exit(f'ERROR: file exceeds FAT32 single-file limit: {p.relative_to(stage)}')
        with p.open('rb') as f:
            digest = hashlib.file_digest(f, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else None
            if digest is None:
                h = hashlib.sha256()
                for chunk in iter(lambda: f.read(1024*1024), b''): h.update(chunk)
                digest = h.hexdigest()
        lines.append(f'{digest}  {p.relative_to(stage).as_posix()}\n')
for p in sorted(stage.rglob('*'), reverse=True): os.utime(p, (int(epoch), int(epoch)))
os.utime(stage, (int(epoch), int(epoch)))
manifest = ''.join(lines)
(work/'payload.manifest').write_text(manifest)
seed = hashlib.sha256(manifest.encode()).hexdigest()
with (work/'ids').open('w') as f:
    for n in range(7): f.write(str(uuid.uuid5(uuid.NAMESPACE_URL, f'fidebook:{seed}:{n}'))+'\n')
PY

make_ext4_image() {
  # Arguments: NEW regular-image pathname, label, MiB, optional "verity", optional UUID.
  _ext_file=$1; _ext_label=$2; _ext_mb=$3; _ext_feature=${4:-}; _ext_uuid=${5:-}
  [ ! -e "$_ext_file" ] && [ ! -L "$_ext_file" ] || die "ext4 image already exists: $_ext_file"
  (set -C; : > "$_ext_file") || die "cannot reserve ext4 image: $_ext_file"
  truncate -s "${_ext_mb}M" "$_ext_file"
  # Explicit root ownership also works when building as an ordinary host user.
  # Fix UUID/hash seed in production; avoid lazy background initialization and discard.
  _ext_options=nodiscard,lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0
  [ -z "$_ext_uuid" ] || _ext_options=$_ext_options,hash_seed=$_ext_uuid
  set -- -F -q -t ext4 -E "$_ext_options" -m 0 -L "$_ext_label"
  [ -z "$_ext_uuid" ] || set -- "$@" -U "$_ext_uuid"
  if [ "$_ext_feature" = verity ]; then
    mke2fs "$@" -O verity "$_ext_file"
    dumpe2fs -h "$_ext_file" > "$_ext_file.features" 2>/dev/null
    grep '^Filesystem features:.*\bverity\b' "$_ext_file.features" >/dev/null || die "created /data image lacks fs-verity"
    rm "$_ext_file.features"
  else
    mke2fs "$@" "$_ext_file"
  fi
}

EFI_MB=256; SYS_MB=6400; META_MB=0; DATA_MB=0; EFI_LABEL=EFI; SYS_LABEL=FIDEBOOK
if [ "$BUILD_TYPE" = looper ]; then
  EFI_MB=512; SYS_MB=8192; META_MB=64; DATA_MB=$((DATA_GB * 1024)); EFI_LABEL=FIDE_EFI; SYS_LABEL=FIDESYS
fi
say "creating FAT images with unprivileged mkfs/mtools"
truncate -s "${EFI_MB}M" "$WORKP/p1.fat"
mkfs.fat --invariant -F 32 -i "$(sed -n '2p' "$WORK/ids" | tr -d '-' | cut -c1-8)" -n "$EFI_LABEL" "$WORKP/p1.fat" >/dev/null
mcopy -s -m -i "$WORKP/p1.fat" "$STAGE/efi/EFI" ::/
truncate -s "${SYS_MB}M" "$WORKP/p2.fat"
mkfs.fat --invariant -F 32 -i "$(sed -n '3p' "$WORK/ids" | tr -d '-' | cut -c1-8)" -n "$SYS_LABEL" "$WORKP/p2.fat" >/dev/null
mcopy -s -m -i "$WORKP/p2.fat" "$STAGE/fidebook/"* ::/
if [ "$BUILD_TYPE" = looper ]; then
  export E2FSPROGS_FAKE_TIME=$BUILD_EPOCH
  make_ext4_image "$WORKP/p3.ext4" FIDE_META "$META_MB" '' "$(sed -n '6p' "$WORK/ids")"
  make_ext4_image "$WORKP/p4.ext4" FIDE_DATA "$DATA_MB" verity "$(sed -n '7p' "$WORK/ids")"
fi
IMG_TMP=$WORK/image.img
truncate -s "$(((EFI_MB + SYS_MB + META_MB + DATA_MB + 2) * 1048576))" "$IMG_TMP"
{
  printf 'label: gpt\nlabel-id: %s\n' "$(sed -n '1p' "$WORK/ids")"
  printf 'start=2048, size=%s, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=%s, name="%s"\n' "$((EFI_MB * 2048))" "$(sed -n '2p' "$WORK/ids")" "$EFI_LABEL"
  printf 'size=%s, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, uuid=%s, name="%s"\n' "$((SYS_MB * 2048))" "$(sed -n '3p' "$WORK/ids")" "$SYS_LABEL"
  if [ "$BUILD_TYPE" = looper ]; then
    printf 'size=%s, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=%s, name="FIDE_META"\n' "$((META_MB * 2048))" "$(sed -n '4p' "$WORK/ids")"
    printf 'size=%s, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=%s, name="FIDE_DATA"\n' "$((DATA_MB * 2048))" "$(sed -n '5p' "$WORK/ids")"
  fi
} > "$WORK/layout.sfdisk"
sfdisk --no-reread --no-tell-kernel -q "$IMG_TMP" < "$WORK/layout.sfdisk"
dd if="$WORKP/p1.fat" of="$IMG_TMP" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$WORKP/p2.fat" of="$IMG_TMP" bs=1M seek="$((1 + EFI_MB))" conv=notrunc,sparse status=none
if [ "$BUILD_TYPE" = looper ]; then
  dd if="$WORKP/p3.ext4" of="$IMG_TMP" bs=1M seek="$((1 + EFI_MB + SYS_MB))" conv=notrunc,sparse status=none
  dd if="$WORKP/p4.ext4" of="$IMG_TMP" bs=1M seek="$((1 + EFI_MB + SYS_MB + META_MB))" conv=notrunc,sparse status=none
fi
mdir -i "$IMG_TMP@@$((1048576 * (1 + EFI_MB)))" ::/fidebook > "$WORK/directory.txt"
# Publish only after every assembly/verification step succeeds. link() is an atomic
# no-clobber operation; replace() with --force replaces a directory entry, never
# follows a target symlink or opens a physical device for writing.
python3 - "$WORK" "$IMG" "$FORCE" <<'PY'
import hashlib, os, pathlib, stat, sys
work, dest = map(pathlib.Path, sys.argv[1:3])
force = sys.argv[3] == '1'
h = hashlib.sha256()
with (work/'image.img').open('rb') as f:
    for chunk in iter(lambda: f.read(4*1024*1024), b''): h.update(chunk)
(work/'image.sha256').write_text(f'{h.hexdigest()}  {dest.name}\n')
artifacts = [(work/'payload.manifest', pathlib.Path(str(dest)+'.manifest')), (work/'image.sha256', pathlib.Path(str(dest)+'.sha256')), (work/'image.img', dest)]
for _, p in artifacts:
    if os.path.lexists(p):
        st = p.lstat()
        if not force or not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            sys.exit(f'ERROR: output appeared/changed during build; refusing to replace {p}')
created = []
try:
    for src, p in artifacts:
        if force: os.replace(src, p)
        else:
            os.link(src, p)
            created.append((src, p))
except OSError:
    for src, p in created:
        if p.exists() and os.path.samefile(src, p): p.unlink()
    raise
print((pathlib.Path(str(dest)+'.sha256')).read_text(), end='')
PY
say "created $IMG"
printf 'Logical size: %s bytes\n' "$(stat -c %s "$IMG")"
printf 'Physical size: %s (sparse file)\n' "$(du -h "$IMG" | cut -f1)"
printf 'Payload hashes: %s.manifest\n' "$IMG"
printf 'No physical disk was written. Flash separately only after checking the target drive.\n'
