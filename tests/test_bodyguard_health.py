"""Bodyguard liveness uses isolated scripts and fake launchd/process commands."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from macos_process_fixture import with_process_paths

ROOT = Path(__file__).resolve().parents[1]
CORE = (ROOT / "core/claude-switch.sh").read_text(encoding="utf-8")
DAEMON = (ROOT / "daemons/claude-bodyguard.sh").read_text(encoding="utf-8")
NOW = 2_000_000_000


def function(name):
    return re.search(r"(?ms)^" + name + r"\(\) \{\n.*?^\}", CORE).group(0)


class BodyguardHealthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bodyguard-health-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.guard = self.root / "guard.sh"
        self.guard.write_text('MODE="tag"\nHEALTH_SCHEMA=1\n')
        self.heartbeat = self.root / "claude-bodyguard-health"
        self.env = dict(os.environ, HOME=str(self.root), TEST_ROOT=str(self.root),
                        PATH=f"{self.bin}:/usr/bin:/bin", PROXY_MODE="tag")
        for key in ("BASH_ENV", "ENV"):
            self.env.pop(key, None)
        self.stub("launchctl", '''n=$(cat "$TEST_ROOT/counter" 2>/dev/null || echo 0)
echo $((n + 1)) > "$TEST_ROOT/counter"
file="$TEST_ROOT/launch-$n"
[ -f "$file" ] || file="$TEST_ROOT/launch-last"
[ "$(cat "$file")" != UNAVAILABLE ] || exit 1
cat "$file"''')
        self.stub("sleep", "exit 0")
        self.stub("stat", 'cat "$TEST_ROOT/attributes"')
        self.stub("date", f"echo {NOW}")
        (self.root / "attributes").write_text("0:644\n")
        self.snapshots(self.snapshot())

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    @staticmethod
    def snapshot(runs=20, state="not running", code=0):
        return f"state = {state}\nruns = {runs}\nlast exit code = {code}\n"

    def snapshots(self, *values):
        for path in self.root.glob("launch-*"):
            path.unlink()
        (self.root / "counter").unlink(missing_ok=True)
        for index, value in enumerate(values):
            (self.root / f"launch-{index}").write_text(value)
        (self.root / "launch-last").write_text(values[-1])

    def record(self, *, stamp=NOW - 2, mode="tag", result="ok"):
        self.heartbeat.write_text(f"schema=1\ntime={stamp}\nmode={mode}\nresult={result}\n")

    def status(self):
        source = function("bodyguard_status").replace(
            "/Library/Application Support/claude-switcher/claude-bodyguard.sh", str(self.guard))
        run = subprocess.run(["/bin/bash", "-c", source + "\nbodyguard_status\n"],
                             env=self.env, text=True, capture_output=True, timeout=8)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stderr, "")
        return run.stdout.strip()

    def test_recent_completion_passes_even_while_between_scheduled_runs(self):
        self.record()
        self.assertEqual(self.status(), "ok:巡检在线（2秒前完成）")

    def test_offline_or_nonzero_exit_cannot_pass_with_fresh_heartbeat(self):
        self.record()
        for snapshot, expected in (("UNAVAILABLE", "保镖离线"),
                                   (self.snapshot(code=1), "退出码 1")):
            with self.subTest(snapshot=snapshot):
                self.snapshots(snapshot)
                self.assertIn(expected, self.status())
                self.assertTrue(self.status().startswith("fail:"))

    def test_missing_stale_future_and_wrong_client_heartbeats_fail(self):
        self.assertTrue(self.status().startswith("fail:"))
        for values in ({"stamp": NOW - 31}, {"stamp": NOW + 1}, {"mode": "flclash"}):
            with self.subTest(values=values):
                self.record(**values)
                self.assertTrue(self.status().startswith("fail:"))

    def test_failure_and_malformed_records_fail_closed(self):
        self.record(result="error")
        self.assertIn("保护操作失败", self.status())
        for text in ("schema=1\ntime=nope\nmode=tag\nresult=ok\n",
                     "schema=2\ntime=2000000000\nmode=tag\nresult=ok\n",
                     "schema=1=extra\ntime=2000000000\nmode=tag\nresult=ok\n",
                     "schema=1\ntime=2000000000\nmode=tag\nresult=ok\nextra=ok\n",
                     "schema=1\ntime=2000000000\nmode=tag\nmode=tag\n"):
            with self.subTest(record=text):
                self.heartbeat.write_text(text)
                self.assertIn("fail:保镖巡检记录无效", self.status())

    def test_heartbeat_must_be_regular_root_owned_and_not_writable_by_user(self):
        self.record()
        for attributes in ("501:644", "0:664", "0:600"):
            with self.subTest(attributes=attributes):
                (self.root / "attributes").write_text(attributes + "\n")
                self.assertIn("fail:保镖巡检记录权限异常", self.status())
        self.heartbeat.unlink()
        self.heartbeat.symlink_to(self.guard)
        self.assertIn("fail:保镖巡检记录类型异常", self.status())

    def test_missing_record_can_recover_during_readonly_observation(self):
        self.stub("sleep", '''printf 'schema=1\ntime=2000000000\nmode=tag\nresult=ok\n' > "$TEST_ROOT/claude-bodyguard-health"''')
        self.assertTrue(self.status().startswith("ok:巡检在线"))

    def test_legacy_guard_requires_new_successful_completion(self):
        self.guard.write_text('MODE="tag"\n')
        self.snapshots(self.snapshot(), self.snapshot(runs=21, state="running"),
                       self.snapshot(runs=21))
        self.assertIn("ok:巡检在线（本轮执行成功；兼容旧保镖）", self.status())
        for snapshots in ((self.snapshot(),),
                          (self.snapshot(), self.snapshot(runs=21, state="running")),
                          (self.snapshot(), self.snapshot(runs=19)),
                          ("state = not running\n",),
                          (self.snapshot(), "UNAVAILABLE")):
            with self.subTest(snapshots=snapshots):
                self.snapshots(*snapshots)
                self.assertTrue(self.status().startswith("fail:"))

    def test_historical_event_is_separate_and_sanitized(self):
        log = self.root / "Library/Logs/claude-bodyguard.log"
        log.parent.mkdir(parents=True)
        for suffix, visible in (("代理离线(内核或TUN丢失),已自动关闭 Claude", True),
                                ("检测到代理/TUN状态变化(203.0.113.10),已自动关闭 Claude", True),
                                ("arbitrary token=SECRET 203.0.113.10", False)):
            with self.subTest(suffix=suffix):
                log.write_text("2026-11-07 01:19:15 " + suffix + "\n")
                run = subprocess.run(["/bin/bash", "-c", function("bodyguard_last_event")
                                      + "\nbodyguard_last_event\n"], env=self.env,
                                     text=True, capture_output=True, timeout=3)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(bool(run.stdout), visible)
                self.assertNotIn("203.0.113.10", run.stdout)
                self.assertNotIn("SECRET", run.stdout)
                if visible:
                    self.assertTrue(run.stdout.startswith("#保镖事件=2026-11-07 01:19:15 "))

    def test_daemon_publishes_completion_and_failure_only_beside_fixture(self):
        source = with_process_paths(DAEMON, r"printf '654\t/bin/sleep\n'")
        self.guard.write_text(source.replace("__HOME__", str(self.root))
                              .replace("__PROXY_MODE__", "flclash"))
        self.stub("id", "echo 501")
        self.stub("pgrep", "exit 1")
        self.stub("ps", "exit 0")
        self.stub("pkill", "exit 99")
        self.stub("kill", "exit 99")
        for ifconfig, expected in (("echo 'inet 192.0.2.1'", "ok"),
                                   ("exit 1", "error")):
            with self.subTest(result=expected):
                self.stub("ifconfig", ifconfig)
                # Sourcing also checks BASH_SOURCE keeps output beside the fixture.
                run = subprocess.run(["/bin/bash", "-c", 'enable -n kill; . "$1"',
                                      "fixture", str(self.guard)], env=self.env, cwd=self.bin,
                                     text=True, capture_output=True, timeout=3)
                self.assertEqual(run.returncode, 0 if expected == "ok" else 1, run.stderr)
                self.assertEqual(self.heartbeat.read_text(),
                                 f"schema=1\ntime={NOW}\nmode=flclash\nresult={expected}\n")
                self.assertEqual(self.heartbeat.stat().st_mode & 0o777, 0o644)
                self.assertFalse((self.bin / "claude-bodyguard-health").exists())
                self.assertEqual(list(self.root.glob(".claude-bodyguard-health.*")), [])

    def test_failed_enforcement_publishes_error_instead_of_healthy_heartbeat(self):
        source = with_process_paths(
            DAEMON, r"printf '654\t/Applications/Claude.app/Contents/MacOS/Claude\n'")
        self.guard.write_text(source.replace("__HOME__", str(self.root))
                              .replace("__PROXY_MODE__", "flclash"))
        (self.root / "Library/Logs").mkdir(parents=True)
        self.stub("id", "echo 501")
        self.stub("ifconfig", "echo 'inet 192.0.2.1'")
        self.stub("ps", '''case "$1" in -p) echo 501 ;; *) echo '654 501 Claude' ;; esac''')
        self.stub("pkill", "exit 99")
        self.stub("kill", "exit 1")
        run = subprocess.run(["/bin/bash", "-c", 'enable -n kill; . "$1"',
                              "fixture", str(self.guard)], env=self.env,
                             text=True, capture_output=True, timeout=3)
        self.assertEqual(run.returncode, 1, run.stderr)
        self.assertIn("result=error\n", self.heartbeat.read_text())
        self.assertIn("目标=Claude,pid=654,结果=发送失败",
                      (self.root / "Library/Logs/claude-bodyguard.log").read_text())


if __name__ == "__main__":
    unittest.main()
