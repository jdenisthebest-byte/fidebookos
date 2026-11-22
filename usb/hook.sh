# FideBookOS pre-Android hook: sourced by stage0 just before switch_root (Android root at /new,
# helpers log/fail/shell and $G=/fidebook/fidebook available). Edit freely, no kernel rebuild needed.

# /dev/null must be the character device (1,3). If an early redirect on an empty /dev tmpfs created
# /dev/null as a regular file before mknod, Android's zygote_next audits fd offsets on SpawnSubspecies
# children and aborts them ("Reinitialization" / EBADF). Recreate atomically if needed.
if [ ! -c /dev/null ]; then
  rm -f /dev/.fidebook-null
  if mknod -m 666 /dev/.fidebook-null c 1 3 && mv -f /dev/.fidebook-null /dev/null && [ -c /dev/null ]; then
    log "hook: /dev/null was a regular file, recreated as character device (1,3)"
  else
    rm -f /dev/.fidebook-null
    log "hook: /dev/null is not a character device and could not be recreated"
  fi
fi

# Ensure /tmp always exists in stage0 before any helper writes temporary bind-mount files
mkdir -p -m 1777 /tmp 2>/dev/null || true

# Reset one-shot MODE=live back to MODE=ask so subsequent boots prompt the user in the graphical menu
if [ -f "$G/fidebook.cfg" ] && grep -q '^MODE=live' "$G/fidebook.cfg" 2>/dev/null; then
  sed -i 's/^MODE=live/MODE=ask/' "$G/fidebook.cfg" 2>/dev/null || true
  sync 2>/dev/null || true
fi

# Library patches. patched/MANIFEST (written by tools/port_build.py) has one line per patch: kind, the path in the Android root
# (/new/...), the sha256 of the exact original the patch was made from, and the patched file (relative to fidebook/). A patch is
# bound only over a file with that hash, so a new Google build never gets a stale patch: the line says "NOT patched" and shows
# the hash it found, which is what tools/port_build.sh needs to regenerate the patch. kind "early" = also bound by early_patch.sh
# before the first dmctl (then already mounted here), "apex" lines belong to apex_patch.sh.
fidebook_bind_patches() {
  fp_ok=0; fp_bad=0
  if [ ! -f $G/patched/MANIFEST ]; then
    log "hook: PATCH-STATUS patched/MANIFEST missing: no library patches (SHA-NI/AVX-VNNI code will be emulated, very slow)"
    return 0
  fi
  while read -r fp_kind fp_target fp_want fp_file fp_rest; do
    case $fp_kind in early|bind) ;; *) continue;; esac
    if grep -q " $fp_target " /proc/mounts; then
      log "hook: $fp_target already patched (early_patch.sh)"; fp_ok=$((fp_ok+1))
    elif [ ! -f $G/$fp_file ]; then
      log "hook: $fp_target NOT patched (missing $fp_file)"; fp_bad=$((fp_bad+1))
    elif [ ! -f $fp_target ]; then
      log "hook: $fp_target NOT patched (not in this Google build)"; fp_bad=$((fp_bad+1))
    else
      fp_have=$(sha256sum $fp_target | cut -d' ' -f1)
      if [ "$fp_have" != "$fp_want" ]; then
        log "hook: $fp_target NOT patched (original is $fp_have, patch was made for $fp_want: run tools/port_build.sh)"; fp_bad=$((fp_bad+1))
      elif mount --bind $G/$fp_file $fp_target; then
        log "hook: patched $fp_target ($fp_file) active"; fp_ok=$((fp_ok+1))
      else
        log "hook: $fp_target NOT patched (bind mount failed)"; fp_bad=$((fp_bad+1))
      fi
    fi
  done < $G/patched/MANIFEST
  log "hook: PATCH-STATUS $fp_ok applied, $fp_bad not applied"
}

# Google's userspace needs AVX2: the dynamic linker and bionic libc (__linker_init: vxorps/vmovups ymm, vpbroadcastb)
# use AVX2 instructions, and the kernel's emulator only covers the newer extensions (GFNI, VNNI, SHA-NI, ...),
# not baseline AVX/AVX2. REQUIRE_AVX=0 in fidebook.cfg skips this check.
if [ "${REQUIRE_AVX:-1}" != 0 ]; then
  if ! grep -qw avx2 ${CPUINFO:-/proc/cpuinfo}; then
    log "CPU: $(grep -m1 'model name' ${CPUINFO:-/proc/cpuinfo})"
    if ! grep -qw avx ${CPUINFO:-/proc/cpuinfo}; then
      fail "this CPU has no AVX, so Android init cannot run on it (not fixable by drivers). Power off, or type exit to try anyway (REQUIRE_AVX=0 in fidebook.cfg skips this check)."
    else
      fail "this CPU lacks AVX2 instruction support (Sandy/Ivy Bridge 2nd/3rd Gen). Userspace executes AVX2 (vpbroadcastb) in init/linker64, requiring Intel 4th Gen Haswell+ or AMD Zen+. Power off, or type exit to try anyway (REQUIRE_AVX=0 in fidebook.cfg skips this check)."
    fi
  fi
fi

# zram is a module here (=m in Google's config too); mmd_setup aborts without /sys/block/zram0.
modprobe zram && log "hook: zram loaded" || log "hook: modprobe zram FAILED"

# Speakup synth probing without serial hardware causes kernel panic on modern platforms: disable synth probe
[ -e /sys/accessibility/speakup/synth ] && echo "none" > /sys/accessibility/speakup/synth 2>/dev/null

# Generic hardware bring-up (FideBookOS for any Intel gen6+ or AMD laptop): usb/hwdetect.sh binds the full module tree from
# fidebook/modules, coldplugs every device by modalias (Wi-Fi, Bluetooth, audio, webcam, input, hotkeys, backlight, ...),
# runs hardware-aware USB Bluetooth bring-up (MediaTek MT7902 13d3:3594, Intel, Realtek, QCA, Broadcom) with firmware
# from fidebook/firmware, and writes hwdetect.txt.
FWP=/sys/module/firmware_class/parameters/path
# Symlink /postinstall -> /fidebook in stage0 so /postinstall/fidebook/firmware resolves identically both before and after switch_root,
# preventing async firmware loads (e.g. btmtk MT7902 ~2.8s WMT setup or amdgpu/mt7902e) from hitting ENOENT across the handoff.
[ -d /fidebook ] && [ ! -e /postinstall ] && ln -s /fidebook /postinstall 2>/dev/null || true
[ -d $G/firmware ] && echo -n $G/firmware > $FWP 2>/dev/null || true
if [ "$HWDETECT" != 0 ] && [ -f $G/hwdetect.sh ] && [ -d $G/modules/lib/modules ]; then
  . $G/hwdetect.sh
  fidebook_hwdetect 15
  grep -q '^zram ' /proc/modules || { modprobe zram && log "hook: zram loaded (after hwdetect)" || log "hook: modprobe zram FAILED (after hwdetect)"; }
