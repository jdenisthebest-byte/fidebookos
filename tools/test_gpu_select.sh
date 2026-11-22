#!/bin/sh
# Shell unit test of the GPU decision, gralloc/Vulkan bind logic, build.prop generation, and governor policy
# in usb/hook.sh and usb/optimize.sh (fake /sys and fake /new trees, no root, no mounts).
#   sh tools/test_gpu_select.sh
# Pulls the gbos_gpu_* block out of hook.sh between its marker comments, so what is tested is what boots.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK=$HERE/../usb/hook.sh
OPT=$HERE/../usb/optimize.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/gpusel.XXXXXX"); trap 'rm -rf "$T"' EXIT
sed -n '/^# --- software rendering for GPUs/,/^# --- end software rendering ---/p' "$HOOK" > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL: marker block not found in hook.sh"; exit 1; }
fails=0; n=0
log() { echo "$*" >> "$T/log"; }
sleep() { :; }
mount() { echo "$*" >> "$T/mounts"; return ${MOUNT_RC:-0}; }
sha256sum() { case "$1" in */libminigbm_gralloc.so) echo "${FAKE_GRALLOC_SHA:-d48536951fd0e9643e71a5c8843e90833ce3e212e182782185470e2fbbfad673}  $1";; */libgbm.so) echo "${FAKE_LIBGBM_SHA:-64a0f2537a5917822cb3f538dc74229e7ccf4ca45a30265bb97f742678ba294e}  $1";; */vulkan.intel.so) echo "${FAKE_VK_SHA:-5c687450523ea9ed9e8d4d9cc98ef4fef6c8d592d46db4bf425ad571dc6f7c73}  $1";; *) command sha256sum "$@" 2>/dev/null || shasum -a 256 "$@";; esac; }
. "$T/block.sh"

# fake sysfs: $1 = list of "cardN:driver" ("none" = unbound), $2 = list of "vendor:class" PCI devices
mk() {
  rm -rf "$T/sys" "$T/log" "$T/mounts"; mkdir -p "$T/sys/class/drm" "$T/sys/bus/pci/devices" "$T/drivers"
  for mc in $1; do
    mn=${mc%%:*}; md=${mc#*:}; mkdir -p "$T/sys/class/drm/$mn/device" "$T/sys/class/drm/$mn-eDP-1"
    [ "$md" = none ] || { mkdir -p "$T/drivers/$md"; ln -s "$T/drivers/$md" "$T/sys/class/drm/$mn/device/driver"; }
  done
  mi=0
  for mp in $2; do
    mi=$((mi+1)); pdir="$T/sys/bus/pci/devices/0000:00:0$mi.0"; mkdir -p "$pdir"
    echo "$mp" | cut -d: -f1 > "$pdir/vendor"
    echo "$mp" | cut -d: -f2 > "$pdir/class"
    mdev=$(echo "$mp" | cut -d: -f3)
    [ -n "$mdev" ] && echo "$mdev" > "$pdir/device"
  done
}
check() { # name expected(GPU_SW) cards pci [GPU_SOFTWARE]
  n=$((n+1)); mk "$3" "$4"; SYSFS=$T/sys; GPU_SOFTWARE=${5:-auto}; GPU_SW=x
  fidebook_gpu_decide 3
  if [ "$GPU_SW" = "$2" ]; then echo "ok   $1 -> $GPU_SW ($(tail -n1 $T/log | cut -c1-110))"; else echo "FAIL $1: wanted $2, got $GPU_SW"; cat "$T/log"; fails=$((fails+1)); fi
}
AMD=0x1002:0x030000; INTEL=0x8086:0x030000; NV=0x10de:0x030200
INTEL_BDW=0x8086:0x030000:0x1616; INTEL_HSW=0x8086:0x030000:0x0416
check "Intel i915 laptop"              0 "card0:i915"                "$INTEL"
check "Intel xe"                       0 "card0:xe"                  "$INTEL"
check "Intel Broadwell Gen 8 (legacy)" 1 "card0:i915"                "$INTEL_BDW"
check "Intel Haswell Gen 7.5 (legacy)" 1 "card0:i915"                "$INTEL_HSW"
check "Intel, i915 not bound yet"      0 "card0:simpledrm"           "$INTEL"
check "Intel Broadwell unbound"        1 "card0:simpledrm"           "$INTEL_BDW"
check "Intel + AMD dGPU (hybrid)"      0 "card0:i915 card1:amdgpu"   "$INTEL $AMD"
check "AMD amdgpu (reporter's laptop)" 1 "card0:amdgpu"              "$AMD"
check "AMD, simpledrm replaced"        1 "card1:amdgpu card0:simpledrm" "$AMD"
check "AMD but amdgpu did not bind"    0 "card0:simpledrm"           "$AMD"
check "AMD, no card at all"            0 ""                          "$AMD"
check "nouveau only"                   1 "card0:nouveau"             "$NV"
check "forced on Intel"                1 "card0:i915"                "$INTEL" 1
check "disabled on AMD"                0 "card0:amdgpu"              "$AMD" 0
check "vkms only"                      0 "card0:vkms"                ""

# enable: binds only over the exact originals, skips quietly when the stick has no files
# runenable NAME GRALLOC LIBGBM VULKAN SW_AFTER: expected 1 = bind attempted
runenable() {
  n=$((n+1)); rm -f "$T/log" "$T/mounts"; GPU_SW=1; fidebook_gpu_enable
  m=$(cat "$T/mounts" 2>/dev/null)
  g=0; b=0; v=0; case "$m" in *libminigbm_gralloc.so*) g=1;; esac; case "$m" in *lib64/libgbm.so*) b=1;; esac; case "$m" in *vulkan.intel.so*) v=1;; esac
  if [ $g = $2 ] && [ $b = $3 ] && [ $v = $4 ] && [ "$GPU_SW" = $5 ]; then echo "ok   enable: $1 (gralloc=$g gbm=$b vk=$v sw=$GPU_SW hw_radv=$GPU_HW_RADV)"
  else echo "FAIL enable: $1: gralloc=$g gbm=$b vk=$v sw=$GPU_SW hw_radv=$GPU_HW_RADV"; cat "$T/log"; fails=$((fails+1)); fi
}
G=$T/fidebook; NEWROOT=$T/new; mkdir -p $G/patched $NEWROOT/vendor/lib64/hw
: > $NEWROOT/vendor/lib64/libgbm.so; : > $NEWROOT/vendor/lib64/libminigbm_gralloc.so; : > $NEWROOT/vendor/lib64/hw/vulkan.intel.so
runenable "stick without the files (old stick)" 0 0 0 0
: > $G/patched/libgbm.amdgpu.so; : > $G/patched/vulkan.swiftshader.so; : > $G/patched/libminigbm_gralloc.amdgpu.so
runenable "all files, originals match" 1 1 1 1
FAKE_VK_SHA=deadbeef; runenable "unknown vulkan.intel.so (new Google build)" 1 1 0 0; unset FAKE_VK_SHA
FAKE_GRALLOC_SHA=deadbeef; runenable "unknown libminigbm_gralloc.so" 0 1 1 0; unset FAKE_GRALLOC_SHA
FAKE_LIBGBM_SHA=deadbeef; runenable "unknown libgbm.so (not essential)" 1 0 1 1; unset FAKE_LIBGBM_SHA
rm $G/patched/vulkan.swiftshader.so
runenable "no SwiftShader HAL on the stick" 1 1 0 0
: > $G/patched/vulkan.swiftshader.so; MOUNT_RC=1; runenable "bind fails" 1 1 1 0; unset MOUNT_RC

