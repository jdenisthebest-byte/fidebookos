#!/system/bin/sh
# Shared source-only boot/UI policy. Ship beside optimize.sh and oobe_apply.sh at
# /postinstall/fidebook/boot_policy.sh. Sourcing this file performs no actions.

fidebook_current_ui_user() (
    # Do not guess user 0/10 or fall back to a property when services are starting.
    # In headless mode user 0 may be current briefly, but is never the UI target.
    _fbp_headless=$(cmd user is-headless-system-user-mode 2>/dev/null) || return 1
    case "$_fbp_headless" in true|false) ;; *) return 1 ;; esac
    _fbp_user=$(am get-current-user 2>/dev/null) || return 1
    case "$_fbp_user" in ''|*[!0-9]*) return 1 ;; esac
    case "$_fbp_user" in 0|[1-9]*) ;; *) return 1 ;; esac
    [ "$_fbp_headless:$_fbp_user" != true:0 ] || return 1
    printf '%s\n' "$_fbp_user"
)

# Exactly what optimize.sh ran `pm disable-user` on every boot up to 1.25 R2
# (identical in every revision since 37a3442). DISABLED_USER (enabled=3) is saved
# in package-restrictions.xml, so it outlived the script. In headless mode the
# desktop user's Messages / phone link, Gemini, Google app and AICore clients
# bind user-0 components (as the Play Store "Pending" bug showed for vending).
FIDEBOOK_LEGACY_USER0_DISABLED="com.google.android.apps.messaging com.google.android.apps.photos
com.google.android.youtube com.google.android.keep com.google.android.apps.recorder
com.google.android.apps.bard com.google.android.retaildemo com.google.android.federatedcompute
com.google.android.ondevicepersonalization.services com.google.android.aicore
com.google.android.marvin.talkback com.google.android.googlequicksearchbox com.android.vending
com.android.chrome"
# The old script disabled these in the hardcoded desktop user (10).
FIDEBOOK_LEGACY_UI_DISABLED="com.google.android.retaildemo com.google.android.federatedcompute
com.google.android.ondevicepersonalization.services com.google.android.snapshotservice
com.android.simappdialog com.android.emergency com.android.eyedropper"
FIDEBOOK_LEGACY_OLD_UI_USER=10

fidebook_package_user_state() (
    # Print the per-user enabled state (0 default, 1 enabled, 2 disabled,
    # 3 disabled-user, 4 disabled-until-used); print nothing if not installed.
    _fbp_dump=$(dumpsys package "$1" 2>/dev/null) || return 1
    printf '%s\n' "$_fbp_dump" | awk -v tag="User $2:" '
        index($0, tag) && match($0, /enabled=[0-9]+/) { print substr($0, RSTART + 8, RLENGTH - 8); exit }'
)

fidebook_restore_legacy_disabled_for_user() (
    # Undo only the optimizer's own `disable-user` on its own list. Any other
    # state (user/admin disable, default, enabled) is left exactly as it is.
    _fbp_u=$1
    shift
    _fbp_rc=0
    for _fbp_p in "$@"; do
        _fbp_s=$(fidebook_package_user_state "$_fbp_p" "$_fbp_u") || { _fbp_rc=1; continue; }
        [ "$_fbp_s" = 3 ] || continue
        pm enable --user "$_fbp_u" "$_fbp_p" >/dev/null 2>&1 || _fbp_rc=1
    done
    return "$_fbp_rc"
)

