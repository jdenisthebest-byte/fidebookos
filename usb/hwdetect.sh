# FideBookOS hardware detection: sourced by stage0_init.sh (once the fidebook volume is mounted at /fidebook) and by hook.sh.
# Needs: $G (fidebook dir), log(), $L (boot log dir, optional). Pure busybox ash.
#
# What it does, in order (every step is non-fatal; a laptop just ends up with fewer drivers):
#  1. fidebook_modules_mount: bind the stick's full module tree (fidebook/modules/lib/modules/<uname -r>, depmod'ed,
#     ~1000 drivers) over /lib/modules, so modprobe can resolve any device's modalias.
#  2. fidebook_coldplug: the usual udev trick without udev: read every device's `modalias` from sysfs and
#     `modprobe -a` them, repeated because a loaded driver (HDA controller, USB hub, ...) creates new devices.
#     This finds the right Wi-Fi, Bluetooth, audio (HDA or SOF), touchpad/keyboard (I2C-HID, ISH, PS/2),
#     laptop hotkey/backlight (dell/hp/thinkpad/ideapad/asus/...), card-reader and webcam drivers on any machine.
#     MODOPTS="xe.enable_psr=0 ..." in fidebook.cfg (the same module.param=value spelling as on a Linux kernel command line)
#     loads those modules first with the given parameters (fidebook_modopts), so a screen/driver quirk fix needs no kernel rebuild.
#  3. firmware: the kernel's firmware loader looks in fidebook/firmware (a copy of linux-firmware, trimmed).
#  4. fidebook_hw_report: writes hwdetect.txt next to the other boot logs: what got a driver, what didn't,
#     which firmware files were missing.
FIDEBOOK_FWPATH=/sys/module/firmware_class/parameters/path

# Post-boot Android Bluetooth diagnostic helper (invoked by fidebook_btdiag in fidebook.rc:
# `sh /postinstall/fidebook/hwdetect.sh --btdiag <bootN>`).
if [ "${1:-}" = "--btdiag" ]; then
  _bn="${2:-1}"
  _out="/postinstall/fidebook/logs/boot-$_bn/bluetooth.txt"
  # Ensure Android bluetooth HAL (uid/gid 1002) can reset hci* and rfkill is unblocked
  for _r in /sys/class/rfkill/rfkill*; do
    [ -f "$_r/type" ] && [ "$(cat "$_r/type" 2>/dev/null)" = "bluetooth" ] && echo 0 > "$_r/soft" 2>/dev/null || true
  done
  for _h in /sys/class/bluetooth/hci*; do
    [ -e "$_h/reset" ] && chown 1002:1002 "$_h/reset" 2>/dev/null && chmod 0220 "$_h/reset" 2>/dev/null || true
  done
  sleep 25
  {
    echo "== bluetooth sysfs (/sys/class/bluetooth)"
    for _h in /sys/class/bluetooth/hci*; do
      [ -e "$_h" ] || continue
      echo "${_h##*/}: dev=$(readlink "$_h/device" 2>/dev/null) drv=$(readlink "$_h/device/driver" 2>/dev/null | sed 's#.*/##') reset_perm=$(ls -ln "$_h/reset" 2>/dev/null)"
      for _a in type name address; do [ -f "$_h/$_a" ] && echo "  $_a=$(cat "$_h/$_a" 2>/dev/null)"; done
    done
    echo "== bluetooth module versions"
    for _m in bluetooth btmtk btusb btintel btbcm btrtl btqca; do
      [ -d "/sys/module/$_m" ] && echo "$_m: srcversion=$(cat /sys/module/$_m/srcversion 2>/dev/null) refcnt=$(cat /sys/module/$_m/refcnt 2>/dev/null)"
    done
    echo "== bluetooth rfkill"
    for _r in /sys/class/rfkill/rfkill*; do
      [ -e "$_r" ] && echo "${_r##*/}: name=$(cat "$_r/name" 2>/dev/null) type=$(cat "$_r/type" 2>/dev/null) soft=$(cat "$_r/soft" 2>/dev/null) hard=$(cat "$_r/hard" 2>/dev/null)"
    done
    echo "== kernel bluetooth dmesg"
    dmesg 2>/dev/null | grep -iE 'bluetooth|btusb|btmtk|btintel|btrtl|btbcm|btqca|hci[0-9]|13d3|3594|mt7902' | tail -n 120
    echo "== android bluetooth properties"
    getprop 2>/dev/null | grep -i bluetooth
    echo "== dumpsys bluetooth_manager"
    dumpsys bluetooth_manager 2>&1 | head -n 160
    echo "== logcat bluetooth HAL & stack"
    logcat -d -v threadtime 2>/dev/null | grep -iE 'bt_hcihal|bthcihal|bluetooth-service|BluetoothAdapter|BluetoothSystemServer|bt_stack' | tail -n 160
  } > "$_out" 2>&1
  exit 0