else
  # Fallback when HWDETECT=0 or fidebook/modules is absent: Wi-Fi + hardware-aware USB Bluetooth using $G/kmod.
  if [ -f $G/firmware/iwlwifi-9000-pu-b0-jf-b0-46.ucode ] && grep -qi '0x8086' /sys/bus/pci/devices/*/vendor 2>/dev/null; then
    echo -n $G/firmware > $FWP
    grep -q '^iwlmvm ' /proc/modules || { modprobe iwlmvm && log "hook: iwlmvm loaded" || log "hook: modprobe iwlmvm FAILED"; }
    i=0; while [ $i -lt 15 ] && ! dmesg | grep -q 'iwlwifi.*loaded firmware version'; do sleep 1; i=$((i+1)); done
    log "hook: wifi after ${i}s: $(dmesg | grep -m1 -o 'iwlwifi.*loaded firmware version.*') ifaces: $(ls /sys/class/net | tr '\n' ' ')"
  fi

  if [ -f $G/hwdetect.sh ]; then
    . $G/hwdetect.sh
    fidebook_bt_init 12 || true
  elif [ -f $G/kmod/btusb.ko ]; then
    echo -n $G/firmware > $FWP
    grep -q '^bluetooth ' /proc/modules || modprobe bluetooth 2>/dev/null || true
    grep -q '^btbcm ' /proc/modules || modprobe btbcm 2>/dev/null || true
    [ -f $G/kmod/btmtk.ko ] && ! grep -q '^btmtk ' /proc/modules && insmod $G/kmod/btmtk.ko 2>/dev/null || true
    [ -f $G/kmod/btintel.ko ] && ! grep -q '^btintel ' /proc/modules && insmod $G/kmod/btintel.ko 2>/dev/null || true
    [ -f $G/kmod/btrtl.ko ] && ! grep -q '^btrtl ' /proc/modules && insmod $G/kmod/btrtl.ko 2>/dev/null || true
    grep -q '^btusb ' /proc/modules || insmod $G/kmod/btusb.ko 2>/dev/null \
      && log "hook: btusb fallback loaded ($(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' '))" \
      || log "hook: btusb fallback FAILED"
  fi
fi

# --- software rendering for GPUs Google's image has no driver for (AMD) -- fidebook_gpu_* functions ---
# Google's image ships only Intel's ANV (/vendor/lib64/hw/vulkan.intel.so), and minigbm (/vendor/lib64/libminigbm_gralloc.so)
# has no amdgpu backend. On AMD Radeon laptops, FideBookOS binds our optimized hardware Mesa RADV Vulkan 1.4 multi-queue driver
# (with GPU scroll motion blur) over vulkan.intel.so + AB24 gralloc/libgbm; on legacy Intel Gen <= 8 or unsupported GPUs, it falls
# back to SwiftShader + XB24 gralloc.
# GPU_SOFTWARE in fidebook.cfg: auto (default), 1 (force), 0 (never). SYSFS= and NEWROOT= are for tools/test_gpu_select.sh.
FIDEBOOK_GRALLOC_SHA=d48536951fd0e9643e71a5c8843e90833ce3e212e182782185470e2fbbfad673
FIDEBOOK_LIBGBM_SHA=64a0f2537a5917822cb3f538dc74229e7ccf4ca45a30265bb97f742678ba294e
FIDEBOOK_VKINTEL_SHA=5c687450523ea9ed9e8d4d9cc98ef4fef6c8d592d46db4bf425ad571dc6f7c73
# "cardN driver" per DRM card (connectors like card0-eDP-1 are skipped); driver "none" = no driver bound.
fidebook_gpu_cards() {
  for c in ${SYSFS:-/sys}/class/drm/card*; do
    [ -e "$c" ] || continue
    case ${c##*/} in card*-*) continue;; esac
    d=$(readlink $c/device/driver 2>/dev/null); d=${d##*/}
    echo "${c##*/} ${d:-none}"
  done
}
# A driver that really drives a GPU, as opposed to the firmware framebuffer (simpledrm) or the virtual test driver (vkms).
fidebook_gpu_real() { case "$1" in none|simpledrm|simple-framebuffer|efifb|vesafb|vkms) return 1;; esac; return 0; }
# PCI display controllers (class 0x03xxxx) by vendor: "yes" when one is Intel's.
fidebook_gpu_intel_pci() {
  for d in ${SYSFS:-/sys}/bus/pci/devices/*; do
    [ -e "$d/class" ] || continue
    case "$(cat $d/class)" in 0x03*) [ "$(cat $d/vendor)" = 0x8086 ] && return 0;; esac
  done
  return 1
}
# Checks if an Intel GPU has native Vulkan hardware support in Google's image (Gen 9 Skylake+).
fidebook_gpu_intel_has_vulkan() {
  [ "${1:-}" = xe ] && return 0

  _ver=$(dmesg 2>/dev/null | grep -m1 -o 'integrated display version [0-9]*' | awk '{print $4}')
  if [ -n "$_ver" ] && [ "$_ver" -lt 9 ] 2>/dev/null; then return 1; fi
  if dmesg 2>/dev/null | grep -qiE 'Found (broadwell|haswell|ivybridge|sandybridge|valleyview|cherryview)'; then return 1; fi

  for _d in ${SYSFS:-/sys}/bus/pci/devices/*; do
    [ -e "$_d/class" ] || continue
    case "$(cat "$_d/class" 2>/dev/null)" in 0x03*)
      [ "$(cat "$_d/vendor" 2>/dev/null)" = 0x8086 ] || continue
      _dev=$(cat "$_d/device" 2>/dev/null | tr '[A-Z]' '[a-z]')
      case "$_dev" in
        0x16*) return 1;; # Broadwell Gen 8
        0x04*|0x0a*|0x0c*|0x0d*) return 1;; # Haswell Gen 7.5
        0x0f*|0x22*) return 1;; # Valleyview / Cherryview
        0x015*|0x016*) return 1;; # Ivy Bridge Gen 7
        0x010*|0x011*|0x012*) return 1;; # Sandy Bridge Gen 6
      esac
      ;;
    esac
  done
  return 0
}
# Sets GPU_SW=1 (non-Intel / legacy GPU override wanted) or 0 and logs why. $1 = seconds to wait for a non-Intel driver to bind.
fidebook_gpu_decide() {
  GPU_SW=0
  GPU_HW_RADV=0
  case "${GPU_SOFTWARE:-auto}" in
    0) log "hook: GPU override: off (GPU_SOFTWARE=0)"; return 0;;
    1) GPU_SW=1; log "hook: GPU override: on (GPU_SOFTWARE=1, forced)"; return 0;;
  esac
  w=0; real=; intel=
  while :; do
    real=; intel=
    for e in $(fidebook_gpu_cards | tr ' ' ','); do
      drv=${e#*,}
      case "$drv" in i915|xe) intel=$drv;; *) fidebook_gpu_real "$drv" && real="$real ${e%%,*}:$drv";; esac
    done
    if [ -n "$intel" ]; then
      if fidebook_gpu_intel_has_vulkan "$intel"; then
        log "hook: GPU override: off (auto; Intel GPU driver $intel bound, Gen 9+ hardware Vulkan supported)"
        return 0
      else
        GPU_SW=1
        log "hook: GPU override: on (auto; Intel GPU driver $intel bound, Gen <= 8 uses SwiftShader)"
        return 0
      fi
    fi
    if fidebook_gpu_intel_pci; then
      if fidebook_gpu_intel_has_vulkan ""; then
        log "hook: GPU override: off (auto; Intel display controller present)"
        return 0
      else
        GPU_SW=1
        log "hook: GPU override: on (auto; Intel display controller present, Gen <= 8 uses SwiftShader)"
        return 0
      fi
    fi
    [ -n "$real" ] && break
    [ $w -ge ${1:-0} ] && break
    sleep 1; w=$((w+1))
  done
  if [ -n "$real" ]; then
    GPU_SW=1; log "hook: GPU override: on (auto; non-Intel DRM:$real, after ${w}s)"
  else
    log "hook: GPU override: off (auto; no DRM GPU driver bound after ${w}s; cards: $(fidebook_gpu_cards | tr '\n' ';'))"
  fi
}
# Bind patched/$2 over $3 when it exists and $3 is the exact original ($4 = its sha256). $1 = what it is, for the log.
fidebook_gpu_bind() {
  if [ ! -f "$G/patched/$2" ]; then log "hook: GPU override: fidebook/patched/$2 missing ($1 not replaced)"; return 1; fi
  if [ "$(sha256sum "$3" | cut -d' ' -f1)" != "$4" ]; then log "hook: GPU override: $1 NOT replaced (unexpected original, new Google build?)"; return 1; fi
  mount --bind "$G/patched/$2" "$3" && log "hook: GPU override: $1 replaced" || { log "hook: GPU override: $1 bind FAILED"; return 1; }
}
# radv or swiftshader: which Vulkan driver to use (GPU_VULKAN=radv|swiftshader forces one; auto = RADV when amdgpu is bound).
fidebook_gpu_vulkan() {
  case "${GPU_VULKAN:-auto}" in
    swiftshader) echo swiftshader; return 0;;
    radv) echo radv; return 0;;
  esac
  if [ -f "$G/patched/vulkan.radv.so" ] && fidebook_gpu_cards | grep -q ' amdgpu$'; then echo radv; else echo swiftshader; fi
}
# Bind gralloc + libgbm + Vulkan HAL (RADV hardware AMD Vulkan 1.4 multi-queue or SwiftShader CPU fallback).
fidebook_gpu_enable() {
  GPU_HW_RADV=0
  V=${NEWROOT:-/new}/vendor
  _vk_target=$(fidebook_gpu_vulkan)
  _gralloc_so=libminigbm_gralloc.amdgpu.so
  if [ "$_vk_target" != radv ] && [ -f "$G/patched/libminigbm_gralloc.swr.so" ]; then
    _gralloc_so=libminigbm_gralloc.swr.so
  fi
  fidebook_gpu_bind "gralloc (libminigbm_gralloc, $_gralloc_so)" "$_gralloc_so" $V/lib64/libminigbm_gralloc.so $FIDEBOOK_GRALLOC_SHA || GPU_SW=0
  fidebook_gpu_bind "libgbm (amdgpu backend)" libgbm.amdgpu.so $V/lib64/libgbm.so $FIDEBOOK_LIBGBM_SHA
  if [ "$_vk_target" = radv ] && fidebook_gpu_bind "Vulkan driver (RADV, AMD hardware GPU)" vulkan.radv.so $V/lib64/hw/vulkan.intel.so $FIDEBOOK_VKINTEL_SHA; then
    [ "$GPU_SW" = 1 ] && GPU_HW_RADV=1
  else
    fidebook_gpu_bind "Vulkan driver (SwiftShader, CPU)" vulkan.swiftshader.so $V/lib64/hw/vulkan.intel.so $FIDEBOOK_VKINTEL_SHA || GPU_SW=0
  fi
}
# --- end software rendering ---

# Let the DRM driver (amdgpu probes for several seconds and loads firmware) finish before deciding.
fidebook_gpu_decide ${GPU_WAIT:-25}
[ "$GPU_SW" = 1 ] && fidebook_gpu_enable
# Late firmware requests (after switch_root) see the stick/disk as /postinstall/fidebook/firmware.
echo -n /postinstall/fidebook/firmware > $FWP 2>/dev/null || true

# Set up DRM device nodes cleanly before switch_root
fidebook_drm_setup() {
  mkdir -p -m 0755 /dev/dri
  for _c in /sys/class/drm/card[0-9]* /sys/class/drm/renderD[0-9]*; do
    [ -f "$_c/dev" ] || continue
    _name=${_c##*/}
    _dev=$(cat "$_c/dev")
    [ -c "/dev/dri/$_name" ] || mknod -m 0666 "/dev/dri/$_name" c ${_dev%:*} ${_dev#*:}
  done
  _prim=
  for _s in /sys/class/drm/card*-*/status; do
    [ -f "$_s" ] || continue
    if grep -q '^connected' "$_s" 2>/dev/null; then
      _prim=${_s%/status}; _prim=${_prim##*/}; _prim=${_prim%%-*}; break
    fi
  done
  if [ -z "$_prim" ]; then
    for _c in /sys/class/drm/card[0-9]*; do
      case ${_c##*/} in card*-*) continue;; esac
      _drv=$(readlink "$_c/device/driver" 2>/dev/null); _drv=${_drv##*/}
      case "$_drv" in i915|xe|amdgpu|nouveau|radeon) _prim=${_c##*/}; break;; esac
    done
  fi
  if [ -n "$_prim" ] && [ "$_prim" != "card0" ] && [ -f "/sys/class/drm/$_prim/dev" ]; then
    _pdev=$(cat "/sys/class/drm/$_prim/dev")
    rm -f /dev/dri/card0
    mknod -m 0666 /dev/dri/card0 c ${_pdev%:*} ${_pdev#*:}
    log "hook: primary display on $_prim ($_pdev), mapped to /dev/dri/card0"
  fi
  chmod 0666 /dev/dri/* 2>/dev/null || true
}
fidebook_drm_setup

# --- laptop webcam bring-up (tested by tools/test_fidebook_release.sh) ---
# Google's desktop USB camera HAL (/vendor/bin/hw/android.hardware.camera.provider-usb-service.android-desktop) reads
# /vendor/etc/camera/internal_usb_camera_info.txtpb. Two issues block non-reference laptops:
#   1. Line 1 sets `use_hardware_jpeg_decoder: true`, which calls Intel-only HardwareJpegDecoderVaapi::new (libcros_libva.dylib.so)
#      and panics with Option::unwrap() on AMD Radeon / non-VAAPI systems. Setting `use_hardware_jpeg_decoder: false` when GPU_SW=1
#      switches cleanly to Google's built-in software MJPEG decoder.
#   2. Built-in laptop UVC cameras (such as Acer Aspire A315-24P's Chicony 04f2:b79c `ACER HD User Facing`) are only exposed as
#      FACING_FRONT internal Camera 0 if their USB VID:PID is present in `camera_modules`.
fidebook_camera_append_module() { # $1=vid:pid $2=width $3=height $4=out_file
  grep -qi "key:[[:space:]]*\"$1\"" "$4" 2>/dev/null && return 1
  cat >> "$4" <<CAM_EOF
camera_modules {
  key: "$1"
  value {
    lens_info {
      available_focal_lengths: 1.8
      minimum_focus_distance: 0.25
      optimal_focus_distance: 0.5
      available_apertures: 2.0
    }
    sensor_info {
      physical_size {
        width: 2.7288
        height: 1.5498
      }
      pixel_array_size {
        width: $2
        height: $3
      }
      active_array {
        left: 0
        top: 0
        right: $2
        bottom: $3
      }
    }
    enable_face_detection: true
    facing: FACING_FRONT
  }
}
CAM_EOF
  return 0
}

fidebook_camera_setup() {
  _cam_sys=${CAM_SYSFS:-/sys}
  _cam_dev=${CAM_DEV:-/dev}
  _cam_cfg=${NEWROOT:-/new}/vendor/etc/camera/internal_usb_camera_info.txtpb
  _cam_out=${CAM_OUT:-/tmp/internal_usb_camera_info.txtpb}

  # Create V4L2 /dev/video* and /dev/media* character devices before switch_root
  for _vd in "$_cam_sys"/class/video4linux/video* "$_cam_sys"/bus/media/devices/media*; do
    [ -f "$_vd/dev" ] || continue
    _vn=${_vd##*/}
    _vmm=$(cat "$_vd/dev" 2>/dev/null)
    case "$_vmm" in [0-9]*:[0-9]*)
      [ -c "$_cam_dev/$_vn" ] || mknod -m 0666 "$_cam_dev/$_vn" c "${_vmm%:*}" "${_vmm#*:}" 2>/dev/null || true
      chmod 0666 "$_cam_dev/$_vn" 2>/dev/null || true
      ;;
    esac
  done

  [ -f "$_cam_cfg" ] || return 0
  mkdir -p -m 1777 "$(dirname "$_cam_out")" 2>/dev/null || true
  cp "$_cam_cfg" "$_cam_out" || return 0
  chmod 0644 "$_cam_out" 2>/dev/null || true

  if [ "${GPU_SW:-0}" = 1 ]; then
    sed -i 's/^use_hardware_jpeg_decoder:[[:space:]]*true/use_hardware_jpeg_decoder: false/' "$_cam_out"
  fi

  _cam_added=""
  # Always register Acer Aspire A315-24P built-in HD webcam (Chicony 04f2:b79c, native 1280x720)
  if fidebook_camera_append_module "04f2:b79c" 1280 720 "$_cam_out"; then
    _cam_added="04f2:b79c"
  fi

  # Auto-discover any other connected UVC camera on /sys/class/video4linux/video*
  for _vd in "$_cam_sys"/class/video4linux/video*; do
    [ -e "$_vd" ] || continue
    _vp=$(readlink -f "$_vd/device" 2>/dev/null)
    while [ -n "$_vp" ] && [ "$_vp" != "/" ]; do
      if [ -f "$_vp/idVendor" ] && [ -f "$_vp/idProduct" ]; then
        _vid=$(tr 'A-Z' 'a-z' < "$_vp/idVendor" 2>/dev/null | tr -d '\r\n ')
        _pid=$(tr 'A-Z' 'a-z' < "$_vp/idProduct" 2>/dev/null | tr -d '\r\n ')
        if [ -n "$_vid" ] && [ -n "$_pid" ]; then
          if fidebook_camera_append_module "${_vid}:${_pid}" 1920 1080 "$_cam_out"; then
            _cam_added="${_cam_added:+$_cam_added }${_vid}:${_pid}"
          fi
        fi
        break
      fi
      _vp=$(dirname "$_vp")
    done
  done

  if [ "${CAM_NOBIND:-0}" != 1 ]; then
    mount --bind "$_cam_out" "$_cam_cfg" \
      && log "hook: camera config bound (sw_jpeg=${GPU_SW:-0}, added=${_cam_added:-none}, nodes=$(ls "$_cam_dev"/video* 2>/dev/null | tr '\n' ' '))"
  fi
}
# --- end laptop webcam bring-up ---
fidebook_camera_setup

# Maximize CPU governor during early boot; optimize.sh switches hardware GPUs to schedutil at boot_completed.
for _g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$_g" 2>/dev/null || true
done
for _e in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
  echo performance > "$_e" 2>/dev/null || true
done

# Gate heavy diagnostic tracing behind DEBUG_TELEMETRY=1 (default 0 for FideBookOS 1.0 Stable release)
if [ "${DEBUG_TELEMETRY:-0}" = 1 ]; then
  echo 0x04 > /sys/module/drm/parameters/debug 2>/dev/null && log "hook: drm.debug=0x04 (DEBUG_TELEMETRY=1)"
fi

# FideBookOS visual branding: 60 FPS motion-blur boot animation + Dock "F" & Settings static RRO overlays
if [ -f "$G/branding/bootanimation.zip" ] && [ -f /new/system/media/bootanimation.zip ]; then
  mount --bind "$G/branding/bootanimation.zip" /new/system/media/bootanimation.zip \
    && log "hook: FideBookOS 60fps motion-blur bootanimation active"
fi

if [ -d "$G/branding/overlays" ] && [ -d /new/product/overlay ]; then
  mkdir -p /tmp/poverlay
  if mount --bind /new/product/overlay /tmp/poverlay \
     && { mount -t tmpfs -o mode=0755,context=u:object_r:system_file:s0 tmpfs /new/product/overlay 2>/dev/null \
          || mount -t tmpfs -o mode=0755 tmpfs /new/product/overlay; }; then
    for _of in /tmp/poverlay/*; do
      [ -e "$_of" ] || continue
      _on=${_of##*/}
      if [ -d "$_of" ]; then
        mkdir -p "/new/product/overlay/$_on" && mount --bind "$_of" "/new/product/overlay/$_on"
      else
        touch "/new/product/overlay/$_on" && mount --bind "$_of" "/new/product/overlay/$_on"
      fi
    done
    _ov_cnt=0
    for _fapk in "$G"/branding/overlays/*.apk; do
      [ -f "$_fapk" ] || continue
      cp "$_fapk" "/new/product/overlay/${_fapk##*/}" && chmod 0644 "/new/product/overlay/${_fapk##*/}" && _ov_cnt=$((_ov_cnt + 1))
    done
    log "hook: FideBookOS RRO overlays active ($_ov_cnt branded APKs in /product/overlay)"
  else
    log "hook: product/overlay tmpfs mount FAILED"
  fi
fi

# Inject FideBookVisualSettings.apk into /system/app so Android Settings (TileUtils IA_SETTINGS)
# surfaces "Liquid Glass & Motion" natively in Settings -> Display & touch and Settings Homepage
if [ -f "$G/branding/app/FideBookVisualSettings.apk" ] && [ -d /new/system/app ]; then
  mkdir -p /tmp/sysapp
  if mount --bind /new/system/app /tmp/sysapp \
     && { mount -t tmpfs -o mode=0755,context=u:object_r:system_file:s0 tmpfs /new/system/app 2>/dev/null \
          || mount -t tmpfs -o mode=0755 tmpfs /new/system/app; }; then
    for _sa in /tmp/sysapp/*; do
      [ -e "$_sa" ] || continue
      _san=${_sa##*/}
      if [ -d "$_sa" ]; then
        mkdir -p "/new/system/app/$_san" && mount --bind "$_sa" "/new/system/app/$_san"
      else
        touch "/new/system/app/$_san" && mount --bind "$_sa" "/new/system/app/$_san"
      fi
    done
    mkdir -p -m 0755 /new/system/app/FideBookVisualSettings
    if cp "$G/branding/app/FideBookVisualSettings.apk" /new/system/app/FideBookVisualSettings/FideBookVisualSettings.apk \
       && chmod 0644 /new/system/app/FideBookVisualSettings/FideBookVisualSettings.apk; then
      log "hook: FideBookVisualSettings.apk active in /system/app (Liquid Glass & Motion Settings entry)"
    fi
  else
    log "hook: /system/app tmpfs mount FAILED"
  fi