# RADV + gralloc split: RADV uses libminigbm_gralloc.amdgpu.so (AB24) and sets GPU_HW_RADV=1;
# SwiftShader / legacy Intel uses libminigbm_gralloc.swr.so (XB24) and sets GPU_HW_RADV=0.
radvmount() { grep -q "vulkan.radv.so" "$T/mounts" 2>/dev/null && echo radv || { grep -q "vulkan.swiftshader.so" "$T/mounts" 2>/dev/null && echo swiftshader || echo none; }; }
grallocmount() { grep -q "libminigbm_gralloc.swr.so" "$T/mounts" 2>/dev/null && echo swr || { grep -q "libminigbm_gralloc.amdgpu.so" "$T/mounts" 2>/dev/null && echo amdgpu || echo none; }; }
rv() { # name expected_vk expected_hw_radv expected_gralloc
  n=$((n+1)); runenable_quiet; r=$(radvmount); gm=$(grallocmount)
  if [ "$r" = "$2" ] && [ "$GPU_HW_RADV" = "$3" ] && [ "$gm" = "$4" ]; then
    echo "ok   vulkan: $1 -> vk=$r hw_radv=$GPU_HW_RADV gralloc=$gm"
  else
    echo "FAIL vulkan: $1: wanted vk=$2 hw_radv=$3 gralloc=$4, got vk=$r hw_radv=$GPU_HW_RADV gralloc=$gm"; cat "$T/log"; fails=$((fails+1))
  fi
}
runenable_quiet() { rm -f "$T/log" "$T/mounts"; GPU_SW=1; fidebook_gpu_enable; }
: > $G/patched/libminigbm_gralloc.swr.so
mk "card0:amdgpu" "$AMD"; SYSFS=$T/sys; : > $G/patched/vulkan.swiftshader.so
rv "amdgpu, no RADV on the stick" swiftshader 0 swr
: > $G/patched/vulkan.radv.so
rv "amdgpu + RADV on the stick" radv 1 amdgpu
GPU_VULKAN=swiftshader; rv "forced SwiftShader" swiftshader 0 swr
GPU_VULKAN=radv; rv "forced RADV" radv 1 amdgpu; unset GPU_VULKAN
mk "card0:nouveau" "$NV"; SYSFS=$T/sys; rv "other GPU driver, RADV present" swiftshader 0 swr
mk "card0:i915" "$INTEL_BDW"; SYSFS=$T/sys; rv "Intel Broadwell legacy, RADV present" swiftshader 0 swr
mk "card0:amdgpu" "$AMD"; SYSFS=$T/sys; FAKE_VK_SHA=deadbeef; rv "unknown vulkan.intel.so" none 0 amdgpu; unset FAKE_VK_SHA
FAKE_GRALLOC_SHA=deadbeef; rv "RADV bound but gralloc SHA mismatch cancels GPU_HW_RADV" radv 0 none; unset FAKE_GRALLOC_SHA

