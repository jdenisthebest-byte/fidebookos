#!/bin/sh
# Compile the committed GLSL sources, validate the actual SPIR-V, then emit the
# C arrays used by the Android driver. This NEVER downloads or touches /w/mesa.
# Usage: build_shaders.sh [OUT_DIR]
# SHADER_TOOL_MODE=auto|host|container (default auto); RADV_BUILD_IMAGE overrides
# the already-cached gbos-radvbuild image. Container execution is always offline.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "${1:-}" = --help ]; then
    sed -n '2,7p' "$0"
    exit 0
fi
[ "$#" -le 1 ] || { echo "Usage: $0 [OUT_DIR]" >&2; exit 2; }
OUT=${1:-$HERE/../../build/radv-shaders}
mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)
MODE=${SHADER_TOOL_MODE:-auto}
case "$MODE" in auto|host|container) ;; *) echo "Invalid SHADER_TOOL_MODE: $MODE" >&2; exit 2 ;; esac
HAVE_HOST=1
for tool in glslangValidator spirv-val python3; do
    command -v "$tool" >/dev/null 2>&1 || HAVE_HOST=0
done
if [ "$MODE" = container ] || { [ "$MODE" = auto ] && [ "$HAVE_HOST" = 0 ]; }; then
    IMAGE=${RADV_BUILD_IMAGE:-gbos-radvbuild}
    if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "Shader tools unavailable: install cached glslangValidator + spirv-val + python3, or provide cached Docker image $IMAGE. No downloads attempted." >&2
        exit 1
    fi
    exec docker run --rm --pull=never --network none --platform linux/amd64 \
        --user "$(id -u):$(id -g)" -e SHADER_TOOL_MODE=host \
        -v "$HERE":/h:ro -v "$OUT":/out "$IMAGE" sh /h/build_shaders.sh /out
fi
if [ "$HAVE_HOST" = 0 ]; then
    echo "Host shader compilation requires glslangValidator, spirv-val and python3. No downloads attempted." >&2
    exit 1
fi
for shader in est apply glass_detect glass_apply; do
    glslangValidator -V --target-env vulkan1.0 -I"$HERE/shaders" \
        "$HERE/shaders/$shader.comp" -o "$OUT/$shader.spv"
    spirv-val --target-env vulkan1.0 "$OUT/$shader.spv"
done
python3 - "$OUT" <<'PY'
import pathlib
import struct
import sys

out = pathlib.Path(sys.argv[1])
shaders = (
    ("est", "est.h", "fidebook_mblur_est_spv"),
    ("apply", "apply.h", "fidebook_mblur_apply_spv"),
    ("glass_detect", "glass_det.h", "fidebook_glass_detect_spv"),
    ("glass_apply", "glass_app.h", "fidebook_glass_apply_spv"),
)
expected = [("dims", 0), ("ov_count", 8), ("level", 12), ("bg_valid", 16),
            ("bg_swizzle", 20), ("blur_px", 24), ("reserved", 28)]

def string(words):
    return struct.pack("<%dI" % len(words), *words).split(b"\0", 1)[0].decode()

def check_pc(words, name):
    names, offsets, types, structs = {}, {}, {}, {}
    pc_types = []
    pos = 5
    while pos < len(words):
        size, opcode = words[pos] >> 16, words[pos] & 0xffff
        if size == 0 or pos + size > len(words):
            raise SystemExit("Invalid SPIR-V instruction in " + name)
        args = words[pos + 1:pos + size]
        if opcode == 6:  # OpMemberName
            names[args[0], args[1]] = string(args[2:])
        elif opcode == 72 and args[2] == 35:  # OpMemberDecorate Offset
            offsets[args[0], args[1]] = args[3]
        elif opcode in (21, 23):  # OpTypeInt, OpTypeVector
            types[args[0]] = (opcode, args[1:])
        elif opcode == 30:  # OpTypeStruct
            structs[args[0]] = args[1:]
        elif opcode == 32 and args[1] == 9:  # OpTypePointer PushConstant
            pc_types.append(args[2])
        pos += size
    blocks = {typ for typ in pc_types if typ in structs}
    if len(blocks) != 1:
        raise SystemExit(name + ": expected exactly one push-constant block")
    block = blocks.pop()
    members = structs[block]
    actual = [(names.get((block, i)), offsets.get((block, i)))
              for i in range(len(members))]
    if actual != expected:
        raise SystemExit("%s: 32-byte glass PC ABI mismatch: %r" % (name, actual))
    for index, member in enumerate(members):
        typ = types[member]
        if index == 0:
            if typ[0] != 23 or typ[1][1] != 2:
                raise SystemExit(name + ": dims must be ivec2")
            typ = types[typ[1][0]]
        if typ != (21, (32, 1)):
            raise SystemExit(name + ": all PC components must be signed int32")
    print(name + ": verified 32-byte glass PC offsets 0,8,12,16,20,24,28")

headers = []
for source, header, symbol in shaders:
    data = (out / (source + ".spv")).read_bytes()
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    if words[0] != 0x07230203:
        raise SystemExit("Invalid SPIR-V magic in " + source)
    if source.startswith("glass_"):
        check_pc(words, source)
    rows = ["    " + ", ".join("0x%08x" % w for w in words[i:i + 8]) + ","
            for i in range(0, len(words), 8)]
    text = ("// Generated from validated shaders/%s.comp; do not edit.\n" % source +
            "static const uint32_t %s[] = {\n" % symbol + "\n".join(rows) + "\n};\n")
    (out / header).write_text("#pragma once\n#include <stdint.h>\n" + text)
    headers.append(text)
(out / "fidebook_mblur_spirv.h").write_text(
    "#pragma once\n#include <stdint.h>\n" + "\n".join(headers))
print("SHADERS_VALIDATED: 4 modules; headers emitted from the validated binaries")
PY
