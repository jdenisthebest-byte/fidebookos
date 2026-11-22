#!/bin/sh
# Test of the multi-partition FideBookOS build.prop identity rewrite in usb/hook.sh
# (DEV_NAME / DEVICE_MODEL, DENSITY, sRGB display, fingerprint preservation, and fidebook_devname service).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/devmodel.XXXXXX"); trap 'rm -rf "$W"' EXIT
fail=0; n=0
ok()  { n=$((n+1)); echo "ok   $*"; }
bad() { n=$((n+1)); fail=$((fail+1)); echo "FAIL $*"; }

H="$ROOT/usb/hook.sh"
{
  awk '/^DEV_NAME=/{p=1} p{print} p&&/^\[ -n "\$DEV_NAME" \]/{exit}' "$H"
  awk '/^case "\$DENSITY" in/{p=1} p{print} /^\} > \/tmp\/vendor\.build\.prop/{exit}' "$H" \
    | sed -e 's# && mount --bind.*$##' \
          -e "s#/new/vendor/build.prop#$W/vendor.in.prop#g" \
          -e "s#/tmp/vendor.build.prop#$W/vendor.out.prop#g" \
          -e "s#/tmp/system.build.prop#$W/system.out.prop#g" \
          -e "s#/tmp/product.build.prop#$W/product.out.prop#g" \
          -e "s#/tmp/system_ext.build.prop#$W/system_ext.out.prop#g"
} > "$W/block.sh"
[ -s "$W/block.sh" ] && ok "identity block extracted from hook.sh ($(wc -l < "$W/block.sh") lines)" || { bad "block not found in hook.sh"; exit 1; }

mkdir -p "$W/new/system" "$W/new/product/etc" "$W/new/system_ext/etc"
cat > "$W/new/system/build.prop" <<'EOF'
ro.product.system.brand=Android
ro.product.system.model=Desktop System
ro.build.display.id=CL3B.260622.276.R5
EOF
cat > "$W/new/product/etc/build.prop" <<'EOF'
ro.product.product.brand=ASUS
ro.product.product.manufacturer=ASUS
ro.product.product.model=ASUS Googlebook 14
ro.product.build.fingerprint=ASUS/lapis/lapis:17/CL3B.260622.276.R5/16693588:user/release-keys
ro.build.display.id=CL3B.260622.276.R5
EOF
cat > "$W/new/system_ext/etc/build.prop" <<'EOF'
ro.product.system_ext.brand=ASUS
ro.product.system_ext.model=ASUS Googlebook 14
EOF
cat > "$W/vendor.in.prop" <<'EOF'
ro.product.vendor.model=ASUS Googlebook 14
ro.product.vendor.marketname=ASUS Googlebook 14
ro.product.vendor.brand=ASUS
ro.boot.hypervisor.protected_vm.supported=1
ro.sf.lcd_density=260
EOF

# 1. Default (DEVICE_MODEL unset -> defaults to "FideBook" across all 4 partitions, fingerprint preserved!)
NEWROOT="$W/new" PROP_NOBIND=1 DEVICE_MODEL= GPU_SW=0 DENSITY= sh "$W/block.sh"
grep -q '^ro.product.model=FideBook$' "$W/vendor.out.prop" \
  && grep -q '^ro.product.vendor.model=FideBook$' "$W/vendor.out.prop" \
  && grep -q '^ro.product.product.model=FideBook$' "$W/product.out.prop" \
  && grep -q '^ro.product.system_ext.model=FideBook$' "$W/system_ext.out.prop" \
  && grep -q '^ro.product.system.model=FideBook$' "$W/system.out.prop" \
  && ok "default identity: all 4 partitions report model=FideBook" \
  || bad "default identity missing FideBook across partitions"

grep -qi 'Googlebook' "$W/vendor.out.prop" "$W/product.out.prop" "$W/system_ext.out.prop" "$W/system.out.prop" \
  && bad "ASUS Googlebook 14 survived in build.prop" \
  || ok "zero 'ASUS Googlebook 14' left in any partition build.prop"

grep -q '^ro.product.build.fingerprint=ASUS/lapis/lapis:17/CL3B.260622.276.R5/16693588:user/release-keys$' "$W/product.out.prop" \
  && ok "GMS fingerprint preserved untouched" || bad "GMS fingerprint altered!"

grep -q '^ro.build.display.id=FideBookOS 1.0 Stable$' "$W/system.out.prop" \
  && grep -q '^ro.build.display.id=FideBookOS 1.0 Stable$' "$W/product.out.prop" \
  && ok "ro.build.display.id=FideBookOS 1.0 Stable" || bad "display.id missing"

grep -q 'protected_vm' "$W/vendor.out.prop" && bad "protected_vm not hidden" || ok "protected_vm.supported hidden"
grep -q '^ro.sf.lcd_density=260$' "$W/vendor.out.prop" && ok "stock density kept when DENSITY unset" || bad "density changed without DENSITY"

# 2. Custom DEVICE_MODEL + DENSITY
NEWROOT="$W/new" PROP_NOBIND=1 DEVICE_MODEL="FideBook Pro" GPU_SW=0 DENSITY=180 sh "$W/block.sh"
grep -q '^ro.product.vendor.model=FideBook Pro$' "$W/vendor.out.prop" \
  && grep -q '^ro.product.product.model=FideBook Pro$' "$W/product.out.prop" \
  && grep -q '^ro.sf.lcd_density=180$' "$W/vendor.out.prop" \
  && ok "custom DEVICE_MODEL and DENSITY applied cleanly" || bad "custom DEVICE_MODEL/DENSITY failed"

# 3. fidebook_devname service
grep -qF "settings put global device_name '\$DEV_NAME'" "$H" && ok "hook: fidebook_devname sets Settings.Global.device_name" || bad "hook: no device_name service"
grep -qF 'start fidebook_devname' "$H" && ok "hook: fidebook_devname is started" || bad "hook: fidebook_devname never started"
sh -n "$H" && ok "sh -n hook.sh" || bad "syntax"

echo "$n checks, $fail failed"
[ $fail = 0 ] && echo DEVICE_MODEL_TEST_PASS
exit $fail