# vendor build.prop rewrite: verify BOTH Optimized Hardware AMD RADV Mode (GPU_SW=1, GPU_HW_RADV=1)
# AND CPU SwiftShader Mode (GPU_SW=1, GPU_HW_RADV=0) AND Intel Stock Mode (GPU_SW=0).
sed -n '/^DROP=/,/^} > \/tmp\/vendor.build.prop/p' "$HOOK" | sed "s#/new/vendor/build.prop#$T/vendor.build.prop#g; s#/tmp/vendor.build.prop#$T/out.prop#g; s#^} > .*#}#" > "$T/prop.sh"
printf 'ro.hwui.use_vulkan=true\nvendor.hwc.drm.enable_color_pipeline=true\nvendor.hwc.use_log_gamma_lut=true\nro.sf.lcd_density=260\n' > "$T/vendor.build.prop"

# 1. Hardware AMD RADV Mode (GPU_SW=1, GPU_HW_RADV=1)
n=$((n+1))
( GPU_SW=1; GPU_HW_RADV=1; DENSITY=; DEV_NAME=FideBook; . "$T/prop.sh" > "$T/out.prop" ) 2>/dev/null
if grep -q '^ro.fidebook.gpu_mode=radv$' "$T/out.prop" \
   && ! grep -q '^ro.fidebook.software_rendering=' "$T/out.prop" \
   && [ "$(grep -c '^ro.hwui.use_vulkan=' "$T/out.prop")" = 1 ] \
   && grep -q '^ro.hwui.use_vulkan=true$' "$T/out.prop" \
   && grep -q '^debug.renderengine.backend=skiavkthreaded$' "$T/out.prop" \
   && grep -q '^debug.renderengine.vulkan=true$' "$T/out.prop" \
   && grep -q '^vendor.hwc.drm.enable_color_pipeline=false$' "$T/out.prop" \
   && [ "$(grep -c '^vendor.hwc.use_log_gamma_lut=' "$T/out.prop")" = 1 ] \
   && grep -q '^vendor.hwc.use_log_gamma_lut=false$' "$T/out.prop" \
   && grep -q '^vendor.hwc.backend_override=client$' "$T/out.prop" \
   && grep -q '^ro.surface_flinger.supports_background_blur=1$' "$T/out.prop" \
   && grep -q '^ro.surface_flinger.max_frame_buffer_acquired_buffers=3$' "$T/out.prop" \
   && ! grep -q '^ro.surface_flinger.default_composition_pixel_format=' "$T/out.prop"; then
  echo "ok   build.prop: Hardware AMD RADV mode -> Vulkan HWUI + skiavkthreaded + blur=1 + client HWC + linear gamma + no software_rendering"
else
  echo "FAIL build.prop: Hardware AMD RADV mode"; cat "$T/out.prop"; fails=$((fails+1))
fi

# 2. Hardware AMD RADV Mode with GPU_HWUI_VULKAN=0 escape hatch
n=$((n+1))
( GPU_SW=1; GPU_HW_RADV=1; GPU_HWUI_VULKAN=0; DENSITY=; DEV_NAME=FideBook; . "$T/prop.sh" > "$T/out.prop" ) 2>/dev/null
if grep -q '^ro.hwui.use_vulkan=false$' "$T/out.prop" && grep -q '^debug.renderengine.backend=skiavkthreaded$' "$T/out.prop"; then
  echo "ok   build.prop: Hardware AMD RADV mode respects GPU_HWUI_VULKAN=0"
else
  echo "FAIL build.prop: GPU_HWUI_VULKAN=0"; cat "$T/out.prop"; fails=$((fails+1))
fi

