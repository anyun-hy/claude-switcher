"""Opt-in GUI lifecycle tests; fake core and fake opener, no installed app changes."""
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(
    platform.system() == "Darwin" and shutil.which("swiftc")
    and os.environ.get("CLAUDE_SWITCHER_GUI_INTEGRATION") == "1",
    "requires an explicitly enabled macOS GUI session",
)
class RelaunchLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="switcher-relaunch-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.binary = cls.root / "RelaunchLifecycleTests"
        build = subprocess.run(
            ["swiftc", "-parse-as-library", "-warnings-as-errors", "-D", "CLAUDE_SWITCHER_TESTS",
             "-target", f"{platform.machine()}-apple-macos13.0", "-module-cache-path", str(cls.root / "cache"),
             str(ROOT / "app/main.swift"), str(ROOT / "tests/RelaunchLifecycleTests.swift"),
             "-o", str(cls.binary), "-framework", "SwiftUI", "-framework", "AppKit"],
            cwd=ROOT, text=True, capture_output=True, timeout=180,
        )
        if build.returncode:
            raise AssertionError(build.stdout + build.stderr)

    def setUp(self):
        self.temporary_case = tempfile.TemporaryDirectory(prefix="case-", dir=self.root)
        self.addCleanup(self.temporary_case.cleanup)
        self.case = Path(self.temporary_case.name)
        fakebin = self.case / "bin"
        fakebin.mkdir()
        self.marker = self.case / "open-result"
        opener = fakebin / "open"
        opener.write_text('''#!/bin/sh
if kill -0 "$RELAUNCH_TEST_OLD_PID" 2>/dev/null; then
    echo old-process-still-alive > "$RELAUNCH_TEST_MARKER"
    exit 1
fi
echo old-process-exited > "$RELAUNCH_TEST_MARKER"
''', encoding="utf-8")
        opener.chmod(0o755)
        self.core = self.case / "fake-core.sh"
        self.core.write_text('''#!/bin/bash
case "$1" in
  checkdetail) for k in 代理内核 TUN网卡 出口IP IP一致 时区 地区 IPv6 DNS WebRTC 保镖 规则置顶 客户端语言 ASN属性 生态可达性; do echo "$k=ok"; done ;;
  get-client) echo client=tag ;;
  status) echo 'current=none hasA=0 hasB=0' ;;
  detect-client) echo stable ;;
  update) echo 'OK:核心脚本更新完成（已同步更新：界面App）' ;;
  *) exit 2 ;;
esac
''', encoding="utf-8")
        self.env = dict(os.environ, PATH=str(fakebin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        RELAUNCH_TEST_MARKER=str(self.marker))
        self.env.pop("BASH_ENV", None)

    def run_scenario(self, scenario):
        try:
            return subprocess.run([str(self.binary), str(self.core), scenario], cwd=ROOT,
                                  env=self.env, text=True, capture_output=True, timeout=15)
        except subprocess.TimeoutExpired:
            # Keep the fake opener in place until any detached helper has timed out.
            time.sleep(6)
            raise

    def test_sheet_closes_and_new_instance_opens_only_after_exit(self):
        result = self.run_scenario("normal")
        deadline = time.monotonic() + 6
        while not self.marker.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS termination requested", result.stdout)
        self.assertTrue(self.marker.exists(), "restart helper did not invoke the fake opener")
        self.assertEqual(self.marker.read_text(encoding="utf-8").strip(), "old-process-exited")

    def test_vetoed_exit_does_not_open_existing_instance_and_reports_failure(self):
        result = self.run_scenario("veto")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS veto reported", result.stdout)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
