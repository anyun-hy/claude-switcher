"""Exercise the fork updater offline, using only a temporary installation.

The install/rollback cases run on macOS because production deliberately retains
upstream's BSD sed/stat behavior. All platforms exercise downloads, archive
validation, config-only comparisons and both read-only command aliases.
"""
import hashlib
import os
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
        self.original = SOURCE.read_text(encoding="utf-8").replace(
            'APPDIR="/Library/Application Support/claude-switcher"',
            'APPDIR="' + str(self.appdir) + '"')
        self.core.write_text(self.configured(self.original, LOCAL_CONFIG), encoding="utf-8")
        self.core.chmod(0o700)
        self.archive = self.root / "remote.zip"
        self.curl_log = self.root / "curl.log"
        self.forbidden_log = self.root / "forbidden.log"
        self.env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.tmp),
                        PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        CLAUDE_SWITCHER_PYTHON=sys.executable,
                        FIXTURE_ARCHIVE=str(self.archive), CURL_LOG=str(self.curl_log),
                        EXPECTED_UPDATE_URL=UPDATE_URL, FORBIDDEN_LOG=str(self.forbidden_log),
                        SELF_CHECK_MARKER=str(self.root / "self-check-called"))
        self.env.pop("BASH_ENV", None)
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

    def prepare_remote(self, content, manifest="valid", package="claude-switcher-main"):
        if isinstance(content, str):
            content = content.encode("utf-8")
        files = {
            "core/claude-switch.sh": content,
            "daemons/claude-bodyguard.sh": b'HOME_DIR="__HOME__"\nMODE="__PROXY_MODE__"\n',
            "daemons/tz-watchdog.sh": b'HOME_DIR="__HOME__"\nTZV="__TZ_TARGET__"\n',
        }
        entries = [(hashlib.sha256(body).hexdigest(), name) for name, body in files.items()]
        if manifest == "wrong-core":
            entries[0] = ("0" * 64, entries[0][1])
        elif manifest == "missing-core":
            entries = entries[1:]
        elif manifest == "missing-file":
            entries.append(("0" * 64, "core/not-in-archive.sh"))
        elif manifest == "wrong-extra":
            files["daemons/claude-bodyguard.sh"] += b"# corrupted after hashing\n"
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
                for directory in (self.home, self.appdir)
                for path in directory.rglob("*") if path.is_file()}

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
        self.prepare_remote(self.install_candidate("proxy=ok"))
        run, urls = self.run_core("update")
        self.assert_run(run, True, "核心脚本更新完成")
        self.assertIn("请运行 installer/安装.command", run.stdout)
        self.assertEqual(urls, [UPDATE_URL])
        self.assertEqual(self.backup.read_bytes(), before)
        installed = self.core.read_text()
        self.assertIn("# installed fork candidate", installed)
        for key, value in LOCAL_CONFIG.items():
            self.assertIn(key + '="' + value + '"', installed)
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
                self.prepare_remote(self.install_candidate(check_result))
                run, urls = self.run_core("update")
                self.assert_run(run, False, "已自动回滚")
                self.assertEqual(urls, [UPDATE_URL])
                self.assertEqual(self.core.read_bytes(), before)
                self.assertEqual(self.backup.read_bytes(), before)
                self.assertTrue(Path(self.env["SELF_CHECK_MARKER"]).exists())


if __name__ == "__main__":
    unittest.main()
