#!/system/bin/sh
# oobe_apply.sh [--boot|--watch|--fx]:
#   - Applies explicit choices from FideBook Setup and Android's visual settings.
#   - Keeps the existing first-boot-only lifecycle, without guessing UI user IDs.

if [ -n "${FIDEBOOK_BOOT_POLICY_HELPER:-}" ]; then
  if [ -r "$FIDEBOOK_BOOT_POLICY_HELPER" ]; then
    . "$FIDEBOOK_BOOT_POLICY_HELPER"
  else
    echo "oobe_apply: boot_policy.sh unavailable; leaving boot policy unchanged" >&2
    exit 1
  fi
elif [ -r /postinstall/fidebook/boot_policy.sh ]; then
  . /postinstall/fidebook/boot_policy.sh
elif [ -r "$(dirname "$0")/boot_policy.sh" ]; then
  . "$(dirname "$0")/boot_policy.sh"
else
  echo "oobe_apply: boot_policy.sh unavailable; leaving boot policy unchanged" >&2
  exit 1
fi

OOBE_DIR="${FIDEBOOK_OOBE_DIR:-/data/local/tmp/fidebook_oobe}"
DONE_FILE="${FIDEBOOK_OOBE_DONE:-/data/local/tmp/.fidebook_oobe_done}"
MISC_DONE="${FIDEBOOK_MISC_DONE:-/data/misc/fidebook_oobe_done}"
FIRST_BOOT_STAMP="${FIDEBOOK_FIRST_BOOT_STAMP:-/data/misc/fidebook_first_boot_done}"
PERSIST_CFG="${FIDEBOOK_PERSIST_CFG:-/postinstall/fidebook/fidebook.cfg}"
SETUP_APK="${FIDEBOOK_SETUP_APK:-/postinstall/fidebook/branding/app/FideBookSetup.apk}"
SETUP_TMP_APK="${FIDEBOOK_SETUP_TMP_APK:-/data/local/tmp/FideBookSetup.apk}"

upsert_cfg_key() { # $1=KEY $2=VALUE
  [ -f "$PERSIST_CFG" ] && [ -w "$PERSIST_CFG" ] || return 0
  if grep -q "^#*$1=" "$PERSIST_CFG" 2>/dev/null; then
    sed -i "s|^#*$1=.*|$1=$2|" "$PERSIST_CFG" 2>/dev/null || true
  else
    echo "$1=$2" >> "$PERSIST_CFG" 2>/dev/null || true
  fi
}

apply_liquid_glass_rros() (
  case "$1" in
    0|off|false) _glass=0 ;;
    1|on|true) _glass=1 ;;
    *) return 1 ;;
  esac
  fidebook_sync_liquid_glass_rros "$_glass" || return 1
  setprop persist.fidebook.liquid_glass "$_glass" 2>/dev/null
)

apply_live_fx() (
  [ -f "$OOBE_DIR/fx.trigger" ] || return 0
  [ -f "$OOBE_DIR/fx.cmd" ] || return 1
  # Keep the trigger for a later watcher tick if Android services are not ready.
  fidebook_current_ui_user >/dev/null || return 1
  _lg=$(sed -n 's/^LIQUID_GLASS=\([01a-z]*\)$/\1/p' "$OOBE_DIR/fx.cmd" | head -n 1)
  _lv=$(sed -n 's/^LIQUID_GLASS_LEVEL=\([123]\)$/\1/p' "$OOBE_DIR/fx.cmd" | head -n 1)
  _mb=$(sed -n 's/^MOTION_BLUR=\([a-z0-9]*\)$/\1/p' "$OOBE_DIR/fx.cmd" | head -n 1)

  case "$_lg" in
    0|off|false)
      apply_liquid_glass_rros 0 || return 1
      upsert_cfg_key LIQUID_GLASS 0
      ;;
    1|on|true)
      apply_liquid_glass_rros 1 || return 1
      upsert_cfg_key LIQUID_GLASS 1
      ;;
  esac
  case "$_lv" in
    1|2|3)
      setprop persist.fidebook.liquid_glass_level "$_lv" 2>/dev/null || return 1
      upsert_cfg_key LIQUID_GLASS_LEVEL "$_lv"
      ;;
  esac
  case "$_mb" in
    ui|all|off|0)
      setprop persist.fidebook.motion_blur "$_mb" 2>/dev/null || return 1
      upsert_cfg_key MOTION_BLUR "$_mb"
      ;;
  esac
  rm -f "$OOBE_DIR/fx.trigger" 2>/dev/null || return 1
  sync 2>/dev/null || true
)