fi

# Fake ChromeOS boot disk for the boot HAL: misc + vbmeta_a/vbmeta_b with cgpt slot attributes.
if [ -f $G/bootdisk.img ]; then
  losetup -P /dev/loop6 $G/bootdisk.img; sleep 1; mdev -s
  mknod -m 600 /dev/block/loop6 b 7 6 2>/dev/null
  i=1
  for n in misc vbmeta_a vbmeta_b; do
    [ -e /dev/block/loop6p$i ] || mknod -m 600 /dev/block/loop6p$i b $(tr : ' ' < /sys/class/block/loop6p$i/dev)
    ln -sf /dev/block/loop6p$i /dev/block/by-name/$n
    i=$((i+1))
  done
  for b in boot_a boot_b vendor_boot_a vendor_boot_b init_boot_a init_boot_b; do
    ln -sf /dev/block/loop6p1 /dev/block/by-name/$b
  done
  log "hook: bootdisk on loop6: $(ls /sys/class/block | grep loop6p | tr '\n' ' ')"
fi

# Mask SetupWizard APK directories so Android skips initial setup and launches Desktop directly
mkdir -p /tmp/empty_suw
for suw_dir in /new/product/priv-app/*SetupWizard* /new/system_ext/priv-app/*SetupWizard* /new/product/priv-app/*setupwizard* /new/system_ext/priv-app/*setupwizard*; do
  if [ -d "$suw_dir" ]; then
    mount --bind /tmp/empty_suw "$suw_dir" && log "hook: masked $suw_dir with empty dir"
  fi
done

# Fake crossystem (no ChromeOS firmware on this laptop)
[ -f $G/crossystem ] && mount --bind $G/crossystem /new/vendor/bin/crossystem && log "hook: crossystem faked"

# Resolve device identity (default: "FideBook"; "auto" reads laptop DMI; custom string uses that name)
DEV_NAME="${DEVICE_MODEL:-FideBook}"
if [ "$DEV_NAME" = "auto" ]; then
  _prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr -d '\000\r\n' | sed -e 's/[[:space:]]\+/ /g' -e 's/^ *//; s/ *$//')
  _vend=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr -d '\000\r\n' | sed -e 's/[[:space:]]\+/ /g' -e 's/^ *//; s/ *$//')
  case "$_prod" in
    ''|'None'|'Default string'|'System Product Name'|'To be filled by O.E.M.'|'System Version') _prod="" ;;
  esac
  if [ -n "$_prod" ]; then
    case "$_prod" in
      *"$_vend"*) DEV_NAME="$_prod" ;;
      *) DEV_NAME="$_vend $_prod" ;;
    esac
    DEV_NAME=$(echo "$DEV_NAME" | sed 's/^ *//; s/ *$//')
    command -v log >/dev/null 2>&1 && log "hook: auto-detected device model: $DEV_NAME"
  else
    DEV_NAME="FideBook"
  fi