fi

# Scan USB devices for Bluetooth controllers and print "<vid>:<pid>:<family>" lines (lowercase hex).
# Overrides for unit tests: SYSFS.
fidebook_bt_usb_scan() {
  _sys=${SYSFS:-/sys}
  for _d in $_sys/bus/usb/devices/[0-9]*-[0-9.]*; do
    [ -f "$_d/idVendor" ] && [ -f "$_d/idProduct" ] || continue
    case "${_d##*/}" in *:*) continue;; esac
    _vid=$(tr 'A-Z' 'a-z' < "$_d/idVendor" 2>/dev/null)
    _pid=$(tr 'A-Z' 'a-z' < "$_d/idProduct" 2>/dev/null)
    [ -n "$_vid" ] && [ -n "$_pid" ] || continue
    _fam=""
    case "$_vid:$_pid" in
      13d3:3594|13d3:3579|13d3:3580|13d3:3596|0489:e156|0e8d:1ede)
        _fam="mtk7902" ;;
      0e8d:*|13d3:3563|13d3:3564|13d3:3567|13d3:3568|13d3:3583|13d3:3606|13d3:3620|13d3:3621|13d3:3622|0489:e0c8|0489:e0cd|0489:e0d8|0489:e0d9|0489:e0f5|0489:e0f6|0489:e134|0489:e135|0489:e158|04ca:3801|043e:3109|043e:310c)
        _fam="mtk" ;;
      8087:*)
        _fam="intel" ;;
      0bda:*|13d3:3529|13d3:3533|13d3:3548|13d3:3549|13d3:3553|13d3:3555|13d3:3591|13d3:3592|13d3:3600|13d3:3601|13d3:3612|13d3:3618|13d3:3619)
        _fam="realtek" ;;
      0cf3:*|04ca:30*)
        _fam="qca" ;;
      0a5c:*|05ac:82*)
        _fam="bcm" ;;
    esac
    if [ -z "$_fam" ]; then
      _dcls=$(tr 'A-Z' 'a-z' < "$_d/bDeviceClass" 2>/dev/null)
      _dsc=$(tr 'A-Z' 'a-z' < "$_d/bDeviceSubClass" 2>/dev/null)
      _dpr=$(tr 'A-Z' 'a-z' < "$_d/bDeviceProtocol" 2>/dev/null)
      if [ "$_dcls/$_dsc/$_dpr" = "e0/01/01" ]; then
        _fam="generic"
      else
        for _i in "$_d":*; do
          [ -f "$_i/bInterfaceClass" ] || continue
          _icls=$(tr 'A-Z' 'a-z' < "$_i/bInterfaceClass" 2>/dev/null)
          _isc=$(tr 'A-Z' 'a-z' < "$_i/bInterfaceSubClass" 2>/dev/null)
          _ipr=$(tr 'A-Z' 'a-z' < "$_i/bInterfaceProtocol" 2>/dev/null)
          if [ "$_icls/$_isc/$_ipr" = "e0/01/01" ]; then
            _fam="generic"
            break
          fi
        done
      fi
    fi
    [ -n "$_fam" ] && echo "$_vid:$_pid:$_fam"
  done
}

# Unblock any soft-blocked Bluetooth rfkill switches so hci_power_on (firmware setup) can run.
fidebook_bt_rfkill_unblock() {
  _sys=${SYSFS:-/sys}
  for _r in $_sys/class/rfkill/rfkill*; do
    [ -f "$_r/type" ] || continue
    if [ "$(cat "$_r/type" 2>/dev/null)" = "bluetooth" ]; then
      if [ "$(cat "$_r/soft" 2>/dev/null)" != "0" ]; then
        echo 0 > "$_r/soft" 2>/dev/null && log "bt: unblocked soft rfkill ${_r##*/}" || true
      fi
    fi
  done
}

# True when module $1 (hyphens normalized to underscores) is already in /proc/modules.
fidebook_mod_loaded() {
  _mn=$(echo "$1" | tr '-' '_')
  grep -q "^${_mn} " "${PROC_MODULES:-/proc/modules}" 2>/dev/null
}

