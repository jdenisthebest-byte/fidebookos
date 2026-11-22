#!/bin/sh
# port_build.sh [PARTS_DIR] [--write] [--isa] [--product]
#
# Port gbOS86 to a Google build (default PARTS_DIR: lapis/parts, filled by build.sh / tools/fetch_google_parts.py).
# Unpacks system, vendor, system_ext (+ product) and every APEX payload in the gbos-erofs container, then runs
# tools/port_build.py on them: re-applies the binary patches (libz, libcrypto, libkm_compat), regenerates the VINTF
# manifest and usb/patched/MANIFEST, checks every anchor the boot scripts rely on, and with --isa scans the build for
# instructions the kernel emulator does not cover. Without --write the repo is not touched.
#
#   PORT_KEEP=1   keep the unpacked build in the docker volume gbos-port-work (a re-run skips the ~minutes of unpacking)
#
# See porting.md.  Needs docker and the gbos-erofs image (docker build -t gbos-erofs tools/erofs-docker).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARTS=$ROOT/lapis/parts; WRITE=0; EXTRA=""; EXARGS=""; KC=""
while [ $# -gt 0 ]; do
  case $1 in
    --write) WRITE=1; EXTRA="$EXTRA --write";;
    --isa) EXTRA="$EXTRA --isa";;
    --product) EXARGS="--product";;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    -*) echo "unknown option $1"; exit 2;;
    *) PARTS=$(cd "$1" && pwd);;
  esac
  shift
done
for n in system_a vendor_a system_ext_a; do [ -f "$PARTS/$n.img" ] || { echo "missing $PARTS/$n.img (run ./build.sh, or tools/fetch_google_parts.py)"; exit 1; }; done
# kernel.config sits next to the partitions when lp_extract.py put it there
[ -f "$PARTS/kernel.config" ] && EXTRA="$EXTRA --kernel-config=/in/kernel.config"

# Fedora/RHEL (SELinux enforcing): bind mounts of this repo need :z (never relabel other directories)
Z=; [ "$(getenforce 2>/dev/null)" = Enforcing ] && Z=,z
RO=ro; [ $WRITE = 1 ] && RO=rw

if docker image inspect gbos-erofs >/dev/null 2>&1; then
  V=gbos-port-work; [ "${PORT_KEEP:-0}" = 1 ] || V=gbos-port-work-$$
  docker volume create $V >/dev/null
  trap '[ "${PORT_KEEP:-0}" = 1 ] || docker volume rm $V >/dev/null 2>&1' EXIT
  docker run --rm --network none -v $V:/work -v "$ROOT":/host:$RO$Z -v "$PARTS":/in:ro$Z gbos-erofs sh -ec "
    [ -f /work/.done ] || { rm -rf /work/*; python3 -I /host/tools/extract_build.py /in /work $EXARGS; }
    python3 -I /host/tools/port_build.py /work $EXTRA"
else
  # Offline fallback using local gbos-kbuild + kernel erofs loop mounts (zero network access needed)
  docker run --rm --privileged --network none -v "$ROOT":/host:$RO$Z -v "$PARTS":/in:ro$Z gbos-kbuild:latest sh -ec "
    for _li in \$(seq 0 63); do [ -b /dev/loop\$_li ] || mknod -m 0660 /dev/loop\$_li b 7 \$_li 2>/dev/null || true; done
    mkdir -p /work/system /work/vendor /work/system_ext /work/apex /tmp/apex_imgs
    cleanup_mounts() {
      for m in /work/apex/* /work/product /work/system_ext /work/vendor /work/system; do
        [ -d \"\$m\" ] && umount \"\$m\" 2>/dev/null || true
      done
    }
    trap cleanup_mounts EXIT
    mount -t erofs -o loop,ro /in/system_a.img /work/system
    mount -t erofs -o loop,ro /in/vendor_a.img /work/vendor
    mount -t erofs -o loop,ro /in/system_ext_a.img /work/system_ext
    if [ \"$EXARGS\" = \"--product\" ] && [ -f /in/product_a.img ]; then
      mkdir -p /work/product && mount -t erofs -o loop,ro /in/product_a.img /work/product
    fi
    python3 - << 'PY'
import glob, io, os, subprocess, zipfile
EROFS_MAGIC = bytes.fromhex('e2e1f5e0')
BIG = 64 << 20
idx = 0
for d in ['/work/system/system/apex', '/work/vendor/apex', '/work/system_ext/apex']:
    if not os.path.isdir(d): continue
    for f in sorted(os.listdir(d)):
        if not f.endswith(('.apex', '.capex')): continue
        name = f.rsplit('.', 1)[0]
        try:
            z = zipfile.ZipFile(os.path.join(d, f))
            if f.endswith('.capex'):
                z = zipfile.ZipFile(io.BytesIO(z.read('original_apex')))
            info = z.getinfo('apex_payload.img')
        except Exception:
            continue
        if info.file_size > BIG: continue
        pimg = f'/tmp/apex_imgs/{idx}_{name}.img'
        idx += 1
        with z.open(info) as s, open(pimg, 'wb') as o:
            o.write(s.read())
        with open(pimg, 'rb') as fh:
            fh.seek(1024)
            if fh.read(4) != EROFS_MAGIC: continue
        mp = f'/work/apex/{name}'
        os.makedirs(mp, exist_ok=True)
        subprocess.run(['mount', '-t', 'erofs', '-o', 'loop,ro', pimg, mp], check=False)
PY
    python3 -I /host/tools/port_build.py /work $EXTRA"
fi