fi
[ -n "$DEV_NAME" ] || DEV_NAME="FideBook"

# Non-USB touchpads ("vid:pid" lower-case hex) for IDC flick tuning
fidebook_touchpads() {
  awk -v RS= -F'\n' '{
    bus = ""; v = ""; p = ""; name = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^I: /) { n = split($i, a, " "); for (j = 1; j <= n; j++) {
        if (a[j] ~ /^Bus=/) bus = substr(a[j], 5); if (a[j] ~ /^Vendor=/) v = substr(a[j], 8); if (a[j] ~ /^Product=/) p = substr(a[j], 9) } }
      if ($i ~ /^N: Name=/) name = tolower($i)
    }
    if (name ~ /touchpad|trackpad/ && bus != "0003" && v != "" && p != "") print tolower(v) ":" tolower(p)
  }' ${INPUTS:-/proc/bus/input/devices} 2>/dev/null | sort -u
}

if mount --bind /fidebook /new/postinstall; then
  mkdir -p /tmp/sysinit && cp -a /new/system/etc/init/. /tmp/sysinit/
  rm -f /tmp/sysinit/gscd.rc           # gscd needs Google's security chip (/dev/tpm0)
  rm -f /tmp/sysinit/timberslide.rc    # timberslide needs ChromeOS EC (/dev/cros_ec)
  rm -f /tmp/sysinit/udsattestation.rc # udsattestation needs Titan C security chip
  rm -f /tmp/sysinit/mmd.rc            # disable mmd & 24GB zram/8GB disk swap on pendrive

  case "$RESOLUTION" in [0-9]*x[0-9]*) WMSIZE=$RESOLUTION;; *) WMSIZE=reset;; esac
  if [ "${TRUSTY_VM:-0}" = 1 ]; then TRUSTYSTOP="# fidebook: Trusty VM kept (TRUSTY_VM=1)"; else TRUSTYSTOP="stop trusty_security_protected_vm_launcher"; fi
  if grep -qi 'Surface' /sys/class/dmi/id/product_name 2>/dev/null; then
    SURFACESTART="start fidebook_camera
    start fidebook_sleep_guard"
  else
    SURFACESTART="# fidebook: not a Surface, camera bridge and sleep guard not started"
  fi

  IDCRC=
  if [ "${TOUCHPAD_FLICK:-1}" != 0 ]; then
    for tp in $(fidebook_touchpads); do
      IDCN=Vendor_${tp%:*}_Product_${tp#*:}.idc
      printf 'device.internal = 1\ntouch.deviceType = touchPad\ngestureProp.Drumroll_Suppression_Enable = 0\ngestureProp.Change_Timeout = 0.02\n' > $L/$IDCN \
        && IDCRC="$IDCRC
    copy /postinstall/fidebook/logs/boot-$N/$IDCN /data/system/devices/idc/$IDCN
    chown system system /data/system/devices/idc/$IDCN
    chmod 0644 /data/system/devices/idc/$IDCN" && log "hook: touchpad $tp: IDC with Change_Timeout=0.02 queued"
    done
    if [ -f $G/surface/Vendor_045e_Product_0c9f.idc ]; then
      IDCRC="$IDCRC
    copy /postinstall/fidebook/surface/Vendor_045e_Product_0c9f.idc /data/system/devices/idc/Vendor_045e_Product_0c9f.idc
    chown system system /data/system/devices/idc/Vendor_045e_Product_0c9f.idc
    chmod 0644 /data/system/devices/idc/Vendor_045e_Product_0c9f.idc" && log "hook: Surface precision touchpad IDC queued"
    fi
    [ -n "$IDCRC" ] && IDCRC="    mkdir /data/system 0775 system system
    mkdir /data/system/devices 0775 system system
    mkdir /data/system/devices/idc 0775 system system$IDCRC"
  fi

  WALLRC=
  if [ -f "$G/branding/wallpaper.jpg" ]; then
    WALLRC="    mkdir /data/local 0777 root root encryption=None
    mkdir /data/local/tmp 01777 shell shell encryption=None
    copy /postinstall/fidebook/branding/wallpaper.jpg /data/local/tmp/fidebook_wallpaper.jpg
    chmod 0644 /data/local/tmp/fidebook_wallpaper.jpg"
  fi

  if [ "$GPU_SW" = 1 ] && [ "${GPU_HW_RADV:-0}" = 1 ]; then
    RENDERENGINE_RC="    setprop debug.renderengine.backend skiavkthreaded
    setprop debug.renderengine.vulkan true
    setprop debug.renderengine.graphite false
    setprop debug.renderengine.graphite_desktop_optin false
    setprop debug.hwui.use_hint_manager false
    setprop debug.sf.auto_latch_unsignaled true
    setprop ro.surface_flinger.max_frame_buffer_acquired_buffers 3"
  elif [ "$GPU_SW" = 1 ]; then
    RENDERENGINE_RC="    setprop debug.renderengine.backend skiaglthreaded
    setprop debug.renderengine.vulkan false
    setprop debug.renderengine.graphite false
    setprop debug.renderengine.graphite_desktop_optin false"
  else
    RENDERENGINE_RC="    # fidebook: stock Intel RenderEngine"
  fi

  if [ "${DEBUG_TELEMETRY:-0}" = 1 ]; then
    TELEMETRY_EARLY_FS="    write /sys/kernel/tracing/buffer_size_kb 8192
    write /sys/kernel/tracing/events/kvm/kvm_inj_exception/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_emulate_insn/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_userspace_exit/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_exit/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_pio/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_mmio/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_hypercall/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_fast_mmio/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_inj_virq/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_pic_set_irq/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_ioapic_set_irq/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_msi_set_irq/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_set_irq/enable 1
    write /sys/kernel/tracing/events/kvm/kvm_apic_accept_irq/enable 1
    write /sys/kernel/tracing/tracing_on 1"
    TELEMETRY_POST_FS="    start fidebook_logcat
    start fidebook_sync"
    TELEMETRY_BOOT_DONE="    start fidebook_audiodiag
    start fidebook_displaydiag
    start fidebook_aidiag"
  else
    TELEMETRY_EARLY_FS="    # fidebook: KVM exit trace disabled in stable release (DEBUG_TELEMETRY=0)"
    TELEMETRY_POST_FS="    start fidebook_backchannel"
    TELEMETRY_BOOT_DONE="    # fidebook: heavy diagnostic dumps disabled in stable release (DEBUG_TELEMETRY=0)"
  fi

  cat > /tmp/sysinit/fidebook.rc <<RC
# Full logcat rotation (enabled only when DEBUG_TELEMETRY=1)
service fidebook_logcat /system/bin/logcat -b all -v threadtime -r 1024 -n 10 -f /postinstall/fidebook/logs/boot-$N/logcat.txt
    user root
    group root log
    seclabel u:r:shell:s0
    disabled

# Crash buffer only (FATAL EXCEPTION / native crashes): tiny footprint, always kept for crash resilience
service fidebook_crashlog /system/bin/logcat -b crash -v threadtime -f /postinstall/fidebook/logs/boot-$N/crash.txt
    user root
    group root log
    seclabel u:r:shell:s0

# Ensure Play Store is enabled in headless user 0 so MultiUserCoordinatorService can bind
service fidebook_play_repair /system/bin/pm enable --user 0 com.android.vending
    user root
    group root
    seclabel u:r:shell:s0
    oneshot
    disabled

# Always-on Play Store / GMS health snapshot after boot completes (writes boot-N/play.txt)
service fidebook_playdiag /system/bin/sh /postinstall/fidebook/play_diagnostics.sh $N
    user root
    group root log
    seclabel u:r:shell:s0
    oneshot
    disabled

# Debug sync + backchannel loop (DEBUG_TELEMETRY=1 only)
service fidebook_sync /system/bin/sh -c "while true; do sleep 1; [ -f /data/local/tmp/fidebook_oobe/fx.trigger ] && sh /postinstall/fidebook/oobe_apply.sh --fx; [ -f /data/local/tmp/fidebook_oobe/apply.trigger ] && sh /postinstall/fidebook/oobe_apply.sh; if [ -f /postinstall/fidebook/run.sh ]; then sh /postinstall/fidebook/run.sh > /postinstall/fidebook/run.log 2>&1; rm -f /postinstall/fidebook/run.sh; fi; sync; done"
    user root
    group root
    seclabel u:r:shell:s0
    disabled

# Lightweight 1.25 backchannel & live Settings Liquid Glass / Motion Blur applier
service fidebook_backchannel /system/bin/sh -c "while true; do sleep 1; [ -f /data/local/tmp/fidebook_oobe/fx.trigger ] && sh /postinstall/fidebook/oobe_apply.sh --fx; [ -f /data/local/tmp/fidebook_oobe/apply.trigger ] && sh /postinstall/fidebook/oobe_apply.sh; if [ -f /postinstall/fidebook/run.sh ]; then sh /postinstall/fidebook/run.sh > /postinstall/fidebook/run.log 2>&1; rm -f /postinstall/fidebook/run.sh; sync; fi; done"
    user root
    group root
    seclabel u:r:shell:s0
    disabled

# Sound diagnostics, 60 s after boot (DEBUG_TELEMETRY=1)
service fidebook_audiodiag /system/bin/sh -c "sleep 60; cd /proc/asound; ( head -n 3000 cards pcm devices card*/id card*/codec*; ls -l /dev/snd; grep '^N: Name' /proc/bus/input/devices; dumpsys media.audio_flinger; dumpsys media.audio_policy ) > /postinstall/fidebook/logs/boot-$N/audio.txt 2>&1; sh /postinstall/fidebook/audio/mixdiag.sh $N"
    user root
    group root audio
    seclabel u:r:shell:s0
    oneshot
    disabled

on early-init
    setprop sys.fidebook_dri_fixed 1
$RENDERENGINE_RC

on init
    chown cameraserver camera /dev/video0
    chown cameraserver camera /dev/video1
    chown cameraserver camera /dev/video2
    chown cameraserver camera /dev/video3
    chown cameraserver camera /dev/media0
    chown cameraserver camera /dev/media1
    chmod 0666 /dev/video0
    chmod 0666 /dev/video1
    chmod 0666 /dev/video2
    chmod 0666 /dev/video3
    chmod 0666 /dev/media0
    chmod 0666 /dev/media1

on property:sys.fidebook_dri_fixed=1
    restart vendor.drm-widevine-hal

on post-fs-data
    mkdir /data/local 0777 root root encryption=None
    mkdir /data/local/tmp 01777 shell shell encryption=None
    mkdir /data/local/tmp/fidebook_oobe 0777 shell shell encryption=None
    chmod 0777 /data/local
    chmod 01777 /data/local/tmp
    chmod 0777 /data/local/tmp/fidebook_oobe
$WALLRC
$IDCRC

on boot
    chown bluetooth bluetooth /sys/class/bluetooth/hci0/reset
    chmod 0220 /sys/class/bluetooth/hci0/reset
    chown cameraserver camera /dev/video0
    chown cameraserver camera /dev/video1
    chown cameraserver camera /dev/media0
    chmod 0666 /dev/video0
    chmod 0666 /dev/video1
    chmod 0666 /dev/media0
    chown system system /sys/class/backlight/amdgpu_bl0/brightness
    chmod 0664 /sys/class/backlight/amdgpu_bl0/brightness
    chown system system /sys/class/backlight/amdgpu_bl0/bl_power
    chmod 0664 /sys/class/backlight/amdgpu_bl0/bl_power
    chown system system /sys/class/backlight/amdgpu_bl1/brightness
    chmod 0664 /sys/class/backlight/amdgpu_bl1/brightness
    chown system system /sys/class/backlight/amdgpu_bl1/bl_power
    chmod 0664 /sys/class/backlight/amdgpu_bl1/bl_power
    setprop persist.zygote.zygote_next.start_on_boot false
    start fidebook_nativezygote

on property:sys.boot_completed=1
    write /sys/module/drm/parameters/debug 0
    write /sys/kernel/tracing/tracing_on 0
    write /sys/accessibility/speakup/synth none
    $TRUSTYSTOP
    start fidebook_oobe_watch
    start fidebook_skip_setup
    start fidebook_optimize
    start fidebook_btdiag
    start fidebook_devname
    start fidebook_talkback
    start fidebook_iptsd
    $SURFACESTART
    start fidebook_wmsize
    start fidebook_ksu
$TELEMETRY_BOOT_DONE

# First-boot Material 3 FideBook Setup Wizard watcher (exits permanently as soon as setup completes)
service fidebook_oobe_watch /system/bin/sh /postinstall/fidebook/oobe_apply.sh --watch
    user root
    group root
    seclabel u:r:shell:s0
    oneshot
    disabled

# Bypass stock ChromeOS/GSC SetupWizard, enable desktop freeform windows, and launch FideBookOS Material 3 Setup Wizard ONLY on the very first boot
service fidebook_skip_setup /system/bin/sh /postinstall/fidebook/oobe_apply.sh --boot ${OOBE_SETUP:-1}
    user root
    group root
    seclabel u:r:shell:s0
    oneshot
    disabled

# FideBookOS 1.0 Stable System, Desktop UI, APU TDP & I/O Optimization Service
service fidebook_optimize /system/bin/sh /postinstall/fidebook/optimize.sh
    user root
    group root
    seclabel u:r:shell:s0
    oneshot
    disabled

# Bluetooth diagnostics + rfkill/reset permission guard
service fidebook_btdiag /system/bin/sh /postinstall/fidebook/hwdetect.sh --btdiag $N
    user root
    group root bluetooth log
    seclabel u:r:shell:s0
    oneshot
    disabled

# Keep Android 17 zygote_next disabled so Chrome/WebView sandboxed processes launch cleanly
service fidebook_nativezygote /system/bin/sh /postinstall/fidebook/native_zygote.sh $N
    user root
    group root
    seclabel u:r:shell:s0
    oneshot
    disabled

# AI diagnostics (DEBUG_TELEMETRY=1)
service fidebook_aidiag /system/bin/sh /postinstall/fidebook/aidiag.sh $N
    user root
    group root
    seclabel u:r:shell:s0
    oneshot
    disabled

service fidebook_aidns_10107 /system/bin/sh -c "(ping -c 1 -W 5 www.google.com; ping -c 2 -W 5 ondevicesafety-pa.googleapis.com) > /dev/aidns_10107.txt 2>&1"
    user 10107
    group inet
    seclabel u:r:shell:s0
    oneshot
    disabled

service fidebook_aidns_10118 /system/bin/sh -c "(ping -c 1 -W 5 www.google.com; ping -c 2 -W 5 ondevicesafety-pa.googleapis.com) > /dev/aidns_10118.txt 2>&1"
    user 10118
    group inet
    seclabel u:r:shell:s0
    oneshot
    disabled

service fidebook_aidns_10119 /system/bin/sh -c "(ping -c 1 -W 5 www.google.com; ping -c 2 -W 5 ondevicesafety-pa.googleapis.com) > /dev/aidns_10119.txt 2>&1"
    user 10119
    group inet
    seclabel u:r:shell:s0
    oneshot
    disabled

service fidebook_aidns_2000 /system/bin/sh -c "(ping -c 1 -W 5 www.google.com; ping -c 2 -W 5 ondevicesafety-pa.googleapis.com) > /dev/aidns_2000.txt 2>&1"
    user 2000
    group inet
    seclabel u:r:shell:s0
    oneshot
    disabled

# KernelSU daemon & manager installer
service fidebook_ksu /system/bin/sh /postinstall/fidebook/ksu/install.sh $N ${KSU_MANAGER:-1}
    user root
    group root
    seclabel u:r:shell:s0
    oneshot
    disabled

# Logical display size (RESOLUTION in fidebook.cfg); "reset" = native panel resolution.
service fidebook_wmsize /system/bin/wm size $WMSIZE
    user root
    group root
    seclabel u:r:shell:s0
    oneshot
    disabled

# Display diagnostics, 70 s after boot (DEBUG_TELEMETRY=1)
service fidebook_displaydiag /system/bin/sh -c "sleep 70; ( mount -t debugfs debugfs /sys/kernel/debug; head -n 20000 /sys/kernel/debug/dri/*/state /sys/kernel/debug/dri/*/amdgpu_pm_info /sys/kernel/debug/dri/*/i915_display_info /sys/kernel/debug/dri/*/i915_display_capabilities /sys/kernel/debug/dri/*/eDP-1/* /sys/class/drm/card*/device/gpu_busy_percent /sys/class/drm/card*/device/pp_dpm_sclk; echo EDID; od -A x -t x1 /sys/class/drm/card*-eDP-1/edid; dumpsys SurfaceFlinger; dumpsys color_display; dumpsys display; settings list secure; settings list system ) > /postinstall/fidebook/logs/boot-$N/display.txt 2>&1"
    user root
    group root graphics
    seclabel u:r:shell:s0
    oneshot
    disabled

# Surface Laptop 7 multitouch / camera / sleep daemons
service fidebook_iptsd /system/bin/sh /postinstall/fidebook/surface/iptsd-run.sh $N
    user root
    group root input
    seclabel u:r:shell:s0
    oneshot
    disabled

service fidebook_camera /system/bin/sh /postinstall/fidebook/surface/surface-camera.sh
    user root
    group root camera graphics
    seclabel u:r:shell:s0
    oneshot
    disabled

service fidebook_sleep_guard /system/bin/sh /postinstall/fidebook/surface/sleep-guard.sh
    user root
    group root
    seclabel u:r:shell:s0
    disabled

# ACCESSIBILITY=talkback in fidebook.cfg: enable TalkBack screen reader on first boot of /data
service fidebook_talkback /system/bin/sh -c "[ '$ACCESSIBILITY' = talkback ] || exit 0; [ -e /data/local/tmp/.fidebook_talkback ] && exit 0; sleep 3; settings put --user 0 secure enabled_accessibility_services com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService; settings put --user 0 secure accessibility_enabled 1; settings put --user 10 secure enabled_accessibility_services com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService; settings put --user 10 secure accessibility_enabled 1; touch /data/local/tmp/.fidebook_talkback"
    user root
    group root
    seclabel u:r:shell:s0
    oneshot
    disabled

# Device name in Settings > About, Bluetooth & Quick Share: synced with DEV_NAME (default "FideBook")
service fidebook_devname /system/bin/sh -c "sleep 12; settings put global device_name '$DEV_NAME'; settings put --user 0 secure bluetooth_name '$DEV_NAME'; settings put --user 10 secure bluetooth_name '$DEV_NAME'"
    user root
    group root
    seclabel u:r:shell:s0
    oneshot
    disabled

# Software Gatekeeper (gatekeeper/soft_gk.c) in place of the Trusty one
service fidebook_soft_gk /postinstall/fidebook/soft_gk
    class hal
    user system
    group system
    seclabel u:r:hal_gatekeeper_default:s0
    interface aidl android.hardware.gatekeeper.IGatekeeper/default

on property:sys.boot_completed=1
    start fidebook_play_repair
    start fidebook_playdiag

on early-init
    setprop ro.boot.hypervisor.vm.supported 1
    setprop sys.use_memfd true
on init && property:trusty.security_vm.enabled=1
    setprop desktop.security_vm.vm_image /system_ext/etc/vm/trusty_vm/desktop_trusty_ext_boot_signed.elf
    setprop trusty.security_vm.vm_cid 200
    setprop trusty.security_vm.nonsecure_vm_ready 1
    setprop ro.hardware.trusty_ipc_dev.gatekeeper VSOCK:200:0
    setprop storageproxyd_system.trusty_ipc_dev VSOCK:200:0

on early-fs
    start trusty_security_protected_vm_launcher
$TELEMETRY_EARLY_FS

on post-fs
$TELEMETRY_POST_FS
    start fidebook_crashlog
on post-fs-data
$TELEMETRY_POST_FS
    start fidebook_crashlog
    start fidebook_ksu
RC

  if [ -f $G/apex_patch.sh ] && [ "$(grep -c '^    wait_for_prop apexd.status activated$' /tmp/sysinit/hw/init.rc)" = 1 ]; then
    sed -i 's#^    wait_for_prop apexd.status activated$#&\n    exec u:r:shell:s0 root root -- /system/bin/sh /postinstall/fidebook/apex_patch.sh#' /tmp/sysinit/hw/init.rc \
      && log "hook: init.rc runs apex_patch.sh after APEX activation"
  else
    log "hook: apex_patch NOT installed (script missing or init.rc anchor not unique)"
  fi
  mount -t tmpfs -o mode=0755 tmpfs /new/system/etc/init && cp -a /tmp/sysinit/. /new/system/etc/init/ \
    && log "hook: init overlay active ($(ls /new/system/etc/init | wc -l) rc files, telemetry=${DEBUG_TELEMETRY:-0})" \
    || log "hook: init overlay FAILED"
else
  log "hook: bind /fidebook -> /postinstall FAILED"
fi

# Auto-detect optimal UI density from connected screen if unset or auto
if [ "$DENSITY" = "auto" ] || [ -z "$DENSITY" ]; then
  DENSITY=
  for _s in /sys/class/drm/card*-*/status; do
    [ -f "$_s" ] || continue
    if grep -q '^connected$' "$_s" 2>/dev/null; then
      _d=$(dirname "$_s")
      if [ -f "$_d/modes" ] && [ -s "$_d/modes" ]; then
        _res=$(head -n1 "$_d/modes" 2>/dev/null | tr -d '\r\n')
        if [ -n "$_res" ]; then
          _w=$(echo "$_res" | cut -d'x' -f1)
          _h=$(echo "$_res" | cut -d'x' -f2)
          if [ "$_w" -le 1366 ]; then
            DENSITY=140
          elif [ "$_w" -le 1600 ]; then
            DENSITY=160
          elif [ "$_w" -le 1920 ]; then
            [ "$_h" -ge 1200 ] && DENSITY=180 || DENSITY=160
          elif [ "$_w" -le 2560 ]; then
            DENSITY=220
          elif [ "$_w" -le 2880 ]; then
            DENSITY=240
          else
            DENSITY=320
          fi
          log "hook: auto-detected resolution ${_res}, calculated density: $DENSITY"
          break
        fi
      fi
    fi
  done
fi
case "$DENSITY" in ''|*[!0-9]*) DENSITY=;; esac

