"""Exercise the fork updater offline, using only a temporary installation.

The install/rollback cases run on macOS because production deliberately retains
upstream's BSD sed/stat behavior. All platforms exercise downloads, archive
validation, config-only comparisons and both read-only command aliases.
"""
import hashlib
import os
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"
UPDATE_URL = "https://codeload.github.com/anyun-hy/claude-switcher/zip/refs/heads/main"
LOCAL_CONFIG = {
    "PROXY_MODE": "tag",
    "PROXY_GROUP": "My local group",
    "COUNTRY_TARGET": "CA",
    "TZ_TARGET": "America/Toronto",
    "LOCALE_TARGET": "en_CA",
}
CHECK_COMMANDS = (("update-check",), ("update", "--check"))


class ForkUpdateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fork-update-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home"
        self.bin = self.root / "commands"
        self.tmp = self.root / "downloads"
        self.appdir = self.root / "system-appdir"
        for directory in (self.home, self.bin, self.tmp, self.appdir):
            directory.mkdir()
        self.core = self.home / ".local/bin/claude-switch.sh"
        self.core.parent.mkdir(parents=True)
        self.backup = self.core.with_name("claude-switch.sh.bak")
        self.base = self.home / ".claude-switcher"
        (self.base / "accounts").mkdir(parents=True)
        (self.base / "checks.json").write_text('{"logging": false}\n', encoding="utf-8")
        self.stun = self.base / "stun-probe.py"
        self.stun_source = (ROOT / "core/stun-probe.py").read_bytes()
        self.stun.write_bytes(self.stun_source)
        self.original = SOURCE.read_text(encoding="utf-8").replace(
            'APPDIR="/Library/Application Support/claude-switcher"',
            'APPDIR="' + str(self.appdir) + '"')
        self.core.write_text(self.configured(self.original, LOCAL_CONFIG), encoding="utf-8")
        self.core.chmod(0o700)
        self.archive = self.root / "remote.zip"
        self.curl_log = self.root / "curl.log"
        self.forbidden_log = self.root / "forbidden.log"
        self.app_target = self.root / "Applications/Claude Switcher.app"
        self.daemons_dir = self.root / "LaunchDaemons"
        self.env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.tmp),
                        PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        CLAUDE_SWITCHER_PYTHON=sys.executable,
                        CLAUDE_SWITCHER_APP=str(self.app_target),
                        CLAUDE_SWITCHER_DAEMONS=str(self.daemons_dir),
                        FIXTURE_ARCHIVE=str(self.archive), CURL_LOG=str(self.curl_log),
                        EXPECTED_UPDATE_URL=UPDATE_URL, FORBIDDEN_LOG=str(self.forbidden_log),
                        SELF_CHECK_MARKER=str(self.root / "self-check-called"))
        self.env.pop("BASH_ENV", None)
        self.env.pop("ENV", None)
        self.stub("curl", '''out=""; url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >> "$CURL_LOG"
[ "$url" = "$EXPECTED_UPDATE_URL" ] || exit 90
[ "${FAKE_DOWNLOAD_FAILURE:-0}" = 0 ] || exit 22
[ -n "$out" ] || exit 91
cp "$FIXTURE_ARCHIVE" "$out"
''')
        # No real privileged/system/process action is permitted, even on macOS.
        for command in ("sudo", "launchctl", "osascript", "pkill", "killall", "open"):
            self.stub(command, 'printf "%s\\n" "$0 $*" >> "$FORBIDDEN_LOG"; exit 99')
        self.stub("id", '[ "$*" = "-u" ] && { echo 501; exit 0; }; exit 1')

    def tearDown(self):
        self.assertFalse(self.forbidden_log.exists(), "unexpected system action in updater")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n", encoding="utf-8")
        path.chmod(0o755)

    def configured(self, text, values):
        for key, value in values.items():
            text, count = re.subn(r'(?m)^' + re.escape(key) + r'="[^"\n]*"',
                                  lambda _: key + '="' + value + '"', text, count=1)
            self.assertEqual(count, 1, key)
        return text

    def prepare_remote(self, content, manifest="valid", package="claude-switcher-main",
                       app_source=None, stun_source=None, guard_plist_source=None):
        if isinstance(content, str):
            content = content.encode("utf-8")
        if stun_source is None:
            stun_source = self.stun_source
        elif isinstance(stun_source, str):
            stun_source = stun_source.encode("utf-8")
        files = {
            "core/claude-switch.sh": content,
            "core/stun-probe.py": stun_source,
            "daemons/claude-bodyguard.sh": b'HOME_DIR="__HOME__"\nMODE="__PROXY_MODE__"\n',
            "daemons/tz-watchdog.sh": b'HOME_DIR="__HOME__"\nTZV="__TZ_TARGET__"\n',
        }
        if guard_plist_source is not None:
            files["daemons/local.claude-bodyguard.plist"] = guard_plist_source
        if app_source is not None:
            files["app/main.swift"] = app_source.encode("utf-8") if isinstance(app_source, str) else app_source
            files["scripts/build-app.sh"] = (ROOT / "scripts/build-app.sh").read_bytes()
        entries = [(hashlib.sha256(body).hexdigest(), name) for name, body in files.items()]
        if manifest == "wrong-core":
            entries[0] = ("0" * 64, entries[0][1])
        elif manifest == "missing-core":
            entries = [e for e in entries if e[1] != "core/claude-switch.sh"]
        elif manifest == "missing-stun":
            entries = [e for e in entries if e[1] != "core/stun-probe.py"]
        elif manifest == "missing-app":
            entries = [(d, n) for d, n in entries if n != "app/main.swift"]
        elif manifest == "missing-build":
            entries = [(d, n) for d, n in entries if n != "scripts/build-app.sh"]
        elif manifest == "missing-guard-plist":
            entries = [(d, n) for d, n in entries if n != "daemons/local.claude-bodyguard.plist"]
        elif manifest == "missing-file":
            entries.append(("0" * 64, "core/not-in-archive.sh"))
        elif manifest == "wrong-extra":
            files["daemons/claude-bodyguard.sh"] += b"# corrupted after hashing\n"
        elif manifest == "wrong-guard-plist":
            files["daemons/local.claude-bodyguard.plist"] += b"corrupted after hashing\n"
        sums = "".join(digest + "  " + name + "\n" for digest, name in entries)
        if manifest == "empty":
            sums = ""
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name, body in files.items():
                archive.writestr(package + "/" + name, body)
            if manifest != "absent":
                archive.writestr(package + "/SHA256SUMS", sums)

    def run_core(self, *args):
        self.curl_log.unlink(missing_ok=True)
        run = subprocess.run(["/bin/bash", str(self.core), *args], env=self.env,
                             text=True, capture_output=True, timeout=30)
        urls = self.curl_log.read_text().splitlines() if self.curl_log.exists() else []
        self.assertTrue(all(url == UPDATE_URL for url in urls), urls)
        self.assertLessEqual(len(urls), 1, "one archive must supply both core and checksums")
        return run, urls

    def installed_state(self):
        return {str(path.relative_to(self.root)): path.read_bytes()
                for directory in (self.home, self.appdir, self.daemons_dir)
                for path in directory.rglob("*") if path.is_file()}

    def prepare_schedule_update(self):
        # These match the remote script templates byte-for-byte: only the plist changes.
        (self.appdir / "claude-bodyguard.sh").write_text(
            f'HOME_DIR="{self.home}"\nMODE="{LOCAL_CONFIG["PROXY_MODE"]}"\n')
        (self.appdir / "tz-watchdog.sh").write_text(
            f'HOME_DIR="{self.home}"\nTZV="{LOCAL_CONFIG["TZ_TARGET"]}"\n')
        self.daemons_dir.mkdir()
        plist = self.daemons_dir / "local.claude-bodyguard.plist"
        new = (ROOT / "daemons/local.claude-bodyguard.plist").read_bytes()
        old = plistlib.loads(new)
        old["StartInterval"] = 10
        old.pop("ThrottleInterval", None)
        plist.write_bytes(plistlib.dumps(old))
        self.env["LAUNCH_TRACE"] = str(self.root / "launch-trace")
        self.stub("chown", "exit 0")
        self.stub("launchctl", '''printf '%s\\n' "$*" >> "$LAUNCH_TRACE"
if [ "${FAIL_NEW_SCHEDULE:-0}" = 1 ] && [ "$1" = bootstrap ] &&
   /usr/bin/grep -q '<integer>1</integer>' "$3"; then exit 1; fi
exit 0''')
        return plist, new

    def test_schedule_only_change_is_detected_by_readonly_update_checks(self):
        plist, new = self.prepare_schedule_update()
        self.prepare_remote(self.core.read_bytes(), guard_plist_source=new)
        for args in CHECK_COMMANDS:
            with self.subTest(args=args):
                before = self.installed_state()
                run, _ = self.run_core(*args)
                self.assert_run(run, True, "发现新版本")
                self.assertEqual(self.installed_state(), before)
                self.assertFalse(Path(self.env["LAUNCH_TRACE"]).exists())

    def test_schedule_plist_requires_valid_archive_checksum(self):
        new = (ROOT / "daemons/local.claude-bodyguard.plist").read_bytes()
        for manifest in ("missing-guard-plist", "wrong-guard-plist"):
            with self.subTest(manifest=manifest):
                self.prepare_remote(self.core.read_bytes(), manifest=manifest, guard_plist_source=new)
                before = self.installed_state()
                run, _ = self.run_core("update", "--gui")
                self.assert_run(run, False, "校验")
                self.assertEqual(self.installed_state(), before)

    @unittest.skipUnless(sys.platform == "darwin", "actual updater uses macOS BSD commands")
    def test_gui_schedule_update_reloads_service_without_replacing_unchanged_scripts(self):
        plist, new = self.prepare_schedule_update()
        guard = self.appdir / "claude-bodyguard.sh"
        modified = guard.stat().st_mtime_ns
        self.stub("osascript", 'script="$2"; /bin/bash "$script"')
        self.prepare_remote(self.install_candidate("保镖=ok:fixture"), guard_plist_source=new)
        run, _ = self.run_core("update", "--gui")
        self.assert_run(run, True, "守护进程")
        self.assertEqual(plist.read_bytes(), new)
        self.assertEqual(plist.stat().st_mode & 0o777, 0o644)
        self.assertEqual(guard.stat().st_mtime_ns, modified)
        trace = Path(self.env["LAUNCH_TRACE"]).read_text()
        self.assertIn("bootout system/local.claude-bodyguard", trace)
        self.assertIn("bootstrap system " + str(plist), trace)
        self.assertIn("print system/local.claude-bodyguard", trace)
        self.assertNotIn("tz-watchdog", trace)
        self.assertEqual(list(self.daemons_dir.glob(".claude-bodyguard.*")), [])

    @unittest.skipUnless(sys.platform == "darwin", "actual updater uses macOS BSD commands")
    def test_cancelled_schedule_update_leaves_existing_system_config_untouched(self):
        plist, new = self.prepare_schedule_update()
        old = plist.read_bytes()
        before_core = self.core.read_bytes()
        self.stub("osascript", "exit 1")
        self.prepare_remote(self.install_candidate("保镖=ok:fixture"), guard_plist_source=new)
        run, _ = self.run_core("update", "--gui")
        self.assert_run(run, False, "已自动回滚")
        self.assertEqual(plist.read_bytes(), old)
        self.assertEqual(self.core.read_bytes(), before_core)
        self.assertFalse(Path(self.env["LAUNCH_TRACE"]).exists())

    @unittest.skipUnless(sys.platform == "darwin", "actual updater uses macOS BSD commands")
    def test_tampered_schedule_is_rejected_before_system_mutation(self):
        plist, new = self.prepare_schedule_update()
        old = plist.read_bytes()
        before_core = self.core.read_bytes()
        self.stub("osascript", 'printf tampered > "${2%/*}/bg.plist"; /bin/bash "$2"')
        self.prepare_remote(self.install_candidate("保镖=ok:fixture"), guard_plist_source=new)
        run, _ = self.run_core("update", "--gui")
        self.assert_run(run, False, "已自动回滚")
        self.assertEqual(plist.read_bytes(), old)
        self.assertEqual(self.core.read_bytes(), before_core)
        self.assertFalse(Path(self.env["LAUNCH_TRACE"]).exists())

    @unittest.skipUnless(sys.platform == "darwin", "actual updater uses macOS BSD commands")
    def test_failed_new_schedule_restores_and_reloads_previous_schedule(self):
        plist, new = self.prepare_schedule_update()
        old = plist.read_bytes()
        before_core = self.core.read_bytes()
        self.env["FAIL_NEW_SCHEDULE"] = "1"
        self.stub("osascript", '/bin/bash "$2"')
        self.prepare_remote(self.install_candidate("保镖=ok:fixture"), guard_plist_source=new)
        run, _ = self.run_core("update", "--gui")
        self.assert_run(run, False, "已自动回滚")
        self.assertEqual(plist.read_bytes(), old)
        self.assertEqual(self.core.read_bytes(), before_core)
        trace = Path(self.env["LAUNCH_TRACE"]).read_text()
        self.assertEqual(trace.count("bootstrap system " + str(plist)), 2)
        self.assertIn("print system/local.claude-bodyguard", trace)
        self.assertEqual(list(self.daemons_dir.glob(".claude-bodyguard.*")), [])

    def assert_run(self, run, success, message):
        self.assertEqual(run.returncode == 0, success, run.stdout + run.stderr)
        self.assertIn(message, run.stdout)

    def test_check_aliases_use_own_main_and_leave_installation_and_backup_untouched(self):
        for client in ("tag", "clash-verge"):
            self.core.write_text(self.configured(self.original, {"PROXY_MODE": client}))
            self.prepare_remote(self.core.read_bytes() + b"\n# new fork version\n")
            for existing_backup in (False, True):
                if existing_backup:
                    self.backup.write_bytes(b"previous backup must survive a check\n")
                else:
                    self.backup.unlink(missing_ok=True)
                for args in CHECK_COMMANDS:
                    with self.subTest(client=client, backup=existing_backup, args=args):
                        before = self.installed_state()
                        run, urls = self.run_core(*args)
                        self.assert_run(run, True, "发现新版本")
                        self.assertEqual(urls, [UPDATE_URL])
                        self.assertEqual(self.installed_state(), before)

    def test_comparison_ignores_all_five_local_config_values(self):
        self.prepare_remote(self.original)
        for args in CHECK_COMMANDS:
            with self.subTest(args=args):
                before = self.installed_state()
                run, urls = self.run_core(*args)
                self.assert_run(run, True, "已是最新版本")
                self.assertEqual(urls, [UPDATE_URL])
                self.assertEqual(self.installed_state(), before)

    def test_normal_and_automatic_updates_are_allowed_for_tag_and_other_clients(self):
        for client in ("tag", "clash-verge"):
            self.core.write_text(self.configured(self.original, {"PROXY_MODE": client}))
            self.prepare_remote(self.core.read_bytes())
            for args in (("update",), ("update", "--auto")):
                with self.subTest(client=client, args=args):
                    before = self.core.read_bytes()
                    run, urls = self.run_core(*args)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    output = (self.base / "update.log").read_text() if "--auto" in args else run.stdout
                    self.assertIn("已是最新版本", output)
                    self.assertEqual(urls, [UPDATE_URL])
                    self.assertEqual(self.core.read_bytes(), before)
                    self.assertFalse(self.backup.exists())

    def test_unknown_update_argument_fails_before_downloading_or_writing(self):
        before = self.installed_state()
        run, urls = self.run_core("update", "--unknown")
        self.assert_run(run, False, "用法")
        self.assertEqual(urls, [])
        self.assertEqual(self.installed_state(), before)

    def test_manifest_must_be_in_archive_and_verify_core_and_other_listed_files(self):
        for manifest in ("absent", "empty", "wrong-core", "missing-core", "missing-file", "wrong-extra"):
            self.prepare_remote(self.core.read_bytes() + b"\n# candidate update\n", manifest)
            for args in (*CHECK_COMMANDS, ("update",)):
                with self.subTest(manifest=manifest, args=args):
                    self.backup.write_bytes(b"existing known-good backup\n")
                    before = self.installed_state()
                    run, urls = self.run_core(*args)
                    self.assert_run(run, False, "校验")
                    self.assertEqual(urls, [UPDATE_URL])
                    self.assertEqual(self.installed_state(), before)

    def test_download_failure_never_falls_back_to_upstream(self):
        self.env["FAKE_DOWNLOAD_FAILURE"] = "1"
        for args in CHECK_COMMANDS:
            with self.subTest(args=args):
                before = self.installed_state()
                run, urls = self.run_core(*args)
                self.assert_run(run, False, "下载或解压失败")
                self.assertEqual(urls, [UPDATE_URL])
                self.assertEqual(self.installed_state(), before)

    def test_invalid_zip_or_wrong_package_structure_cannot_change_installation(self):
        for kind in ("not-zip", "wrong-package"):
            if kind == "not-zip":
                self.archive.write_bytes(b"not a zip archive")
            else:
                self.prepare_remote(self.core.read_bytes(), package="other-project-main")
            with self.subTest(kind=kind):
                before = self.installed_state()
                run, urls = self.run_core("update-check")
                self.assert_run(run, False, "FAIL:")
                self.assertEqual(urls, [UPDATE_URL])
                self.assertEqual(self.installed_state(), before)

    def install_candidate(self, check_result):
        config = '\n'.join(key + '="remote-default"' for key in LOCAL_CONFIG)
        return ('#!/bin/bash\n' + config + '\n# installed fork candidate\n'
                'if [ "${1:-}" = checkdetail ]; then\n'
                '    printf called > "$SELF_CHECK_MARKER"\n'
                '    printf "%s\\n" "' + check_result + '"\n'
                'fi\n')

    @unittest.skipUnless(sys.platform == "darwin", "actual updater uses macOS BSD sed/stat")
    def test_install_preserves_config_backup_and_prompts_for_separate_daemon_refresh(self):
        before = self.core.read_bytes()
        guard = self.appdir / "claude-bodyguard.sh"
        guard.write_bytes(b"existing installed guard\n")
        tz = self.appdir / "tz-watchdog.sh"
        tz.write_bytes(b"existing installed timezone hook\n")
        ui = self.home / "Applications/Claude Switcher.app/Contents/MacOS/applet"
        ui.parent.mkdir(parents=True)
        ui.write_bytes(b"existing UI\n")
        candidate = self.install_candidate("proxy=ok")
        self.prepare_remote(candidate, stun_source="# updated stun probe v2\n")
        run, urls = self.run_core("update")
        self.assert_run(run, True, "核心脚本更新完成")
        self.assertIn("STUN探针", run.stdout)
        self.assertIn("请运行 installer/安装.command", run.stdout)
        self.assertEqual(urls, [UPDATE_URL])
        self.assertEqual(self.backup.read_bytes(), before)
        self.assertEqual(self.core.read_text(encoding="utf-8"), candidate)
        cfg_text = (self.base / "config.env").read_text(encoding="utf-8")
        for key, value in LOCAL_CONFIG.items():
            self.assertIn(key + '="' + value + '"', cfg_text)
        self.assertEqual(self.stun.read_text(encoding="utf-8"), "# updated stun probe v2\n")
        self.assertTrue(os.access(self.core, os.X_OK))
        self.assertTrue(Path(self.env["SELF_CHECK_MARKER"]).exists())
        self.assertEqual(guard.read_bytes(), b"existing installed guard\n")
        self.assertEqual(tz.read_bytes(), b"existing installed timezone hook\n")
        self.assertEqual(ui.read_bytes(), b"existing UI\n")

    @unittest.skipUnless(sys.platform == "darwin", "actual updater uses macOS BSD sed/stat")
    def test_failed_or_empty_self_check_restores_previous_core(self):
        for check_result in ("proxy=fail:fixture", ""):
            with self.subTest(check_result=check_result):
                before = self.core.read_bytes()
                before_stun = self.stun.read_bytes()
                self.prepare_remote(self.install_candidate(check_result),
                                    stun_source="# broken stun candidate\n")
                run, urls = self.run_core("update")
                self.assert_run(run, False, "已自动回滚")
                self.assertEqual(urls, [UPDATE_URL])
                self.assertEqual(self.core.read_bytes(), before)
                self.assertEqual(self.backup.read_bytes(), before)
                self.assertEqual(self.stun.read_bytes(), before_stun)
                self.assertFalse((self.base / "config.env").exists())
                self.assertTrue(Path(self.env["SELF_CHECK_MARKER"]).exists())

    def test_archive_with_unlisted_app_or_build_or_stun_fails_verification(self):
        for manifest in ("missing-app", "missing-build", "missing-stun"):
            with self.subTest(manifest=manifest):
                self.prepare_remote(self.core.read_bytes(), manifest=manifest, app_source="// new ui\n")
                before = self.installed_state()
                run, urls = self.run_core("update-check")
                self.assert_run(run, False, "校验")
                self.assertEqual(urls, [UPDATE_URL])
                self.assertEqual(self.installed_state(), before)

    @unittest.skipUnless(sys.platform == "darwin", "actual updater uses macOS BSD sed/stat/PlistBuddy")
    def test_gui_update_compiles_app_and_syncs_daemons_via_admin(self):
        guard = self.appdir / "claude-bodyguard.sh"
        guard.write_bytes(b"stale guard\n")
        tz = self.appdir / "tz-watchdog.sh"
        tz.write_bytes(b"stale tz\n")
        self.stub("swiftc", '''out=""
while [ "$#" -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
printf '#!/bin/sh\necho new-binary\n' > "$out"
chmod 755 "$out"
''')
        self.stub("codesign", "exit 0")
        self.stub("ditto", '/bin/cp -R "$1" "$2"')
        self.stub("chown", "exit 0")
        self.stub("osascript", 'script="$2"; /bin/bash "$script"')
        app_src = "// updated SwiftUI source v2\n"
        expected_sha = hashlib.sha256(app_src.encode("utf-8")).hexdigest()
        self.prepare_remote(self.install_candidate("proxy=ok"), app_source=app_src)
        run, urls = self.run_core("update", "--gui")
        self.assert_run(run, True, "核心脚本更新完成")
        self.assertIn("界面App", run.stdout)
        self.assertIn("守护进程", run.stdout)
        self.assertEqual(urls, [UPDATE_URL])
        self.assertTrue((self.app_target / "Contents/MacOS/ClaudeSwitcher").is_file())
        plist_text = (self.app_target / "Contents/Info.plist").read_text(encoding="utf-8")
        self.assertIn(expected_sha, plist_text)
        self.assertIn('MODE="tag"', guard.read_text(encoding="utf-8"))
        self.assertIn('TZV="America/Toronto"', tz.read_text(encoding="utf-8"))

    @unittest.skipUnless(sys.platform == "darwin", "actual updater uses macOS BSD sed/stat/PlistBuddy")
    def test_gui_update_runs_self_check_before_admin_and_leaves_app_and_daemons_untouched_on_fail(self):
        guard = self.appdir / "claude-bodyguard.sh"
        guard.write_bytes(b"stale guard\n")
        tz = self.appdir / "tz-watchdog.sh"
        tz.write_bytes(b"stale tz\n")
        self.stub("swiftc", '''out=""
while [ "$#" -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
printf '#!/bin/sh\necho new-binary\n' > "$out"
chmod 755 "$out"
''')
        self.stub("codesign", "exit 0")
        # Keep osascript on the forbidden stub! Since self-check fails first, osascript must never be called.
        before_core = self.core.read_bytes()
        self.prepare_remote(self.install_candidate("出口IP=fail:CN"), app_source="// updated SwiftUI source v3\n")
        run, urls = self.run_core("update", "--gui")
        self.assert_run(run, False, "已自动回滚")
        self.assertIn("新版自检未通过(出口IP)", run.stdout)
        self.assertEqual(urls, [UPDATE_URL])
        self.assertEqual(self.core.read_bytes(), before_core)
        self.assertFalse(self.app_target.exists())
        self.assertEqual(guard.read_bytes(), b"stale guard\n")
        self.assertEqual(tz.read_bytes(), b"stale tz\n")

    @unittest.skipUnless(sys.platform == "darwin", "actual updater uses macOS BSD sed/stat")
    def test_replacing_running_core_does_not_execute_bytes_from_new_file(self):
        # bash reads the running script incrementally; an in-place overwrite would make the old
        # process resume at its byte offset inside the new file. The candidate is padded beyond the
        # installed core so that any such offset lands on a leak marker followed by a non-zero exit.
        leak = "echo SELF_OVERWRITE_LEAK; exit 42\n"
        head = self.install_candidate("proxy=ok") + "exit 0\n"
        padding = leak * (len(self.core.read_bytes()) // len(leak) + 200)
        candidate = head + padding
        self.prepare_remote(candidate)
        run, urls = self.run_core("update")
        self.assert_run(run, True, "核心脚本更新完成")
        self.assertNotIn("SELF_OVERWRITE_LEAK", run.stdout + run.stderr)
        self.assertEqual(urls, [UPDATE_URL])
        self.assertEqual(self.core.read_text(encoding="utf-8"), candidate)
        self.assertTrue(os.access(self.core, os.X_OK))
        self.assertEqual(list(self.core.parent.glob(".claude-switch.sh.*")), [])

    def test_update_lock_prevents_concurrent_updates_and_recovers_stale_lock(self):
        lockdir = self.base / "update.lock"
        lockdir.mkdir(parents=True)
        (lockdir / "pid").write_text(str(os.getpid()), encoding="utf-8")
        before = self.installed_state()
        run, urls = self.run_core("update", "--gui")
        self.assert_run(run, False, "另一个更新进程正在运行")
        self.assertEqual(urls, [])
        self.assertEqual(self.installed_state(), before)
        # Stale PID should be automatically recovered
        (lockdir / "pid").write_text("999999", encoding="utf-8")
        self.prepare_remote(self.original)
        run, urls = self.run_core("update")
        self.assert_run(run, True, "已是最新版本")
        self.assertEqual(urls, [UPDATE_URL])
        self.assertFalse(lockdir.exists())


if __name__ == "__main__":
    unittest.main()
