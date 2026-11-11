"""Local TAG adaptation checks, with isolated state and commands."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from macos_process_fixture import shell_function as function, with_process_paths

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"
GUARD = ROOT / "daemons/claude-bodyguard.sh"
INSTALLER = ROOT / "installer/安装.command"
TAG_EXE = "/Applications/TAG.app/Contents/Resources/bin/mihomo-universal-tag-darwin"


class TagAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tag-adapter-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        self.core = self.home / ".local/bin/claude-switch.sh"
        self.core.parent.mkdir(parents=True)
        source = SOURCE.read_text(encoding="utf-8")
        source, count = re.subn(r'(?m)^PROXY_MODE="clash-verge"', 'PROXY_MODE="tag"', source, count=1)
        self.assertEqual(count, 1)
        self.core.write_text(source, encoding="utf-8")
        self.core.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        CLAUDE_SWITCHER_PYTHON=sys.executable)
        # Non-interactive Bash can source BASH_ENV and silently replace PATH.
        self.env.pop("BASH_ENV", None)
        self.env.pop("ENV", None)
        self.stub("launchctl", "exit 1")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n", encoding="utf-8")
        path.chmod(0o755)

    def run_core(self, *args):
        return subprocess.run(["/bin/bash", str(self.core), *args], env=self.env,
                              text=True, capture_output=True, timeout=30)

    def test_tag_identity_and_auto_mode_require_the_real_executable(self):
        text = with_process_paths(self.core.read_text(encoding="utf-8"), r'''
case "$FAKE_TAG" in
    present) printf '321\t%s\n' "$TAG_EXE" ;;
    spoof) printf '321\t/tmp/mihomo-universal-tag-darwin\n' ;;
    missing) printf '321\t/usr/bin/other-process\n' ;;
    *) return 1 ;;
esac
''')
        harness = "\n".join(function(text, name) for name in (
            "macos_process_paths", "proxy_processes", "proxy_seen", "proxy_alive"))
        harness += "\nshadowrocket_up() { return 1; }\nproxy_alive\n"
        for client in ("tag", "auto"):
            for mode, expected in (("present", 0), ("missing", 1), ("spoof", 1), ("error", 1)):
                with self.subTest(client=client, mode=mode):
                    env = dict(self.env, FAKE_TAG=mode, TAG_EXE=TAG_EXE, PROXY_MODE=client)
                    run = subprocess.run(["/bin/bash"], input=harness, env=env,
                                         text=True, capture_output=True, timeout=5)
                    self.assertEqual(run.returncode, expected, run.stdout + run.stderr)

    def test_core_and_guard_use_the_same_process_identity_rules(self):
        core = SOURCE.read_text(encoding="utf-8")
        guard = GUARD.read_text(encoding="utf-8")
        for name in ("macos_process_paths", "proxy_processes", "proxy_seen"):
            self.assertEqual(function(core, name), function(guard, name))

    def test_client_discovery_reports_tag(self):
        run = self.run_core("get-client")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("client=tag", run.stdout)
        self.assertIn("clients=tag,clash-verge,flclash", run.stdout)

    @unittest.skipUnless(sys.platform == "darwin", "macOS sed syntax")
    def test_switching_client_recognizes_tag_and_rejects_unknown(self):
        self.env["CLAUDE_SWITCHER_CORE"] = str(self.core)
        for mode in ("flclash", "tag"):
            run = self.run_core("set-client", mode)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('PROXY_MODE="' + mode + '"', self.core.read_text())
        before = self.core.read_bytes()
        run = self.run_core("set-client", "invalid")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(self.core.read_bytes(), before)

    def test_guard_mode_mismatch_cannot_pass(self):
        self.stub("launchctl", '''n=$(cat "$HOME/runs" 2>/dev/null || echo 0)
n=$((n + 1)); echo "$n" > "$HOME/runs"
printf 'state = not running\\nruns = %s\\nlast exit code = 0\\n' "$n"''')
        self.stub("sleep", "exit 0")
        guard = self.root / "guard.sh"
        guard.write_text('MODE="tag"\n')
        text = self.core.read_text(encoding="utf-8").replace(
            "/Library/Application Support/claude-switcher/claude-bodyguard.sh", str(guard))
        harness = (function(text, "bodyguard_status")
                   + '\nPROXY_MODE=tag\nbodyguard_status\n')
        run = subprocess.run(["/bin/bash", "-c", harness], env=self.env,
                             text=True, capture_output=True, timeout=5)
        self.assertIn("ok:", run.stdout)
        guard.write_text('MODE="clash-verge"\n')
        run = subprocess.run(["/bin/bash", "-c", harness], env=self.env,
                             text=True, capture_output=True, timeout=5)
        self.assertIn("fail:客户端不一致", run.stdout)

    def test_guard_accepts_tag_and_fails_closed_for_missing_or_spoofed_process(self):
        marker = self.home / "kill-called"
        (self.home / "Library/Logs").mkdir(parents=True)
        self.env.update(FAKE_TAG="present", FAKE_TUN="up", TAG_EXE=TAG_EXE,
                        KILL_MARKER=str(marker))
        self.stub("ifconfig", 'if [ "$FAKE_TUN" = up ]; then echo "inet 198.18.0.1"; fi')
        self.stub("id", "echo 501")
        self.stub("ps", '''case "$1" in
    -p) echo 501 ;;
    *) echo '654 501 Claude' ;;
esac''')
        self.stub("kill", 'printf "%s\n" "$*" > "$KILL_MARKER"')
        self.stub("pkill", 'printf unexpected > "$KILL_MARKER"; exit 99')
        guard = self.root / "guard.sh"
        source = with_process_paths(GUARD.read_text(encoding="utf-8"), r'''
case "$FAKE_TAG" in
    present) printf '321\t%s\n' "$TAG_EXE" ;;
    spoof) printf '321\t/tmp/mihomo-universal-tag-darwin\n' ;;
esac
printf '654\t/Applications/Claude.app/Contents/MacOS/Claude\n'
''')
        guard.write_text(source.replace("__HOME__", str(self.home)).replace("__PROXY_MODE__", "tag"),
                         encoding="utf-8")
        for mode, tun, should_close in (("present", "up", False), ("missing", "up", True),
                                        ("spoof", "up", True), ("present", "down", True)):
            with self.subTest(mode=mode, tun=tun):
                if marker.exists():
                    marker.unlink()
                env = dict(self.env, FAKE_TAG=mode, FAKE_TUN=tun)
                run = subprocess.run(["/bin/bash", "-c", 'enable -n kill || exit 1; . "$1"',
                                      "guard", str(guard)], env=env, text=True,
                                     capture_output=True, timeout=5)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertEqual(marker.exists(), should_close)
                if should_close:
                    self.assertEqual(marker.read_text(), "-TERM 654\n")

    def test_installer_recognizes_only_a_real_tag_process_and_accepts_manual_tag(self):
        self.stub("pgrep", '[ "$FAKE_TAG" = missing ] && exit 1; echo 321')
        self.stub("ps", '''case "$FAKE_TAG" in
    present) echo "$TAG_EXE" ;;
    spoof) echo /usr/bin/other-process ;;
    *) exit 1 ;;
esac''')
        self.stub("scutil", "exit 1")
        text = INSTALLER.read_text(encoding="utf-8")
        start = text.index('CLASH_DIR="$H/Library/Application Support/')
        end = text.index('echo "✓ 代理客户端: $MODE"', start)
        code = text[start:end].replace("/Applications/Bettbox.app", str(self.root / "Bettbox.app"))
        code += '\nprintf "selected=%s\\n" "$MODE"\n'
        env = dict(self.env, H=str(self.home), TAG_EXE=TAG_EXE)
        clash = self.home / "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
        clash.mkdir(parents=True)
        for mode, expected in (("present", "tag"), ("spoof", "clash-verge")):
            with self.subTest(mode=mode):
                run = subprocess.run(["/bin/bash"], input=code, env=dict(env, FAKE_TAG=mode),
                                     text=True, capture_output=True, timeout=5)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertIn("selected=" + expected, run.stdout)
        clash.rmdir()
        # Read the harness from a file so its prompt can use stdin.
        fixture = self.root / "installer-detection.sh"
        fixture.write_text(code, encoding="utf-8")
        run = subprocess.run(["/bin/bash", str(fixture)], env=dict(env, FAKE_TAG="missing"),
                             input="8\n", text=True, capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("selected=tag", run.stdout)
        run = subprocess.run(["/bin/bash", "-c", code], env=dict(env, FAKE_TAG="missing"),
                             input="9\n", text=True, capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("selected=bettbox", run.stdout)
        (self.root / "Bettbox.app").mkdir()
        run = subprocess.run(["/bin/bash", "-c", code], env=dict(env, FAKE_TAG="missing"),
                             text=True, capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("selected=bettbox", run.stdout)


if __name__ == "__main__":
    unittest.main()
