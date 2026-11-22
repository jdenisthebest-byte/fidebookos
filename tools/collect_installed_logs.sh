#!/bin/sh
# Copy the installed FideBookOS logs to the host user's home, READ-ONLY.
# Mounts FIDESYS (vfat) and FIDE_DATA (ext4, no journal replay) read-only, copies
# fidebook/logs plus Android's crash dropbox and package/overlay state, unmounts.
# Never writes to either partition.
#   sudo sh tools/collect_installed_logs.sh [OUT_DIR]   (default: ~/fidebook-logs-<date>)
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
U=${SUDO_USER:-root}
H=$(getent passwd "$U" | cut -d: -f6)
OUT=${1:-$H/fidebook-logs-$(date +%Y%m%d-%H%M%S)}
SYS=$(blkid -L FIDESYS || true)
DATA=$(blkid -L FIDE_DATA || true)
[ -b "$SYS" ] || { echo "no FIDESYS partition found" >&2; exit 1; }
M=$(mktemp -d /tmp/fidebook-logs.XXXXXX)
cleanup() { for d in "$M/sys" "$M/data"; do mountpoint -q "$d" && umount "$d"; done; rmdir "$M"/* "$M" 2>/dev/null || true; }
trap cleanup EXIT
mkdir -p "$M/sys" "$M/data" "$OUT"
mount -o ro "$SYS" "$M/sys"
[ -d "$M/sys/fidebook/logs" ] && cp -r "$M/sys/fidebook/logs" "$OUT/fidesys-logs"
cp "$M/sys/fidebook/fidebook.cfg" "$OUT/" 2>/dev/null || true
if [ -b "$DATA" ] && mount -o ro,noload "$DATA" "$M/data"; then
  D=$M/data
  mkdir -p "$OUT/data"
  [ -d "$D/system/dropbox" ] && cp -r "$D/system/dropbox" "$OUT/data/dropbox"
  for f in system/overlays.xml system/packages.xml system/users/userlist.xml; do
    [ -f "$D/$f" ] && cp "$D/$f" "$OUT/data/$(echo "$f" | tr / _)"
  done
  for r in "$D"/system/users/*/package-restrictions.xml; do
    [ -f "$r" ] && cp "$r" "$OUT/data/package-restrictions-user$(basename "$(dirname "$r")").xml"
  done
  [ -d "$D/tombstones" ] && cp -r "$D/tombstones" "$OUT/data/tombstones"
  [ -d "$D/anr" ] && cp -r "$D/anr" "$OUT/data/anr"
else
  echo "note: FIDE_DATA not copied (missing or not mountable read-only)" >&2
fi
chown -R "$U": "$OUT"
echo "copied to $OUT"
du -sh "$OUT"
