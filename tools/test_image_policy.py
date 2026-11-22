#!/usr/bin/env python3
"""Offline image/installer policy regression tests. No root, downloads or devices.

Uses tiny source fixtures and command mocks for complete image-builder runs, plus
one real sparse ext4 regular-file test using the production formatting function.
Never execute either physical-disk installer as a whole in this suite.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "tools/make_fidebookos_image.sh"
HOST_INSTALL = ROOT / "tools/install_dualboot.sh"
USB_INSTALL = ROOT / "usb/install.sh"


def shell_var(text, name):
    match = re.search(r'^' + re.escape(name) + r'="([^"]*)"', text, re.M)
    if not match:
        raise AssertionError(f"missing {name} declaration")
    return match[1].replace("\\\n", " ").split()


def shell_function(text, name):
    start = text.index(f"{name}() {{\n")
    return text[start:text.index("\n}\n", start) + 3]


MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
cmd, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
record = {"cmd": cmd, "args": args}
if cmd == "mcopy":
    record["files"] = []
    for arg in args:
        p = pathlib.Path(arg)
        if p.is_dir():
            record["files"].extend(str(f) for f in sorted(p.rglob("*")) if f.is_file())
        elif p.is_file(): record["files"].append(str(p))
if cmd == "sfdisk": record["stdin"] = sys.stdin.read()
with open(os.environ["MOCK_LOG"], "a") as f: f.write(json.dumps(record) + "\n")
# Refuse any accidental device path even if a production policy regresses.
for arg in args:
    value = arg.split("=", 1)[-1] if arg.startswith(("if=", "of=")) else arg
    if value.startswith(("/dev/", "/proc/", "/sys/")):
        sys.exit("mock refuses all device/kernel-tree paths")
if os.environ.get("MOCK_FAIL") == cmd: sys.exit(9)
if cmd == "truncate":
    # Deliberately tiny regular files, never the multi-GiB production sizes.
    with open(args[-1], "wb") as f: f.truncate(8192)
elif cmd == "mkfs.fat":
    with open(args[-1], "r+b") as f: f.write(b"fixture FAT\n")
elif cmd == "dd":
    src = next(a[3:] for a in args if a.startswith("if="))
    dst = next(a[3:] for a in args if a.startswith("of="))
    with open(dst, "ab") as f: f.write(pathlib.Path(src).name.encode() + b"\n")
elif cmd == "dumpe2fs":
    print("Filesystem features: extent 64bit" + ("" if os.environ.get("MOCK_NO_VERITY") else " verity"))
elif cmd == "mdir":
    print("fixture directory verified")
    if os.environ.get("MOCK_RACE_DEST"):
        pathlib.Path(os.environ["MOCK_RACE_DEST"]).write_text("racing writer\n")
elif cmd == "lsblk":
    print("FIXTURE-SERIAL" if "SERIAL" in args else os.environ.get("MOCK_LSBLK", ""))
'''


class ImagePolicy(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ.get("TMPDIR", "/tmp/opencode"))
        if not base.is_dir():
            base = Path(tempfile.gettempdir())
        self.tmp = tempfile.TemporaryDirectory(prefix="image-policy-", dir=base)
        self.addCleanup(self.tmp.cleanup)
        self.w = Path(self.tmp.name)
        self.repo = self.w / "source fixture"
        self.bin = self.w / "bin"
        self.bin.mkdir()
        (self.repo / "tools").mkdir(parents=True)
        self.script = self.repo / "tools/make_fidebookos_image.sh"
        shutil.copyfile(IMAGE, self.script)
        text = IMAGE.read_text()
        self.files = shell_var(text, "FILES")
        self.dirs = shell_var(text, "DIRS")
        required = self.files + shell_var(text, "PAYLOAD_FILES") + [
            "out/BOOTX64.EFI", "modules/lib/modules/test/modules.dep",
            "firmware/fixture.bin", "kmod/fixture.ko", "patched/system.libz.so",
        ]
        for rel in required:
            self.put("usb/" + rel, rel + "\n")
        self.put("usb/fidebook.cfg", "# fixture\nMODE=install\nOOBE_SETUP=1\n")
        self.put("usb/patched/MANIFEST", "early /new/system/lib64/libz.so " + "0"*64 + " patched/system.libz.so\n")
        self.put("build/super.img", "fixture system image\n")
        self.put("build/super.layout", "fixture layout\n")
        self.put("kernel/out/busybox", "fixture busybox\n")
        for cmd in ("mkfs.fat", "mcopy", "mdir", "sfdisk", "truncate", "dd", "mke2fs", "dumpe2fs", "lsblk"):
            p = self.bin / cmd
            p.write_text(MOCK)
            p.chmod(0o755)
        self.log = self.w / "commands.jsonl"
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"],
                        MOCK_LOG=str(self.log), SOURCE_DATE_EPOCH="1795086000")
        for key in ("MOCK_FAIL", "MOCK_NO_VERITY", "MOCK_RACE_DEST"):
            self.env.pop(key, None)
        self.out = self.w / "output" / "fixture.img"

    def put(self, rel, content):
        p = self.repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        return p

    def run_image(self, *args, ok=True, output=True, env=None):
        command = ["sh", str(self.script)]
        if output:
            command += ["--output", str(self.out)]
        command += list(args)
        result = subprocess.run(command, cwd=self.repo, env=env or self.env,
                                text=True, capture_output=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def no_work(self):
        self.assertEqual(self.commands(), [])
        self.assertFalse(self.out.exists())
        self.assertEqual(list(self.w.rglob("*.build.*")), [])

    def test_reject_bad_arguments_before_writes(self):
        cases = [
            ["--type=typo"], ["--bogus"], ["--type"], ["--output"], ["-o"],
            ["--name"], ["--data-size"], ["--output="], ["--name="],
            ["--type", "standard", "--data-size", "2"],
            ["--type", "looper", "--data-size", "0"],
            ["--type", "looper", "--data-size", "-2"],
            ["--type", "looper", "--data-size", "2.5"],
            ["--type", "looper", "--data-size", "99999999999999999999999"],
            ["--type", "looper", "--data-size", "16385"],
            ["--name", "../escape"], ["--name", ".img"], ["--name", "bad/name"],
            ["--output", "not-an-image"], ["one-dir", "second-dir"],
            ["--output", "one.img", "--name", "two"],
        ]
        for args in cases:
            with self.subTest(args=args):
                self.run_image(*args, ok=False, output=False)
                self.no_work()

    def test_preflight_is_read_only_and_does_not_need_root(self):
        self.run_image("--check")
        self.no_work()
        self.assertFalse(self.out.parent.exists())
        self.assertNotRegex(IMAGE.read_text(), r"(?m)^\s*(sudo|mount|losetup)\s")

    def test_system_trees_and_alias_are_forbidden_even_force(self):
        alias = self.w / "device-alias"
        alias.symlink_to("/dev", target_is_directory=True)
        for dest in ("/dev/fidebook-test.img", "/proc/fidebook-test.img", "/sys/fidebook-test.img", str(alias / "test.img")):
            with self.subTest(dest=dest):
                self.run_image("--output", dest, "--force", ok=False, output=False)
                self.no_work()

    def test_never_replace_source_payload(self):
        for rel in ("usb/new.img", "lapis/parts/new.img", "kernel/out/new.img", "build/super.img", "dist/super.img"):
            with self.subTest(rel=rel):
                self.run_image("--output", str(self.repo / rel), "--force", ok=False, output=False)
        self.assertEqual((self.repo / "build/super.img").read_text(), "fixture system image\n")
        self.no_work()

    def test_symlink_special_and_hardlink_outputs_rejected(self):
        self.out.parent.mkdir()
        sentinel = self.w / "sentinel"
        sentinel.write_text("unchanged")
        for kind in ("symlink", "dangling", "hardlink", "fifo", "directory"):
            with self.subTest(kind=kind):
                if kind == "symlink": self.out.symlink_to(sentinel)
                elif kind == "dangling": self.out.symlink_to(self.w / "missing")
                elif kind == "hardlink": os.link(sentinel, self.out)
                elif kind == "fifo": os.mkfifo(self.out)
                else: self.out.mkdir()
                self.run_image("--force", ok=False)
                if self.out.is_dir(): self.out.rmdir()
                else: self.out.unlink()
                self.assertEqual(sentinel.read_text(), "unchanged")
                self.no_work()

    def test_existing_outputs_and_sidecars_protected(self):
        self.out.parent.mkdir()
        for suffix in ("", ".sha256", ".manifest"):
            p = Path(str(self.out) + suffix)
            p.write_text("keep me")
            self.run_image(ok=False)
            self.assertEqual(p.read_text(), "keep me")
            p.unlink()
            self.no_work()

    def test_missing_startup_payload_is_fatal(self):
        for rel in ("optimize.sh", "oobe_apply.sh", "hook.sh", "installer/bin/fidebook-gui",
                    "branding/app/FideBookSetup.apk", "patched/system.libz.so", "firmware/fixture.bin"):
            with self.subTest(rel=rel):
                p = self.repo / "usb" / rel
                data = p.read_bytes()
                p.unlink()
                self.run_image("--check", ok=False)
                p.write_bytes(data)
                self.no_work()

    def test_missing_referenced_platform_helper_is_fatal(self):
        for helper in ("user_context.sh", "boot_policy.sh"):
            with self.subTest(helper=helper):
                self.put("usb/optimize.sh", f". /postinstall/fidebook/{helper}\n")
                self.run_image("--check", ok=False)
                self.no_work()
                self.put("usb/" + helper, "# offline helper fixture\n")
                self.run_image("--check")
                self.no_work()

    def test_success_publishes_hashes_and_complete_payload(self):
        self.put("usb/user_context.sh", "# platform helper fixture\n")
        self.put("usb/boot_policy.sh", "# boot policy fixture\n")
        old_stage = self.out.parent / "fixture.stage"
        old_parts = self.out.parent / "fixture.parts"
        old_stage.mkdir(parents=True)
        old_parts.mkdir()
        (old_stage / "user-file").write_text("keep stage")
        (old_parts / "user-file").write_text("keep parts")
        self.run_image()
        self.assertEqual((old_stage / "user-file").read_text(), "keep stage")
        self.assertEqual((old_parts / "user-file").read_text(), "keep parts")
        sha = Path(str(self.out) + ".sha256").read_text()
        self.assertEqual(sha, hashlib.sha256(self.out.read_bytes()).hexdigest() + "  fixture.img\n")
        manifest = Path(str(self.out) + ".manifest").read_text()
        self.assertNotIn(str(self.repo), manifest)
        for rel in self.files + ["user_context.sh", "boot_policy.sh"]:
            self.assertIn("  fidebook/fidebook/" + rel + "\n", manifest)
        cfg = next(line.split("  ", 1)[0] for line in manifest.splitlines() if line.endswith("  fidebook/fidebook/fidebook.cfg"))
        expected_cfg = "# fixture\nOOBE_SETUP=1\n\nMODE=ask\n"
        self.assertEqual(cfg, hashlib.sha256(expected_cfg.encode()).hexdigest())
        self.assertIn("MODE=install", (self.repo / "usb/fidebook.cfg").read_text())
        self.assertEqual(list(self.out.parent.glob(".*.build.*")), [])
        self.assertFalse({c["cmd"] for c in self.commands()} & {"sudo", "mount", "losetup"})

    def test_force_failure_keeps_old_image_and_cleans_workspace(self):
        self.out.parent.mkdir()
        self.out.write_text("old image")
        Path(str(self.out) + ".sha256").write_text("old checksum")
        env = dict(self.env, MOCK_FAIL="mcopy")
        self.run_image("--force", ok=False, env=env)
        self.assertEqual(self.out.read_text(), "old image")
        self.assertEqual(Path(str(self.out) + ".sha256").read_text(), "old checksum")
        self.assertEqual(list(self.out.parent.glob(".*.build.*")), [])
        self.run_image("--force")
        self.assertNotEqual(self.out.read_text(), "old image")

    def test_destination_race_does_not_clobber(self):
        self.run_image(ok=False, env=dict(self.env, MOCK_RACE_DEST=str(self.out)))
        self.assertEqual(self.out.read_text(), "racing writer\n")
        self.assertFalse(Path(str(self.out) + ".sha256").exists())
        self.assertEqual(list(self.out.parent.glob(".*.build.*")), [])

    def test_looper_formats_data_with_verity_and_no_discard(self):
        self.run_image("--type", "looper", "--data-size", "0002")
        formats = [c for c in self.commands() if c["cmd"] == "mke2fs"]
        self.assertEqual(len(formats), 2)
        data = next(c["args"] for c in formats if "FIDE_DATA" in c["args"])
        self.assertEqual(data[data.index("-O") + 1], "verity")
        self.assertIn("nodiscard", data[data.index("-E") + 1].split(","))
        self.assertIn("root_owner=0:0", data[data.index("-E") + 1].split(","))
        self.assertIn("-U", data)
        self.assertIn("data_gib=2;", Path(str(self.out) + ".manifest").read_text())
        table = next(c["stdin"] for c in self.commands() if c["cmd"] == "sfdisk")
        self.assertIn('name="FIDE_DATA"', table)
        self.assertIn("size=4194304", table)  # 2 GiB / 512-byte sectors

    def test_missing_verity_feature_aborts_publication(self):
        self.run_image("--type", "looper", "--data-size", "1", ok=False,
                       env=dict(self.env, MOCK_NO_VERITY="1"))
        self.assertFalse(self.out.exists())
        self.assertEqual(list(self.out.parent.glob(".*.build.*")), [])

    def test_fixed_input_manifest_and_partition_ids_are_repeatable(self):
        self.run_image()
        first_manifest = Path(str(self.out) + ".manifest").read_text()
        first_table = next(c["stdin"] for c in self.commands() if c["cmd"] == "sfdisk")
        self.log.unlink()
        self.run_image("--force")
        self.assertEqual(first_manifest, Path(str(self.out) + ".manifest").read_text())
        self.assertEqual(first_table, next(c["stdin"] for c in self.commands() if c["cmd"] == "sfdisk"))

    def test_usb_payload_preflight_only_with_regular_source_fixtures(self):
        text = USB_INSTALL.read_text()
        declarations = text[text.index('FILES="'):text.index('validate_payload() {')]
        validator = shell_function(text, "validate_payload").replace(
            "/fidebook/busybox", shlex.quote(str(self.repo / "kernel/out/busybox")))
        for rel in ("super.img", "super.layout"):
            self.put("usb/" + rel, "fixture " + rel + "\n")
        prefix = ('die() { echo "$*" >&2; exit 73; }; tool() { return 0; };\n' +
                  'G=' + shlex.quote(str(self.repo / "usb")) + '\n')
        command = ["sh", "-c", prefix + declarations + validator + "\nvalidate_payload\n"]
        r = subprocess.run(command, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for rel in ("optimize.sh", "oobe_apply.sh", "branding/bootanimation.zip", "patched/system.libz.so"):
            with self.subTest(rel=rel):
                p = self.repo / "usb" / rel
                data = p.read_bytes()
                p.unlink()
                r = subprocess.run(command, env=self.env, capture_output=True, text=True, timeout=10)
                self.assertEqual(r.returncode, 73, r.stdout + r.stderr)
                p.write_bytes(data)
        self.no_work()

    def test_host_cleanup_does_not_delete_a_still_mounted_workspace(self):
        workspace = self.w / "mounted-workspace"
        mountdir = workspace / "system"
        mountdir.mkdir(parents=True)
        marker = mountdir / "existing-os-file"
        marker.write_text("preserve")
        fn = shell_function(HOST_INSTALL.read_text(), "cleanup")
        prefix = ('mountpoint() { return 0; }; umount() { return 1; };\n' +
                  'WORK=' + shlex.quote(str(workspace)) + '\nMNT_EFI=\nMNT_SYS=' +
                  shlex.quote(str(mountdir)) + '\n')
        subprocess.run(["sh", "-c", prefix + fn + "\ncleanup\n"],
                       capture_output=True, text=True, check=True, timeout=5)
        self.assertEqual(marker.read_text(), "preserve")
        self.no_work()

    def test_host_installer_rejects_invalid_values_without_devices(self):
        for args in (["--target"], ["--efi-part"], ["--sys-size"], ["--data-size", "bogus"],
                     ["--data-size", "0"], ["--meta-size", "1M"], ["--sys-size", "1.5G"]):
            with self.subTest(args=args):
                r = subprocess.run(["sh", str(HOST_INSTALL), *args], env=self.env,
                                   capture_output=True, text=True, timeout=10)
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(self.commands(), [])

    def test_host_partition_lookup_handles_unformatted_gpt_names(self):
        fn = shell_function(HOST_INSTALL.read_text(), "find_named_part")
        env = dict(self.env, MOCK_LSBLK="/fixture/diskp4 FIDESYS\n/fixture/diskp5 FIDE_DATA")
        r = subprocess.run(["sh", "-c", fn + '\nTARGET_DISK=/fixture/disk\nfind_named_part FIDESYS'],
                           env=env, capture_output=True, text=True, check=True)
        self.assertEqual(r.stdout, "/fixture/diskp4\n")

    def test_host_reformat_also_requires_the_exact_serial(self):
        text = HOST_INSTALL.read_text()
        start = text.index('say "Disk $TARGET_DISK:"')
        end = text.index('\nWORK=$(mktemp', start)
        block = text[start:end]
        prefix = ('die() { echo "$*" >&2; exit 73; }; say() { :; }; '
                  'TARGET_DISK=/fixture/disk; SYS_PART=/fixture/sys; META_PART=/fixture/meta; '
                  'DATA_PART=/fixture/data; EFI_PART=/fixture/efi; ALREADY_PARTITIONED=1; REFORMAT=1;\n')
        for serial, expected in (("wrong", 73), ("FIXTURE-SERIAL", 0)):
            r = subprocess.run(["sh", "-c", prefix + block], input=serial + "\n", env=self.env,
                               capture_output=True, text=True, timeout=10)
            self.assertEqual(r.returncode, expected, r.stdout + r.stderr)


class InstallerSourcePolicy(unittest.TestCase):
    def test_required_payload_lists_do_not_drift(self):
        expected = set(shell_var(IMAGE.read_text(), "PAYLOAD_FILES"))
        core = set(shell_var(IMAGE.read_text(), "FILES")) - {"fidebook.cfg"}
        for path in (HOST_INSTALL, USB_INSTALL):
            self.assertEqual(expected, set(shell_var(path.read_text(), "PAYLOAD_FILES")), path)
            self.assertEqual(core, set(shell_var(path.read_text(), "FILES")) -
                             {"fidebook.cfg", "super.img", "super.layout"}, path)
            self.assertEqual(set(shell_var(IMAGE.read_text(), "DIRS")),
                             set(shell_var(path.read_text(), "DIRS")), path)

    def test_required_startup_files_shipped_in_all_paths(self):
        for path in (IMAGE, HOST_INSTALL, USB_INSTALL):
            with self.subTest(path=path.name):
                files = shell_var(path.read_text(), "FILES")
                for f in ("hook.sh", "optimize.sh", "oobe_apply.sh", "install.sh", "hwdetect.sh", "native_zygote.sh"):
                    self.assertIn(f, files)
                self.assertIn("user_context.sh", path.read_text())
                self.assertIn("boot_policy.sh", path.read_text())

    def test_direct_init_script_dependencies_are_required_payload(self):
        hook = (ROOT / "usb/hook.sh").read_text()
        dependencies = set(re.findall(
            r'^service [^\n]*? /system/bin/sh /postinstall/fidebook/([A-Za-z0-9_./-]+\.sh)',
            hook, re.M))
        self.assertTrue(dependencies)
        for path in (IMAGE, HOST_INSTALL, USB_INSTALL):
            shipped = set(shell_var(path.read_text(), "FILES")) | set(shell_var(path.read_text(), "PAYLOAD_FILES"))
            self.assertFalse(dependencies - shipped, f"{path}: missing {dependencies - shipped}")

    def test_every_new_data_format_requests_verity(self):
        for path in (HOST_INSTALL, USB_INSTALL):
            formats = [line for line in path.read_text().splitlines()
                       if re.search(r'\b(mke2fs|mkfs\.ext4)\b', line) and "-L FIDE_DATA" in line]
            self.assertTrue(formats, path)
            for line in formats:
                self.assertIn("-O verity", line, path)

    def test_installer_cancellation_cannot_fall_through(self):
        fn = shell_function(USB_INSTALL.read_text(), "halt_here")
        prefix = ('gui_progress_stop() { :; }; say() { :; }; ask() { :; }; '
                  'sync() { :; }; reboot() { return 1; }; USE_GUI=0;\n')
        r = subprocess.run(["sh", "-c", prefix + fn + '\nhalt_here cancelled\necho UNSAFE'],
                           capture_output=True, text=True, timeout=5)
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("UNSAFE", r.stdout)

    def test_usb_clean_and_dualboot_confirmation_blocks(self):
        text = USB_INSTALL.read_text()
        clean_start = text.index('if [ "$INSTALL_MODE" = clean ]; then\n') + len('if [ "$INSTALL_MODE" = clean ]; then\n')
        clean = text[clean_start:text.index('  gui_progress_start "Partitioning', clean_start)]
        dual_start = text.index('  if [ -n "$CONFIRM_CMDLINE" ]; then\n    REPLY=$CONFIRM_CMDLINE\n')
        dual = text[dual_start:text.index('  gui_progress_start "Creating Dual-Boot', dual_start)]
        prefix = ('halt_here() { exit 73; }; say() { :; }; ask() { REPLY=wrong; }; '
                  'T=fixture; TD=/fixture/disk; STICKDISK=installer; USE_GUI=0; '
                  'SERIAL=FIXTURE-SERIAL; free_mb=18000;\n')
        for block in (clean, dual):
            for serial, expected in (("wrong", 73), ("FIXTURE-SERIAL", 0)):
                r = subprocess.run(["sh", "-c", prefix + f'CONFIRM_CMDLINE={serial};\n' + block],
                                   capture_output=True, text=True, timeout=5)
                self.assertEqual(r.returncode, expected, r.stdout + r.stderr)

    def test_no_implicit_installer_disk_or_global_efi_fallback(self):
        text = USB_INSTALL.read_text()
        disks = shell_function(text, "internal_disks")
        self.assertNotIn('_all="$STICKDISK"', disks)
        self.assertNotIn("findfs", shell_function(text, "internal_efi"))
        dual = text[text.index('  say "Dual-boot on $TD'):text.index('  mkdir -p /mnt/nefi', text.index('  say "Dual-boot on $TD'))]
        self.assertNotIn("findfs LABEL=EFI", dual)


class RealExt4Policy(unittest.TestCase):
    @unittest.skipUnless(all(shutil.which(x) for x in ("mke2fs", "dumpe2fs", "e2fsck", "truncate")),
                         "host e2fsprogs needed for real sparse ext4 regular-file test")
    def test_production_formatter_creates_sparse_verity_ext4(self):
        base = "/tmp/opencode" if Path("/tmp/opencode").is_dir() else None
        with tempfile.TemporaryDirectory(prefix="image-ext4-", dir=base) as td:
            image = Path(td) / "data.ext4"
            fn = shell_function(IMAGE.read_text(), "make_ext4_image")
            script = ('set -eu\nexport LC_ALL=C\ndie() { echo "$*" >&2; exit 1; }\n' + fn +
                      '\nmake_ext4_image "$1" FIDE_DATA 64 verity 01234567-89ab-4cde-8fab-0123456789ab\n')
            env = dict(os.environ, E2FSPROGS_FAKE_TIME="1795086000")
            env["PATH"] += ":/usr/sbin:/sbin"
            subprocess.run(["sh", "-s", "--", str(image)], input=script, text=True,
                           env=env, capture_output=True, check=True, timeout=30)
            header = subprocess.run(["dumpe2fs", "-h", str(image)], text=True, capture_output=True,
                                    env=env, check=True, timeout=10).stdout
            self.assertRegex(header, r"Filesystem features:.*\bverity\b")
            self.assertIn("FIDE_DATA", header)
            self.assertEqual(image.stat().st_size, 64 * 1024 * 1024)
            self.assertLess(image.stat().st_blocks * 512, image.stat().st_size // 2)
            subprocess.run(["e2fsck", "-fn", str(image)], env=env, check=True,
                           capture_output=True, timeout=30)
            # The helper itself refuses overwriting even another ordinary image.
            again = subprocess.run(["sh", "-s", "--", str(image)], input=script, text=True,
                                   env=env, capture_output=True, timeout=10)
            self.assertNotEqual(again.returncode, 0)
            repeat = Path(td) / "repeat.ext4"
            subprocess.run(["sh", "-s", "--", str(repeat)], input=script, text=True,
                           env=env, capture_output=True, check=True, timeout=30)
            self.assertEqual(hashlib.sha256(image.read_bytes()).digest(),
                             hashlib.sha256(repeat.read_bytes()).digest())


if __name__ == "__main__":
    unittest.main(verbosity=2)
