"""Optional checks and privacy-safe client diagnostics, using isolated fixtures only."""
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"
OPTIONAL = ("IP一致", "DNS", "WebRTC", "客户端语言", "ASN属性", "生态可达性")


class OptionalLoggingTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="optional-logging-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        self.base = self.home / ".claude-switcher"
        self.base.mkdir()
        self.settings = self.base / "checks.json"
        self.core = Path(self.tmp.name) / "claude-switch.sh"
        text = SOURCE.read_text(encoding="utf-8")
        text = text.replace('PROXY_MODE="clash-verge"', 'PROXY_MODE="sing-box"', 1)
        self.core.write_text(text, encoding="utf-8")
        self.core.chmod(0o755)
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.calls = Path(self.tmp.name) / "calls"
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        CLAUDE_SWITCHER_PYTHON=sys.executable, PYTHONUTF8="1")

    def support(self, *args, input_text=None):
        return subprocess.run(
            ["/bin/bash", str(self.core), "_support", *args], input=input_text,
            text=True, encoding="utf-8", capture_output=True, env=self.env, timeout=10)

    def write_settings(self, value):
        self.settings.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nprintf '%s\\n' '" + name + "' >>'" +
                        str(self.calls) + "'\n" + body + "\n", encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def prepare_checkdetail(self):
        self.stub("pgrep", "exit 0")
        self.stub("ifconfig", "echo 'inet 198.18.0.1'")
        self.stub("curl", '''case "$*" in
  *cdn-cgi/trace*) printf 'ip=203.0.113.10\\nloc=US\\n' ;;
  *ipinfo.io*) printf '{\"org\":\"Example Residential\"}' ;;
  *claude.ai*|*api.anthropic.com*) printf '200' ;;
esac''')
        self.stub("dig", "echo 198.18.0.2")
        self.stub("readlink", "echo /var/db/timezone/zoneinfo/America/New_York")
        self.stub("defaults", '''if [[ "$*" == *AppleLocale* ]]; then echo en_US; else printf '(\\n    en-US,\\n)'; fi''')
        self.stub("networksetup", "echo 'IPv6: Off'")
        self.stub("python3", "echo RESULT:203.0.113.10")
        self.stub("launchctl", "exit 1")

    def test_settings_validate_allowlist_and_booleans(self):
        for value in ({"disabled": ["出口IP"]}, {"disabled": ["保镖"]},
                      {"disabled": ["unknown"]}, {"allowOptionalFailures": "yes"},
                      {"logging": 1}, {"unknown": True}, {"disabled": "DNS"}):
            with self.subTest(value=value):
                self.write_settings(value)
                run = self.support("config")
                self.assertNotEqual(run.returncode, 0)
                self.assertNotIn("203.0.113", run.stdout + run.stderr)

    def test_config_set_is_atomic_and_normalizes_optional_names(self):
        run = self.support("config-set", json.dumps(
            {"disabled": ["DNS"], "allowOptionalFailures": True, "logging": False}))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads(self.settings.read_text(encoding="utf-8")),
                         {"disabled": ["DNS"], "allowOptionalFailures": True, "logging": False})
        self.assertEqual(stat.S_IMODE(self.settings.stat().st_mode), 0o600)
        run = self.support("config")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("DNS", run.stdout)
        self.assertIn("allowOptionalFailures=1", run.stdout)
        self.assertIn("logging=0", run.stdout)

    def test_disabled_checks_skip_probes_and_never_report_ok(self):
        self.prepare_checkdetail()
        self.write_settings({"disabled": ["DNS", "WebRTC", "ASN属性", "生态可达性"],
                             "allowOptionalFailures": False, "logging": True})
        run = subprocess.run(["/bin/bash", str(self.core), "checkdetail"],
                             text=True, capture_output=True, env=self.env, timeout=10)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        for name in ("DNS", "WebRTC", "ASN属性", "生态可达性"):
            self.assertIn(name + "=skip:用户已禁用", run.stdout)
        calls = self.calls.read_text(encoding="utf-8") if self.calls.exists() else ""
        self.assertNotIn("python3", calls)
        self.assertEqual(len(re.findall(r"(?m)^dig$", calls)), 3,
                         "三次 dig 应全部来自不可关闭的规则置顶检查")
        curl_count = len(re.findall(r"(?m)^curl$", calls))
        self.assertEqual(curl_count, 1, "禁用 ASN 与生态检查后只应探测出口")

    def test_all_six_optional_names_are_accepted(self):
        self.write_settings({"disabled": list(OPTIONAL)})
        run = self.support("config")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        for name in OPTIONAL:
            self.assertIn(name, run.stdout)

    def test_client_log_has_operation_metadata_but_no_sensitive_detail(self):
        run = self.support("log", "checkdetail", "1", "123", "DNS=fail WebRTC=skip")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        log = self.home / "Library/Logs/claude-switcher/client.log"
        text = log.read_text(encoding="utf-8")
        self.assertIn("command=checkdetail", text)
        self.assertIn("exit=1", text)
        self.assertIn("duration_ms=123", text)
        self.assertIn("DNS=fail WebRTC=skip", text)
        self.assertRegex(text, r"version=")
        for secret in ("203.0.113.10", "Bearer", "token", "session", "cookie"):
            self.assertNotIn(secret, text)

    def test_log_rejects_sensitive_or_malformed_fields(self):
        for summary in ("IP=203.0.113.10", "token=abc", "session=abc", "cookie=abc",
                        "DNS=fail;rm", "DNS=unknown"):
            with self.subTest(summary=summary):
                run = self.support("log", "checkdetail", "1", "123", summary)
                self.assertNotEqual(run.returncode, 0)

    def test_logging_can_be_disabled_and_rotates(self):
        self.write_settings({"logging": False})
        self.assertEqual(self.support("log", "status", "0", "1", "").returncode, 0)
        log = self.home / "Library/Logs/claude-switcher/client.log"
        self.assertFalse(log.exists())
        self.write_settings({"logging": True})
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text("x" * (512 * 1024), encoding="utf-8")
        self.assertEqual(self.support("log", "status", "0", "1", "").returncode, 0)
        self.assertLessEqual(log.stat().st_size, 512 * 1024)
        self.assertTrue((log.parent / "client.log.1").exists())

    def test_allow_optional_failures_warns_only_for_allowlisted_checks(self):
        self.prepare_checkdetail()
        self.write_settings({"allowOptionalFailures": True, "logging": True})
        (self.base / "lastip").write_text("192.0.2.1", encoding="utf-8")
        self.stub("curl", '''case "$*" in
  *cdn-cgi/trace*) printf 'ip=203.0.113.10\\nloc=US\\n' ;;
  *ipinfo.io*) printf '' ;;
  *claude.ai*|*api.anthropic.com*) printf '000' ;;
esac''')
        self.stub("dig", "printf ''")
        self.stub("python3", "printf ''")
        self.stub("defaults", "echo zh_CN")
        run = subprocess.run(["/bin/bash", str(self.core), "checkdetail"],
                             text=True, capture_output=True, env=self.env, timeout=10)
        for name in OPTIONAL:
            self.assertRegex(run.stdout, rf"(?m)^{re.escape(name)}=warn:")
            self.assertNotRegex(run.stdout, rf"(?m)^{re.escape(name)}=fail:")
        self.assertIn("保镖=fail:", run.stdout)

    def test_hard_security_failures_remain_blocking_when_optional_failures_allowed(self):
        self.prepare_checkdetail()
        self.write_settings({"allowOptionalFailures": True, "logging": True})
        self.stub("pgrep", "exit 1")
        self.stub("ifconfig", "printf ''")
        self.stub("curl", "printf 'ip=203.0.113.10\\nloc=CN\\n'")
        run = subprocess.run(["/bin/bash", str(self.core), "checkdetail"],
                             text=True, capture_output=True, env=self.env, timeout=10)
        for name in ("代理内核", "TUN网卡", "出口IP", "保镖"):
            self.assertRegex(run.stdout, rf"(?m)^{re.escape(name)}=fail:")
        silent = subprocess.run(["/bin/bash", str(self.core), "check"],
                                text=True, capture_output=True, env=self.env, timeout=10)
        self.assertNotEqual(silent.returncode, 0)

    def test_invalid_config_fails_closed_for_silent_gate(self):
        self.prepare_checkdetail()
        self.write_settings({"disabled": ["出口IP"]})
        run = subprocess.run(["/bin/bash", str(self.core), "check"],
                             text=True, capture_output=True, env=self.env, timeout=10)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("检查配置无效", run.stdout)
        self.assertFalse(self.calls.exists(), "无效配置必须在任何网络探测前阻断")

    def test_checkdetail_log_discards_ip_and_other_details(self):
        self.prepare_checkdetail()
        run = subprocess.run(["/bin/bash", str(self.core), "checkdetail"],
                             text=True, capture_output=True, env=self.env, timeout=10)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        log = (self.home / "Library/Logs/claude-switcher/client.log").read_text(encoding="utf-8")
        self.assertIn("command=checkdetail", log)
        self.assertIn("出口IP=ok", log)
        self.assertIn("DNS=ok", log)
        for detail in ("203.0.113.10", "198.18.0.2", "Example Residential", "走隧道"):
            self.assertNotIn(detail, log)

    def test_diagnostic_export_contains_only_sanitized_allowlisted_files(self):
        self.assertEqual(self.support("log", "checkdetail", "0", "8", "DNS=ok").returncode, 0)
        self.write_settings({"disabled": ["DNS"], "logging": True})
        (self.base / "last-check.txt").write_text("出口IP=ok:203.0.113.10 token=secret", encoding="utf-8")
        (self.base / "lastip").write_text("203.0.113.10", encoding="utf-8")
        (self.base / "accounts").mkdir()
        (self.base / "accounts" / "A").mkdir()
        destination = Path(self.tmp.name) / "diagnostics.zip"
        run = self.support("export-diagnostics", str(destination))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        with zipfile.ZipFile(destination) as archive:
            names = set(archive.namelist())
            self.assertIn("client.log", names)
            self.assertIn("checks.json", names)
            self.assertIn("environment.json", names)
            self.assertIn("recent-status.json", names)
            self.assertNotIn("last-check.txt", names)
            self.assertNotIn("lastip", names)
            self.assertFalse(any("account" in name.lower() or "clash" in name.lower() for name in names))
            payload = b"".join(archive.read(name) for name in names)
        for secret in (b"203.0.113.10", b"Bearer", b"token", b"session", b"cookie", b"secret"):
            self.assertNotIn(secret, payload)


if __name__ == "__main__":
    unittest.main()