# Load module $1 once (no duplicate loads). Uses modprobe when modules.dep is mounted, else insmod $2.
fidebook_load_mod() {
  fidebook_mod_loaded "$1" && return 0
  _kver=${KVER_OVERRIDE:-$(uname -r)}
  _mroot=${MODROOT:-/lib/modules/$_kver}
  if [ -f "$_mroot/modules.dep" ]; then
    ${MODPROBE_CMD:-modprobe} -q "$1" 2>/dev/null && return 0
  fi
  if [ -n "${2:-}" ] && [ -f "$2" ]; then
    ${INSMOD_CMD:-insmod} "$2" 2>/dev/null && return 0
  fi
  ${MODPROBE_CMD:-modprobe} -q "$1" 2>/dev/null
}

# Resolve target .ko path on the mounted module tree or fallback $G/kmod.
fidebook_bt_ko_path() {
  _kver=${KVER_OVERRIDE:-$(uname -r)}
  _mroot=${MODROOT:-/lib/modules/$_kver}
  if [ -f "$_mroot/kernel/drivers/bluetooth/$1.ko" ]; then
    echo "$_mroot/kernel/drivers/bluetooth/$1.ko"
  elif [ -f "$G/modules/lib/modules/$_kver/kernel/drivers/bluetooth/$1.ko" ]; then
    echo "$G/modules/lib/modules/$_kver/kernel/drivers/bluetooth/$1.ko"
  elif [ -f "$G/kmod/$1.ko" ]; then
    echo "$G/kmod/$1.ko"
  fi
}

# Ensure an outdated initramfs copy of btusb/btmtk (e.g. stage0's built-in btusb without 13d3:3594)
# is never left loaded when a newer patched copy exists in $G/modules or $G/kmod.
fidebook_bt_ensure_fresh() {
  _sys=${SYSFS:-/sys}
  _btusb_ko=$(fidebook_bt_ko_path btusb)
  if fidebook_mod_loaded btusb && [ -n "$_btusb_ko" ]; then
    _live_sv=$(cat "$_sys/module/btusb/srcversion" 2>/dev/null)
    _want_sv=$(${MODINFO_CMD:-modinfo} -F srcversion "$_btusb_ko" 2>/dev/null)
    if [ -n "$_live_sv" ] && [ -n "$_want_sv" ] && [ "$_live_sv" != "$_want_sv" ]; then
      log "bt: unloading outdated btusb (live srcversion $_live_sv != patched $_want_sv)"
      ${RMMOD_CMD:-rmmod} btusb 2>/dev/null || log "bt: WARNING: rmmod outdated btusb failed"
      FIDEBOOK_BT_SETUP_DONE=
    fi
  fi
  if ! fidebook_mod_loaded btusb && fidebook_mod_loaded btmtk; then
    _btmtk_ko=$(fidebook_bt_ko_path btmtk)
    if [ -n "$_btmtk_ko" ]; then
      _live_msv=$(cat "$_sys/module/btmtk/srcversion" 2>/dev/null)
      _want_msv=$(${MODINFO_CMD:-modinfo} -F srcversion "$_btmtk_ko" 2>/dev/null)
      if [ -n "$_live_msv" ] && [ -n "$_want_msv" ] && [ "$_live_msv" != "$_want_msv" ]; then
        log "bt: unloading outdated btmtk (live srcversion $_live_msv != patched $_want_msv)"
        ${RMMOD_CMD:-rmmod} btmtk 2>/dev/null || true
      fi
    fi
  fi
}

