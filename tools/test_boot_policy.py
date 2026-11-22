#!/usr/bin/env python3
"""Source the real shell policy with mocked Android commands; no device/root/network.

Use BOOT_POLICY_TEST_SHELL='bash --posix' (or a locally available busybox ash) to
repeat under another shell. All writable paths live in a private temp directory.
The hardware-tuning function is not executed against the host's sysfs.
"""
import copy
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GLASS = [f"org.fidebookos.glass.{name}" for name in ("framework", "launcher", "systemui")]
BRANDING = ["org.fidebookos.launcher.overlay", "org.fidebookos.settings.overlay"]
SHELL = shlex.split(os.environ.get("BOOT_POLICY_TEST_SHELL", "/bin/sh"))

MOCK = r'''
import json
import os
from pathlib import Path
import sys

root = Path(os.environ['BOOT_POLICY_FAKE'])
state_file = root / 'state.json'
s = json.loads(state_file.read_text())
name = Path(sys.argv[0]).name
a = sys.argv[1:]

def log(**extra):
    with (root / 'commands.jsonl').open('a') as f:
        f.write(json.dumps(dict(command=name, args=a, **extra)) + '\n')

def save():
    state_file.write_text(json.dumps(s))

def unexpected():
    log(unexpected=True)
    print('unexpected mocked command: ' + name + ' ' + repr(a), file=sys.stderr)
    sys.exit(91)

log()
if name == 'getprop' and len(a) == 1:
    if a[0] in s.get('get_fail_props', []):
        sys.exit(1)
    print(s['props'].get(a[0], ''))
elif name == 'setprop' and len(a) == 2:
    if a[0] in s.get('fail_props', []):
        sys.exit(1)
    s['props'][a[0]] = a[1]
    save()
elif name == 'am':
    if a == ['get-current-user']:
        if not s.get('activity_ready', True):
            sys.exit(1)
        print(s.get('user_response', s['user']))
    elif a[:1] == ['start'] and '--user' in a:
        if a[a.index('--user') + 1] != s['user']:
            unexpected()
        if s.get('start_failures', 0):
            s['start_failures'] -= 1
            save()
            sys.exit(1)
    else:
        unexpected()
elif name == 'cmd':
    if a == ['user', 'is-headless-system-user-mode']:
        if not s.get('user_ready', True):
            sys.exit(1)
        print(s['headless'])
    elif a[:2] == ['overlay', 'list'] and len(a) == 4 and a[2] == '--user':
        if not s.get('overlay_ready', True):
            sys.exit(1)
        if 'overlay_response' in s:
            print(s['overlay_response'])
        else:
            print('android')
            for package, enabled in s['overlays'][a[3]].items():
                prefix = '[x]' if enabled is True else '[ ]' if enabled is False else '---'
                print(prefix, package)
    elif len(a) == 5 and a[0] == 'overlay' and a[1] in ('enable', 'disable') and a[2] == '--user':
        if a[3] != s['user'] or a[4] not in s['overlays'][a[3]]:
            unexpected()
        if not s.get('overlay_ready', True) or s.get('overlay_write_fail', False):
            sys.exit(1)
        s['overlays'][a[3]][a[4]] = a[1] == 'enable'
        save()
    elif a[:2] == ['uimode', 'night'] and a[2:] in (['yes'], ['no']):
        s['settings'].setdefault('secure:' + s['user'], {})['ui_night_mode'] = '2' if a[2] == 'yes' else '1'
        save()
    else:
        unexpected()
elif name == 'settings':
    if not s.get('settings_ready', True):
        sys.exit(1)
    user = None
    if a[:1] == ['--user']:
        user, a = a[1], a[2:]
    if len(a) not in (3, 4) or a[0] not in ('get', 'put') or a[1] not in ('global', 'secure'):
        unexpected()
    if a[1] == 'secure' and user != s['user']:
        unexpected()
    scope = a[1] if a[1] == 'global' else a[1] + ':' + user
    values = s['settings'].setdefault(scope, {})
    if a[0] == 'get' and len(a) == 3:
        print(values.get(a[2], 'null'))
    elif a[0] == 'put' and len(a) == 4:
        values[a[2]] = a[3]
        save()
    else:
        unexpected()
elif name == 'pm':
    if len(a) == 5 and a[:3] == ['install', '-r', '--user'] and a[3] == s['user']:
        if s.get('install_fail', False):
            sys.exit(1)
        if not Path(a[4]).is_file():
            unexpected()
        s.setdefault('installed_for', []).append(a[3])
        save()
    elif len(a) == 4 and a[:2] == ['disable', '--user'] and a[2] == s['user'] and a[3] == 'org.fidebookos.setup/.SetupActivity':
        s['packages'][a[2]][a[3]] = 'disabled'
        save()
    elif len(a) == 4 and a[:2] == ['enable', '--user'] and a[3] in s['packages'].get(a[2], {}):
        if a[3] in s.get('enable_fail', []):
            sys.exit(1)
        s['packages'][a[2]][a[3]] = 'enabled'
        save()
    elif len(a) == 5 and a[:2] == ['grant', '--user'] and a[3] in s['packages'].get(a[2], {}):
        if s.get('grant_fail', False):
            sys.exit(1)
        s.setdefault('grants', []).append([a[2], a[3], a[4]])
        save()
    else:
        unexpected()
elif name == 'dumpsys' and len(a) == 2 and a[0] == 'package':
    codes = {'default': 0, 'enabled': 1, 'disabled': 2, 'disabled-user': 3, 'disabled-until-used': 4}
    users = [u for u in s['packages'] if a[1] in s['packages'][u]]
    if not users:
        print('Unable to find package: ' + a[1])
    else:
        print('Packages:')
        print('  Package [' + a[1] + '] (fake):')
        for u in sorted(users, key=int):
            print('    User %s: ceDataInode=1 installed=true hidden=false suspended=false stopped=false notLaunched=false enabled=%d instant=false virtual=false' % (u, codes[s['packages'][u][a[1]]]))
elif name == 'wm' and len(a) == 2 and a[0] == 'density':
    s.setdefault('density', {})[s['user']] = a[1]
    save()
elif name == 'pidof' and a == ['org.fidebookos.setup']:
    if not s.get('setup_alive', False):
        sys.exit(1)
    print('4242')
elif name in ('sleep', 'sync', 'chown', 'restorecon'):
    pass
else:
    unexpected()
'''


