"""Exercise installer and uninstaller App handling with temporary bundles only."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "installer/安装.command"
UNINSTALLER = ROOT / "installer/卸载.command"


def extract(path, start, end):
    text = path.read_text(encoding="utf-8")
    return text[text.index(start):text.index(end, text.index(start))]


@unittest.skipUnless(sys.platform == "darwin", "macOS bundle identity uses PlistBuddy")
class MacAppLocationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="switcher-app-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.root), PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin")
        self.env.pop("BASH_ENV", None)
        self.stub("ditto", 'if [ "${FAIL_COPY:-0}" = 1 ]; then exit 1; fi\n/bin/cp -R "$1" "$2"')
        self.stub("codesign", 'exit "${FAIL_SIGNATURE:-0}"')
        self.stub("pkill", "exit 1")
        self.stub("pgrep", 'exit "${PROCESS_ABSENT:-1}"')
        self.stub("mv", 'case "$1" in */new.app) [ "${FAIL_NEW_MOVE:-0}" = 1 ] && exit 1 ;; esac\nexec /bin/mv "$@"')
        self.source = self.bundle(self.root / "source.app", "new")
        self.target = self.root / "Applications" / "Claude切换器.app"
        self.target.parent.mkdir()

    def stub(self, name, body):
        p = self.bin / name
        p.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
        p.chmod(0o755)

    def bundle(self, path, marker, identity="local.claude-switcher"):
        contents = path / "Contents"
        contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as f:
            plistlib.dump({"CFBundleIdentifier": identity}, f)
        (path / "marker").write_text(marker, encoding="utf-8")
        return path

    def run_function(self, definition, function, *args, **variables):
        return subprocess.run(
            ["/bin/bash", "-c", definition + '\n' + function + ' "$@"', "_", *map(str, args)],
            env=dict(self.env, **variables), text=True, capture_output=True, timeout=15,
        )

    def install(self, **variables):
        definition = extract(INSTALLER, "install_app_bundle() {", "# ---- 4.")
        return self.run_function(definition, "install_app_bundle", self.source, self.target, **variables)

    def remove(self, path):
        definition = extract(UNINSTALLER, "remove_app_bundle() {", "app_removal_failed=0")
        return self.run_function(definition, "remove_app_bundle", path)

    def test_entrypoints_use_application_and_legacy_paths(self):
        install = INSTALLER.read_text(encoding="utf-8")
        uninstall = UNINSTALLER.read_text(encoding="utf-8")
        self.assertIn('APP_TARGET="/Applications/Claude切换器.app"', install)
        self.assertIn('install_app_bundle "$APP" "$APP_TARGET"', install)
        self.assertIn('remove_app_bundle "/Applications/Claude切换器.app"', uninstall)
        self.assertIn('remove_app_bundle "$HOME/Desktop/Claude切换器.app"', uninstall)
        self.assertNotIn('rm -rf "$H/Desktop/Claude切换器.app"', install)

    def test_installs_to_target_and_replaces_known_app(self):
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual((self.target / "marker").read_text(), "new")
        (self.target / "marker").write_text("old")
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual((self.target / "marker").read_text(), "new")
        self.assertEqual(list(self.target.parent.glob(".claude-switcher.*")), [])

    def test_rejects_unknown_or_symlinked_target(self):
        self.bundle(self.target, "unrelated", identity="other.app")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual((self.target / "marker").read_text(), "unrelated")
        self.assertNotEqual(self.remove(self.target).returncode, 0)
        self.target.rename(self.root / "unrelated.app")
        self.target.symlink_to(self.root / "unrelated.app", target_is_directory=True)
        self.assertNotEqual(self.install().returncode, 0)
        self.assertNotEqual(self.remove(self.target).returncode, 0)
        self.assertEqual((self.target / "marker").read_text(), "unrelated")

    def test_failed_copy_or_move_preserves_existing_app(self):
        self.bundle(self.target, "old")
        for failure in ("FAIL_COPY", "FAIL_SIGNATURE", "FAIL_NEW_MOVE"):
            with self.subTest(failure=failure):
                self.assertNotEqual(self.install(**{failure: "1"}).returncode, 0)
                self.assertEqual((self.target / "marker").read_text(), "old")
                self.assertEqual(list(self.target.parent.glob(".claude-switcher.*")), [])

    def test_uninstall_handles_new_and_legacy_locations(self):
        legacy = self.root / "Desktop" / "Claude切换器.app"
        self.bundle(self.target, "installed")
        self.bundle(legacy, "legacy")
        self.assertEqual(self.remove(self.target).returncode, 0)
        self.assertEqual(self.remove(legacy).returncode, 0)
        self.assertFalse(self.target.exists())
        self.assertFalse(legacy.exists())
        self.assertEqual(self.remove(legacy).returncode, 0)

    def test_running_app_and_cancelled_admin_leave_original(self):
        self.bundle(self.target, "old")
        self.assertNotEqual(self.install(PROCESS_ABSENT="0").returncode, 0)
        self.assertEqual((self.target / "marker").read_text(), "old")
        self.target.chmod(0o555)
        self.addCleanup(self.target.chmod, 0o755)
        self.stub("sudo", "exit 1")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertNotEqual(self.remove(self.target).returncode, 0)
        self.assertEqual((self.target / "marker").read_text(), "old")


if __name__ == "__main__":
    unittest.main()