# --- FideBookOS 1.25 multi-partition build.prop identity, ARM64 native bridge & GPU overrides ---
# 1. Select ARM64 mobile app native bridge: Google's stock /system/build.prop hardcodes Intel-only
#    `libhoudini.so` (which executes 4 GenuineIntel CPUID checks + AVX-512 instructions and aborts
#    every ARM64 mobile app on AMD Ryzen and non-AVX-512 CPUs). Switch cleanly to Google's built-in
#    vendor-neutral `libndk_translation.so` (Berberis 16.0.0) whenever host CPU lacks GenuineIntel+avx512f.
fidebook_select_native_bridge() {
  _ci=${CPUINFO:-/proc/cpuinfo}
  case "${NATIVE_BRIDGE:-auto}" in
    ndk_translation|berberis) echo "libndk_translation.so"; return 0 ;;
    houdini)                  echo "libhoudini.so"; return 0 ;;
  esac
  if grep -q 'GenuineIntel' "$_ci" 2>/dev/null && grep -qw 'avx512f' "$_ci" 2>/dev/null; then
    echo "libhoudini.so"
  else
    echo "libndk_translation.so"
  fi
}
FIDEBOOK_BRIDGE_SO=$(fidebook_select_native_bridge)
if [ "$FIDEBOOK_BRIDGE_SO" = "libndk_translation.so" ] \
   && [ -d "${NEWROOT:-/new}/system/lib64/berberis/arm64" ] \
   && [ -d "${NEWROOT:-/new}/system/lib64/arm64" ] \
   && [ "${PROP_NOBIND:-0}" != 1 ]; then
  mount --bind "${NEWROOT:-/new}/system/lib64/berberis/arm64" "${NEWROOT:-/new}/system/lib64/arm64" 2>/dev/null \
    && log "hook: bound /system/lib64/berberis/arm64 -> /system/lib64/arm64 (libndk_translation ARM64 mobile apps active)"
