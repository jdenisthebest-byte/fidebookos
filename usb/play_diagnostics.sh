#!/system/bin/sh
# play_diagnostics.sh N: always-on Play Store / Google Play services health snapshot.
# Started by the fidebook_playdiag init service once sys.boot_completed=1. Writes
# logs/boot-N/play.txt on the stick, so the next Update boot brings it to the Mac.
#
# This is evidence collection only. It never changes accounts, package state or GMS
# certification data, and it does not try to bypass Play Integrity or attestation.
N=${1:-0}
L=/postinstall/fidebook/logs/boot-$N
OUT=$L/play.txt
mkdir -p "$L" 2>/dev/null
exec >"$OUT" 2>&1

say() { echo; echo "==== $*"; }
sec() { echo; echo "---- $*"; }

# Wait for the user unlock / GMS startup to settle, but keep the boot-1 margin small.
sleep 30

say "Play diagnostics: $(date)"
echo "kernel: $(uname -a)"
echo "fingerprint: $(getprop ro.build.fingerprint)"
echo "model: $(getprop ro.product.model) / device: $(getprop ro.product.device)"
echo "build: $(getprop ro.build.id) / $(getprop ro.build.version.release) / sdk $(getprop ro.build.version.sdk)"
echo "boot: $(getprop ro.boot.bootreason) / slot: $(getprop ro.boot.slot_suffix)"
echo "uptime: $(uptime)"
echo "time: $(date) / auto_time=$(settings get global auto_time) / tz=$(getprop persist.sys.timezone)"

sec "storage"
df -h /data /postinstall 2>&1

say "package state"
for p in com.android.vending com.google.android.gms com.google.android.gsf \
         com.google.android.gms.ui com.google.android.apps.nexuslauncher; do
  echo
  echo "-- $p"
  timeout 20 dumpsys package "$p" 2>&1 \
    | grep -E '^[[:space:]]*(versionName|versionCode|firstInstallTime|lastUpdateTime|codePath|dataDir|userId=|installed=|enabled=|stopped=|hidden=|suspended=|notLaunched=|Package \[)' \
    | head -25
  echo "   path: $(pm path "$p" 2>&1 | head -3 | tr '\n' ' ')"
done

sec "package flags"
echo "user 0 enabled: $(pm list packages -e --user 0 2>/dev/null | grep -E 'vending|google.android.gms|google.android.gsf' | tr '\n' ' ')"
echo "user 0 disabled: $(pm list packages -d --user 0 2>/dev/null | grep -E 'vending|google.android.gms|google.android.gsf' | tr '\n' ' ')"
echo "user 10 enabled: $(pm list packages -e --user 10 2>/dev/null | grep -E 'vending|google.android.gms|google.android.gsf' | tr '\n' ' ')"
echo "user 10 disabled: $(pm list packages -d --user 10 2>/dev/null | grep -E 'vending|google.android.gms|google.android.gsf' | tr '\n' ' ')"
echo "disabled: $(pm list packages -d 2>/dev/null | grep -E 'vending|google.android.gms|google.android.gsf' | tr '\n' ' ')"
echo "enabled: $(pm list packages -e 2>/dev/null | grep -E 'vending|google.android.gms|google.android.gsf' | tr '\n' ' ')"
echo "uninstalled-for-user: $(pm list packages -u 2>/dev/null | grep -E 'vending|google.android.gms|google.android.gsf' | tr '\n' ' ')"

say "accounts (counts/types only)"
A=$(timeout 20 dumpsys account 2>&1)
echo "$A" | grep -c 'Account {' | sed 's/^/accounts_total=/'
echo "$A" | grep -o 'type=[^,}]*' | sort -u | tr '\n' ' ' | sed 's/^/account_types=/'
echo
echo "$A" | grep -c 'type=com.google' | sed 's/^/google_accounts=/'
echo "account services:"
echo "$A" | grep -E 'ServiceInfo|AccountType' | head -20