mark_never_again() {
  setprop persist.sys.fidebook.oobe_done 1 2>/dev/null || true
  mkdir -p "$(dirname "$MISC_DONE")" "$(dirname "$FIRST_BOOT_STAMP")" "$(dirname "$DONE_FILE")" 2>/dev/null || true
  : > "$MISC_DONE" 2>/dev/null || true
  : > "$FIRST_BOOT_STAMP" 2>/dev/null || true
  : > "$DONE_FILE" 2>/dev/null || true
  chmod 0644 "$DONE_FILE" "$MISC_DONE" "$FIRST_BOOT_STAMP" 2>/dev/null || true
  upsert_cfg_key OOBE_SETUP 0
  sync 2>/dev/null || true
}

check_started() {
  if [ -f "$OOBE_DIR/started.flag" ]; then
    # Confirm SetupActivity survived initialization before locking its start stamp.
    if [ -f "$OOBE_DIR/done.flag" ] || pidof org.fidebookos.setup >/dev/null 2>&1; then
      mkdir -p "$(dirname "$FIRST_BOOT_STAMP")" 2>/dev/null || true
      : > "$FIRST_BOOT_STAMP" 2>/dev/null || true
      chmod 0644 "$FIRST_BOOT_STAMP" 2>/dev/null || true
      upsert_cfg_key OOBE_SETUP 0
      rm -f "$OOBE_DIR/started.flag"
      sync 2>/dev/null || true
    fi
  fi
}

complete_current_setup() (
  _setup_user=$(fidebook_current_ui_user) || return 1
  mark_never_again
  # This is an explicit setup-completion action, not an unattended package list.
  # Keep the app/data for other users; global uninstall would delete their state.
  pm disable --user "$_setup_user" org.fidebookos.setup/.SetupActivity >/dev/null 2>&1 || true
  rm -f "$OOBE_DIR/done.flag" 2>/dev/null || true
)

apply_once() (
  if [ -f "$OOBE_DIR/fx.trigger" ]; then
    apply_live_fx || return 1
  fi
  _oobe_user=$(fidebook_current_ui_user) || return 1
  check_started
  if [ -f "$OOBE_DIR/done.flag" ] && [ ! -f "$OOBE_DIR/apply.trigger" ]; then
    complete_current_setup
    return $?
  fi
  [ -f "$OOBE_DIR/apply.trigger" ] || return 1
  [ -f "$OOBE_DIR/config.env" ] || return 1

  _dev=$(sed -n 's/^DEVICE_NAME="\([^"]*\)".*/\1/p' "$OOBE_DIR/config.env" | head -n 1 | tr -cd 'A-Za-z0-9 _.-')
  _lg=$(sed -n 's/^LIQUID_GLASS=\([01]\)$/\1/p' "$OOBE_DIR/config.env" | head -n 1)
  _mb=$(sed -n 's/^MOTION_BLUR=\([a-z0-9]*\)$/\1/p' "$OOBE_DIR/config.env" | head -n 1)
  _dark=$(sed -n 's/^DARK_MODE=\([a-z]*\)$/\1/p' "$OOBE_DIR/config.env" | head -n 1)
  _dpi=$(sed -n 's/^DENSITY=\([0-9]*\)$/\1/p' "$OOBE_DIR/config.env" | head -n 1)
  _tp=$(sed -n 's/^TOUCHPAD_FLICK=\([01]\)$/\1/p' "$OOBE_DIR/config.env" | head -n 1)
  _done=$(sed -n 's/^COMPLETE=\([01]\)$/\1/p' "$OOBE_DIR/config.env" | head -n 1)

  case "$_lg" in
    0|1) apply_liquid_glass_rros "$_lg" || return 1 ;;
  esac
  case "$_mb" in
    ui|all|off) setprop persist.fidebook.motion_blur "$_mb" 2>/dev/null || return 1 ;;
  esac
  if [ -n "$_dev" ]; then
    settings put global device_name "$_dev" 2>/dev/null || return 1
    settings --user "$_oobe_user" put secure bluetooth_name "$_dev" 2>/dev/null || return 1
  fi
  # UiModeManager and wm density operate on Android's current user themselves;
  # neither needs a guessed secondary user or an unscoped am fallback.
  case "$_dark" in
    yes) cmd uimode night yes >/dev/null 2>&1 || return 1 ;;
    no)  cmd uimode night no  >/dev/null 2>&1 || return 1 ;;
  esac

  if [ "$_done" = 1 ]; then
    case "$_dpi" in
      120|140|160|180|200|220|240|280|320)
        wm density "$_dpi" >/dev/null 2>&1 || return 1
        ;;
    esac
    [ -z "$_dev" ] || upsert_cfg_key DEVICE_MODEL "\"$_dev\""
    case "$_lg" in 0|1) upsert_cfg_key LIQUID_GLASS "$_lg" ;; esac
    case "$_mb" in ui|all|off) upsert_cfg_key MOTION_BLUR "$_mb" ;; esac
    case "$_dpi" in 120|140|160|180|200|220|240|280|320) upsert_cfg_key DENSITY "$_dpi" ;; esac
    case "$_tp" in 0|1) upsert_cfg_key TOUCHPAD_FLICK "$_tp" ;; esac
    complete_current_setup || return 1
  fi
  rm -f "$OOBE_DIR/apply.trigger" 2>/dev/null || return 1
  return 0
)

