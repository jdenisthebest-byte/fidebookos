#!/bin/sh
# Offline policy tests only: no ADB, physical device, downloads, or hardware I/O.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for script in usb/boot_policy.sh usb/optimize.sh usb/oobe_apply.sh; do
    sh -n "$ROOT/$script"
done
exec python3 "$ROOT/tools/test_boot_policy.py" "$@"