# Hardware-aware USB Bluetooth bring-up (MediaTek MT7902 13d3:3594, MT7921/7922/7925, Intel, Realtek, QCA, Broadcom).
# $1 = max seconds to wait for async firmware setup (default 8).
fidebook_bt_init() {
  _sys=${SYSFS:-/sys}
  _fwpath=${FIDEBOOK_FWPATH_OVERRIDE:-$FIDEBOOK_FWPATH}
  # Bridge /postinstall -> /fidebook in stage0 so firmware requests succeed both before and after switch_root.
  if [ -z "${SYSFS:-}" ] && [ -d /fidebook ] && [ ! -e /postinstall ]; then
    ln -s /fidebook /postinstall 2>/dev/null || true
  fi
  [ -d "$G/firmware" ] && [ -w "$_fwpath" ] && printf '%s' "$G/firmware" > "$_fwpath" 2>/dev/null || true

  _bt_devs=$(fidebook_bt_usb_scan)
  [ -n "$_bt_devs" ] || return 0

  # Fast-path if a previous pass in this boot already verified hci0 firmware setup with the patched module.
  fidebook_bt_ensure_fresh
  if [ "${FIDEBOOK_BT_SETUP_DONE:-}" = "1" ] && fidebook_mod_loaded btusb && [ -n "$(ls "$_sys/class/bluetooth" 2>/dev/null)" ]; then
    fidebook_bt_rfkill_unblock
    return 0
  fi

  log "bt: detected USB Bluetooth: $(echo "$_bt_devs" | tr '\n' ' ')"

  _need_mtk=0; _need_mtk7902=0; _need_intel=0; _need_rtl=0; _need_qca=0
  for _entry in $_bt_devs; do
    case "${_entry##*:}" in
      mtk7902) _need_mtk=1; _need_mtk7902=1 ;;
      mtk)     _need_mtk=1 ;;
      intel)   _need_intel=1 ;;
      realtek) _need_rtl=1 ;;
      qca)     _need_qca=1 ;;
    esac
  done

  if [ "$_need_mtk7902" = 1 ]; then
    if [ -s "$G/firmware/mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin" ]; then
      log "bt: MT7902 firmware verified ($G/firmware/mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin)"
    else
      log "bt: ERROR: MT7902 firmware missing at $G/firmware/mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin"
    fi
  fi
  if [ "$_need_intel" = 1 ] && [ ! -d "$G/firmware/intel" ]; then
    log "bt: WARNING: Intel Bluetooth detected but $G/firmware/intel directory is missing"
  fi

  # 1. Core Bluetooth stack + RFKILL + profile modules (idempotent, no duplicate loads)
  fidebook_load_mod rfkill
  fidebook_load_mod bluetooth || { log "bt: ERROR: failed to load bluetooth core module"; return 1; }
  fidebook_load_mod rfcomm || true
  fidebook_load_mod hidp || true
  fidebook_bt_rfkill_unblock

  # 2. Vendor sub-drivers BEFORE btusb (btusb links against btmtk, btintel, btbcm, btrtl).
  #    Explicitly load btmtk first when MediaTek hardware is present or when using kmod fallback.
  if [ "$_need_mtk" = 1 ] || [ -f "$G/kmod/btmtk.ko" ]; then
    fidebook_load_mod btmtk "$G/kmod/btmtk.ko" \
      || log "bt: WARNING: failed to load btmtk before btusb"
  fi
  fidebook_load_mod btbcm "$G/kmod/btbcm.ko" || true
  fidebook_load_mod btintel "$G/kmod/btintel.ko" || true
  fidebook_load_mod btrtl "$G/kmod/btrtl.ko" || true
  [ "$_need_qca" = 1 ] && { fidebook_load_mod btqca "$G/kmod/btqca.ko" || true; }

  # 3. Patched btusb driver
  if ! fidebook_load_mod btusb "$G/kmod/btusb.ko"; then
    log "bt: ERROR: btusb load FAILED: $(${DMESG_CMD:-dmesg} 2>/dev/null | grep -iE 'btusb|btmtk|btintel|bluetooth' | tail -n 3 | tr '\n' ' ')"
    return 1
  fi

  # 4. Poll smartly (0.25s intervals, no unnecessary fixed sleep) for hci0 registration & async firmware setup
  _max_ticks=$(( ${1:-8} * 4 ))
  _t=0
  _setup_msg=""
  _err_msg=""
  while [ "$_t" -lt "$_max_ticks" ]; do
    fidebook_bt_rfkill_unblock
    _hcis=$(ls "$_sys/class/bluetooth" 2>/dev/null | tr '\n' ' ')
    _dlog=$(${DMESG_CMD:-dmesg} 2>/dev/null | grep -iE 'Bluetooth: hci[0-9]|btmtk|btusb|btintel|Direct firmware load for (mediatek|intel)/' | tail -n 40)
    _err_msg=$(printf '%s\n' "$_dlog" | grep -E 'Failed to set up firmware|Failed to send wmt|Failed to get (device id|fw )|Failed to load .*firmware|Direct firmware load.*failed|Opcode 0x[0-9a-fA-F]+ failed' | tail -n 1)
    if [ -n "$_err_msg" ]; then
      break
    fi
    if [ -n "$_hcis" ]; then
      if [ "$_need_mtk" = 1 ]; then
        _setup_msg=$(printf '%s\n' "$_dlog" | grep -oE 'hci[0-9]+: Device setup in [0-9]+ usecs' | tail -n 1)
        [ -n "$_setup_msg" ] && break
      elif [ "$_need_intel" = 1 ]; then
        _setup_msg=$(printf '%s\n' "$_dlog" | grep -oE 'hci[0-9]+: (Firmware loaded[^,]*|Found device firmware: [^ ]+|Device booted[^,]*)' | tail -n 1)
        [ -n "$_setup_msg" ] && break
      else
        _setup_msg="hci registered ($_hcis)"
        break
      fi
    fi
    ${SLEEP_CMD:-sleep} 0.25 2>/dev/null || ${SLEEP_CMD:-sleep} 1
    _t=$((_t + 1))
  done

  # Ensure Android bluetooth HAL (uid/gid 1002) can access hci*/reset immediately after switch_root
  for _h in $_sys/class/bluetooth/hci*; do
    [ -e "$_h/reset" ] && chown 1002:1002 "$_h/reset" 2>/dev/null && chmod 0220 "$_h/reset" 2>/dev/null || true
  done
  fidebook_bt_rfkill_unblock

  _hcis=$(ls "$_sys/class/bluetooth" 2>/dev/null | tr '\n' ' ')
  if [ -n "$_err_msg" ]; then
    log "bt: ERROR during firmware/controller init (hci=${_hcis:-none}): $_err_msg"
    return 1
  elif [ -n "$_setup_msg" ]; then
    FIDEBOOK_BT_SETUP_DONE=1
    log "bt: ready (${_hcis% }): $_setup_msg (btusb=$(cat $_sys/module/btusb/srcversion 2>/dev/null))"
    return 0
  elif [ -n "$_hcis" ]; then
    log "bt: hci present (${_hcis% }), firmware setup still in progress or quiet"
    return 0
  else
    log "bt: WARNING: btusb loaded but no /sys/class/bluetooth/hci* appeared within ${1:-8}s"
    return 1
  fi
}

