#!/bin/sh
# Fast deploy to a mounted FideBookOS USB stick: copies only changed files from usb/, verifies after remount, ejects.
# Usage: tools/deploy_stick.sh [--no-eject] [VOLUME]      (VOLUME defaults to /Volumes/FIDEBOOK)
set -e
EJECT=1; [ "${1:-}" = "--no-eject" ] && { EJECT=0; shift; }
VOL=${1:-/Volumes/FIDEBOOK}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
U=$ROOT/usb
G=$VOL/fidebook
[ -d "$G" ] || { echo "no fidebook folder on $VOL: plug the stick in (it mounts as /Volumes/FIDEBOOK or /run/media/\$USER/FIDEBOOK)"; exit 1; }
CHANGED=$(mktemp); trap 'rm -f "$CHANGED"' EXIT

put() {  # put SRC DST(relative to fidebook/): copy when different
  [ -f "$1" ] || return 0
  if ! cmp -s "$1" "$G/$2" 2>/dev/null; then
    mkdir -p "$(dirname "$G/$2")"
    printf '  %s\n' "$2"
    dd if="$1" of="$G/$2.part" bs=1048576 2>/dev/null && mv -f "$G/$2.part" "$G/$2"
    echo "$2" >> "$CHANGED"
  fi
}

echo "deploying FideBookOS updates to $VOL"
for f in hook.sh oobe_apply.sh install.sh aidiag.sh play_diagnostics.sh native_zygote.sh optimize.sh early_patch.sh hwdetect.sh apex_patch.sh crossystem libkm_compat.so system_ext_manifest.xml soft_gk Add-FideBookOS-to-Windows-BootMenu.bat; do
  put "$U/$f" "$f"
done
for d in branding patched audio installer kmod ksu a11y surface; do
  [ -d "$U/$d" ] || continue
  (cd "$U" && find "$d" -type f ! -name '.DS_Store') | while read -r f; do put "$U/$f" "$f"; done
done

MODS=$U/modules/lib/modules
if [ -d "$MODS" ]; then
  R=$(ls "$MODS" | head -1)
  if [ -n "$R" ] && ! cmp -s "$MODS/$R/fidebook-build-id" "$G/modules/lib/modules/$R/fidebook-build-id" 2>/dev/null; then
    printf '  modules/ (kernel %s: the stick has %s)\n' "$R" "$(ls "$G/modules/lib/modules" 2>/dev/null | tr '\n' ' ')"
    rm -rf "$G/modules" && cp -R "$U/modules" "$G/modules" && echo "modules/lib/modules/$R/fidebook-build-id" >> "$CHANGED"
  elif [ -n "$R" ]; then
    for mf in "$MODS/$R/kernel/drivers/bluetooth/btusb.ko" "$MODS/$R/kernel/drivers/bluetooth/btmtk.ko" "$MODS/$R/extra/mt7902/mt7902e.ko" "$MODS/$R"/modules.*; do
      [ -f "$mf" ] && put "$mf" "${mf#$U/}"
    done
  fi
fi

[ -s "$CHANGED" ] || echo "  nothing to copy: the stick already matches usb/"
sync

if command -v diskutil >/dev/null 2>&1; then
  DEV=$(diskutil info "$VOL" 2>/dev/null | awk -F: '/Device Identifier/{gsub(/ /,"",$2); print $2}')
  WHOLE=$(diskutil info "$VOL" 2>/dev/null | awk -F: '/Part of Whole/{gsub(/ /,"",$2); print $2}')
  if [ -n "$DEV" ] && [ -s "$CHANGED" ]; then
    diskutil unmount "$VOL" >/dev/null && diskutil mount "$DEV" >/dev/null
  fi
fi

BAD=0
while read -r f; do
  cmp -s "$U/$f" "$G/$f" || { echo "VERIFY FAILED: $f"; BAD=1; }
done < "$CHANGED"
[ $BAD = 0 ] || { echo "some files did not verify; the stick is NOT ejected"; exit 1; }
echo "verified $(wc -l < "$CHANGED" | tr -d ' ') file(s)"
if [ $EJECT = 1 ] && [ -n "${WHOLE:-}" ] && command -v diskutil >/dev/null 2>&1; then
  sync; diskutil unmount "$VOL" >/dev/null 2>&1 || true
  diskutil eject "/dev/$WHOLE" | tail -1
fi