fi

# 2. Rewrite system, product, system_ext, and vendor build.prop files so the OS identifies everywhere as
#    FideBook / FideBookOS 1.25 while NEVER altering any ro.*.build.fingerprint line (preserving GMS).
fidebook_rewrite_partition_prop() { # $1=src_prop $2=tmp_prop $3=part_prefix ("system"|"product"|"system_ext")
  [ -f "$1" ] || return 0
  _pp="$3"
  _nb=$(fidebook_select_native_bridge)
  _pdrop="^ro\\.product\\.${_pp}\\.(model|marketname)=|^ro\\.build\\.display\\.id="
  [ "$_pp" = "system" ] && _pdrop="$_pdrop|^ro\\.fidebook\\.version=|^persist\\.fidebook\\.(motion_blur|liquid_glass|liquid_glass_level)=|^ro\\.dalvik\\.vm\\.native\\.bridge=|^ro\\.enable\\.native\\.bridge\\.exec(64)?=|^ro\\.surface_flinger\\.enable_layer_caching=|^bluetooth\\.device\\.default_name=|^ro\\.config\\.wallpaper="
  {
    grep -v -E "$_pdrop" "$1"
    echo "ro.product.${_pp}.model=$DEV_NAME"
    echo "ro.product.${_pp}.marketname=$DEV_NAME"
    if [ "$_pp" = "system" ] || [ "$_pp" = "product" ]; then
      echo "ro.build.display.id=FideBookOS 1.25"
    fi
    if [ "$_pp" = "system" ]; then
      echo "ro.fidebook.version=1.25"
      echo "ro.dalvik.vm.native.bridge=$_nb"
      echo "ro.enable.native.bridge.exec=1"
      echo "ro.enable.native.bridge.exec64=1"
      echo "persist.fidebook.liquid_glass=${LIQUID_GLASS:-1}"
      echo "persist.fidebook.liquid_glass_level=${LIQUID_GLASS_LEVEL:-2}"
      echo "persist.fidebook.motion_blur=${MOTION_BLUR:-ui}"
      echo "ro.surface_flinger.enable_layer_caching=true"
      echo "bluetooth.device.default_name=$DEV_NAME"
      if [ -f "${G:-/fidebook/fidebook}/branding/wallpaper.jpg" ]; then
        echo "ro.config.wallpaper=/data/local/tmp/fidebook_wallpaper.jpg"
      fi
    fi
  } > "$2"
  chmod 0644 "$2" 2>/dev/null || true
  if [ "${PROP_NOBIND:-0}" != 1 ]; then
    mount --bind "$2" "$1" && log "hook: $_pp build.prop branded (model=$DEV_NAME, ver=1.25, bridge=$_nb)"
  fi
}

fidebook_rewrite_partition_prop "${NEWROOT:-/new}/system/build.prop" /tmp/system.build.prop system
fidebook_rewrite_partition_prop "${NEWROOT:-/new}/product/etc/build.prop" /tmp/product.build.prop product
fidebook_rewrite_partition_prop "${NEWROOT:-/new}/system_ext/etc/build.prop" /tmp/system_ext.build.prop system_ext

