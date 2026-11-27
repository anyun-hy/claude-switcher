"""Isolated regression tests for runtime exit-IP guard (`guard-exit-ip`)."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest

from macos_process_fixture import with_process_paths


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"


class GuardExitIpTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="guard-ip-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        (self.home / "Library/Logs").mkdir(parents=True)
        self.base = self.home / ".claude-switcher"
        self.base.mkdir()
        self.process_paths = Path(self.tmp.name) / "process-paths"
        self.process_paths.write_text("321\t/usr/local/bin/sing-box\n", encoding="utf-8")
        self.core = Path(self.tmp.name) / "claude-switch.sh"
        text = SOURCE.read_text(encoding="utf-8")
        text = text.replace('PROXY_MODE="clash-verge"', 'PROXY_MODE="sing-box"', 1)
        text = text.replace('COUNTRY_TARGET="US"', 'COUNTRY_TARGET="JP"', 1)
        # Support both full listing and single-PID lookup in macos_process_paths fixture.
        body = (
            'if [ "$#" -eq 1 ]; then grep "^$1\t" "$TEST_PROCESS_PATHS"; '
            'else cat "$TEST_PROCESS_PATHS"; fi'
        )
        self.core.write_text(with_process_paths(text, body=body), encoding="utf-8")
        self.core.chmod(0o755)
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.calls = Path(self.tmp.name) / "calls"
        self.env = dict(
            os.environ,
            HOME=str(self.home),
            PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
            CLAUDE_SWITCHER_PYTHON=sys.executable,
            PYTHONUTF8="1",
            TEST_PROCESS_PATHS=str(self.process_paths),
        )
        self.env.pop("BASH_ENV", None)
        self.env.pop("ENV", None)
        (self.base / "lastip").write_text("106.178.150.201\n", encoding="utf-8")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(
            "#!/bin/bash\nprintf '%s %s\\n' '" + name + "' \"$*\" >>'"
            + str(self.calls) + "'\n" + body + "\n",
            encoding="utf-8",
        )
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def run_core(self, *args):
        return subprocess.run(
            ["/bin/bash", str(self.core), *args],
            text=True,
            encoding="utf-8",
            capture_output=True,
            env=self.env,
            timeout=15,
        )

    def parse_kv(self, stdout):
        out = {}
        for line in stdout.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k] = v
        return out

    def test_skips_external_probe_when_proxy_or_tun_down(self):
        self.stub("ifconfig", "echo 'inet 127.0.0.1'")
        self.stub("curl", "printf 'ip=1.2.3.4\\nloc=CN\\n'")
        res = self.run_core("guard-exit-ip")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.parse_kv(res.stdout).get("status"), "proxy_down")
        calls = self.calls.read_text(encoding="utf-8") if self.calls.exists() else ""
        self.assertNotIn("curl ", calls, "TUN 离线时严禁发起外部 curl 探测")

    def test_skips_when_cli_operation_lock_present(self):
        self.stub("ifconfig", "echo 'inet 198.18.0.1'")
        self.stub("curl", "printf 'ip=106.178.149.35\\nloc=JP\\n'")
        (self.base / "cli-operation.lock").mkdir()
        res = self.run_core("guard-exit-ip")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.parse_kv(res.stdout).get("status"), "busy")
        calls = self.calls.read_text(encoding="utf-8") if self.calls.exists() else ""
        self.assertNotIn("curl ", calls)

    def test_returns_same_when_ip_and_country_match(self):
        self.stub("ifconfig", "echo 'inet 198.18.0.1'")
        self.stub("curl", "printf 'ip=106.178.150.201\\nloc=JP\\n'")
        res = self.run_core("guard-exit-ip")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        kv = self.parse_kv(res.stdout)
        self.assertEqual(kv.get("status"), "same")
        self.assertEqual(kv.get("ip"), "106.178.150.201")
        self.assertEqual(kv.get("loc"), "JP")

    def test_disconnects_verified_claude_main_and_helper_without_leaking_ip(self):
        self.stub("ifconfig", "echo 'inet 198.18.0.1'")
        self.stub("curl", "printf 'ip=106.178.149.35\\nloc=JP\\n'")
        # Simulate stubborn Electron/CLI processes that ignore SIGTERM; guard must SIGKILL immediately!
        main_proc = subprocess.Popen(["/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 30"])
        helper_proc = subprocess.Popen(["/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 30"])
        builtin_cli_proc = subprocess.Popen(["/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 30"])
        def cleanup_proc(proc):
            if proc.poll() is None:
                proc.kill()
            proc.wait()
        self.addCleanup(cleanup_proc, main_proc)
        self.addCleanup(cleanup_proc, helper_proc)
        self.addCleanup(cleanup_proc, builtin_cli_proc)
        self.process_paths.write_text(
            "321\t/usr/local/bin/sing-box\n"
            f"{main_proc.pid}\t/Applications/Claude.app/Contents/MacOS/Claude\n"
            f"{helper_proc.pid}\t/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper\n"
            f"{builtin_cli_proc.pid}\t/Users/anyun/Library/Application Support/Claude/claude-code/2.1.331/claude\n",
            encoding="utf-8",
        )
        t0 = time.time()
        res = self.run_core("guard-exit-ip")
        elapsed = time.time() - t0
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        kv = self.parse_kv(res.stdout)
        self.assertEqual(kv.get("status"), "changed")
        self.assertEqual(kv.get("reason"), "ip_changed")
        self.assertEqual(kv.get("before"), "106.178.150.201")
        self.assertEqual(kv.get("after"), "106.178.149.35")
        self.assertEqual(kv.get("disconnected"), "1")
        self.assertLess(elapsed, 4.0, f"应零等待立即 SIGKILL，不应拖延 {elapsed:.2f}s")
        self.assertIsNotNone(main_proc.poll(), "忽略 SIGTERM 的 Claude 主程序未被 SIGKILL 彻底结束")
        self.assertIsNotNone(helper_proc.poll(), "忽略 SIGTERM 的 Claude 后台助手未被 SIGKILL 彻底结束")
        self.assertIsNotNone(builtin_cli_proc.poll(), "含空格路径下的内置 claude-code 未被 SIGKILL 彻底结束")
        # Privacy invariant: neither IP may appear in claude-switch.log.
        log_file = self.home / "Library/Logs/claude-switch.log"
        log_text = log_file.read_text(encoding="utf-8") if log_file.exists() else ""
        self.assertIn("已立即强制断开 Claude", log_text)
        self.assertNotIn("106.178.150.201", log_text)
        self.assertNotIn("106.178.149.35", log_text)

    def test_respects_disabled_ip_check_but_still_enforces_hard_country_check(self):
        self.stub("ifconfig", "echo 'inet 198.18.0.1'")
        (self.base / "checks.json").write_text('{"disabled":["IP一致"]}', encoding="utf-8")
        # Same target country + different IP -> skipped because IP一致 is disabled.
        self.stub("curl", "printf 'ip=106.178.149.35\\nloc=JP\\n'")
        res = self.run_core("guard-exit-ip")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.parse_kv(res.stdout).get("status"), "same")
        # Wrong country -> MUST still trigger country_mismatch even with IP一致 disabled!
        self.stub("curl", "printf 'ip=106.178.150.201\\nloc=US\\n'")
        res = self.run_core("guard-exit-ip")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        kv = self.parse_kv(res.stdout)
        self.assertEqual(kv.get("status"), "changed")
        self.assertEqual(kv.get("reason"), "country_mismatch")
        self.assertEqual(kv.get("loc"), "US")
        self.assertEqual(kv.get("target_loc"), "JP")

    def test_unreachable_does_not_false_trigger_or_disconnect(self):
        self.stub("ifconfig", "echo 'inet 198.18.0.1'")
        self.stub("curl", "exit 28")
        main_proc = subprocess.Popen(["/bin/sleep", "30"])
        def cleanup_proc(proc):
            if proc.poll() is None:
                proc.kill()
            proc.wait()
        self.addCleanup(cleanup_proc, main_proc)
        self.process_paths.write_text(
            "321\t/usr/local/bin/sing-box\n"
            f"{main_proc.pid}\t/Applications/Claude.app/Contents/MacOS/Claude\n",
            encoding="utf-8",
        )
        res = self.run_core("guard-exit-ip")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertEqual(self.parse_kv(res.stdout).get("status"), "unreachable")
        self.assertIsNone(main_proc.poll(), "探测超时不能误杀 Claude")


if __name__ == "__main__":
    unittest.main()