fidebook_restore_legacy_disabled() (
    # One-time migration: after it succeeds, a later choice by the user to
    # disable any of these apps is never overridden again.
    [ "$(getprop persist.fidebook.legacy_restore 2>/dev/null)" = 1 ] && return 0
    _fbp_ui=$(fidebook_current_ui_user) || return 1
    _fbp_rc=0
    # The lists are word-split on purpose.
    fidebook_restore_legacy_disabled_for_user 0 $FIDEBOOK_LEGACY_USER0_DISABLED || _fbp_rc=1
    _fbp_done=" 0 "
    for _fbp_u in "$FIDEBOOK_LEGACY_OLD_UI_USER" "$_fbp_ui"; do
        case "$_fbp_done" in *" $_fbp_u "*) continue ;; esac
        _fbp_done="$_fbp_done$_fbp_u "
        fidebook_restore_legacy_disabled_for_user "$_fbp_u" $FIDEBOOK_LEGACY_UI_DISABLED || _fbp_rc=1
    done
    # Phone app streaming (phone link "apps"): the pre-R3 optimizer granted this
    # every boot; the boot-policy rewrite dropped it, so new installs lack it.
    _fbp_s=$(fidebook_package_user_state com.google.ambient.streaming "$_fbp_ui") || _fbp_rc=1
    if [ -n "$_fbp_s" ]; then
        # Best effort: a build where it is not a grantable runtime permission
        # must not keep the package migration from completing.
        pm grant --user "$_fbp_ui" com.google.ambient.streaming android.permission.ACCESS_LOCAL_NETWORK >/dev/null 2>&1 || :
    fi
    [ "$_fbp_rc" = 0 ] || return 1
    setprop persist.fidebook.legacy_restore 1 2>/dev/null
)

fidebook_default_global_setting() (
    # Only seed an absent value. A legacy port value cannot be distinguished from
    # a user's choice, so even an existing 0 must not be "repaired" at boot.
    [ "$#" = 2 ] || return 1
    _fbp_value=$(settings get global "$1" 2>/dev/null) || return 1
    [ "$_fbp_value" = null ] || return 0
    settings put global "$1" "$2" >/dev/null 2>&1
)

fidebook_desktop_defaults() (
    fidebook_default_global_setting enable_freeform_support 1 || return 1
    fidebook_default_global_setting force_resizable_activities 1 || return 1
    fidebook_default_global_setting enable_non_resizable_multi_window 1
)

fidebook_sync_liquid_glass_rros() (
    # With no argument, replay an explicit persistent preference at boot. An
    # absent preference leaves OverlayManager's per-user state alone. Static
    # branding overlays need no reset/enable pass and are deliberately untouched.
    _fbp_user=$(fidebook_current_ui_user) || return 1
    if [ "$#" -gt 0 ]; then
        _fbp_glass=$1
    else
        _fbp_glass=$(getprop persist.fidebook.liquid_glass 2>/dev/null) || return 1
    fi
    case "$_fbp_glass" in
        1|on|true) _fbp_action=enable ;;
        0|off|false) _fbp_action=disable ;;
        '') [ "$#" = 0 ] && return 0; return 1 ;;
        *) return 1 ;;
    esac
    # Software rendering changes only the effective RRO state, not the saved
    # choice, so moving back to a hardware GPU does not lose the user's toggle.
    _fbp_software=$(getprop ro.fidebook.software_rendering 2>/dev/null) || return 1
    if [ "$_fbp_software" = 1 ]; then
        _fbp_action=disable
    fi
    _fbp_list=$(cmd overlay list --user "$_fbp_user" 2>/dev/null) || return 1
    _fbp_plan=
    for _fbp_overlay in org.fidebookos.glass.framework org.fidebookos.glass.launcher org.fidebookos.glass.systemui; do
        _fbp_state=$(printf '%s\n' "$_fbp_list" | awk -v package="$_fbp_overlay" '
            $1 == "[x]" && $2 == package { print "enable" }
            $1 == "[" && $2 == "]" && $3 == package { print "disable" }
        ')
        # Missing targets, an unready overlay service, or unknown states must not
        # turn into a blanket disable/enable. Validate every target before writes.
        case "$_fbp_state" in enable|disable) ;; *) return 1 ;; esac
        [ "$_fbp_state" = "$_fbp_action" ] || _fbp_plan="$_fbp_plan $_fbp_overlay"
    done
    _fbp_result=0
    for _fbp_overlay in $_fbp_plan; do
        cmd overlay "$_fbp_action" --user "$_fbp_user" "$_fbp_overlay" >/dev/null 2>&1 || _fbp_result=1
    done
    return "$_fbp_result"
)