DROP='^ro.boot.hypervisor.protected_vm.supported=|^ro.surface_flinger.has_wide_color_display=|^ro.surface_flinger.has_HDR_display=|^ro.product.(vendor\.)?(model|marketname)='
[ "$GPU_SW" = 1 ] && DROP="$DROP|^ro.surface_flinger.supports_background_blur=|^persist.sys.sf.disable_blurs=|^ro.launcher.blur.appLaunch=|^log.tag.drmhwc=|^persist.log.tag.drmhwc=|^ro.vendor.hwc.use_overlay_planes=|^vendor.hwc.drm.use_overlay_planes=|^vendor.hwc.drm.scale_with_gpu=|^vendor.hwc.drm.enable_color_pipeline=|^vendor.hwc.use_log_gamma_lut=|^vendor.hwc.backend_override=|^ro.hwui.use_vulkan=|^ro.surface_flinger.default_composition_pixel_format=|^debug.renderengine.backend=|^debug.renderengine.graphite=|^debug.renderengine.graphite_desktop_optin=|^debug.renderengine.vulkan=|^ro.hwui.render_ahead=|^ro.surface_flinger.max_frame_buffer_acquired_buffers=|^debug.sf.enable_gl_backpressure="
[ -n "$DENSITY" ] && DROP="$DROP|^ro.sf.lcd_density="
{ grep -v -E "$DROP" /new/vendor/build.prop
  echo "ro.surface_flinger.has_wide_color_display=false"
  echo "ro.surface_flinger.has_HDR_display=false"
  echo "ro.product.model=$DEV_NAME"
  echo "ro.product.vendor.model=$DEV_NAME"
  echo "ro.product.marketname=$DEV_NAME"
  echo "ro.product.vendor.marketname=$DEV_NAME"
  if [ "$GPU_SW" = 1 ] && [ "${GPU_HW_RADV:-0}" = 1 ]; then
    # Optimized Hardware AMD GPU Mode (amdgpu + multi-queue Vulkan 1.4 RADV + hardware GPU scroll motion blur):
    echo "ro.fidebook.gpu_mode=radv"
    echo "ro.surface_flinger.supports_background_blur=1"
    echo "persist.sys.sf.disable_blurs=0"
    echo "ro.launcher.blur.appLaunch=1"
    echo "log.tag.drmhwc=WARN"
    echo "persist.log.tag.drmhwc=WARN"
    echo "vendor.hwc.drm.enable_color_pipeline=false"
    echo "vendor.hwc.use_log_gamma_lut=false"
    echo "vendor.hwc.backend_override=client"
    echo "ro.vendor.hwc.use_overlay_planes=false"
    echo "vendor.hwc.drm.use_overlay_planes=0"
    if [ "${GPU_HWUI_VULKAN:-auto}" = 0 ] || [ "${GPU_HWUI_VULKAN:-auto}" = false ]; then
      echo "ro.hwui.use_vulkan=false"
    else
      echo "ro.hwui.use_vulkan=true"
    fi
    echo "debug.renderengine.backend=skiavkthreaded"
    echo "debug.renderengine.vulkan=true"
    echo "debug.renderengine.graphite=false"
    echo "debug.renderengine.graphite_desktop_optin=false"
    echo "ro.surface_flinger.max_frame_buffer_acquired_buffers=3"
    echo "debug.sf.rounded_corner_opaque_optimization=true"
  elif [ "$GPU_SW" = 1 ]; then
    # CPU SwiftShader Mode (legacy Intel Gen <= 8, non-Intel without RADV, or GPU_VULKAN=swiftshader):
    echo "ro.fidebook.gpu_mode=swiftshader"
    echo "ro.surface_flinger.supports_background_blur=0"
    echo "ro.fidebook.software_rendering=1"
    echo "persist.sys.sf.disable_blurs=1"
    echo "ro.launcher.blur.appLaunch=0"
    echo "log.tag.drmhwc=WARN"
    echo "persist.log.tag.drmhwc=WARN"
    is_intel_drm=0
    if fidebook_gpu_cards 2>/dev/null | grep -qE " (i915|xe)$"; then
      is_intel_drm=1
    fi
    if [ "$is_intel_drm" = 1 ]; then
      echo "ro.vendor.hwc.use_overlay_planes=true"
      echo "vendor.hwc.drm.use_overlay_planes=0"
    else
      echo "ro.vendor.hwc.use_overlay_planes=false"
      echo "vendor.hwc.drm.use_overlay_planes=0"
      echo "vendor.hwc.drm.scale_with_gpu=1"
      echo "vendor.hwc.use_log_gamma_lut=false"
    fi
    echo "vendor.hwc.drm.enable_color_pipeline=false"
    echo "ro.hwui.use_vulkan=false"
    echo "ro.surface_flinger.default_composition_pixel_format=2"
    echo "debug.renderengine.backend=skiaglthreaded"
    echo "debug.renderengine.graphite=false"
    echo "debug.renderengine.graphite_desktop_optin=false"
    echo "debug.renderengine.vulkan=false"
    echo "ro.hwui.render_ahead=0"
    echo "ro.surface_flinger.max_frame_buffer_acquired_buffers=2"
    echo "debug.sf.enable_gl_backpressure=0"
    echo "debug.sf.rounded_corner_opaque_optimization=true"
  fi
  if [ -n "$DENSITY" ]; then echo "ro.sf.lcd_density=$DENSITY"; fi
  echo "ro.product.model=$DEV_NAME"
  echo "ro.product.vendor.model=$DEV_NAME"
  echo "ro.product.marketname=$DEV_NAME"
  echo "ro.product.vendor.marketname=$DEV_NAME"
} > /tmp/vendor.build.prop && mount --bind /tmp/vendor.build.prop /new/vendor/build.prop \
  && log "hook: vendor build.prop: model=$DEV_NAME, lcd_density=${DENSITY:-stock}, gpu_sw=${GPU_SW:-0}, gpu_hw_radv=${GPU_HW_RADV:-0}"

# Only one Trusty VM may own CID 200: drop the plain launcher's auto-start
R=/new/system_ext/etc/init/desktop-trusty_security_vm_launcher.rc
sed 's/^    start trusty_security_vm_launcher$/    # fidebook: plain launcher disabled/' $R > /tmp/vm_launcher.rc \
  && mount --bind /tmp/vm_launcher.rc $R \
  && log "hook: plain trusty launcher disabled ($(grep -c 'fidebook: plain launcher disabled' $R) triggers)"

# Software KeyMint + binary library patches from patched/MANIFEST
fidebook_bind_patches
[ -f $G/system_ext_manifest.xml ] && mount --bind $G/system_ext_manifest.xml /new/system_ext/etc/vintf/manifest.xml \
  && log "hook: Trusty KeyMint VINTF declarations hidden"

# StrongBox KeyMint (vendor APEX) needs Google's security chip: overlay /vendor/apex without it
mkdir -p /tmp/vapex && mount --bind /new/vendor/apex /tmp/vapex \
  && mount -t tmpfs -o mode=0755 tmpfs /new/vendor/apex && for f in /tmp/vapex/*; do
    n=${f##*/}; case $n in com.android.hardware.keymint.strongbox.desktop.apex) continue;; esac
    touch /new/vendor/apex/$n && mount --bind $f /new/vendor/apex/$n
  done && log "hook: vendor apex without strongbox: $(ls /new/vendor/apex | tr '\n' ' ')"

# Hide Weaver, Secretkeeper, and Trusty Gatekeeper (replaced by fidebook_soft_gk)
W=/new/vendor/etc/vintf/manifest/android.hardware.weaver-service.android-desktop.xml
[ -f $W ] && echo '<manifest version="9.0" type="device"/>' > /tmp/weaver.xml \
  && mount --bind /tmp/weaver.xml $W && log "hook: Weaver VINTF declaration hidden"

SK=/new/vendor/etc/vintf/manifest/android.hardware.security.secretkeeper.trusty.xml
[ -f $SK ] && echo '<manifest version="9.0" type="device"/>' > /tmp/secretkeeper.xml \
  && mount --bind /tmp/secretkeeper.xml $SK && : > /tmp/empty.rc \
  && mount --bind /tmp/empty.rc /new/vendor/etc/init/android.hardware.security.secretkeeper.trusty.desktop.rc \
  && log "hook: Secretkeeper VINTF declaration hidden"

GK=/new/vendor/etc/vintf/manifest/android.hardware.gatekeeper-service.trusty.xml
: > /tmp/empty.rc && mount --bind /tmp/empty.rc /new/vendor/etc/init/android.hardware.gatekeeper-service.trusty.rc
if [ -x $G/soft_gk ]; then
  log "hook: Trusty Gatekeeper replaced by software Gatekeeper (soft_gk)"
else
  echo '<manifest version="9.0" type="device"/>' > /tmp/gatekeeper.xml && mount --bind /tmp/gatekeeper.xml $GK \
    && log "hook: Trusty Gatekeeper hidden, no soft_gk"
fi