class BootPolicyTest(unittest.TestCase):
    def setUp(self):
        temp_base = os.environ.get("TMPDIR") or ("/tmp/opencode" if Path("/tmp/opencode").is_dir() else None)
        self.temp = tempfile.TemporaryDirectory(prefix="boot-policy.", dir=temp_base)
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        mock = self.bin / "android-mock"
        mock.write_text(f"#!{sys.executable}\n" + MOCK)
        mock.chmod(0o755)
        for command in ("am", "pm", "dumpsys", "cmd", "settings", "getprop", "setprop", "wm", "pidof", "sleep", "sync", "chown", "restorecon", "swapoff", "swapon", "sysctl", "stop"):
            (self.bin / command).symlink_to(mock.name)
        self.users = ("0", "10", "11", "23", "42")
        self.oobe = self.work / "local/tmp/fidebook_oobe"
        self.oobe.mkdir(parents=True)
        self.user_root = self.work / "users"
        for user in self.users:
            (self.user_root / user).mkdir(parents=True)
        self.wallpaper = self.work / "wallpaper.jpg"
        self.wallpaper.write_bytes(b"fixture default wallpaper, not a real image\n")
        self.apk = self.work / "Setup.apk"
        self.apk.write_bytes(b"fixture only; mock pm never reads APK internals\n")
        self.config = self.work / "fidebook.cfg"
        self.config.write_text("OOBE_SETUP=1\nLIQUID_GLASS=1\nLIQUID_GLASS_LEVEL=2\nMOTION_BLUR=ui\n")
        overlays = {name: True for name in GLASS + BRANDING}
        overlays["org.example.user.overlay"] = False
        packages = {
            "com.android.vending": "disabled-user",
            "com.android.providers.downloads": "enabled",
            "com.android.providers.downloads.ui": "enabled",
            "com.google.android.gms": "enabled",
            "com.google.android.gsf": "enabled",
            "com.google.android.marvin.talkback": "disabled-user",
            "org.fidebookos.setup/.SetupActivity": "default",
        }
        # Legacy optimizer state: user 0 had its list disable-user'd; the old
        # hardcoded desktop user 10 had the global list disable-user'd.
        legacy0 = {
            "com.google.android.apps.messaging": "disabled-user",
            "com.google.android.aicore": "disabled-user",
            "com.google.android.apps.bard": "disabled-user",
            "com.google.android.googlequicksearchbox": "disabled-user",
            "com.android.chrome": "disabled",          # e.g. disabled by an admin/user: keep
            "com.google.android.youtube": "default",   # never disabled: keep untouched
        }
        legacy10 = {
            "com.android.eyedropper": "disabled-user",
            "com.google.android.federatedcompute": "disabled-user",
            "com.google.ambient.streaming": "default",
        }
        self.initial = {
            "user": "10", "headless": "true",
            "props": {"persist.fidebook.liquid_glass": "1", "ro.fidebook.software_rendering": "0", "persist.fidebook.rro_rev": "old", "persist.wm.debug.predictive_back": "1", "persist.wm.debug.predictive_back_anim": "0", "persist.sys.max_cached_processes": "32"},
            "overlays": {user: copy.deepcopy(overlays) for user in self.users},
            "packages": {user: dict(copy.deepcopy(packages), **(legacy0 if user == "0" else legacy10 if user == "10" else {})) for user in self.users},
            "settings": {"global": {"window_animation_scale": "0.7", "transition_animation_scale": "0", "animator_duration_scale": "1.3", "disable_window_blurs": "1", "enable_freeform_support": "0", "force_resizable_activities": "1", "enable_non_resizable_multi_window": "0", "auto_system_update": "1", "ota_disable_automatic_update": "0", "restrict_background_data": "1"}},
            "network": {"metered": True, "data_saver": True, "wifi_overrides": {"user-network": "metered"}},
        }
        self.set_state(copy.deepcopy(self.initial))
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], BOOT_POLICY_FAKE=str(self.work), FIDEBOOK_BOOT_POLICY_HELPER=str(ROOT / "usb/boot_policy.sh"), FIDEBOOK_OPTIMIZE_LIBRARY_ONLY="1", FIDEBOOK_OOBE_LIBRARY_ONLY="1", FIDEBOOK_LOCAL_DIR=str(self.work / "local"), FIDEBOOK_TMP_DIR=str(self.work / "local/tmp"), FIDEBOOK_OOBE_DIR=str(self.oobe), FIDEBOOK_OOBE_DONE=str(self.work / "done"), FIDEBOOK_MISC_DONE=str(self.work / "misc/done"), FIDEBOOK_FIRST_BOOT_STAMP=str(self.work / "misc/first_boot"), FIDEBOOK_PERSIST_CFG=str(self.config), FIDEBOOK_SETUP_APK=str(self.apk), FIDEBOOK_SETUP_TMP_APK=str(self.work / "local/tmp/Setup.apk"), FIDEBOOK_WALLPAPER=str(self.wallpaper), FIDEBOOK_WALLPAPER_TMP=str(self.work / "local/tmp/wallpaper.jpg"), FIDEBOOK_USER_SYSTEM_DIR=str(self.user_root))

    def tearDown(self):
        self.assertEqual([c for c in self.commands() if c.get("unexpected")], [], "a policy invoked an unexpected/destructive mocked Android command")

    def set_state(self, state):
        (self.work / "state.json").write_text(json.dumps(state))

    def state(self):
        return json.loads((self.work / "state.json").read_text())

    def update(self, **values):
        state = self.state()
        state.update(values)
        self.set_state(state)

    def commands(self):
        path = self.work / "commands.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def overlay_writes(self):
        return [c for c in self.commands() if c["command"] == "cmd" and c["args"][:1] == ["overlay"] and c["args"][1] in ("enable", "disable")]

    def run_policy(self, body, success=True, source="both"):
        scripts = {"both": ("optimize.sh", "oobe_apply.sh"), "helper": ("boot_policy.sh",)}[source]
        program = "set -u\n" + "".join(". " + shlex.quote(str(ROOT / "usb" / script)) + "\n" for script in scripts) + body
        result = subprocess.run(SHELL + ["-c", program], env=self.env, text=True, capture_output=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def fx(self, text):
        (self.oobe / "fx.cmd").write_text(text)
        (self.oobe / "fx.trigger").touch()

    def setup_choices(self, text):
        (self.oobe / "config.env").write_text(text)
        (self.oobe / "apply.trigger").touch()

    def optimizer(self):
        # Isolate only the hardware boundary; run the actual main/user functions.
        self.run_policy("fidebook_optimize_hardware() { :; }; fidebook_optimize_main")

    def test_library_mode_has_no_side_effects(self):
        self.run_policy(":")
        self.assertEqual(self.commands(), [])
        self.assertFalse((self.work / "done").exists())

    def test_missing_shared_helper_fails_closed(self):
        self.env["FIDEBOOK_BOOT_POLICY_HELPER"] = str(self.work / "missing")
        self.run_policy(":", success=False)
        self.assertEqual(self.commands(), [])

    def test_resolver_handles_headless_and_nonheadless_users(self):
        for headless in ("true", "false"):
            for user in ("0", "10", "23", "42"):
                with self.subTest(headless=headless, user=user):
                    self.update(headless=headless, user=user)
                    valid = not (headless == "true" and user == "0")
                    result = self.run_policy("fidebook_current_ui_user", success=valid, source="helper")
                    self.assertEqual(result.stdout.strip(), user if valid else "")

    def test_resolver_rejects_invalid_or_ambiguous_ids(self):
        for response in ("", "-1", "-2", " 10", "010", "10\n0", "Current user: 10", "10; echo unsafe"):
            with self.subTest(response=response):
                self.update(user_response=response)
                self.run_policy("fidebook_current_ui_user", success=False, source="helper")

    def test_resolver_requires_ready_services_and_known_mode(self):
        for change in ({"user_ready": False}, {"activity_ready": False}, {"headless": "unknown"}):
            with self.subTest(change=change):
                state = copy.deepcopy(self.initial)
                state.update(change)
                self.set_state(state)
                self.run_policy("fidebook_current_ui_user", success=False, source="helper")
        self.assertEqual(self.overlay_writes(), [])

    def test_optimizer_targets_only_current_ui_user(self):
        for headless, user in (("true", "10"), ("true", "23"), ("false", "0"), ("false", "11")):
            with self.subTest(headless=headless, user=user):
                state = copy.deepcopy(self.initial)
                state.update(headless=headless, user=user)
                state["props"]["persist.fidebook.liquid_glass"] = "0"
                self.set_state(state)
                self.run_policy("fidebook_optimize_visual_policy")
                after = self.state()
                for target in self.users:
                    for overlay in GLASS:
                        self.assertEqual(after["overlays"][target][overlay], target != user)
                    for overlay in BRANDING + ["org.example.user.overlay"]:
                        self.assertEqual(after["overlays"][target][overlay], state["overlays"][target][overlay])
                self.assertEqual(after["props"]["persist.fidebook.rro_rev"], "old")

    def test_headless_system_user_zero_gets_no_ui_policy(self):
        self.update(user="0")
        self.run_policy("fidebook_optimize_visual_policy", success=False)
        self.assertEqual(self.state(), self.initial | {"user": "0"})
        self.assertEqual(self.overlay_writes(), [])
        self.assertFalse((self.user_root / "0/wallpaper").exists())

    def test_explicit_glass_aliases_and_software_renderer(self):
        for choice in ("0", "off", "false", "1", "on", "true"):
            with self.subTest(choice=choice):
                state = copy.deepcopy(self.initial)
                enabled = choice in ("1", "on", "true")
                state["props"]["persist.fidebook.liquid_glass"] = choice
                for overlay in GLASS:
                    state["overlays"]["10"][overlay] = not enabled
                self.set_state(state)
                self.run_policy("fidebook_sync_liquid_glass_rros")
                self.assertTrue(all(self.state()["overlays"]["10"][ov] == enabled for ov in GLASS))
        state = copy.deepcopy(self.initial)
        state["props"]["ro.fidebook.software_rendering"] = "1"
        self.set_state(state)
        self.run_policy("fidebook_sync_liquid_glass_rros")
        self.assertEqual(self.state()["props"]["persist.fidebook.liquid_glass"], "1")
        self.assertTrue(all(not self.state()["overlays"]["10"][ov] for ov in GLASS))
        state = self.state()
        state["props"]["ro.fidebook.software_rendering"] = "0"
        self.set_state(state)
        self.run_policy("fidebook_sync_liquid_glass_rros")
        self.assertTrue(all(self.state()["overlays"]["10"][ov] for ov in GLASS))

    def test_absent_or_unknown_glass_preference_never_resets_overlays(self):
        for choice in ("", "unexpected"):
            with self.subTest(choice=choice):
                state = copy.deepcopy(self.initial)
                state["props"]["persist.fidebook.liquid_glass"] = choice
                state["overlays"]["10"][GLASS[1]] = False
                self.set_state(state)
                self.run_policy("fidebook_sync_liquid_glass_rros", success=(choice == ""))
                self.assertEqual(self.state()["overlays"], state["overlays"])
        self.assertEqual(self.overlay_writes(), [])

    def test_overlay_readiness_and_missing_targets_fail_before_writes(self):
        for change in ({"overlay_ready": False}, {"overlay_response": "Error: service not ready"}, {"overlay_response": "[x] " + GLASS[0]}):
            with self.subTest(change=change):
                state = copy.deepcopy(self.initial)
                state.update(change)
                state["props"]["persist.fidebook.liquid_glass"] = "0"
                self.set_state(state)
                self.run_policy("fidebook_sync_liquid_glass_rros", success=False)
        self.assertEqual(self.overlay_writes(), [])

    def test_property_read_failure_does_not_infer_preferences(self):
        for prop in ("persist.fidebook.liquid_glass", "ro.fidebook.software_rendering"):
            with self.subTest(prop=prop):
                self.update(get_fail_props=[prop])
                self.run_policy("fidebook_sync_liquid_glass_rros", success=False)
        self.assertEqual(self.overlay_writes(), [])
        self.update(get_fail_props=["persist.sys.fidebook.oobe_done"])
        self.run_policy("oobe_boot 1", success=False)
        self.assertFalse(any(c["command"] == "pm" or (c["command"] == "am" and c["args"][:1] == ["start"]) for c in self.commands()))
        self.assertFalse((self.work / "misc/first_boot").exists())

    def test_reboot_does_not_toggle_unchanged_overlays(self):
        self.run_policy("fidebook_sync_liquid_glass_rros; fidebook_sync_liquid_glass_rros")
        self.assertEqual(self.overlay_writes(), [])
        self.fx("LIQUID_GLASS=0\nLIQUID_GLASS_LEVEL=3\nMOTION_BLUR=off\n")
        self.run_policy("apply_live_fx")
        self.assertEqual(len(self.overlay_writes()), 3)
        self.optimizer()
        self.optimizer()
        self.assertEqual(len(self.overlay_writes()), 3)
        self.assertEqual(self.state()["props"]["persist.fidebook.liquid_glass"], "0")
        self.assertIn("LIQUID_GLASS=0\n", self.config.read_text())
        self.fx("LIQUID_GLASS=1\nMOTION_BLUR=ui\n")
        self.run_policy("apply_live_fx")
        self.optimizer()
        self.assertEqual(len(self.overlay_writes()), 6)
        self.assertEqual(self.state()["props"]["persist.fidebook.liquid_glass"], "1")

    def test_wallpaper_is_per_user_and_never_overwrites_existing_state(self):
        self.run_policy("fidebook_default_wallpaper")
        self.assertEqual((self.user_root / "10/wallpaper").read_bytes(), self.wallpaper.read_bytes())
        self.assertFalse((self.user_root / "0/wallpaper").exists())
        (self.user_root / "10/wallpaper").write_bytes(b"user choice")
        self.run_policy("fidebook_default_wallpaper")
        self.assertEqual((self.user_root / "10/wallpaper").read_bytes(), b"user choice")
        for user, evidence in (("11", "wallpaper_orig"), ("23", "wallpaper_info.xml"), ("42", "wallpaper_lock")):
            (self.user_root / user / evidence).write_bytes(b"keep")
            self.update(user=user)
            self.run_policy("fidebook_default_wallpaper")
            self.assertFalse((self.user_root / user / "wallpaper").exists())

    def test_visual_defaults_preserve_existing_values_even_on_software(self):
        for software in ("0", "1"):
            state = copy.deepcopy(self.initial)
            state["props"]["ro.fidebook.software_rendering"] = software
            self.set_state(state)
            self.run_policy("fidebook_optimize_visual_policy")
            self.assertEqual(self.state()["settings"], state["settings"])
            self.assertEqual(self.state()["props"]["persist.wm.debug.predictive_back_anim"], "0")

    def test_visual_defaults_seed_only_absent_settings(self):
        for software in ("0", "1"):
            state = copy.deepcopy(self.initial)
            state["props"]["ro.fidebook.software_rendering"] = software
            state["settings"]["global"] = {}
            self.set_state(state)
            self.run_policy("fidebook_optimize_visual_policy")
            settings = self.state()["settings"]["global"]
            self.assertEqual(settings["window_animation_scale"], "0" if software == "1" else "0.85")
            self.assertEqual(settings["disable_window_blurs"], software)
            self.assertEqual(settings["enable_freeform_support"], "1")

    def test_unready_settings_service_does_not_seed_defaults(self):
        self.update(settings_ready=False)
        self.run_policy("fidebook_optimize_visual_policy", success=False)
        self.assertEqual(self.state()["settings"], self.initial["settings"])

    def pm_writes(self):
        return [c["args"] for c in self.commands() if c["command"] == "pm" and c["args"][:1] in (["enable"], ["grant"], ["disable"], ["uninstall"], ["install"])]

    def test_optimizer_never_alters_unrelated_packages_or_memory_owner(self):
        self.optimizer()
        after = self.state()["packages"]
        for user, pkgs in self.initial["packages"].items():
            for pkg, value in pkgs.items():
                legacy = (user == "0" and pkg in ("com.google.android.apps.messaging", "com.google.android.aicore", "com.google.android.apps.bard", "com.google.android.googlequicksearchbox", "com.android.vending", "com.google.android.marvin.talkback")) or \
                         (user == "10" and pkg in ("com.android.eyedropper", "com.google.android.federatedcompute"))
                with self.subTest(user=user, pkg=pkg):
                    self.assertEqual(after[user][pkg], "enabled" if legacy else value)
        self.assertEqual(self.state()["props"]["persist.sys.max_cached_processes"], "32")
        self.assertFalse(any(c["command"] in ("swapoff", "swapon", "sysctl") or (c["command"] == "am" and c["args"] != ["get-current-user"]) for c in self.commands()))
        # Only `pm enable` (legacy restore) and the one streaming grant are allowed.
        for args in self.pm_writes():
            self.assertIn(args[0], ("enable", "grant"), args)
        # Guard against reintroducing bypasses in unexecuted absolute-path code.
        for script in ("optimize.sh", "oobe_apply.sh", "boot_policy.sh"):
            code = "\n".join(line for line in (ROOT / "usb" / script).read_text().splitlines() if not line.lstrip().startswith("#"))
            self.assertNotRegex(code, r"\b(?:swapoff|swapon|mkswap)\b|/sys/block/zram|rm\s+-[a-z]*r|\bforce-stop\b|disable-user|pm\s+uninstall\b|--user\s+10\b")

    def test_legacy_restore_only_touches_optimizer_disable_user_state(self):
        self.run_policy("fidebook_restore_legacy_disabled")
        after = self.state()
        self.assertEqual(after["packages"]["0"]["com.google.android.apps.messaging"], "enabled")
        self.assertEqual(after["packages"]["0"]["com.google.android.aicore"], "enabled")
        self.assertEqual(after["packages"]["0"]["com.android.chrome"], "disabled")
        self.assertEqual(after["packages"]["0"]["com.google.android.youtube"], "default")
        self.assertEqual(after["packages"]["10"]["com.android.eyedropper"], "enabled")
        # Not on the legacy list: never touched, even though disable-user'd.
        self.assertEqual(after["packages"]["11"]["com.google.android.marvin.talkback"], "disabled-user")
        self.assertEqual(after["props"]["persist.fidebook.legacy_restore"], "1")
        self.assertEqual(after["grants"], [["10", "com.google.ambient.streaming", "android.permission.ACCESS_LOCAL_NETWORK"]])

    def test_legacy_restore_runs_once_and_respects_later_user_choice(self):
        self.run_policy("fidebook_restore_legacy_disabled")
        state = self.state()
        state["packages"]["0"]["com.google.android.apps.messaging"] = "disabled-user"  # user disables it later
        self.set_state(state)
        before = len(self.pm_writes())
        self.run_policy("fidebook_restore_legacy_disabled")
        self.assertEqual(len(self.pm_writes()), before)
        self.assertEqual(self.state()["packages"]["0"]["com.google.android.apps.messaging"], "disabled-user")

    def test_legacy_restore_retries_after_failure_and_needs_ui_user(self):
        self.update(enable_fail=["com.google.android.aicore"])
        self.run_policy("fidebook_restore_legacy_disabled", success=False)
        self.assertNotIn("persist.fidebook.legacy_restore", self.state()["props"])
        self.update(enable_fail=[])
        self.run_policy("fidebook_restore_legacy_disabled")
        self.assertEqual(self.state()["packages"]["0"]["com.google.android.aicore"], "enabled")
        self.assertEqual(self.state()["props"]["persist.fidebook.legacy_restore"], "1")
        state = copy.deepcopy(self.initial)
        state["user"] = "0"  # headless system user is not a UI target: do nothing
        self.set_state(state)
        self.run_policy("fidebook_restore_legacy_disabled", success=False)
        self.assertEqual(self.state()["packages"], self.initial["packages"])

    def test_streaming_grant_failure_does_not_block_migration(self):
        self.update(grant_fail=True)
        self.run_policy("fidebook_restore_legacy_disabled")
        self.assertEqual(self.state()["props"]["persist.fidebook.legacy_restore"], "1")

    def test_network_metering_data_saver_and_update_preferences_untouched(self):
        for metered in (True, False):
            for data_saver in (True, False):
                with self.subTest(metered=metered, data_saver=data_saver):
                    state = copy.deepcopy(self.initial)
                    state["network"].update(metered=metered, data_saver=data_saver)
                    self.set_state(state)
                    self.optimizer()
                    self.run_policy("oobe_boot 0")
                    self.fx("LIQUID_GLASS=0\nMOTION_BLUR=off\n")
                    self.run_policy("apply_live_fx")
                    after = self.state()
                    self.assertEqual(after["network"], state["network"])
                    for key in ("restrict_background_data", "auto_system_update", "ota_disable_automatic_update"):
                        self.assertEqual(after["settings"]["global"][key], state["settings"]["global"][key])
                    self.assertFalse(any("netpolicy" in c["args"] for c in self.commands()))

    def test_live_fx_retains_trigger_until_user_and_overlay_services_ready(self):
        self.fx("LIQUID_GLASS=0\nLIQUID_GLASS_LEVEL=3\nMOTION_BLUR=off\n")
        before_cfg = self.config.read_text()
        for change in ({"user_ready": False}, {"activity_ready": False}, {"user": "0"}, {"overlay_ready": False}):
            with self.subTest(change=change):
                state = copy.deepcopy(self.initial)
                state.update(change)
                self.set_state(state)
                self.run_policy("apply_live_fx", success=False)
                self.assertEqual(self.state(), state)
                self.assertEqual(self.config.read_text(), before_cfg)
                self.assertTrue((self.oobe / "fx.trigger").exists())
        self.set_state(copy.deepcopy(self.initial))
        self.run_policy("apply_live_fx")
        self.assertFalse((self.oobe / "fx.trigger").exists())
        self.assertEqual(self.state()["props"]["persist.fidebook.liquid_glass_level"], "3")
        self.assertEqual(self.state()["props"]["persist.fidebook.motion_blur"], "off")

    def test_live_fx_write_failure_is_retryable(self):
        self.update(overlay_write_fail=True)
        self.fx("LIQUID_GLASS=0\n")
        self.run_policy("apply_live_fx", success=False)
        self.assertTrue((self.oobe / "fx.trigger").exists())
        self.assertEqual(self.state()["props"]["persist.fidebook.liquid_glass"], "1")
        self.update(overlay_write_fail=False)
        self.run_policy("apply_live_fx")
        self.assertFalse((self.oobe / "fx.trigger").exists())

    def test_invalid_fx_fields_are_not_partially_accepted_or_executed(self):
        self.fx("LIQUID_GLASS=1bad\nLIQUID_GLASS_LEVEL=3bad\nMOTION_BLUR=all; echo bad\n")
        self.run_policy("apply_live_fx")
        self.assertEqual(self.state(), self.initial)
        self.assertEqual(self.overlay_writes(), [])

    def test_oobe_boot_installs_and_starts_only_resolved_user(self):
        for headless, user in (("true", "10"), ("true", "23"), ("false", "0"), ("false", "11")):
            with self.subTest(headless=headless, user=user):
                self.update(headless=headless, user=user)
                self.run_policy("oobe_boot 1")
                self.assertEqual(self.state()["installed_for"][-1], user)
                self.assertEqual(self.state()["settings"]["secure:" + user]["user_setup_complete"], "1")
        self.assertTrue(any(c["command"] == "am" and "org.fidebookos.setup/.SetupActivity" in c["args"] for c in self.commands()))

    def test_oobe_boot_and_apply_fail_closed_without_current_ui(self):
        self.update(activity_ready=False)
        self.setup_choices('DEVICE_NAME="Keep"\nLIQUID_GLASS=0\nCOMPLETE=1\n')
        self.run_policy("oobe_boot 1", success=False)
        self.run_policy("apply_once", success=False)
        self.assertTrue((self.oobe / "apply.trigger").exists())
        self.assertFalse((self.work / "misc/done").exists())
        self.assertEqual(self.state()["props"], self.initial["props"])
        self.assertFalse(any(c["command"] in ("pm", "setprop", "settings") for c in self.commands()))

    def test_oobe_install_signature_failure_never_uninstalls_existing_data(self):
        self.update(install_fail=True)
        self.run_policy("oobe_boot 1", success=False)
        self.assertEqual(self.state()["packages"], self.initial["packages"])
        self.assertFalse(any(c["command"] == "am" and c["args"][:1] == ["start"] for c in self.commands()))
        self.assertFalse((self.work / "misc/first_boot").exists())
        self.assertTrue(self.apk.exists())
        self.update(install_fail=False)
        self.run_policy("oobe_boot 1")
        self.assertEqual(self.state()["installed_for"], ["10"])

    def test_setup_completion_and_reboot_preserve_first_boot_lifecycle(self):
        self.update(user="23")
        self.setup_choices('DEVICE_NAME="My FideBook"\nLIQUID_GLASS=0\nMOTION_BLUR=off\nDARK_MODE=yes\nDENSITY=180\nTOUCHPAD_FLICK=0\nCOMPLETE=1\n')
        self.run_policy("apply_once")
        self.assertFalse((self.oobe / "apply.trigger").exists())
        for stamp in ("done", "misc/done", "misc/first_boot"):
            self.assertTrue((self.work / stamp).exists())
        state = self.state()
        self.assertEqual(state["settings"]["secure:23"]["bluetooth_name"], "My FideBook")
        self.assertNotIn("secure:0", state["settings"])
        self.assertEqual(state["packages"]["23"]["org.fidebookos.setup/.SetupActivity"], "disabled")
        self.assertEqual(state["packages"]["0"], self.initial["packages"]["0"])
        self.assertEqual(state["density"], {"23": "180"})
        self.assertIn('DEVICE_MODEL="My FideBook"\n', self.config.read_text())
        self.assertIn("OOBE_SETUP=0\n", self.config.read_text())
        self.run_policy("oobe_boot 1")
        self.assertFalse(any(c["command"] == "am" and c["args"][:1] == ["start"] for c in self.commands()))
        self.assertFalse(any(c["command"] == "pm" and c["args"][:1] == ["install"] for c in self.commands()))

    def test_started_stamp_requires_live_setup_and_ready_user(self):
        (self.oobe / "started.flag").touch()
        self.run_policy("apply_once", success=False)
        self.assertFalse((self.work / "misc/first_boot").exists())
        self.assertTrue((self.oobe / "started.flag").exists())
        self.update(setup_alive=True, user_ready=False)
        self.run_policy("apply_once", success=False)
        self.assertFalse((self.work / "misc/first_boot").exists())
        self.update(user_ready=True)
        self.run_policy("apply_once", success=False)  # no apply trigger, but start stamp is now valid
        self.assertTrue((self.work / "misc/first_boot").exists())
        self.assertFalse((self.oobe / "started.flag").exists())

    def test_partial_setup_choices_do_not_reset_device_name(self):
        state = self.state()
        state["settings"]["global"]["device_name"] = "User choice"
        self.set_state(state)
        self.setup_choices("MOTION_BLUR=off\nDENSITY=180bad\nCOMPLETE=1bad\n")
        self.run_policy("apply_once")
        self.assertEqual(self.state()["settings"]["global"]["device_name"], "User choice")
        self.assertNotIn("density", self.state())
        self.assertFalse((self.work / "misc/done").exists())


if __name__ == "__main__":
    print("Shell under test: " + shlex.join(SHELL), flush=True)
    result = unittest.main(verbosity=2, exit=False).result
    if result.wasSuccessful():
        print("BOOT_POLICY_TEST_PASS", flush=True)
    sys.exit(0 if result.wasSuccessful() else 1)
