"""Local TAG adaptation and update boundaries, with isolated state and commands."""
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
GUARD = ROOT / "daemons/claude-bodyguard.sh"
INSTALLER = ROOT / "installer/安装.command"
TAG_EXE = "/Applications/TAG.app/Contents/Resources/bin/mihomo-universal-tag-darwin"


def function(text, name):
    result = re.search(r"(?ms)^" + re.escape(name) + r"\(\) \{\n.*?^\}", text)
    if not result:
        raise AssertionError("missing function " + name)
    return result.group(0)


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
        self.stub("launchctl", "exit 1")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n", encoding="utf-8")
        path.chmod(0o755)

    def run_core(self, *args):
        return subprocess.run(["/bin/bash", str(self.core), *args], env=self.env,
                              text=True, capture_output=True, timeout=30)

    def test_tag_identity_requires_the_real_executable(self):
        self.stub("pgrep", '[ "${FAKE_TAG:-}" = missing ] && exit 1; echo 321')
        self.stub("ps", '''case "$FAKE_TAG" in
            present) echo "$TAG_EXE" ;;
            spoof) echo /usr/bin/other-process ;;
            *) exit 1 ;;
        esac''')
        text = self.core.read_text(encoding="utf-8")
        harness = (function(text, "tag_alive") + "\n" + function(text, "proxy_alive")
                   + '\nPROXY_MODE="tag"\nproxy_alive\n')
        for mode, expected in (("present", 0), ("missing", 1), ("spoof", 1), ("error", 1)):
            with self.subTest(mode=mode):
                env = dict(self.env, FAKE_TAG=mode, TAG_EXE=TAG_EXE)
                run = subprocess.run(["/bin/bash", "-c", harness], env=env,
                                     text=True, capture_output=True, timeout=5)
                self.assertEqual(run.returncode, expected, run.stdout + run.stderr)

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
        guard = self.root / "guard.sh"
        guard.write_text('MODE="tag"\n')
        text = self.core.read_text(encoding="utf-8").replace(
            "/Library/Application Support/claude-switcher/claude-bodyguard.sh", str(guard))
        harness = (function(text, "bodyguard_status")
                   + '\nlaunchctl() { return 0; }\nPROXY_MODE=tag\nbodyguard_status\n')
        run = subprocess.run(["/bin/bash", "-c", harness], env=self.env,
                             text=True, capture_output=True, timeout=5)
        self.assertIn("ok:", run.stdout)
        guard.write_text('MODE="clash-verge"\n')
        run = subprocess.run(["/bin/bash", "-c", harness], env=self.env,
                             text=True, capture_output=True, timeout=5)
        self.assertIn("fail:客户端不一致", run.stdout)

    def test_direct_and_automatic_updates_do_not_overwrite_adapter(self):
        self.stub("curl", 'echo invoked >> "$HOME/curl-called"; exit 1')
        old = self.core.read_bytes()
        backup = self.core.with_suffix(".sh.bak")
        backup.write_text("existing file")
        for mode in ("tag", "clash-verge"):
            self.core.write_bytes(old.replace(b'PROXY_MODE="tag"', ('PROXY_MODE="' + mode + '"').encode(), 1))
            before = self.core.read_bytes()
            for args in (("update",), ("update", "--auto"), ("update", "--unknown")):
                with self.subTest(mode=mode, args=args):
                    run = self.run_core(*args)
                    self.assertNotEqual(run.returncode, 0)
                    self.assertIn("不能直接安装原版更新", run.stdout)
                    self.assertNotIn("unbound variable", run.stdout + run.stderr)
                    self.assertEqual(self.core.read_bytes(), before)
                    self.assertEqual(backup.read_text(), "existing file")
                    self.assertFalse((self.home / "curl-called").exists())

    def prepare_remote(self, content, manifest="valid"):
        archive = self.root / "remote.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("claude-switcher-main/core/claude-switch.sh", content)
        sums = self.root / "SHA256SUMS"
        if manifest == "missing-core":
            sums.write_text(hashlib.sha256(b"other").hexdigest() + "  other.txt\n")
            with zipfile.ZipFile(archive, "a") as output:
                output.writestr("claude-switcher-main/other.txt", b"other")
        else:
            digest = hashlib.sha256(content if manifest == "valid" else b"wrong").hexdigest()
            sums.write_text(digest + "  core/claude-switch.sh\n")
        self.env.update(FIXTURE_ARCHIVE=str(archive), FIXTURE_SUMS=str(sums))
        self.stub("curl", '''out=""; url=""
while [ "$#" -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac
done
case "$url" in
    *codeload.github.com*) cp "$FIXTURE_ARCHIVE" "$out" ;;
    *raw.githubusercontent.com*) cp "$FIXTURE_SUMS" "$out" ;;
    *) exit 1 ;;
esac''')

    def test_update_check_compares_verified_upstream_core(self):
        upstream = b"#!/bin/bash\n# synthetic upstream core\n"
        source = self.core.read_text(encoding="utf-8")
        source, count = re.subn(r'(?m)^TAG_UPSTREAM_CORE_SHA256="[0-9a-f]{64}"$',
                                'TAG_UPSTREAM_CORE_SHA256="' + hashlib.sha256(upstream).hexdigest() + '"',
                                source, count=1)
        self.assertEqual(count, 1)
        self.core.write_text(source, encoding="utf-8")
        before = self.core.read_bytes()
        for content, manifest, expected, success in (
            (upstream, "valid", "基线一致", True),
            (upstream + b"\n# new upstream\n", "valid", "上游核心有变化", True),
            (upstream, "wrong", "校验失败", False),
            (upstream, "missing-core", "校验失败", False),
        ):
            with self.subTest(manifest=manifest, success=success):
                self.prepare_remote(content, manifest)
                for args in (("update-check",), ("update", "--check")):
                    with self.subTest(args=args):
                        run = self.run_core(*args)
                        self.assertEqual(run.returncode == 0, success, run.stdout + run.stderr)
                        self.assertIn(expected, run.stdout)
                        self.assertEqual(self.core.read_bytes(), before)
                        self.assertFalse(self.core.with_suffix(".sh.bak").exists())

    def test_guard_accepts_tag_and_fails_closed_for_missing_or_spoofed_process(self):
        marker = self.home / "kill-called"
        (self.home / "Library/Logs").mkdir(parents=True)
        self.env.update(FAKE_TAG="present", FAKE_TUN="up", TAG_EXE=TAG_EXE,
                        KILL_MARKER=str(marker))
        self.stub("ifconfig", '[ "$FAKE_TUN" = up ] && echo "inet 198.18.0.1"')
        self.stub("pgrep", '''case "$*" in
    *mihomo-universal-tag-darwin*) [ "$FAKE_TAG" = missing ] && exit 1; echo 321 ;;
    *Claude.app*) echo 654 ;;
    *) exit 1 ;;
esac''')
        self.stub("ps", '''case "$FAKE_TAG" in
    present) echo "$TAG_EXE" ;;
    spoof) echo /usr/bin/other-process ;;
    *) exit 1 ;;
esac''')
        self.stub("pkill", 'printf called > "$KILL_MARKER"')
        guard = self.root / "guard.sh"
        guard.write_text(GUARD.read_text(encoding="utf-8").replace("__HOME__", str(self.home))
                         .replace("__PROXY_MODE__", "tag"), encoding="utf-8")
        for mode, tun, should_close in (("present", "up", False), ("missing", "up", True),
                                        ("spoof", "up", True), ("present", "down", True)):
            with self.subTest(mode=mode, tun=tun):
                if marker.exists():
                    marker.unlink()
                env = dict(self.env, FAKE_TAG=mode, FAKE_TUN=tun)
                run = subprocess.run(["/bin/bash", str(guard)], env=env, text=True,
                                     capture_output=True, timeout=5)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertEqual(marker.exists(), should_close)

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
        code = text[start:end] + '\nprintf "selected=%s\\n" "$MODE"\n'
        env = dict(self.env, H=str(self.home), TAG_EXE=TAG_EXE)
        clash = self.home / "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
        clash.mkdir(parents=True)
        for mode, expected in (("present", "tag"), ("spoof", "clash-verge")):
            with self.subTest(mode=mode):
                run = subprocess.run(["/bin/bash", "-c", code], env=dict(env, FAKE_TAG=mode),
                                     text=True, capture_output=True, timeout=5)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertIn("selected=" + expected, run.stdout)
        clash.rmdir()
        run = subprocess.run(["/bin/bash", "-c", code], env=dict(env, FAKE_TAG="missing"),
                             input="8\n", text=True, capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("selected=tag", run.stdout)


if __name__ == "__main__":
    unittest.main()