fidebook_modules_mount() {
  KVER=$(uname -r)
  grep -q " /lib/modules/$KVER " /proc/mounts 2>/dev/null && return 0
  MDIR=""
  if [ -f "$G/modules/lib/modules/$KVER/modules.dep" ]; then
    MDIR="$G/modules/lib/modules/$KVER"
  elif [ -f "$G/modules/lib/modules/${KVER}+/modules.dep" ]; then
    MDIR="$G/modules/lib/modules/${KVER}+"
  fi
  if [ -n "$MDIR" ]; then
    mkdir -p "/lib/modules/$KVER"
    mount --bind "$MDIR" "/lib/modules/$KVER" 2>/dev/null \
      && log "hwdetect: module tree $KVER ($(find /lib/modules/$KVER -name '*.ko' | wc -l) modules) bound from $MDIR" \
      || log "hwdetect: bind mount of $MDIR to /lib/modules/$KVER FAILED"
    return 0
  fi
  # A tree built for another kernel (e.g. "6.18.21-fidebook-whl+" on a "6.18.21-fidebook-whl" kernel) is not bound: its modules carry the other
  # release in their vermagic and the kernel refuses them. Say so, because the symptom is only "no driver for anything" (i915, Wi-Fi, audio).
  log "hwdetect: fidebook/modules/lib/modules/$KVER missing (found: $(ls $G/modules/lib/modules 2>/dev/null | tr '\n' ' '))," \
      "only the initramfs modules are available: rebuild the stick (tools/deploy_stick.sh) with the modules of this kernel"
  return 1
}

# iwlwifi is only the bus half: once it has its firmware it asks for the op_mode driver named in the ucode
# ("... op_mode iwlmvm") with request_module(), which silently does nothing in this initramfs. Without
# iwlmvm there is no wlan0 (boot-20 on kernel #32: iwlwifi loaded, firmware loaded, no Wi-Fi). Load it ourselves.
fidebook_load_opmodes() {
  for m in $(dmesg | sed -n 's/.*op_mode \(iwl[a-z]*\).*/\1/p' | sort -u); do
    grep -q "^$m " /proc/modules && continue
    modprobe -q $m && log "hwdetect: loaded $m (op_mode announced by iwlwifi)" || log "hwdetect: modprobe $m FAILED"
  done
}

