#!/system/bin/sh
# FideBookOS 1.25 hardware tuning and conservative desktop visual defaults.

if [ -n "${FIDEBOOK_BOOT_POLICY_HELPER:-}" ]; then
    if [ -r "$FIDEBOOK_BOOT_POLICY_HELPER" ]; then
        . "$FIDEBOOK_BOOT_POLICY_HELPER"
    else
        echo "optimize: boot_policy.sh unavailable; leaving boot policy unchanged" >&2
        exit 1
    fi
elif [ -r /postinstall/fidebook/boot_policy.sh ]; then
    . /postinstall/fidebook/boot_policy.sh
elif [ -r "$(dirname "$0")/boot_policy.sh" ]; then
    . "$(dirname "$0")/boot_policy.sh"
else
    echo "optimize: boot_policy.sh unavailable; leaving boot policy unchanged" >&2
    exit 1
fi

# Keep the standalone governor block intact for the existing fake-sysfs tests.
fidebook_optimize_governor() {
# Software rendering needs CPU throughput. Hardware GPUs share the APU's
# thermal budget, so prefer schedutil + balance_performance there.
if [ "$(getprop ro.fidebook.software_rendering)" = 1 ]; then
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$g" 2>/dev/null
    done
    for e in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        echo performance > "$e" 2>/dev/null
    done
else
    AVAIL_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)
    TARGET_GOV=performance
    case " $AVAIL_GOV " in
        *" schedutil "*) TARGET_GOV=schedutil ;;
        *" ondemand "*)  TARGET_GOV=ondemand ;;
    esac
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$TARGET_GOV" > "$g" 2>/dev/null
    done
    for e in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        echo balance_performance > "$e" 2>/dev/null || echo performance > "$e" 2>/dev/null
    done
fi
}

