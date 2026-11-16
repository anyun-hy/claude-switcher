"""Local TAG adaptation checks, with isolated state and commands."""
import io
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

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
        # Exercise the actual full-snapshot path in each script. The core can
        # also accept a PID or a precomputed snapshot for its desktop controls.
        visible_paths = {
            301: TAG_EXE.encode(),
            302: b"/tmp/mihomo-universal-tag-darwin",
            303: b"/Applications/FlClash.app/Contents/Resources/FlClashCore",
            304: b"/Applications/ClashX Pro.app/Contents/MacOS/ClashX Pro",
            305: b"/usr/local/bin/BettboxCore",
        }
        samples = {**visible_paths, 306: None, 307: b"relative/verge-mihomo", 308: b"/tmp/unsafe\n/sing-box"}

        def list_pids(pids, size):
            if pids is not None:
                pids[:len(samples)] = tuple(samples)
            return len(samples)

        def read_path(pid, buffer, size):
            path = samples[pid]
            if path is None:
                return -1
            buffer.value = path
            return len(path)

        kernel = SimpleNamespace(proc_listallpids=list_pids, proc_pidpath=read_path)
        expected_snapshot = b"".join(f"{pid}\t".encode() + path + b"\n" for pid, path in visible_paths.items())
        for script in (SOURCE, GUARD):
            with self.subTest(script=script.name):
                source = script.read_text(encoding="utf-8")
                probe = function(source, "macos_process_paths").split("<<'PY'\n", 1)[1].rsplit("\nPY\n", 1)[0]
                output = io.BytesIO()
                with (patch("ctypes.CDLL", return_value=kernel) as load,
                      patch.object(sys, "argv", ["-"]),
                      patch.object(sys, "stdout", SimpleNamespace(buffer=output)),
                      self.assertRaises(SystemExit) as exit_status):
                    exec(compile(probe, script.name, "exec"), {})
                load.assert_called_once_with("/usr/lib/libproc.dylib")
                self.assertEqual(exit_status.exception.code, 0)
                self.assertEqual(output.getvalue(), expected_snapshot)

                snapshot = self.root / "process-paths.tsv"
                snapshot.write_bytes(output.getvalue())
                source = with_process_paths(source)
                harness = "\n".join(function(source, name) for name in ("macos_process_paths", "proxy_processes", "proxy_seen"))
                harness += '''
observed=$(proxy_processes) || exit 1
proxy_seen "$observed" tag || exit 2
if proxy_seen "$observed" surge; then exit 3; fi
printf '%s\n' "$observed"
'''
                run = subprocess.run(["/bin/bash"], input=harness,
                                     env=dict(self.env, TEST_PROCESS_PATHS=str(snapshot)),
                                     text=True, capture_output=True, timeout=5)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(run.stdout.splitlines(), ["tag\t301", "flclash\t303", "clashx\t304", "bettbox\t305"])

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
    tagv2) echo "/Applications/TAGv2.app/Contents/MacOS/mihomotag-serv" ;;
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
        for mode, expected in (("present", "tag"), ("tagv2", "tag"), ("spoof", "clash-verge")):
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

    def test_tag_ctl_socket_and_mode_queries(self):
        sock_file = self.root / "tag-mock.sock"
        server = MockTagMihomoServer(sock_file)
        self.addCleanup(server.close)
        env = dict(self.env, TAG_SOCKET_PATH=str(sock_file))

        run = subprocess.run(["/bin/bash", str(self.core), "tag-ctl", "socket"],
                             env=env, text=True, capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 0)
        self.assertEqual(run.stdout.strip(), str(sock_file))

        run = subprocess.run(["/bin/bash", str(self.core), "tag-ctl", "mode"],
                             env=env, text=True, capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 0)
        self.assertEqual(run.stdout.strip(), "rule")

        run = subprocess.run(["/bin/bash", str(self.core), "tag-ctl", "set-global"],
                             env=env, text=True, capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 0)
        self.assertEqual(run.stdout.strip(), "OK")
        self.assertEqual(server.mode, "global")

        run = subprocess.run(["/bin/bash", str(self.core), "tag-ctl", "mode"],
                             env=env, text=True, capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 0)
        self.assertEqual(run.stdout.strip(), "global")

    def test_tag_webrtc_and_fix_flow(self):
        sock_file = self.root / "tag-mock-fix.sock"
        server = MockTagMihomoServer(sock_file)
        self.addCleanup(server.close)
        env = dict(self.env, TAG_SOCKET_PATH=str(sock_file), PROXY_MODE="tag",
                   COUNTRY_TARGET="JP", TZ_TARGET="Asia/Tokyo", LOCALE_TARGET="ja_JP")

        cfg = self.home / ".claude-switcher/config.env"
        cfg.parent.mkdir(parents=True, exist_ok=True)
        cfg.write_text('PROXY_MODE="tag"\nPROXY_GROUP="IpEqual"\nCOUNTRY_TARGET="JP"\nTZ_TARGET="Asia/Tokyo"\nLOCALE_TARGET="ja_JP"\n', encoding="utf-8")

        self.stub("sudo", "exit 0")
        self.stub("osascript", "exit 0")
        self.stub("readlink", "echo /var/db/timezone/zoneinfo/Asia/Tokyo")
        self.stub("systemsetup", "echo 'Time Zone: Asia/Tokyo'")
        self.stub("networksetup", "exit 0")
        self.stub("defaults", "echo ja_JP")
        self.stub("sleep", "exit 0")

        # Stub fake curl trace and STUN probe
        self.stub("curl", '''case "$*" in
    *trace*) echo -e "ip=106.178.162.207\\nloc=JP" ;;
    *) echo 200 ;;
esac''')
        # Stub stun-probe.py
        stun_probe = self.home / ".claude-switcher/stun-probe.py"
        stun_probe.parent.mkdir(parents=True, exist_ok=True)
        stun_probe.write_text("print('RESULT:106.178.162.207,106.178.162.207')\n", encoding="utf-8")

        # In rule mode, tag_mode reports rule
        self.assertEqual(server.mode, "rule")

        # Run fix: it should see rule mode, switch it to global, and verify webrtc
        run = subprocess.run(["/bin/bash", str(self.core), "fix"],
                             env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("FIX:TAG 内核处于 rule 模式，正在同步为全局模式防 WebRTC 泄漏...", run.stdout)
        self.assertIn("FIX:TAG 内核已成功同步为全局模式 ✓", run.stdout)
        self.assertIn("FIX:WebRTC ✓ 仅暴露代理出口IP(全局模式)", run.stdout)
        self.assertEqual(server.mode, "global")


class MockTagMihomoServer:
    def __init__(self, sock_path):
        self.sock_path = str(sock_path)
        self.mode = "rule"
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(self.sock_path)
        self.sock.listen(5)
        self.running = True
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while self.running:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                break
            try:
                req = b""
                while b"\r\n\r\n" not in req:
                    chunk = conn.recv(1024)
                    if not chunk:
                        break
                    req += chunk
                header_part, _, body_part = req.partition(b"\r\n\r\n")
                if not header_part:
                    conn.close()
                    continue
                first_line = header_part.splitlines()[0].decode("utf-8", errors="ignore")
                parts = first_line.split(" ")
                method, path = parts[0], parts[1]
                if method == "GET" and path == "/configs":
                    body = json.dumps({"mode": self.mode}).encode("utf-8")
                    resp = (f"HTTP/1.1 200 OK\r\nContent-Length: {len(body)}\r\nContent-Type: application/json\r\n\r\n").encode("utf-8") + body
                    conn.sendall(resp)
                elif method == "PATCH" and path == "/configs":
                    content_length = 0
                    for line in header_part.splitlines():
                        if line.lower().startswith(b"content-length:"):
                            content_length = int(line.split(b":", 1)[1].strip())
                    while len(body_part) < content_length:
                        chunk = conn.recv(1024)
                        if not chunk:
                            break
                        body_part += chunk
                    if body_part:
                        try:
                            payload = json.loads(body_part.decode("utf-8"))
                            if "mode" in payload:
                                self.mode = str(payload["mode"]).lower()
                        except Exception:
                            pass
                    resp = b"HTTP/1.1 204 No Content\r\n\r\n"
                    conn.sendall(resp)
                else:
                    conn.sendall(b"HTTP/1.1 404 Not Found\r\n\r\n")
            except Exception:
                pass
            finally:
                conn.close()

    def close(self):
        self.running = False
        try:
            self.sock.close()
        except OSError:
            pass
        if os.path.exists(self.sock_path):
            try:
                os.unlink(self.sock_path)
            except OSError:
                pass


if __name__ == "__main__":
    unittest.main()
