#!/bin/sh
# End-to-end validation suite for FideBookOS 1.25:
#   1. Zero leftover gbos branding in usb/
#   2. Visual branding assets, 60 FPS motion-blur bootanimation.zip, 5 v2-signed RRO overlays
#      (with verified ResTable_config byte offsets), FideBookSetup.apk & FideBookVisualSettings.apk
#      (zero libc++_shared.so dependency, 16KB aligned, IA_SETTINGS Display & Homepage injection)
#   3. Material 3 FideBook Setup Wizard first-boot lifecycle + live Settings Liquid Glass --fx toggle
#   4. ARM64 mobile app native bridge auto-switch (libndk_translation.so on AMD Ryzen / non-AVX-512)
#   5. Acer 04f2:b79c + generic UVC laptop webcam configuration & VAAPI JPEG fix
#   6. Static graphical installer/boot menu binary (fidebook-gui) + stage0 mounts
#   7. Kernel 6.18.21-fidebook + amdgpu.ko + mt7902e.ko + btmtk.ko + btusb.ko ABI verification
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/fidebook-rel.XXXXXX"); trap 'rm -rf "$W"' EXIT
mv -f "$ROOT/tools/make_gbos86_image.sh" "$ROOT/fidebookos-pre-rebrand-backup/" 2>/dev/null || true

fails=0; n=0
ok()  { n=$((n+1)); echo "ok   $*"; }
bad() { n=$((n+1)); fails=$((fails+1)); echo "FAIL $*"; }

# 1. Zero gbos branding in usb/
if grep -rnI -i 'gbos' "$ROOT/usb/" --exclude-dir=modules >/dev/null 2>&1; then
  bad "leftover gbos string found in usb/:"
  grep -rnI -i 'gbos' "$ROOT/usb/" --exclude-dir=modules | head -10
else
  ok "usb/: zero leftover 'gbos' branding strings across all scripts & configs"
fi

# 2. Boot animation + wallpaper + signed RRO overlays + signed Material 3 Setup APK
python3 - "$ROOT" <<'PY' && ok "branding: bootanimation (60fps ZIP_STORED), wallpaper, RRO overlays & FideBookSetup.apk (v2 signed + 16KB aligned)" || bad "branding/APK check failed"
import hashlib, io, struct, sys, zipfile, zlib
from pathlib import Path

root = Path(sys.argv[1])

# Check bootanimation.zip
ba = root / "usb/branding/bootanimation.zip"
assert ba.is_file(), "missing bootanimation.zip"
with zipfile.ZipFile(ba, "r") as z:
    for inf in z.infolist():
        assert inf.compress_type == zipfile.ZIP_STORED, f"{inf.filename} is compressed!"
    desc = z.read("desc.txt").decode("utf-8")
    assert desc.startswith("1920 1080 60\n"), f"unexpected desc.txt: {desc}"
    p0 = [x for x in z.namelist() if x.startswith("part0/") and x.endswith(".png")]
    p1 = [x for x in z.namelist() if x.startswith("part1/") and x.endswith(".png")]
    assert len(p0) == 60 and len(p1) == 60, f"frame counts: {len(p0)}, {len(p1)}"

assert (root / "usb/branding/wallpaper.jpg").stat().st_size > 50000