# MODOPTS="module.param=value ..." (fidebook.cfg): configure module parameters generically via /etc/modprobe.d/
# and /etc/modprobe.conf so that when modalias coldplug loads a driver for a detected device, the parameters
# are applied naturally without hardcoding drivers or loading modules for hardware not present.
fidebook_modopts() {
  mkdir -p /etc/modprobe.d 2>/dev/null
  : > /etc/modprobe.d/fidebook.conf

  # Backward compatibility: map legacy XE_PARAMS to options xe ...
  if [ -n "$XE_PARAMS" ]; then
    echo "options xe $XE_PARAMS" >> /etc/modprobe.d/fidebook.conf
    log "hwdetect: MODOPTS: mapped legacy XE_PARAMS to xe options"
  fi

  # Backward compatibility: LOAD_I915=0 blacklists i915
  if [ "$LOAD_I915" = "0" ]; then
    echo "blacklist i915" >> /etc/modprobe.d/fidebook.conf
    log "hwdetect: MODOPTS: LOAD_I915=0 -> blacklisted i915"
  fi

  [ -n "$MODOPTS" ] || { cp /etc/modprobe.d/fidebook.conf /etc/modprobe.conf 2>/dev/null; return 0; }

  # Parse module.param=value entries into "options <module> <param>=<val>"
  echo "$MODOPTS" | tr ' ' '\n' | awk '
    index($0,".")>1 && index($0,"=")>index($0,".") {
      i=index($0,"."); m=substr($0,1,i-1); o[m]=o[m] " " substr($0,i+1)
    }
    /^blacklist=/ { split($0, a, "="); b[a[2]]=1 }
    END {
      for(m in o) print "options " m o[m]
      for(m in b) print "blacklist " m
    }' >> /etc/modprobe.d/fidebook.conf

  cp /etc/modprobe.d/fidebook.conf /etc/modprobe.conf 2>/dev/null
  log "hwdetect: configured modprobe options from MODOPTS"
}

# One coldplug pass: all modaliases, de-duplicated, to a single modprobe (it reads modules.alias once).
fidebook_coldplug_pass() {
  find /sys/devices -name modalias 2>/dev/null | xargs cat 2>/dev/null | sort -u \
    | xargs modprobe -a -q 2>/dev/null
}

fidebook_coldplug() {
  [ -f /lib/modules/$(uname -r)/modules.alias ] || { log "hwdetect: no modules.alias, skipping coldplug"; return 1; }
  # Not loaded by alias: ACPI video (brightness keys), battery already built in.
  p=1; before=$(wc -l < /proc/modules)
  while [ $p -le 4 ]; do
    fidebook_coldplug_pass
    sleep 1; fidebook_load_opmodes; mdev -s 2>/dev/null
    now=$(wc -l < /proc/modules)
    log "hwdetect: coldplug pass $p: $now modules loaded (was $before)"
    [ $now -eq $before ] && break
    before=$now; p=$((p+1))
  done
}

# Give drivers time to finish probing and pull their firmware (Wi-Fi, Bluetooth, audio DSP).
fidebook_wait_devices() {
  i=0
  while [ $i -lt ${1:-15} ]; do
    w=$(ls /sys/class/net 2>/dev/null | grep -c '^wl')
    b=$(ls /sys/class/bluetooth 2>/dev/null | wc -l)
    s=$(grep -c '\[' /proc/asound/cards 2>/dev/null)
    # Done when every class that exists on this machine has shown up, or nothing is loading any more.
    if [ "$w" -gt 0 ] && [ "$b" -gt 0 ] && [ "$s" -gt 0 ]; then break; fi
    [ "$w" -eq 0 ] && grep -q '^iwlwifi ' /proc/modules && fidebook_load_opmodes
    # Peripherals created by the drivers loaded above (SoundWire codecs, Surface Aggregator children) appear after the first
    # coldplug: another pass every 2 s while waiting.
    [ $((i % 2)) -eq 1 ] && fidebook_coldplug_pass
    # SoundWire codecs were not autoloaded by the coldplug here (root cause not found, modalias present on the Surface Laptop 7;
    # on the Latitude 7320 (Tiger Lake) the codec sysfs entries exist but have an empty modalias): ask for them by name once the
    # SoundWire machine driver is in. Surface Laptop 7: RT1320 amp + RT721 jack codec. Latitude 7320: RT711 (SDCA) jack codec,
    # RT1316 amp, RT714 (rt715-sdca driver) on the topology sof-tgl-rt711-l0-rt1316-l1-mono-rt714-l3. Harmless without the chips.
    # Once per boot (the module names are only asked for when the machine driver is loaded).
    if grep -q '^snd_soc_sof_sdw ' /proc/modules && [ -z "$FIDEBOOK_SDW_REQ" ]; then
      FIDEBOOK_SDW_REQ=1
      modprobe -a -q snd-soc-rt1320-sdw snd-soc-rt721-sdca snd-soc-rt711-sdca snd-soc-rt1316-sdw snd-soc-rt715-sdca 2>/dev/null \
        && log "hwdetect: SoundWire codec modules requested (rt1320, rt721, rt711-sdca, rt1316, rt715-sdca)"
    fi
    sleep 1; i=$((i+1))
  done
  log "hwdetect: devices after ${i}s: wifi=$(ls /sys/class/net 2>/dev/null | grep '^wl' | tr '\n' ' ') bt=$(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' ') sound=$(cat /proc/asound/cards 2>/dev/null | grep '\[' | tr -s ' ' | tr '\n' ';') backlight=$(ls /sys/class/backlight 2>/dev/null | tr '\n' ' ')"
}