# 3. CPU SwiftShader Mode (GPU_SW=1, GPU_HW_RADV=0)
n=$((n+1))
mk "card0:amdgpu" "$AMD"; SYSFS=$T/sys
( GPU_SW=1; GPU_HW_RADV=0; DENSITY=; DEV_NAME=FideBook; . "$T/prop.sh" > "$T/out.prop" ) 2>/dev/null
if grep -q '^ro.fidebook.gpu_mode=swiftshader$' "$T/out.prop" \
   && grep -q '^ro.fidebook.software_rendering=1$' "$T/out.prop" \
   && [ "$(grep -c '^ro.hwui.use_vulkan=' "$T/out.prop")" = 1 ] \
   && grep -q '^ro.hwui.use_vulkan=false$' "$T/out.prop" \
   && grep -q '^debug.renderengine.backend=skiaglthreaded$' "$T/out.prop" \
   && grep -q '^debug.renderengine.vulkan=false$' "$T/out.prop" \
   && grep -q '^ro.surface_flinger.supports_background_blur=0$' "$T/out.prop" \
   && grep -q '^ro.surface_flinger.default_composition_pixel_format=2$' "$T/out.prop" \
   && grep -q '^vendor.hwc.drm.use_overlay_planes=0$' "$T/out.prop" \
   && grep -q '^vendor.hwc.drm.enable_color_pipeline=false$' "$T/out.prop"; then
  echo "ok   build.prop: CPU SwiftShader mode -> software_rendering=1 + skiaglthreaded + hwui_vk=false + blur=0 + XB24"
else
  echo "FAIL build.prop: CPU SwiftShader mode"; cat "$T/out.prop"; fails=$((fails+1))
fi

# 4. Intel Stock Mode (GPU_SW=0)
n=$((n+1))
( GPU_SW=0; GPU_HW_RADV=0; DENSITY=; DEV_NAME=FideBook; . "$T/prop.sh" > "$T/out.prop" ) 2>/dev/null
if grep -q '^ro.hwui.use_vulkan=true$' "$T/out.prop" \
   && grep -q '^vendor.hwc.drm.enable_color_pipeline=true$' "$T/out.prop" \
   && ! grep -q '^ro.surface_flinger.default_composition_pixel_format=' "$T/out.prop" \
   && ! grep -q '^ro.fidebook.software_rendering=' "$T/out.prop"; then
  echo "ok   build.prop: Intel stock keeps ro.hwui.use_vulkan=true and color_pipeline=true"
else
  echo "FAIL build.prop: Intel stock"; cat "$T/out.prop"; fails=$((fails+1))
fi

# 5. optimize.sh CPU governor policy: schedutil on hardware GPU (AMD RADV / Intel) vs performance on SwiftShader
awk '/^if \[ "\$\(getprop ro\.fidebook\.software_rendering\)" = 1 \]; then/{p=1} p{print} p&&/^fi$/{exit}' "$OPT" > "$T/gov.sh"
sed "s#/sys/devices/system/cpu#$T/cpusys#g" "$T/gov.sh" > "$T/gov_test.sh"
mkdir -p "$T/cpusys/cpu0/cpufreq" "$T/cpusys/cpu7/cpufreq"
echo "conservative ondemand userspace powersave performance schedutil" > "$T/cpusys/cpu0/cpufreq/scaling_available_governors"
for c in cpu0 cpu7; do echo performance > "$T/cpusys/$c/cpufreq/scaling_governor"; echo performance > "$T/cpusys/$c/cpufreq/energy_performance_preference"; done

n=$((n+1))
( getprop() { echo ""; }; . "$T/gov_test.sh" )
if [ "$(cat "$T/cpusys/cpu0/cpufreq/scaling_governor")" = schedutil ] && [ "$(cat "$T/cpusys/cpu7/cpufreq/scaling_governor")" = schedutil ] \
   && [ "$(cat "$T/cpusys/cpu7/cpufreq/energy_performance_preference")" = balance_performance ]; then
  echo "ok   optimize.sh: hardware GPU (RADV/Intel) selects schedutil + balance_performance across all CPUs"
else
  echo "FAIL optimize.sh hardware GPU governor"; fails=$((fails+1))
fi

n=$((n+1))
( getprop() { echo "1"; }; . "$T/gov_test.sh" )
if [ "$(cat "$T/cpusys/cpu0/cpufreq/scaling_governor")" = performance ] && [ "$(cat "$T/cpusys/cpu7/cpufreq/scaling_governor")" = performance ] \
   && [ "$(cat "$T/cpusys/cpu7/cpufreq/energy_performance_preference")" = performance ]; then
  echo "ok   optimize.sh: CPU SwiftShader selects performance + performance across all CPUs"
else
  echo "FAIL optimize.sh SwiftShader governor"; fails=$((fails+1))
fi

[ $fails = 0 ] && echo "GPU_SELECT_TEST_PASS ($n checks)" || { echo "$fails FAILED"; exit 1; }