# --- Wi-Fi Direct feature ---
# Google's vendor declares android.hardware.wifi.direct for its Intel laptop. Wi-Fi
# Direct beside the station needs firmware channel management (MT792x CNM:
# remain-on-channel + a P2P-device interface combination). MediaTek MT7902 firmware
# has none (same WIFI_RAM_CODE_MT7902_1.bin on Fedora: no remain_on_channel, no P2P
# combination), so Nearby / Quick Share / phone link chose Wi-Fi Direct and stalled
# instead of using Bluetooth, the shared Wi-Fi network or the phone's hotspot.
# WIFI_DIRECT=auto (default) hides it on such adapters; 1 keeps it, 0 always hides it.
fidebook_wifi_no_p2p_adapter() {
  for _wd in ${SYSFS:-/sys}/bus/pci/devices/*; do
    [ -f "$_wd/vendor" ] || continue
    case "$(cat "$_wd/vendor" 2>/dev/null):$(cat "$_wd/device" 2>/dev/null)" in
      0x14c3:0x7902) echo "MediaTek MT7902"; return 0 ;;
    esac
  done
  return 1
}
fidebook_wifi_direct() {
  _wd_xml=${NEWROOT:-/new}/vendor/etc/permissions/android.hardware.wifi.direct.xml
  [ -f "$_wd_xml" ] || return 0
  case "${WIFI_DIRECT:-auto}" in
    1) log "hook: Wi-Fi Direct kept (WIFI_DIRECT=1)"; return 0 ;;
    0) _wd_why="WIFI_DIRECT=0" ;;
    *) _wd_why=$(fidebook_wifi_no_p2p_adapter) || return 0
       _wd_why="$_wd_why has no Wi-Fi Direct concurrency" ;;
  esac
  printf '<?xml version="1.0" encoding="utf-8"?>\n<permissions/>\n' > "${FIDEBOOK_TMP:-/tmp}/no_wifi_direct.xml" \
    && mount --bind "${FIDEBOOK_TMP:-/tmp}/no_wifi_direct.xml" "$_wd_xml" \
    && log "hook: android.hardware.wifi.direct hidden ($_wd_why): Nearby/Quick Share/phone link use BT, LAN or hotspot"
}
# --- end Wi-Fi Direct feature ---
fidebook_wifi_direct || log "hook: Wi-Fi Direct feature override FAILED (feature left as shipped)"

# Keep vold off USB disks so stage0's mount is never corrupted by fsck_msdos
F=/new/vendor/etc/fstab.android-desktop
grep -v 'voldmanaged=usb' $F > /tmp/fstab.android-desktop \
  && mount --bind /tmp/fstab.android-desktop $F && log "hook: vold USB rule removed from fstab"

# --- audio card selection (tested by tools/test_audio_config.sh) ---
fidebook_audio_card() {
  _as=${ASOUND:-/proc/asound}
  for _n in $(sed -n 's/^ *\([0-9][0-9]*\) \[.*/\1/p' $_as/cards 2>/dev/null); do
    if cat $_as/card$_n/codec#* 2>/dev/null | grep '^Codec:' | grep -q -v -i -E 'hdmi|displayport'; then
      grep "^ *$_n \[" $_as/cards; return 0
    fi
  done
  grep '\[' $_as/cards 2>/dev/null | grep -v -i -E 'hdmi|nvidia|HDA ATI|radeon' | head -n 1
}
# --- end audio card selection ---
A=/new/vendor/etc/audio
AC=fidebook-hda-pch
if [ -f $G/audio/fidebook-hda-pch/audio_config.xml ]; then
  CARD=$(fidebook_audio_card)
  CID=$(echo "$CARD" | sed -n 's/^ *[0-9]* \[\([^] ]*\) *\].*/\1/p'); CNAME=$(echo "$CARD" | sed -n 's/.* - //p')
  case "$CID" in *[!A-Za-z0-9]*)
    CNO=$(echo "$CARD" | sed -n 's/^ *\([0-9][0-9]*\) \[.*/\1/p')
    BCNO=
    for _cn in $(sed -n 's/^ *\([0-9][0-9]*\) \[.*/\1/p' /proc/asound/cards); do
      [ "$_cn" = "$CNO" ] && continue
      if grep -h '^Codec:' /proc/asound/card$_cn/codec#* 2>/dev/null | grep -qiE 'HDMI|DisplayPort'; then BCNO=$_cn; break; fi
    done
    D=/sys/bus/pci/drivers/snd_hda_intel
    MDEV=$(readlink -f /sys/class/sound/card$CNO/device 2>/dev/null); MDEV=${MDEV##*/}
    BDEV=$(readlink -f /sys/class/sound/card$BCNO/device 2>/dev/null); BDEV=${BDEV##*/}
    if [ -n "$BCNO" ] && [ -d $D/$MDEV ] && [ -d $D/$BDEV ] \
       && echo "$BDEV" > $D/unbind && echo "$MDEV" > $D/unbind && echo "$MDEV" > $D/bind; then
      CARD=
      _try=0
      while [ -z "$CARD" ] && [ "$_try" -lt 20 ]; do
        CARD=$(fidebook_audio_card)
        [ -n "$CARD" ] || sleep 0.1
        _try=$((_try + 1))
      done
      CID=$(echo "$CARD" | sed -n 's/^ *[0-9]* \[\([^] ]*\) *\].*/\1/p'); CNAME=$(echo "$CARD" | sed -n 's/.* - //p')
      if [ -n "$CID" ]; then
        mkdir -p /dev/snd
        rm -f /dev/snd/*
        _snd_ok=1
        for _snd in /sys/class/sound/*; do
          [ -r "$_snd/dev" ] || continue
          _snd_name=${_snd##*/}
          case "$_snd_name" in card[0-9]*) continue;; esac
          _snd_dev=$(cat "$_snd/dev")
          _snd_major=${_snd_dev%:*}; _snd_minor=${_snd_dev#*:}
          case "$_snd_major:$_snd_minor" in *[!0-9:]*|:*) _snd_ok=0; continue;; esac
          mknod -m 0660 "/dev/snd/$_snd_name" c "$_snd_major" "$_snd_minor" || _snd_ok=0
        done
        [ "$_snd_ok" = 1 ] || log "hook: failed to recreate some /dev/snd nodes from sysfs"
        log "hook: HDMI audio left unbound; internal audio card is '$CARD'"
      else
        log "hook: internal audio card did not register after HDMI audio unbind and re-probe"
      fi
    else
      [ -n "$MDEV" ] && [ -d "$D/$MDEV" ] || { [ -n "$MDEV" ] && echo "$MDEV" > $D/bind; }
      log "hook: could not re-probe internal audio card; HDMI audio may be unavailable"
    fi;;
  esac
  mkdir -p /tmp/fidebook-audio
  if [ -n "$CID" ] && [ "$CID" != PCH ]; then
    AC=fidebook-gen
    if [ -f $G/audio/gen_config.sh ] && AMSG=$(sh $G/audio/gen_config.sh $G/audio/fidebook-hda-pch $G/audio/audio_default.xml /tmp/fidebook-audio $AC "$CID" "$CNAME" 2>&1); then
      log "hook: audio $AMSG"
      cat /tmp/fidebook-audio/$AC/audio_config.xml > $L/audio_config.generated.xml 2>/dev/null
    else
      log "hook: audio gen_config.sh missing or failed (${AMSG:-no output}), plain card id/name substitution"
      rm -rf /tmp/fidebook-audio/$AC; cp -r $G/audio/fidebook-hda-pch /tmp/fidebook-audio/$AC
      sed -i "s/HDA Intel PCH/$CNAME/g; s/PCH/$CID/g" /tmp/fidebook-audio/$AC/*.xml
      sed "s/<soundcard>PCH/<soundcard>$CID/; s#fidebook-hda-pch#$AC#" $G/audio/audio_default.xml > /tmp/fidebook-audio/audio_default.xml
    fi
    if [ "$CID" = sofsoundwire ] && [ -f $G/audio/mixer_paths_surface_laptop_7.xml ] \
       && grep -qi 'Surface Laptop.*7th Edition' /sys/class/dmi/id/product_name 2>/dev/null; then
      cp $G/audio/mixer_paths_surface_laptop_7.xml /tmp/fidebook-audio/$AC/mixer_paths.xml \
        && log "hook: audio mixer_paths for the Surface Laptop 7 (RT1320/RT721) installed"
      if [ -f $G/audio/audio_config_surface_laptop_7.xml ]; then
        cp $G/audio/audio_config_surface_laptop_7.xml /tmp/fidebook-audio/$AC/audio_config.xml \
          && log "hook: audio audio_config for the Surface Laptop 7 installed"
      fi
    fi
    ASRC=/tmp/fidebook-audio/$AC; ADEF=/tmp/fidebook-audio/audio_default.xml
  else
    ASRC=$G/audio/fidebook-hda-pch; ADEF=$G/audio/audio_default.xml
  fi
  mkdir -p /tmp/vaudio && mount --bind $A /tmp/vaudio && mount -t tmpfs -o mode=0755 tmpfs $A \
    && for f in /tmp/vaudio/*; do n=${f##*/}; { [ -d $f ] && mkdir -p $A/$n || touch $A/$n; } && mount --bind $f $A/$n; done \
    && mkdir -p $A/$AC && cp -r $ASRC/. $A/$AC/ \
    && mount --bind $ADEF /new/vendor/etc/data/hal_configs/audio_default.xml \
    && log "hook: audio config $AC (card id ${CID:-none}, name ${CNAME:-none}) active"
fi

# Disable crash-looping desktop services without hardware counterparts
: > /tmp/empty.rc && mount --bind /tmp/empty.rc /new/system_ext/etc/init/apgetty.rc && log "hook: apgetty disabled"
mount --bind /tmp/empty.rc /new/vendor/etc/init/hal_desktop_charge_control_default.rc 2>/dev/null && log "hook: charge_control disabled"
mount --bind /tmp/empty.rc /new/vendor/etc/init/suspend_notification_service.rc 2>/dev/null && log "hook: suspend_notification disabled"
mount --bind /tmp/empty.rc /new/vendor/etc/init/suspend_diagnostics.rc 2>/dev/null && log "hook: suspend_diagnostics disabled"
log "hook: kvm: $(ls /sys/class/misc | grep -E 'kvm|vhost' | tr '\n' ' ')"

if [ "${DEBUG_TELEMETRY:-0}" = 1 ]; then
  T=/tmp/tracing; mkdir -p $T
  if mount -t tracefs tracefs $T; then
    E=$T/events/kvm
    echo 8192 > $T/buffer_size_kb
    for ev in kvm_inj_exception kvm_emulate_insn kvm_userspace_exit kvm_exit kvm_pio kvm_mmio kvm_hypercall kvm_fast_mmio kvm_inj_virq kvm_pic_set_irq kvm_ioapic_set_irq kvm_msi_set_irq kvm_set_irq kvm_apic_accept_irq; do
      [ -d $E/$ev ] && echo 1 > $E/$ev/enable
    done
    ( exec 4<$T/trace_pipe; /fidebook/busybox dd bs=4096 count=8000 iflag=fullblock <&4 >> $L/kvmtrace.txt 2>/dev/null ) &
    log "hook: kvm tracing (all exits) -> kvmtrace.txt"
  else
    log "hook: tracefs mount FAILED"
  fi
fi