fidebook_hw_report() {
  [ -n "$L" ] || return 0
  {
    echo "== kernel"; uname -a
    echo "== cpu"; grep -m1 'model name' /proc/cpuinfo; for f in avx avx2 fma bmi2 sha_ni gfni avx_vnni avx512f; do grep -m1 -qw $f /proc/cpuinfo && echo "$f yes" || echo "$f NO"; done
    echo "== dmi"; for f in sys_vendor product_name product_version bios_version board_name; do echo "$f=$(cat /sys/class/dmi/id/$f 2>/dev/null)"; done
    echo "== pci devices without a driver (slot class vendor:device)"
    for d in /sys/bus/pci/devices/*; do
      [ -e $d/driver ] || echo "${d##*/} $(cat $d/class) $(cat $d/vendor):$(cat $d/device)"
    done
    echo "== usb devices (vid:pid product)"
    for d in /sys/bus/usb/devices/[0-9]*-[0-9.]*; do
      [ -f $d/idVendor ] && echo "$(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/product 2>/dev/null) drv=$(for i in $d:*; do readlink $i/driver 2>/dev/null; done | sed 's#.*/##' | sort -u | tr '\n' ',')"
    done
    echo "== input"; grep -E '^(N: Name|H: Handlers)' /proc/bus/input/devices
    echo "== net";   ls /sys/class/net
    echo "== bluetooth"; ls /sys/class/bluetooth 2>&1
    for h in /sys/class/bluetooth/hci*; do
      [ -e "$h" ] && echo "  ${h##*/}: drv=$(readlink "$h/device/driver" 2>/dev/null | sed 's#.*/##') addr=$(cat "$h/address" 2>/dev/null) btusb_src=$(cat /sys/module/btusb/srcversion 2>/dev/null) btmtk_src=$(cat /sys/module/btmtk/srcversion 2>/dev/null)"
    done
    echo "== backlight"; for b in /sys/class/backlight/*; do [ -e $b ] && echo "$b max=$(cat $b/max_brightness) cur=$(cat $b/brightness)"; done
    # DRM cards and the driver bound to each, then the driver's own dmesg (amdgpu: ip blocks, firmware, ring tests, "[drm] Display Core").
    echo "== gpu (drm card: driver)"; for c in /sys/class/drm/card[0-9]*; do case ${c##*/} in card*-*) continue;; esac; [ -e $c ] && echo "${c##*/}: $(readlink $c/device/driver 2>/dev/null | sed 's#.*/##') $(cat $c/device/vendor $c/device/device 2>/dev/null | tr '\n' ' ')"; done
    echo "== gpu dmesg"; dmesg | grep -iE 'amdgpu|\[drm|drm:|i915|simpledrm|xe 0000|\*ERROR\*' | head -n 100
    echo "== sound"; cat /proc/asound/cards 2>&1
    # Codec id + PCI subsystem id are what an HDA speaker/mic quirk is keyed on; the dmesg lines say why a card is missing
    # (no machine driver, DSP firmware or topology not found, codec probe errors).
    echo "== sound codecs"
    for c in /proc/asound/card*/codec#*; do [ -f "$c" ] && { echo "--- $c"; grep -E '^(Codec|Address|Vendor Id|Subsystem Id|Revision Id|Default PCM|Node 0x[0-9a-f]+ \[Pin Complex\]|  Pin Default)' "$c" | head -n 40; }; done
    # PCM numbers + jack input devices are what usb/audio/gen_config.sh maps the audio HAL config from; the speaker/DAC nodes show
    # whether a codec fixup connected the second speaker pin (0x14) to the same DAC as 0x17.
    echo "== sound pcm"; cat /proc/asound/pcm 2>&1
    echo "== sound inputs"; grep '^N: Name' /proc/bus/input/devices 2>&1 | grep -iE 'sof|hda|pch|headphone|mic|hdmi'
    echo "== sound speaker nodes"
    for c in /proc/asound/card*/codec#*; do [ -f "$c" ] && { echo "--- $c"; awk '/^Node 0x(02|03|14|17|21) /{print; p=1; next} /^Node /{p=0} p' "$c" | head -n 80; }; done
    echo "== sound dmesg"; dmesg | grep -iE 'sof|snd_|hdaudio|hda_|hdac|dmic|tplg|topology|skl_hda|dspcfg|audio|tas2[0-9]+|TAS2XXX' | head -n 80
    echo "== soundwire"; for d in /sys/bus/soundwire/devices/*; do [ -e $d ] && echo "${d##*/} modalias=$(cat $d/modalias 2>/dev/null) driver=$(readlink $d/driver 2>/dev/null | sed 's#.*/##')"; done
    echo "== soundwire dmesg"; dmesg | grep -iE 'sdw|soundwire|rt1320|rt721|sdca|asoc|tplg' | grep -v find_sdca_function | tail -n 60
    echo "== rfkill"; for r in /sys/class/rfkill/*; do [ -e $r ] && echo "$(cat $r/name) $(cat $r/type) soft=$(cat $r/soft) hard=$(cat $r/hard)"; done
    echo "== missing firmware"; dmesg | grep -iE 'firmware.*(failed|not found|-2\))|Direct firmware load.*failed|failed to load.*(ucode|\.bin|\.sfi)' | sort -u
    echo "== MODOPTS"; echo "${MODOPTS:-(none)}"
    echo "== display (drm connectors: status, enabled, first modes)"
    for c in /sys/class/drm/card*-*; do
      [ -e $c/status ] && { echo "${c##*/} status=$(cat $c/status) enabled=$(cat $c/enabled 2>/dev/null)"; head -6 $c/modes 2>/dev/null | sed 's/^/    /'; }
    done
    echo "== video devices (cameras)"; for v in /sys/class/video4linux/*; do [ -e $v ] && echo "${v##*/} $(cat $v/name)"; done
    for m in xe i915; do
      [ -d /sys/module/$m/parameters ] && { echo "== $m parameters"; for p in /sys/module/$m/parameters/*; do echo "${p##*/}=$(cat $p 2>/dev/null)"; done; }
    done
    echo "== driver messages (wifi, graphics, camera, audio, bluetooth; first 250)"
    dmesg | grep -iE 'iwlwifi|iwlmvm|iwlmld|mt7902|mt7921|mt7925|\bxe [0-9a-f:.]+|\[drm|ipu[0-9]|intel-ipu|ivsc|sof-audio|snd_sof|sof-firmware|soundwire|cs42l43|Bluetooth: hci|btmtk|btusb|btintel|No config found|unsupported' | head -250
    echo "== lsmod"; lsmod
  } > $L/hwdetect.txt 2>&1
  log "hwdetect: report written (hwdetect.txt)"
}

# Whole thing; $1 = seconds to wait for devices (default 15).
fidebook_hwdetect() {
  [ -f $G/fidebook.cfg ] && [ "$HWDETECT" = 0 ] && { log "hwdetect: disabled (HWDETECT=0)"; return 0; }
  [ -d /fidebook ] && [ ! -e /postinstall ] && ln -s /fidebook /postinstall 2>/dev/null || true
  [ -d $G/firmware ] && echo -n $G/firmware > $FIDEBOOK_FWPATH
  fidebook_modules_mount && fidebook_modopts && fidebook_coldplug && { fidebook_bt_init 8 || true; } && fidebook_wait_devices ${1:-15}
  # The brightness keys/backlight need acpi_video when the panel has no native backlight.
  [ -d /sys/class/backlight ] && [ -z "$(ls /sys/class/backlight 2>/dev/null)" ] && modprobe -q video 2>/dev/null
  fidebook_hw_report
}