fidebook_optimize_hardware() {
    fidebook_optimize_governor
    # Prevent Realtek/AMD HDA audio codec 1-second sleep speaker pop/click.
    if [ -w /sys/module/snd_hda_intel/parameters/power_save ]; then
        echo 0 > /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null
    fi

    # Preserve the working Radeon/Intel low-latency DPM / SMU clock ramp tuning.
    for gcard in /sys/class/drm/card[0-9]/device; do
        [ -d "$gcard" ] || continue
        echo on > "$gcard/power/control" 2>/dev/null
        if [ -w "$gcard/power_dpm_force_performance_level" ]; then
            echo auto > "$gcard/power_dpm_force_performance_level" 2>/dev/null
        fi
        if [ -w "$gcard/pp_power_profile_mode" ]; then
            echo 1 > "$gcard/pp_power_profile_mode" 2>/dev/null
        fi
    done

    sysctl -w kernel.timer_migration=0 2>/dev/null
    sysctl -w kernel.sched_autogroup_enabled=1 2>/dev/null
    sysctl -w kernel.printk="3 3 1 3" 2>/dev/null

    # Avoid wake latency on input/Bluetooth peripherals.
    for d in /sys/bus/usb/devices/*/power/control; do
        echo on > "$d" 2>/dev/null
    done

    # Non-rotational flash storage only.
    for q in /sys/block/nvme*n*/queue /sys/block/mmcblk*/queue /sys/block/sd*/queue; do
        [ -d "$q" ] || continue
        [ "$(cat "$q/rotational" 2>/dev/null)" = "0" ] || continue
        echo 2 > "$q/rq_affinity" 2>/dev/null
        echo 0 > "$q/nomerges" 2>/dev/null
        echo 256 > "$q/read_ahead_kb" 2>/dev/null
        echo 0 > "$q/iostats" 2>/dev/null
    done

    NUM_CPUS=$(nproc 2>/dev/null || echo 4)
    VALID_CPUS="0-$((NUM_CPUS - 1))"
    for cs in /dev/cpuset/*/cpus /dev/cpuset/cpus; do
        echo "$VALID_CPUS" > "$cs" 2>/dev/null
    done
    setprop vendor.sys_tuner.disable_cpuset_config true
    stop touchpad-inhibitor 2>/dev/null
    setprop log.tag.drmhwc WARN
    setprop persist.log.tag.drmhwc WARN
}

fidebook_prepare_visual_files() {
    # These paths also let source-only tests use private temporary directories.
    _opt_local=${FIDEBOOK_LOCAL_DIR:-/data/local}
    _opt_tmp=${FIDEBOOK_TMP_DIR:-/data/local/tmp}
    _opt_oobe=${FIDEBOOK_OOBE_DIR:-/data/local/tmp/fidebook_oobe}
    mkdir -p -m 0777 "$_opt_local" "$_opt_tmp" "$_opt_oobe" 2>/dev/null
    chmod 0777 "$_opt_local" "$_opt_oobe" 2>/dev/null
    chmod 01777 "$_opt_tmp" 2>/dev/null
    _opt_wp=${FIDEBOOK_WALLPAPER:-/postinstall/fidebook/branding/wallpaper.jpg}
    _opt_wp_tmp=${FIDEBOOK_WALLPAPER_TMP:-/data/local/tmp/fidebook_wallpaper.jpg}
    if [ -f "$_opt_wp" ] && [ ! -e "$_opt_wp_tmp" ]; then
        cp "$_opt_wp" "$_opt_wp_tmp" 2>/dev/null || return 1
        chmod 0644 "$_opt_wp_tmp" 2>/dev/null
    fi
}

fidebook_default_wallpaper() (
    _opt_user=$(fidebook_current_ui_user) || return 1
    _opt_wp=${FIDEBOOK_WALLPAPER:-/postinstall/fidebook/branding/wallpaper.jpg}
    _opt_user_dir=${FIDEBOOK_USER_SYSTEM_DIR:-/data/system/users}/$_opt_user
    [ -f "$_opt_wp" ] && [ -d "$_opt_user_dir" ] || return 0
    # Per-user evidence wins over a global revision/stamp. Never replace an
    # existing image, lock wallpaper, or live-wallpaper metadata on an update.
    for _opt_file in wallpaper wallpaper_orig wallpaper_lock wallpaper_lock_orig wallpaper_info.xml .fidebook_wallpaper_set; do
        [ ! -e "$_opt_user_dir/$_opt_file" ] || return 0
    done
    cp "$_opt_wp" "$_opt_user_dir/wallpaper_orig" 2>/dev/null || return 1
    cp "$_opt_wp" "$_opt_user_dir/wallpaper" 2>/dev/null || return 1
    chown system:system "$_opt_user_dir/wallpaper_orig" "$_opt_user_dir/wallpaper" 2>/dev/null
    chmod 0600 "$_opt_user_dir/wallpaper_orig" "$_opt_user_dir/wallpaper" 2>/dev/null
    restorecon "$_opt_user_dir/wallpaper_orig" "$_opt_user_dir/wallpaper" 2>/dev/null
    : > "$_opt_user_dir/.fidebook_wallpaper_set"
)

fidebook_optimize_visual_policy() (
    fidebook_current_ui_user >/dev/null || return 1
    _opt_result=0
    fidebook_sync_liquid_glass_rros || _opt_result=1
    fidebook_default_wallpaper || _opt_result=1

    # Only absent settings get defaults, including on software rendering. Do not
    # guess whether an existing animation/blur value came from us or the user.
    if [ "$(getprop ro.fidebook.software_rendering)" = 1 ]; then
        _opt_blurs=1
        _opt_animation=0
    else
        _opt_blurs=0
        _opt_animation=0.85
    fi
    fidebook_default_global_setting disable_window_blurs "$_opt_blurs" || _opt_result=1
    for _opt_key in window_animation_scale transition_animation_scale animator_duration_scale; do
        fidebook_default_global_setting "$_opt_key" "$_opt_animation" || _opt_result=1
    done
    fidebook_desktop_defaults || _opt_result=1
    for _opt_prop in persist.wm.debug.predictive_back persist.wm.debug.predictive_back_anim; do
        _opt_value=$(getprop "$_opt_prop" 2>/dev/null) || { _opt_result=1; continue; }
        if [ -z "$_opt_value" ]; then
            setprop "$_opt_prop" 1 2>/dev/null || _opt_result=1
        fi
    done
    return "$_opt_result"
)

fidebook_optimize_main() {
    sleep 3
    fidebook_optimize_hardware
    fidebook_prepare_visual_files
    fidebook_optimize_visual_policy || true
    # One-time undo of the pre-R3 optimizer's own `disable-user` list (Messages /
    # phone link, Gemini, Google app, AICore, ...): only that exact list, only
    # packages still in the DISABLED_USER state it set, then never again.
    fidebook_restore_legacy_disabled || true

    # Android's configured memory owner (mmd/LMKD) owns swap, zram, VM policy,
    # and cached-process limits. Do not tear down live swap or remove its files.
    # hook.sh must separately bound/validate any vendor mmd configuration before
    # enabling it; not interfering here does NOT opt into vendor disk swap.
    #
    # Otherwise packages, permissions, networking, Data Saver and metered-network
    # choices remain Android/user-managed. There is no unattended debloat path.
    setprop sys.use_fifo_ui 1
    sync
}

# Tests source the real policy functions without executing hardware tuning.
if [ "${FIDEBOOK_OPTIMIZE_LIBRARY_ONLY:-0}" != 1 ]; then
    fidebook_optimize_main "$@"
fi