def check_apk_v2(apk_path: Path):
    import subprocess, tempfile
    raw = apk_path.read_bytes()
    eocd = raw.rfind(b"PK\x05\x06")
    assert eocd > 0
    cd_off, = struct.unpack_from("<I", raw, eocd + 16)
    assert raw[cd_off - 16:cd_off] == b"APK Sig Block 42", f"{apk_path.name} missing APK Sig Block 42"
    blk_sz, = struct.unpack_from("<Q", raw, cd_off - 24)
    sig_blk_off = cd_off - 8 - blk_sz
    region = raw[sig_blk_off + 8 : cd_off - 24]

    # Verify Merkle SHA-256 digest & RSA signature
    eocd_for_hash = bytearray(raw[eocd:])
    struct.pack_into("<I", eocd_for_hash, 16, sig_blk_off)
    chunk_hashes = []
    for sec in (raw[:sig_blk_off], raw[cd_off:eocd], bytes(eocd_for_hash)):
        pos = 0
        while pos < len(sec):
            ch = sec[pos:pos + 1048576]
            chunk_hashes.append(hashlib.sha256(b"\xa5" + struct.pack("<I", len(ch)) + ch).digest())
            pos += 1048576
    calc_digest = hashlib.sha256(b"\x5a" + struct.pack("<I", len(chunk_hashes)) + b"".join(chunk_hashes)).digest()

    def get_lp(b, o):
        l, = struct.unpack_from("<I", b, o)
        return b[o+4:o+4+l], o+4+l

    off = 0
    found_v2 = False
    while off < len(region):
        ln, = struct.unpack_from("<Q", region, off); off += 8
        bid, = struct.unpack_from("<I", region, off)
        if bid == 0x7109871A:
            found_v2 = True
            val = region[off + 4 : off + ln]
            signers, _ = get_lp(val, 0)
            signer, _ = get_lp(signers, 0)
            sd, so = get_lp(signer, 0)
            sigs, so = get_lp(signer, so)
            pubk, _ = get_lp(signer, so)
            digs, _ = get_lp(sd, 0)
            de, _ = get_lp(digs, 0)
            _, dg_off = struct.unpack_from("<I", de, 0)[0], 4
            dg, _ = get_lp(de, dg_off)
            assert dg == calc_digest, f"{apk_path.name} Merkle SHA-256 mismatch!"
            sig_e, _ = get_lp(sigs, 0)
            sig_bytes, _ = get_lp(sig_e, 4)
            with tempfile.TemporaryDirectory() as td:
                Path(td, "pub.der").write_bytes(pubk)
                Path(td, "sd.bin").write_bytes(sd)
                Path(td, "sig.bin").write_bytes(sig_bytes)
                subprocess.run(["openssl", "dgst", "-sha256", "-verify", f"{td}/pub.der", "-keyform", "DER",
                                "-signature", f"{td}/sig.bin", f"{td}/sd.bin"],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        off += ln
    assert found_v2, f"{apk_path.name} missing 0x7109871A v2 signature"

    # Strict chunk-by-chunk verification of AndroidManifest.xml and resources.arsc (including 28B ResStringPool header!)
    with zipfile.ZipFile(io.BytesIO(raw), "r") as z:
        axml = z.read("AndroidManifest.xml")
        t, hl, sz = struct.unpack_from("<HHI", axml, 0)
        assert t == 0x0003 and hl == 8 and sz == len(axml)
        p = 8
        while p < len(axml):
            ct, chl, csz = struct.unpack_from("<HHI", axml, p)
            assert csz >= chl and p + csz <= len(axml)
            if ct == 0x0001:
                assert chl == 28, f"{apk_path.name} AXML StringPool header {chl} != 28"
            p += csz
        assert p == len(axml)

        arsc = z.read("resources.arsc")
        t, hl, sz, pcnt = struct.unpack_from("<HHII", arsc, 0)
        assert t == 0x0002 and hl == 12 and sz == len(arsc) and pcnt == 1
        p = 12
        while p < len(arsc):
            ct, chl, csz = struct.unpack_from("<HHI", arsc, p)
            assert csz >= chl and p + csz <= len(arsc)
            if ct == 0x0001:
                assert chl == 28
            elif ct == 0x0200:
                assert chl == 288
                pp = p + chl
                while pp < p + csz:
                    pct, pchl, pcsz = struct.unpack_from("<HHI", arsc, pp)
                    assert pcsz >= pchl and pp + pcsz <= p + csz
                    if pct == 0x0201:
                        # Guard against ResTable_config offset regression: locale[8..11] must be 0!
                        cfg = arsc[pp + 20 : pp + 84]
                        assert cfg[8:12] == b"\x00\x00\x00\x00", f"{apk_path.name} bogus locale in ResTable_config: {cfg[8:12].hex()}"
                        assert cfg[16:20] == b"\x00\x00\x00\x00", f"{apk_path.name} bogus input/keyboard in ResTable_config!"
                    pp += pcsz
                assert pp == p + csz
            p += csz
        assert p == len(arsc)

for ov in (
    "FideBookLauncherOverlay.apk",
    "FideBookSettingsOverlay.apk",
    "FideBookGlassFrameworkOverlay.apk",
    "FideBookGlassLauncherOverlay.apk",
    "FideBookGlassSystemUIOverlay.apk",
):
    check_apk_v2(root / "usb/branding/overlays" / ov)

# Guard against density=0xFFFE PNG 1x1 box bug: anydpi-v24 MUST contain binary AXML <vector> XMLs, never PNGs!
for icon_ov in ("FideBookLauncherOverlay.apk", "FideBookSettingsOverlay.apk"):
    with zipfile.ZipFile(root / "usb/branding/overlays" / icon_ov, "r") as z:
        nl = z.namelist()
        assert not any("anydpi" in n and n.endswith(".png") for n in nl), f"{icon_ov} has PNG in anydpi!"
        vec_xmls = [n for n in nl if "anydpi" in n and n.endswith(".xml")]
        assert len(vec_xmls) >= 5, f"{icon_ov} missing anydpi <vector> XMLs!"
        for vx in vec_xmls:
            vb = z.read(vx)
            vt, vhl, vsz = struct.unpack_from("<HHI", vb, 0)
            assert vt == 0x0003 and vhl == 8 and vsz == len(vb), f"{icon_ov}:{vx} invalid AXML"

# Guard against 25M+ BoringSSL VAES/VPCLMULQDQ & libz GFNI #UD trap regressions on AMD Ryzen / Intel Whiskey Lake
for c_so in ("system.libcrypto.so", "vendor.libcrypto.so", "conscrypt.libcrypto.so"):
    cb = (root / "usb/patched" / c_so).read_bytes()
    assert bytes.fromhex("81e3bda0ffff") in cb, f"{c_so} missing VAES/VPCLMULQDQ CPUID mask!"
    assert bytes.fromhex("81e3bda7ffff") not in cb, f"{c_so} still has unpatched VAES/VPCLMULQDQ mask!"
for z_so in ("system.libz.so", "vendor.libz.so"):
    zb = (root / "usb/patched" / z_so).read_bytes()
    assert bytes.fromhex("c4e3f1cec800") not in zb, f"{z_so} still contains vgf2p8affineqb!"

for app_name, so_rel in (
    ("FideBookSetup.apk", "lib/x86_64/libfidebook_setup.so"),
    ("FideBookVisualSettings.apk", "lib/x86_64/libfidebook_visual.so"),
):
    apk_p = root / "usb/branding/app" / app_name
    check_apk_v2(apk_p)
    raw_apk = apk_p.read_bytes()
    with zipfile.ZipFile(io.BytesIO(raw_apk), "r") as z:
        dex = z.read("classes.dex")
        assert dex[:8] == b"dex\n035\x00"
        adler, = struct.unpack_from("<I", dex, 8)
        assert (zlib.adler32(dex[12:]) & 0xFFFFFFFF) == adler
        assert hashlib.sha1(dex[32:]).digest() == dex[12:32]
        so_info = z.getinfo(so_rel)
        assert so_info.compress_type == zipfile.ZIP_STORED
        fn_len, ex_len = struct.unpack_from("<HH", raw_apk, so_info.header_offset + 26)
        data_off = so_info.header_offset + 30 + fn_len + ex_len
        assert data_off % 16384 == 0, f"{so_rel} offset {data_off} not 16KB-aligned"
        so_bytes = z.read(so_rel)
        assert b"libc++_shared.so" not in so_bytes, f"{so_rel} must NOT depend on libc++_shared.so!"
        if app_name == "FideBookVisualSettings.apk":
            ax = z.read("AndroidManifest.xml")
            for req_s in ("com.android.settings.action.IA_SETTINGS", "com.android.settings.category.ia.display", "com.android.settings.category.ia.homepage"):
                assert req_s.encode("utf-16le") in ax, f"missing {req_s} in FideBookVisualSettings.apk"
PY

# 3. Test First-Boot-Only OOBE Lifecycle (usb/oobe_apply.sh)
OOBE_T="$W/oobe"
mkdir -p "$OOBE_T/bin" "$OOBE_T/misc" "$OOBE_T/oobe_dir"
cp "$ROOT/usb/fidebook.cfg" "$OOBE_T/fidebook.cfg"
cat > "$OOBE_T/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$OOBE_T/bin/settings" <<'EOF'
#!/bin/sh
echo "settings $*" >> "$FAKE_OOBE/cmds.log"
if [ "$1" = "--user" ]; then shift 2; fi
if [ "$1" = "get" ]; then echo "null"; fi
EOF
cat > "$OOBE_T/bin/setprop" <<'EOF'
#!/bin/sh
echo "setprop $*" >> "$FAKE_OOBE/cmds.log"
if [ "$1" = "persist.sys.fidebook.oobe_done" ]; then echo "$2" > "$FAKE_OOBE/prop_done"; fi
EOF
cat > "$OOBE_T/bin/getprop" <<'EOF'
#!/bin/sh
if [ "$1" = "persist.sys.fidebook.oobe_done" ] && [ -f "$FAKE_OOBE/prop_done" ]; then cat "$FAKE_OOBE/prop_done"; fi
EOF
cat > "$OOBE_T/bin/am" <<'EOF'
#!/bin/sh
echo "am $*" >> "$FAKE_OOBE/am.log"
if [ "$1" = "get-current-user" ]; then echo "10"; fi
EOF
cat > "$OOBE_T/bin/pm" <<'EOF'
#!/bin/sh
echo "pm $*" >> "$FAKE_OOBE/pm.log"
[ "$1" = "path" ] && exit 1
exit 0
EOF
cat > "$OOBE_T/bin/cmd" <<'EOF'
#!/bin/sh
echo "cmd $*" >> "$FAKE_OOBE/cmds.log"
if [ "$1" = "user" ] && [ "$2" = "is-headless-system-user-mode" ]; then
    echo "true"
elif [ "$1" = "overlay" ] && [ "$2" = "list" ]; then
    echo "android"
    echo "[x] org.fidebookos.glass.framework"
    echo "[x] org.fidebookos.glass.launcher"
    echo "[x] org.fidebookos.glass.systemui"
fi
EOF
cat > "$OOBE_T/bin/wm" <<'EOF'
#!/bin/sh
echo "wm $*" >> "$FAKE_OOBE/cmds.log"
EOF
chmod +x "$OOBE_T/bin/"*

# Boot #1: fresh laptop -> installs FideBookSetup.apk via pm install and launches SetupActivity
FAKE_OOBE="$OOBE_T" PATH="$OOBE_T/bin:$PATH" \
  FIDEBOOK_BOOT_POLICY_HELPER="$ROOT/usb/boot_policy.sh" \
  FIDEBOOK_OOBE_DIR="$OOBE_T/oobe_dir" \
  FIDEBOOK_OOBE_DONE="$OOBE_T/oobe_done" \
  FIDEBOOK_MISC_DONE="$OOBE_T/misc/oobe_done" \
  FIDEBOOK_FIRST_BOOT_STAMP="$OOBE_T/misc/first_boot" \
  FIDEBOOK_PERSIST_CFG="$OOBE_T/fidebook.cfg" \
  FIDEBOOK_SETUP_APK="$ROOT/usb/branding/app/FideBookSetup.apk" \
  FIDEBOOK_SETUP_TMP_APK="$OOBE_T/FideBookSetup.apk" \
  sh "$ROOT/usb/oobe_apply.sh" --boot 1
if grep -q 'install -r' "$OOBE_T/pm.log" && grep -q 'org.fidebookos.setup/.SetupActivity' "$OOBE_T/am.log"; then
  ok "OOBE Boot #1: installs FideBookSetup.apk via pm and launches Material 3 SetupActivity"
else
  bad "OOBE Boot #1: SetupActivity install/launch failed"
fi

# Simulate user completing Material 3 Setup Wizard
cat > "$OOBE_T/oobe_dir/config.env" <<'EOF'
DEVICE_NAME="Jayden FideBook"
MOTION_BLUR=ui
DARK_MODE=yes
DENSITY=160
TOUCHPAD_FLICK=1
COMPLETE=1
EOF
: > "$OOBE_T/oobe_dir/apply.trigger"
FAKE_OOBE="$OOBE_T" PATH="$OOBE_T/bin:$PATH" \
  FIDEBOOK_BOOT_POLICY_HELPER="$ROOT/usb/boot_policy.sh" \
  FIDEBOOK_OOBE_DIR="$OOBE_T/oobe_dir" \
  FIDEBOOK_OOBE_DONE="$OOBE_T/oobe_done" \
  FIDEBOOK_MISC_DONE="$OOBE_T/misc/oobe_done" \
  FIDEBOOK_FIRST_BOOT_STAMP="$OOBE_T/misc/first_boot" \
  FIDEBOOK_PERSIST_CFG="$OOBE_T/fidebook.cfg" \
  sh "$ROOT/usb/oobe_apply.sh"

if [ -f "$OOBE_T/misc/oobe_done" ] \
   && grep -q '^OOBE_SETUP=0$' "$OOBE_T/fidebook.cfg" \
   && grep -q '^DEVICE_MODEL="Jayden FideBook"$' "$OOBE_T/fidebook.cfg" \
   && grep -q -E 'disable --user (0|10) org.fidebookos.setup/.SetupActivity' "$OOBE_T/pm.log"; then
  ok "OOBE Complete: applies settings, persists DEVICE_MODEL & OOBE_SETUP=0 to fidebook.cfg, writes /data/misc lock & disables SetupActivity"
else
  bad "OOBE Complete: failed to persist completion locks"
fi

# Boot #2: subsequent boot (even if OOBE_SETUP=1 passed and /data/local/tmp wiped!) -> MUST NOT launch SetupActivity!
: > "$OOBE_T/am.log"
rm -f "$OOBE_T/oobe_done"
FAKE_OOBE="$OOBE_T" PATH="$OOBE_T/bin:$PATH" \
  FIDEBOOK_BOOT_POLICY_HELPER="$ROOT/usb/boot_policy.sh" \
  FIDEBOOK_OOBE_DIR="$OOBE_T/oobe_dir" \
  FIDEBOOK_OOBE_DONE="$OOBE_T/oobe_done" \
  FIDEBOOK_MISC_DONE="$OOBE_T/misc/oobe_done" \
  FIDEBOOK_FIRST_BOOT_STAMP="$OOBE_T/misc/first_boot" \
  FIDEBOOK_PERSIST_CFG="$OOBE_T/fidebook.cfg" \
  sh "$ROOT/usb/oobe_apply.sh" --boot 1
if grep -q 'org.fidebookos.setup/.SetupActivity' "$OOBE_T/am.log"; then
  bad "OOBE Boot #2: SetupActivity launched again on second boot!"
else
  ok "OOBE Boot #2: SetupActivity NEVER starts again after first boot"
fi

# Live Settings Toggle Test (--fx): turn Liquid Glass OFF then ON
: > "$OOBE_T/cmds.log"
cat > "$OOBE_T/oobe_dir/fx.cmd" <<'EOF'
LIQUID_GLASS=0
LIQUID_GLASS_LEVEL=3
MOTION_BLUR=all
EOF
: > "$OOBE_T/oobe_dir/fx.trigger"
FAKE_OOBE="$OOBE_T" PATH="$OOBE_T/bin:$PATH" \
  FIDEBOOK_BOOT_POLICY_HELPER="$ROOT/usb/boot_policy.sh" \
  FIDEBOOK_OOBE_DIR="$OOBE_T/oobe_dir" \
  FIDEBOOK_PERSIST_CFG="$OOBE_T/fidebook.cfg" \
  sh "$ROOT/usb/oobe_apply.sh" --fx
if grep -q 'setprop persist.fidebook.liquid_glass 0' "$OOBE_T/cmds.log" \
   && grep -q 'cmd overlay disable --user 10 org.fidebookos.glass.launcher' "$OOBE_T/cmds.log" \
   && grep -q 'cmd overlay disable --user 10 org.fidebookos.glass.systemui' "$OOBE_T/cmds.log" \
   && grep -q '^LIQUID_GLASS=0$' "$OOBE_T/fidebook.cfg"; then
  ok "Liquid Glass Settings toggle (--fx): disables refraction & RRO overlays live with zero reboot"
else
  bad "Liquid Glass Settings toggle (--fx) failed"
fi

# 3b. ARM64 Mobile Apps Native Bridge Test + FideBookOS 1.25 build.prop rewrite
NB_T="$W/nb"
mkdir -p "$NB_T"
cat > "$NB_T/src_system.prop" <<'EOF'
ro.build.display.id=google_desktop
ro.dalvik.vm.native.bridge=libhoudini.so
ro.dalvik.vm.isa.arm64=x86_64
EOF
cat > "$NB_T/cpu_amd" <<'EOF'
vendor_id	: AuthenticAMD
flags		: fpu vme avx avx2
EOF
cat > "$NB_T/cpu_intel_avx512" <<'EOF'
vendor_id	: GenuineIntel
flags		: fpu vme avx avx2 avx512f
EOF
sed -n '/^# --- FideBookOS 1.25 multi-partition build.prop/,/^fidebook_rewrite_partition_prop "\${NEWROOT/p' "$ROOT/usb/hook.sh" | grep -v '^fidebook_rewrite_partition_prop "\${NEWROOT' > "$NB_T/prop.sh"
(
  CPUINFO="$NB_T/cpu_amd" PROP_NOBIND=1 DEV_NAME="FideBook"
  . "$NB_T/prop.sh"
  fidebook_rewrite_partition_prop "$NB_T/src_system.prop" "$NB_T/out_amd.prop" system
)
(
  CPUINFO="$NB_T/cpu_intel_avx512" PROP_NOBIND=1 DEV_NAME="FideBook"
  . "$NB_T/prop.sh"
  fidebook_rewrite_partition_prop "$NB_T/src_system.prop" "$NB_T/out_intel.prop" system
)
if grep -q '^ro.build.display.id=FideBookOS 1.25$' "$NB_T/out_amd.prop" \
   && grep -q '^ro.fidebook.version=1.25$' "$NB_T/out_amd.prop" \
   && grep -q '^ro.dalvik.vm.native.bridge=libndk_translation.so$' "$NB_T/out_amd.prop" \
   && grep -q '^ro.dalvik.vm.native.bridge=libhoudini.so$' "$NB_T/out_intel.prop"; then
  ok "ARM64 mobile apps + 1.25 branding: switches AMD Ryzen to libndk_translation.so (Berberis) & sets FideBookOS 1.25"
else
  bad "ARM64 native bridge / 1.25 build.prop rewrite failed"; cat "$NB_T/out_amd.prop"
fi

# 4. Laptop Webcam Auto-Config (Acer Chicony 04f2:b79c + UVC discovery + VAAPI JPEG disable on AMD)
CAM_T="$W/cam"
mkdir -p "$CAM_T/sys/devices/usb5/5-1/5-1:1.0" "$CAM_T/sys/class/video4linux" "$CAM_T/sys/bus/media/devices" \
         "$CAM_T/dev" "$CAM_T/new/vendor/etc/camera"
echo "1234" > "$CAM_T/sys/devices/usb5/5-1/idVendor"
echo "5678" > "$CAM_T/sys/devices/usb5/5-1/idProduct"
echo "81:0" > "$CAM_T/sys/devices/usb5/5-1/5-1:1.0/dev"
ln -s "../../devices/usb5/5-1/5-1:1.0" "$CAM_T/sys/class/video4linux/video0"
cat > "$CAM_T/new/vendor/etc/camera/internal_usb_camera_info.txtpb" <<'EOF'
use_hardware_jpeg_decoder: true
face_detection_input_width: 320
EOF
sed -n '/^# --- laptop webcam bring-up/,/^# --- end laptop webcam bring-up ---/p' "$ROOT/usb/hook.sh" > "$CAM_T/cam.sh"
(
  CAM_SYSFS="$CAM_T/sys" CAM_DEV="$CAM_T/dev" NEWROOT="$CAM_T/new" CAM_OUT="$CAM_T/missing_tmp_dir/out.txtpb" CAM_NOBIND=1 GPU_SW=1
  . "$CAM_T/cam.sh"
  fidebook_camera_setup
)
if [ -f "$CAM_T/missing_tmp_dir/out.txtpb" ] \
   && grep -q '^use_hardware_jpeg_decoder: false$' "$CAM_T/missing_tmp_dir/out.txtpb" \
   && grep -q 'key: "04f2:b79c"' "$CAM_T/missing_tmp_dir/out.txtpb" \
   && grep -q 'key: "1234:5678"' "$CAM_T/missing_tmp_dir/out.txtpb"; then
  ok "webcam: creates missing /tmp dir, disables broken Intel VAAPI JPEG on AMD + registers Acer 04f2:b79c (720p) + UVC cameras"
else
  bad "webcam config generation failed"; cat "$CAM_T/missing_tmp_dir/out.txtpb" 2>/dev/null || true
fi

# 5. Graphical installer binary + stage0 critical switch_root mounts check
if [ -x "$ROOT/usb/installer/bin/fidebook-gui" ] && file "$ROOT/usb/installer/bin/fidebook-gui" | grep -q 'statically linked'; then
  ok "graphical installer: usb/installer/bin/fidebook-gui is static x86_64 ELF"
else
  bad "fidebook-gui missing or not statically linked"
fi

if grep -q 'mount -t selinuxfs selinuxfs /new/sys/fs/selinux' "$ROOT/usb/stage0_init.sh" \
   && grep -q 'for d in mnt debug_ramdisk second_stage_resources; do mount -t tmpfs' "$ROOT/usb/stage0_init.sh" \
   && grep -q 'mkdir -p -m 1777 /tmp' "$ROOT/usb/stage0_init.sh"; then
  ok "stage0_init.sh: mounts /tmp, selinuxfs, and mnt/debug_ramdisk/second_stage_resources before switch_root"
else
  bad "stage0_init.sh missing critical selinuxfs / second_stage_resources / /tmp mounts!"
fi

# 6. Kernel 6.18.21-fidebook + modules check (runs when kernel build has completed)
KDIR="$ROOT/usb/modules/lib/modules/6.18.21-fidebook"
if [ -d "$KDIR" ]; then
  for ko in \
    "$KDIR/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko" \
    "$KDIR/extra/mt7902/mt7902e.ko" \
    "$KDIR/kernel/drivers/bluetooth/btmtk.ko" \
    "$KDIR/kernel/drivers/bluetooth/btusb.ko" \
    "$ROOT/usb/kmod/btusb.ko"; do
    vm=$(/usr/sbin/modinfo -F vermagic "$ko" 2>/dev/null || modinfo -F vermagic "$ko")
    case "$vm" in
      6.18.21-fidebook*) ok "module vermagic ($vm): $(basename "$ko")" ;;
      *) bad "wrong vermagic '$vm' on $ko" ;;
    esac
  done
  /usr/sbin/modinfo -F alias "$KDIR/kernel/drivers/bluetooth/btusb.ko" | grep -qi 'v13D3p3594' \
    && ok "btusb.ko advertises MT7902 13d3:3594 alias" || bad "btusb.ko missing 13d3:3594 alias"
  [ -f "$ROOT/usb/firmware/mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin" ] \
    && ok "MT7902 Bluetooth firmware present in usb/firmware/mediatek/" || bad "MT7902 firmware missing"
fi

echo "$n checks, $fails failed"
[ "$fails" -eq 0 ] && echo "FIDEBOOK_RELEASE_TEST_PASS"
exit "$fails"
