"""GUI settings bridge: isolated HOME, no real network or account commands."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "core/claude-switch.sh"


class MacOSToolsTests(unittest.TestCase):
    def setUp(self):
        trash = ROOT / "_trash"
        trash.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="macos-tools-", dir=trash)
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.base = self.home / ".claude-switcher"
        self.base.mkdir(parents=True)
        self.fakebin = Path(self.tmp.name) / "bin"
        self.fakebin.mkdir()
        self.calls = Path(self.tmp.name) / "unexpected-calls"
        for name in ("curl", "dig", "osascript", "open", "launchctl", "defaults", "networksetup", "hdiutil"):
            command = self.fakebin / name
            command.write_text(f'#!/bin/sh\nprintf "%s\\n" "{name}" >> "{self.calls}"\nexit 99\n')
            command.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f"{self.fakebin}:/usr/bin:/bin:/usr/sbin:/sbin",
                        CLAUDE_SWITCHER_PYTHON=sys.executable)
        self.env.pop("BASH_ENV", None)
        self.env.pop("ENV", None)

    def run_core(self, *args):
        result = subprocess.run(["/bin/bash", str(CORE), *args], env=self.env,
                                text=True, capture_output=True, timeout=5)
        self.assertFalse(self.calls.exists(), "配置入口不能调用网络、系统或账号操作")
        return result

    def save(self, text):
        return self.run_core("set-keep-paths", json.dumps(text, ensure_ascii=False))

    def test_tools_config_loads_runtime_region_without_network_or_mutation(self):
        (self.base / "config.env").write_text(
            'COUNTRY_TARGET="JP"\nTZ_TARGET="Asia/Tokyo"\nLOCALE_TARGET="ja_JP"\nPROXY_MODE="tag"\n')
        before = (self.base / "config.env").read_bytes()
        result = self.run_core("get-tool-config")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), dict(keepPaths="", policy="proxy", country="JP",
                                                       timezone="Asia/Tokyo", locale="ja_JP", client="tag"))
        self.assertEqual((self.base / "config.env").read_bytes(), before)
        self.assertFalse((self.base / "keep-in-workspace.txt").exists())
        self.assertFalse((self.base / "accounts").exists())
        self.assertFalse((self.home / "Library/Logs/claude-switcher/client.log").exists())

    def test_keep_list_round_trips_comments_spaces_and_empty_disable(self):
        text = '# 通用设置\nsettings.json\nskills/\nfolder with spaces/config.json\n'
        result = self.save(text)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        path = self.base / "keep-in-workspace.txt"
        self.assertEqual(path.read_text(), text)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(json.loads(self.run_core("get-tool-config").stdout)["keepPaths"], text)
        self.assertEqual(self.save("").returncode, 0)
        self.assertEqual(path.read_text(), "")
        self.assertFalse(any(self.base.glob(".keep-*")))

    def test_unsafe_keep_paths_never_replace_existing_list(self):
        self.assertEqual(self.save("settings.json\n").returncode, 0)
        for text in ("/etc/passwd", "../Cookies", "skills/../Cookies", ".", "./", "a\x00b", "x" * 16385):
            with self.subTest(path=text[:30]):
                self.assertNotEqual(self.save(text).returncode, 0)
                self.assertEqual((self.base / "keep-in-workspace.txt").read_text(), "settings.json\n")
        for value in ([], {"paths": []}, 42):
            self.assertNotEqual(self.run_core("set-keep-paths", json.dumps(value)).returncode, 0)

    def test_keep_paths_reject_symlink_components_and_destination(self):
        data = self.home / "Library/Application Support/Claude"
        data.mkdir(parents=True)
        outside = Path(self.tmp.name) / "outside"
        outside.mkdir()
        (outside / "config.json").write_text("untouched")
        (data / "linked").symlink_to(outside, target_is_directory=True)
        self.assertNotEqual(self.save("linked/config.json").returncode, 0)
        (self.base / "keep-in-workspace.txt").symlink_to(outside / "config.json")
        self.assertNotEqual(self.save("settings.json").returncode, 0)
        self.assertNotEqual(self.run_core("get-tool-config").returncode, 0)
        self.assertEqual((outside / "config.json").read_text(), "untouched")

    def test_invalid_or_symlink_policy_fails_without_exposing_content(self):
        policy = self.base / "webrtc-policy"
        policy.write_text("reject\n")
        self.assertEqual(json.loads(self.run_core("get-tool-config").stdout)["policy"], "reject")
        policy.write_text("private-marker")
        result = self.run_core("get-tool-config")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("private-marker", result.stdout + result.stderr)
        policy.unlink()
        outside = Path(self.tmp.name) / "private-policy"
        outside.write_text("private-marker")
        policy.symlink_to(outside)
        result = self.run_core("get-tool-config")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("private-marker", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
