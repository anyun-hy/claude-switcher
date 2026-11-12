"""set-client 回归测试:隔离核心副本,不改动真实安装。"""
from concurrent.futures import ThreadPoolExecutor
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from macos_process_fixture import with_process_paths


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core" / "claude-switch.sh"
GUARD = ROOT / "daemons" / "claude-bodyguard.sh"
TAG_EXE = "/Applications/TAG.app/Contents/Resources/bin/mihomo-universal-tag-darwin"
DESKTOP = "/Applications/Claude.app/Contents/MacOS/Claude"


@unittest.skipUnless(sys.platform == "darwin", "sed -i '' is macOS syntax")
class SetClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.copy = self.root / "core.sh"
        self.guard = self.root / "claude-bodyguard.sh"
        self.guard.write_text('MODE="clash-verge"\n', encoding="utf-8")
        self.fakebin = self.root / "bin"
        self.fakebin.mkdir()
        self.env = dict(os.environ, HOME=str(self.root), PATH=f"{self.fakebin}:/usr/bin:/bin")
        for key in ("BASH_ENV", "ENV"):
            self.env.pop(key, None)
        fake_launchctl = self.fakebin / "launchctl"
        fake_launchctl.write_text("""#!/bin/sh
n=$(cat "$HOME/guard-runs" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$HOME/guard-runs"
printf 'state = not running\\nruns = %s\\nlast exit code = 0\\n' "$n"
""", encoding="utf-8")
        fake_launchctl.chmod(0o755)
        self.stub("sleep", "#!/bin/sh\nexit 0\n")
        self.table = self.root / "processes.tsv"
        self.table.touch()
        self.signals = self.root / "signals"
        self.unsafe_queries = self.root / "unsafe-queries"
        self.env.update(TEST_PROCESS_TABLE=str(self.table), TEST_SIGNALS=str(self.signals),
                        TEST_UNSAFE_QUERIES=str(self.unsafe_queries))
        self.stub("ifconfig", "#!/bin/sh\necho 'inet 198.18.0.1'\n")
        self.stub("kill", '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_SIGNALS"\n')
        for name in ("pgrep", "pkill"):
            self.stub(name, '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_UNSAFE_QUERIES"\nexit 0\n')
        self.stub("ps", r'''#!/bin/sh
case "$1" in
    -p) awk -F '\t' -v pid="$2" '$1 == pid {print $2; found=1} END {exit !found}' "$TEST_PROCESS_TABLE" ;;
    -axww) awk -F '\t' '{print $1, $2, $4}' "$TEST_PROCESS_TABLE" ;;
    *) exit 99 ;;
esac
''')
        source = SCRIPT.read_text(encoding="utf-8")
        source = with_process_paths(source, 'cut -f1,3 "$TEST_PROCESS_TABLE"')
        source = source.replace("/Library/Application Support/claude-switcher/claude-bodyguard.sh", str(self.guard))
        self.copy.write_text(source, encoding="utf-8")

    def run_set(self, mode):
        env = dict(self.env, CLAUDE_SWITCHER_CORE=str(self.copy),
                   HOME=str(self.root), PATH=f"{self.fakebin}:/usr/bin:/bin")
        # Feed the mode over stdin; the installed old guard can match words in argv.
        return subprocess.run(
            ["/bin/bash", "-c", 'IFS= read -r mode; . "$0" set-client "$mode"', str(self.copy)],
            input=mode + "\n", env=env, text=True, capture_output=True, timeout=10)

    def current_mode(self):
        for line in self.copy.read_text(encoding="utf-8").splitlines():
            if line.startswith("PROXY_MODE="):
                return line.split('"')[1]
        return ""

    def test_switches_mode(self):
        for mode in ("shadowrocket", "sing-box", "flclash", "bettbox", "tag", "auto", "clash-verge"):
            result = self.run_set(mode)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.current_mode(), mode)

    def test_rejects_unknown_mode(self):
        before = self.current_mode()
        result = self.run_set("not-a-client")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.current_mode(), before)

    def install_guard(self, mode):
        guard = with_process_paths(
            GUARD.read_text(encoding="utf-8"), 'cut -f1,3 "$TEST_PROCESS_TABLE"')
        guard = guard.replace("__HOME__", str(self.root)).replace("__PROXY_MODE__", mode)
        script = self.root / "installed-bodyguard.sh"
        script.write_text(guard, encoding="utf-8")
        (self.root / "Library" / "Logs").mkdir(parents=True, exist_ok=True)
        self.stub("id", "#!/bin/sh\necho 502\n")
        return script

    def stub(self, name, body):
        path = self.fakebin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def processes(self, *rows):
        self.table.write_text(
            "".join(f"{pid}\t{uid}\t{path}\t{args[0] if args else path}\n"
                    for pid, uid, path, *args in rows), encoding="utf-8")

    def run_guard(self, script):
        return subprocess.run(
            ["/bin/bash", "-c", 'enable -n kill || exit 1; . "$1"', "guard", str(script)],
            env=dict(self.env, TEST_PROBE_ROLE="guard"),
            capture_output=True, text=True, timeout=10)

    def run_detect(self, mode="tag"):
        self.copy.write_text(re.sub(
            r'(?m)^PROXY_MODE="[^"]+"', f'PROXY_MODE="{mode}"',
            self.copy.read_text(encoding="utf-8"), count=1), encoding="utf-8")
        return subprocess.run(
            ["/bin/bash", "-c", 'enable -n kill || exit 1; . "$1" detect-client',
             "core", str(self.copy)], env=dict(self.env, TEST_PROBE_ROLE="core"),
            capture_output=True, text=True, timeout=10)

    def test_known_client_executables_keep_guard_online(self):
        for mode, path in (
            ("flclash", "/Applications/FlClash.app/Contents/Resources/FlClashCore"),
            ("bettbox", "/Applications/Bettbox.app/Contents/Resources/BettboxCore"),
            ("clashx", "/Applications/ClashX Pro.app/Contents/MacOS/ClashX"),
            ("clashx", "/Applications/ClashX Meta.app/Contents/MacOS/ClashX"),
            ("clash-verge", "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo-alpha"),
            ("sing-box", "/opt/homebrew/bin/sing-box"),
            ("surge", "/Applications/Surge.app/Contents/MacOS/Surge"),
        ):
            with self.subTest(mode=mode, path=path):
                self.processes((300, 0, path), (301, 502, DESKTOP),
                               (302, 502, "/usr/local/bin/claude"))
                guard = self.install_guard(mode)
                run = self.run_guard(guard)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertFalse(self.signals.exists(), "代理在线时不能终止桌面或 CLI")

    def test_bodyguard_offline_kills_only_install_user_cli(self):
        script = self.install_guard("clash-verge")
        self.stub("ifconfig", "#!/bin/sh\nprintf ''\n")
        self.stub("id", "#!/bin/sh\necho 0\n")
        self.stub("stat", "#!/bin/sh\necho 4242\n")
        entry = "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        self.processes(
            (101, 4242, "/usr/local/bin/claude"),
            (102, 4242, "/opt/homebrew/bin/node", f"node {entry}"),
            (103, 4242, "/Users/u/.bun/bin/bun", f"bun {entry}"),
            (104, 4242, "/Users/u/wine/drive_c/claude.exe"),
            (105, 4242, "/opt/homebrew/bin/node", "node /Users/u/project/server.js"),
            (110, 4242, "/opt/homebrew/bin/node", f"node /Users/u/project/server.js {entry}"),
            (106, 4242, "/Applications/Claude Switcher.app/Contents/MacOS/ClaudeSwitcher"),
            (107, 0, "/usr/local/bin/claude"),
            (108, 1050, "/opt/homebrew/bin/node", f"node {entry}"),
            (109, 4242, "/bin/bash", f"claude {entry}"),
        )
        run = self.run_guard(script)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.signals.read_text().splitlines(),
                         ["-TERM 101", "-TERM 102", "-TERM 103", "-TERM 104"])
        log = (self.root / "Library/Logs/claude-bodyguard.log").read_text()
        self.assertIn("目标=Claude Code CLI,pid=101,结果=已发送终止信号", log)

    def test_bodyguard_non_root_uses_own_uid(self):
        script = self.install_guard("tag")
        self.stub("stat", "#!/bin/sh\necho 9999\n")
        self.processes((201, 502, "/usr/local/bin/claude"),
                       (202, 9999, "/usr/local/bin/claude"), (203, 502, DESKTOP))
        run = self.run_guard(script)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.signals.read_text().splitlines(), ["-TERM 201", "-TERM 203"])

    def test_installer_offers_bettbox(self):
        install = (ROOT / "installer" / "安装.command").read_text(encoding="utf-8")
        self.assertIn("bettbox", install)
        self.assertIn("/Applications/Bettbox.app", install)

    def test_other_client_detection_includes_bettbox_and_clashx_variants(self):
        self.processes((321, 0, TAG_EXE), (322, 502, "/usr/local/bin/BettboxCore"),
                       (323, 502, "/Applications/ClashX Pro.app/Contents/MacOS/ClashX"))
        run = self.run_detect()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("alive=1\n", run.stdout)
        self.assertIn("others=Bettbox/ClashX\n", run.stdout)

    def test_bettbox_conflict_still_triggers_existing_guard_protection(self):
        script = self.install_guard("flclash")
        self.processes((300, 0, "/usr/local/bin/FlClashCore"),
                       (301, 0, "/usr/local/bin/BettboxCore"), (302, 502, DESKTOP))
        run = self.run_guard(script)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.signals.read_text(), "-TERM 302\n")
        self.assertIn("多代理=bettbox:301",
                      (self.root / "Library/Logs/claude-bodyguard.log").read_text())

    def test_bodyguard_offline_only_signals_verified_desktop_for_install_user(self):
        script = self.install_guard("tag")
        self.processes((301, 502, DESKTOP), (302, 503, DESKTOP),
                       (303, 502, "/bin/bash", f"bash -c {DESKTOP}"),
                       (304, 502, DESKTOP + " Test"))
        run = self.run_guard(script)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.signals.read_text(), "-TERM 301\n")
        log = (self.root / "Library/Logs/claude-bodyguard.log").read_text()
        self.assertIn("代理内核未运行=tag", log)

    def test_detect_client_does_not_signal_or_create_account_state_on_fault(self):
        self.processes((301, 502, DESKTOP), (302, 0, "/usr/local/bin/BettboxCore"))
        self.stub("ifconfig", "#!/bin/sh\nprintf ''\n")
        run = self.run_detect()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stdout.splitlines(),
                         ["configured=tag", "alive=0", "tun_count=0", "others=Bettbox"])
        self.assertFalse(self.signals.exists())
        self.assertFalse((self.root / ".claude-switcher").exists())
        self.assertFalse((self.root / "Library").exists())

    def test_concurrent_checks_ignore_other_checks_and_argv_only_proxy_names(self):
        script = self.install_guard("tag")
        self.processes(
            (321, 0, TAG_EXE), (322, 502, DESKTOP),
            (323, 0, "/usr/bin/pgrep", "pgrep -f FlClashCore"),
            (324, 502, "/usr/bin/pgrep", "pgrep -f FlClashCore"),
            (325, 502, "/bin/sleep", "BettboxCore 2"),
            (326, 502, "/usr/bin/rg", "rg -n verge-mihomo"),
        )
        ready = self.root / "ready"
        ready.mkdir()
        self.env["TEST_PROBE_READY"] = str(ready)
        barrier = r'''
touch "$TEST_PROBE_READY/$TEST_PROBE_ROLE"
for ((try=0; try<300; try++)); do
    if [ -f "$TEST_PROBE_READY/core" ] && [ -f "$TEST_PROBE_READY/guard" ]; then
        cut -f1,3 "$TEST_PROCESS_TABLE"
        return
    fi
    /bin/sleep .01
done
return 99
'''
        for copy in (script, self.copy):
            copy.write_text(with_process_paths(copy.read_text(), barrier))
        with ThreadPoolExecutor(max_workers=2) as pool:
            ui = pool.submit(self.run_detect)
            patrol = pool.submit(self.run_guard, script)
            ui_result, guard_result = ui.result(), patrol.result()
        self.assertEqual(guard_result.returncode, 0, guard_result.stdout + guard_result.stderr)
        self.assertEqual(ui_result.returncode, 0, ui_result.stdout + ui_result.stderr)
        self.assertEqual(ui_result.stdout.splitlines(),
                         ["configured=tag", "alive=1", "tun_count=1", "others=none"])
        self.assertFalse(self.signals.exists())
        self.assertFalse(self.unsafe_queries.exists(), "不得再靠命令行搜索判断冲突")
        self.assertFalse((self.root / "Library/Logs/claude-bodyguard.log").exists())
        self.assertFalse((self.root / ".claude-switcher").exists())

    def test_warns_when_installed_bodyguard_mode_stale(self):
        result = self.run_set("shadowrocket")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.current_mode(), "shadowrocket")
        self.assertIn("WARN:保镖", result.stdout)
        self.assertIn("重新运行安装器", result.stdout)
        self.assertIn('MODE="clash-verge"', self.guard.read_text(encoding="utf-8"))

    def test_no_stale_bodyguard_warning_when_mode_matches(self):
        self.guard.write_text('MODE="shadowrocket"\n', encoding="utf-8")
        result = self.run_set("shadowrocket")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("WARN:保镖", result.stdout)

    def test_gui_set_client_syncs_stale_bodyguard_mode(self):
        self.stub("osascript",
                  f"#!/bin/sh\n/usr/bin/sed -i '' 's/^MODE=\"[^\"]*\"/MODE=\"flclash\"/' '{self.guard}'\n")
        env = dict(self.env, CLAUDE_SWITCHER_CORE=str(self.copy),
                   HOME=str(self.root), PATH=f"{self.fakebin}:/usr/bin:/bin")
        result = subprocess.run(["/bin/bash", str(self.copy), "set-client", "flclash", "--gui"],
                                env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OK:系统保镖守护已同步为 flclash", result.stdout)
        self.assertNotIn("WARN:保镖", result.stdout)
        self.assertIn('MODE="flclash"', self.guard.read_text(encoding="utf-8"))

    def test_fix_syncs_stale_bodyguard_mode(self):
        core = SCRIPT.read_text(encoding="utf-8")
        fix_fn = re.search(r"(?ms)^fix\(\) \{\n.*?^\}", core).group(0)
        self.assertIn("fail:客户端不一致*", fix_fn)
        self.assertIn('/Library/Application Support/claude-switcher/claude-bodyguard.sh', fix_fn)

    def test_gui_set_client_syncs_bettbox_guard_and_keeps_health_gate(self):
        self.stub("osascript",
                  f"#!/bin/sh\n/usr/bin/sed -i '' 's/^MODE=\"[^\"]*\"/MODE=\"bettbox\"/' '{self.guard}'\n")
        env = dict(self.env, CLAUDE_SWITCHER_CORE=str(self.copy))
        result = subprocess.run(["/bin/bash", str(self.copy), "set-client", "bettbox", "--gui"],
                                env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OK:系统保镖守护已同步为 bettbox", result.stdout)
        self.assertNotIn("WARN:保镖", result.stdout)

    def test_guard_status_fails_closed_on_mode_mismatch(self):
        core = self.copy.read_text(encoding="utf-8")
        match = re.search(r"(?ms)^bodyguard_status\(\) \{\n.*?^\}", core)
        self.assertIsNotNone(match, "bodyguard status needs current installed MODE validation")
        self.assertIn('echo "保镖=$(bodyguard_status)"', core)
        cmd = match.group(0) + '\nPROXY_MODE="shadowrocket"\nbodyguard_status\n'
        env = self.env
        run = subprocess.run(["/bin/bash", "-c", cmd], cwd=self.root, env=env,
                             text=True, capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("fail:客户端不一致", run.stdout)
        self.guard.write_text('MODE="shadowrocket"\n', encoding="utf-8")
        ok = subprocess.run(["/bin/bash", "-c", cmd], cwd=self.root, env=env,
                            text=True, capture_output=True, timeout=5)
        self.assertIn("ok:", ok.stdout)


    def test_cli_check_blocks_stale_bodyguard_even_if_launchctl_is_alive(self):
        core = self.copy.read_text(encoding="utf-8")
        guard_fn = re.search(r"(?ms)^bodyguard_status\(\) \{\n.*?^\}", core).group(0)
        check_fn = re.search(r"(?ms)^check\(\) \{\n.*?^\}", core).group(0)
        harness = r"""
PROXY_MODE="shadowrocket"
load_check_config() { return 0; }
COUNTRY_TARGET="US"; TZ_TARGET="America/New_York"; LOCALE_TARGET="en_US"
BASE="$HOME"
proxy_processes() { return 0; }
detect_other_clients() { return 0; }
proxy_alive() { return 0; }
tun_count() { echo 1; }
check_disabled() { return 1; }
curl() { case "$*" in *cdn-cgi/trace*) printf 'ip=198.51.100.2\nloc=US\n' ;; *) printf '403' ;; esac; }
ip_consistency() { echo 'ok:与上次一致'; }
readlink() { echo /var/db/timezone/zoneinfo/America/New_York; }
defaults() { case "$*" in *AppleLocale*) echo en_US ;; *) echo en-US ;; esac; }
networksetup() { echo 'IPv6: off'; }
dig() { echo '198.18.0.1'; }
webrtc_status() { echo 'ok:fixture'; }
route_ok() { return 0; }
"""
        env = self.env
        src = harness + '\n' + guard_fn + '\n' + check_fn + '\ncheck\n'
        fail = subprocess.run(["/bin/bash", "-c", src], env=env, cwd=self.root,
                              text=True, capture_output=True, timeout=6)
        self.assertNotEqual(fail.returncode, 0, fail.stdout + fail.stderr)
        self.assertIn("保镖:客户端不一致", fail.stdout)
        self.guard.write_text('MODE="shadowrocket"\n', encoding="utf-8")
        ok = subprocess.run(["/bin/bash", "-c", src], env=env, cwd=self.root,
                            text=True, capture_output=True, timeout=6)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn("OK:", ok.stdout)

    def test_detect_and_checkdetail_report_multi_tun_and_other_clients_without_modifying_mode(self):
        core = self.copy.read_text(encoding="utf-8")
        checkdetail_fn = re.search(r"(?ms)^checkdetail\(\) \{\n.*?^\}", core).group(0)
        harness = r"""
PROXY_MODE="flclash"
load_check_config() { return 0; }
check_disabled() { return 1; }
optional_result() { echo "$2"; }
client_log_checkdetail() { return 0; }
save_runtime_config() { echo "MUTATED" >&2; exit 99; }
COUNTRY_TARGET="US"; TZ_TARGET="America/New_York"; LOCALE_TARGET="en_US"
BASE="$HOME"
proxy_name() { echo "FlClash"; }
proxy_processes() { return 0; }
detect_other_clients() { echo "TAG"; }
tun_up() { return 1; }
tun_count() { echo 2; }
tun_if() { echo "utun4"; }
curl() { case "$*" in *cdn-cgi/trace*) printf 'ip=198.51.100.2\nloc=US\n' ;; *) printf '403' ;; esac; }
ip_consistency() { echo 'ok:与上次一致'; }
readlink() { echo /var/db/timezone/zoneinfo/America/New_York; }
defaults() { case "$*" in *AppleLocale*) echo en_US ;; *) echo en-US ;; esac; }
networksetup() { echo 'IPv6: off'; }
dig() { echo '198.18.0.1'; }
webrtc_status() { echo 'ok:fixture'; }
bodyguard_status() { echo 'ok:运行中'; }
route_ok() { return 0; }
route_detail() { echo 'ok:fixture'; }
"""
        env = self.env
        # 场景 1: 当前配置的 FlClash 已关闭，但检测到 TAG 运行中，且有 2 个 TUN 网卡
        src_stopped = harness + "\nproxy_alive() { return 1; }\n" + checkdetail_fn + "\ncheckdetail\n"
        res1 = subprocess.run(["/bin/bash", "-c", src_stopped], env=env, cwd=self.root,
                              text=True, capture_output=True, timeout=6)
        self.assertEqual(res1.returncode, 0, res1.stdout + res1.stderr)
        self.assertIn("代理内核=fail:FlClash 未运行(检测到 TAG 运行中,请手动切换客户端或启动 FlClash)", res1.stdout)
        self.assertIn("TUN网卡=fail:检测到多个TUN网卡(2个,请关闭多余VPN软件)", res1.stdout)

        # 场景 2: FlClash 与 TAG 同时运行
        src_both = harness + "\nproxy_alive() { return 0; }\n" + checkdetail_fn + "\ncheckdetail\n"
        res2 = subprocess.run(["/bin/bash", "-c", src_both], env=env, cwd=self.root,
                              text=True, capture_output=True, timeout=6)
        self.assertEqual(res2.returncode, 0, res2.stdout + res2.stderr)
        self.assertIn("代理内核=fail:检测到多个代理软件同时运行(FlClash 与 TAG,请彻底退出多余软件)", res2.stdout)

    def test_bodyguard_kills_claude_when_multiple_tuns_present(self):
        script = self.install_guard("flclash")
        self.stub("ifconfig", "#!/bin/sh\nprintf 'inet 198.18.0.1\\ninet 198.18.0.2\\n'\n")
        self.processes((300, 0, "/usr/local/bin/FlClashCore"), (301, 502, DESKTOP))
        run = self.run_guard(script)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.signals.read_text(), "-TERM 301\n")
        self.assertIn("多TUN=2", (self.root / "Library/Logs/claude-bodyguard.log").read_text())


if __name__ == "__main__":
    unittest.main()