prepare_oobe_files() {
  _oobe_local=${FIDEBOOK_LOCAL_DIR:-/data/local}
  _oobe_tmp=${FIDEBOOK_TMP_DIR:-/data/local/tmp}
  mkdir -p -m 0777 "$_oobe_local" "$_oobe_tmp" 2>/dev/null || true
  mkdir -p -m 0777 "$OOBE_DIR" 2>/dev/null || return 1
  chmod 0777 "$_oobe_local" "$OOBE_DIR" 2>/dev/null || true
  chmod 01777 "$_oobe_tmp" 2>/dev/null || true
  _oobe_wp=${FIDEBOOK_WALLPAPER:-/postinstall/fidebook/branding/wallpaper.jpg}
  _oobe_wp_tmp=${FIDEBOOK_WALLPAPER_TMP:-/data/local/tmp/fidebook_wallpaper.jpg}
  if [ -f "$_oobe_wp" ] && [ ! -e "$_oobe_wp_tmp" ]; then
    cp "$_oobe_wp" "$_oobe_wp_tmp" 2>/dev/null || return 1
    chmod 0644 "$_oobe_wp_tmp" 2>/dev/null || true
  fi
}

provision_current_user() (
  _provision_user=$(fidebook_current_ui_user) || return 1
  _setup_complete=$(settings --user "$_provision_user" get secure user_setup_complete 2>/dev/null) || return 1
  case "$_setup_complete" in
    null|0) settings --user "$_provision_user" put secure user_setup_complete 1 2>/dev/null || return 1 ;;
    1) ;;
    *) return 1 ;;
  esac
  for _provision_key in device_provisioned setup_wizard_has_run; do
    _provision_value=$(settings get global "$_provision_key" 2>/dev/null) || return 1
    case "$_provision_value" in
      null|0) settings put global "$_provision_key" 1 2>/dev/null || return 1 ;;
      1) ;;
      *) return 1 ;;
    esac
  done
  fidebook_desktop_defaults
  # OTA, app updates, metered networks and Data Saver remain user/Android choices.
)

oobe_boot() (
  _want_oobe=${1:-1}
  prepare_oobe_files || return 1
  sleep 1
  _boot_user=$(fidebook_current_ui_user) || return 1
  provision_current_user || return 1
  _prop_done=$(getprop persist.sys.fidebook.oobe_done 2>/dev/null) || return 1
  case "$_prop_done" in ''|0|1) ;; *) return 1 ;; esac
  if [ "$_want_oobe" = 0 ] \
     || [ "$_prop_done" = 1 ] \
     || [ -f "$MISC_DONE" ] \
     || [ -f "$FIRST_BOOT_STAMP" ] \
     || [ -f "$DONE_FILE" ] \
     || [ -f "$OOBE_DIR/done.flag" ]; then
    return 0
  fi

  if [ -f "$SETUP_APK" ]; then
    # A signature mismatch must fail safely, not uninstall an existing app/data.
    cp "$SETUP_APK" "$SETUP_TMP_APK" 2>/dev/null || return 1
    chmod 0644 "$SETUP_TMP_APK" 2>/dev/null || return 1
    _install_result=0
    pm install -r --user "$_boot_user" "$SETUP_TMP_APK" >/dev/null 2>&1 || _install_result=1
    rm -f "$SETUP_TMP_APK" 2>/dev/null || true
    [ "$_install_result" = 0 ] || return 1
  fi
  # Use the user's selected HOME; do not force the stock launcher every reboot.
  am start --user "$_boot_user" -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1 || true
  sleep 1
  am start --user "$_boot_user" --windowingMode 1 -a android.intent.action.MAIN -n org.fidebookos.setup/.SetupActivity >/dev/null 2>&1 \
    || am start --user "$_boot_user" -n org.fidebookos.setup/.SetupActivity >/dev/null 2>&1
)

oobe_apply_main() {
  case "${1:-}" in
    --fx) apply_live_fx ;;
    --boot) oobe_boot "${2:-1}" ;;
    --watch)
      prepare_oobe_files || return 1
      _ticks=0
      while [ ! -f "$DONE_FILE" ] && [ ! -f "$MISC_DONE" ] && [ "$_ticks" -lt 3600 ]; do
        apply_once || true
        [ -f "$DONE_FILE" ] || [ -f "$MISC_DONE" ] && break
        sleep 1
        _ticks=$((_ticks + 1))
      done
      ;;
    *) apply_once || true ;;
  esac
}

# Explicit library mode exposes the actual functions to mocked-command tests.
if [ "${FIDEBOOK_OOBE_LIBRARY_ONLY:-0}" != 1 ]; then
  oobe_apply_main "$@"
fi