sec "settings"
for s in global:device_provisioned global:airplane_mode_on global:wifi_on global:auto_time \
         global:http_proxy global:private_dns_mode secure:android_id secure:user_setup_complete; do
  ns=${s%%:*}; key=${s#*:}
  echo "$ns/$key=$(settings get "$ns" "$key" 2>&1)"
done

say "Play/GMS exit info (latest crash/ANR reasons)"
for p in com.android.vending com.google.android.gms; do
  echo
  echo "-- $p"
  timeout 25 dumpsys activity exit-info "$p" 2>&1 | head -c 200000
  echo
done

say "GMS / Play provider state"
timeout 20 dumpsys activity providers 2>&1 | grep -i -E 'gservices|com.google.android.gsf|com.android.vending' | head -30
echo
timeout 20 dumpsys activity services com.google.android.gms 2>&1 | head -80

say "foreground window"
timeout 15 dumpsys window 2>&1 | grep -E 'mCurrentFocus|mFocusedApp' | head -5

say "connectivity"
timeout 20 dumpsys connectivity 2>&1 | grep -E 'Active default network|NetworkAgentInfo|VALIDATED|LinkAddresses|DnsAddresses' | head -40

say "recent crash buffer"
timeout 20 logcat -d -b crash -t 400 2>&1

say "ActivityManager / PackageManager events"
timeout 20 logcat -d -b system -t 500 -s ActivityManager ActivityTaskManager PackageManager 2>&1 | tail -250

say "dropbox app crashes / ANRs"
for tag in data_app_crash data_app_anr system_app_crash system_app_anr; do
  echo
  echo "-- $tag"
  timeout 20 dumpsys dropbox --print "$tag" 2>&1 | head -c 131072
  echo
done

say "GMS certification / registration markers (read-only, if readable)"
GSF_ID=$(content query --uri content://com.google.android.gsf.gservices --where "name='android_id'" 2>/dev/null | sed -n 's/.*value=\([0-9a-fA-F]*\).*/\1/p')
if [ -n "$GSF_ID" ]; then
  echo "GSF Device Registration ID: $GSF_ID"
  echo "Official Google Play Protect Device Registration Portal: https://www.google.com/android/uncertified/"
fi
for db in /data/data/com.google.android.gsf/databases/gservices.db \
          /data/user_de/0/com.google.android.gsf/databases/gservices.db; do
  [ -f "$db" ] || continue
  echo "-- $db"
  if command -v sqlite3 >/dev/null 2>&1; then
    timeout 15 sqlite3 "$db" \
      "select name, substr(value,1,96) from main where name like '%uncertified%' or name like '%device_registration%' or name like '%checkin%' limit 40;" 2>&1
  else
    echo "sqlite3 not present in this image"
  fi
done

say "done: $(date)"

# ---------------------------------------------------------------------------
# Phone link / Quick Share / Instant Tethering / AI clients: evidence only.
# Written to connect.txt at boot, then again after 10 and 30 minutes so the
# logcat ring buffer covers the user's attempts to link a phone or share files.
connect_snapshot() {
  say "connect snapshot ($1): $(date) uptime=$(cut -d' ' -f1 /proc/uptime)"
  U=$(am get-current-user 2>/dev/null)
  echo "current user: $U / headless: $(cmd user is-headless-system-user-mode 2>&1)"
  echo "legacy_restore=$(getprop persist.fidebook.legacy_restore)"
  sec "package states (enabled: 0 default 1 on 2 off 3 disabled-user)"
  for p in com.google.android.gms com.google.android.apps.messaging com.google.ambient.streaming \
           com.google.android.desktop.ioshub com.google.android.aicore com.google.android.as \
           com.google.android.as.oss com.google.android.apps.bard com.google.android.googlequicksearchbox \
           com.google.android.inputmethod.latin com.android.companiondevicemanager \
           com.google.android.federatedcompute com.google.android.ondevicepersonalization.services; do
    echo "-- $p: $(timeout 15 dumpsys package "$p" 2>/dev/null | grep -o -E 'User [0-9]+: .*(installed=[a-z]+).*(enabled=[0-9])' | sed -E 's/(User [0-9]+:).*(installed=[a-z]+).*(enabled=[0-9]).*/\1 \2 \3/' | tr '\n' ' ')"
  done
  sec "location / nearby settings"
  echo "location_mode=$(settings get --user "$U" secure location_mode 2>&1) bt_on=$(settings get global bluetooth_on 2>&1) wifi_on=$(settings get global wifi_on 2>&1)"
  timeout 10 cmd location is-location-enabled --user "$U" 2>&1 | sed 's/^/location_enabled=/'
  sec "bluetooth"
  timeout 20 dumpsys bluetooth_manager 2>&1 | grep -i -E 'enabled|state:|address|name:|LeExtended|LePeriodic|offload|LeAudio|le_|isLe|scan|advertis|profile' | head -60
  sec "wifi / p2p / aware"
  timeout 15 cmd wifi status 2>&1 | head -20
  timeout 20 dumpsys wifi 2>&1 | grep -i -E 'SupportedFeatures|feature|p2p|aware|softap|ap_|interface|iface' | head -50
  timeout 20 dumpsys wifip2p 2>&1 | head -40
  timeout 20 dumpsys wifiaware 2>&1 | head -25
  ip -br link 2>&1
  sec "companion / virtual devices / nearby service"
  timeout 20 dumpsys companiondevice 2>&1 | head -60
  timeout 20 dumpsys virtualdevice 2>&1 | head -30
  timeout 20 dumpsys nearby 2>&1 | head -40
  sec "logcat: nearby / multidevice / tethering / messages / streaming / AI clients"
  timeout 30 logcat -d -b main -b system -v threadtime 2>/dev/null \
    | grep -i -E 'nearby|quickshare|quick share|multidevice|bettertogether|proximityauth|cryptauth|devicesync|tether|phonehub|phone hub|ambient.?stream|companiondevice|virtualdevice|bugle|ioshub|wifip2p|wifiaware|nan_|aicore|astrea|writingtools|magicrewrite|summar' \
    | grep -v -E 'GCoreUlr|ProviderInstaller' | tail -700
  sec "logcat: errors from GMS/Bluetooth/Wi-Fi"
  timeout 30 logcat -d -b main -b system -v threadtime '*:E' 2>/dev/null \
    | grep -i -E 'gms|bluetooth|bt_|wifi|wpa_|hostapd|nearby|companion|bugle|stream' | tail -300
}
C=$L/connect.txt
sync
connect_snapshot boot > "$C" 2>&1; sync
sleep 570
connect_snapshot "after 10 min" >> "$C" 2>&1; sync
sleep 1200
connect_snapshot "after 30 min" >> "$C" 2>&1; sync
