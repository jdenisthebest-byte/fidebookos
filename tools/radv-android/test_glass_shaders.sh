#!/bin/sh
# Offline compute unit/integration tests of committed GLSL on synthetic fixtures.
# NOT an Android demo/app, driver/HAL integration test, or target-hardware proof.
# Usage: test_glass_shaders.sh [OUT_DIR]
# Needs cached shader tools (host or gbos-radvbuild), a host C compiler, Python 3,
# Vulkan headers/loader and lavapipe. Nothing is downloaded. Uses no ADB/target.
# Optional: FIDEBOOK_TEST_VALIDATION=1 requires an already-installed validation
# layer. GLASS_TEST_ICD may explicitly select a different offline test ICD file.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "${1:-}" = --help ]; then
    sed -n '2,8p' "$0"
    exit 0
fi
[ "$#" -le 1 ] || { echo "Usage: $0 [OUT_DIR]" >&2; exit 2; }
OUT=${1:-$HERE/../../build/radv-shader-tests}
mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)
CC=${CC:-cc}
for tool in "$CC" python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing cached host tool: $tool; no downloads attempted." >&2; exit 1; }
done
ICD=${GLASS_TEST_ICD:-/usr/share/vulkan/icd.d/lvp_icd.x86_64.json}
[ -r "$ICD" ] || { echo "Missing offline test ICD: $ICD; no downloads attempted." >&2; exit 1; }
# Override ambient driver selection so the default is CPU-only lavapipe, not a
# physical Android target or the host's render node. All input is controlled.
export VK_ICD_FILENAMES="$ICD" VK_DRIVER_FILES="$ICD"
export MESA_SHADER_CACHE_DISABLE=true PYTHONDONTWRITEBYTECODE=1
export LP_NUM_THREADS="${LP_NUM_THREADS:-4}"
sh "$HERE/build_shaders.sh" "$OUT/shaders"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -Wformat=2 \
    "$HERE/test_glass_shaders.c" -o "$OUT/test_glass_shaders" -lvulkan
python3 "$HERE/test_glass_shaders.py" --runner "$OUT/test_glass_shaders" \
    --shaders "$OUT/shaders" --work-dir "$OUT/cases"
