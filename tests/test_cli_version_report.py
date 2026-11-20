"""只读 Claude Code 版本探测(cli_latest_version)隔离回归测试。

只提取核心脚本的命名函数,在隔离 HOME 下运行;不访问真实 Claude 安装、
账号数据、网络或保镖。
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "core" / "claude-switch.sh"
TRASH = PROJECT / "_trash"


def function_source(name):
    text = SOURCE.read_text(encoding="utf-8")
    match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}", text)
    if match is None:
        raise AssertionError(f"Missing shell function: {name}")
    return match.group(0)


class CliLatestVersionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        TRASH.mkdir(exist_ok=True)
        cls.functions = function_source("cli_latest_version")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(
            prefix="cli-version-", dir=str(TRASH)
        )
        self.addCleanup(self.tmp.cleanup)
        self.fixture = Path(self.tmp.name)
        self.data = self.fixture / "Claude"
        self.data.mkdir()

    def run_version(self):
        env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.fixture),
            "DATA": str(self.data),
            "LC_ALL": "C",
        }
        return subprocess.run(
            ["/bin/bash", "-c", "set -u" + chr(10) + self.functions + chr(10) + "cli_latest_version"],
            env=env, cwd=self.fixture, text=True, capture_output=True,
            check=False, timeout=20,
        )

    def make_verified(self, version, hashdir="c141a31688d6"):
        vdir = self.data / "claude-code" / version
        (vdir / hashdir).mkdir(parents=True)
        (vdir / hashdir / ".verified").write_text("ok", encoding="utf-8")

    def test_no_claude_code_returns_unknown(self):
        result = self.run_version()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "unknown")

    def test_picks_latest_verified_version(self):
        self.make_verified("2.1.326", "c4434d650cb3")
        self.make_verified("2.1.328", "c141a31688d6")
        result = self.run_version()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "2.1.328")

    def test_numeric_order_not_lexical(self):
        self.make_verified("2.1.9")
        self.make_verified("2.1.10")
        result = self.run_version()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "2.1.10")

    def test_falls_back_to_version_dirs_without_verified(self):
        for v in ("2.1.317", "2.1.328"):
            (self.data / "claude-code" / v).mkdir(parents=True)
        result = self.run_version()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "2.1.328")

    def test_ignores_non_numeric_dirs(self):
        self.make_verified("2.1.326")
        (self.data / "claude-code" / "nightly").mkdir()
        (self.data / "claude-code" / "claude-code-spare").mkdir()
        result = self.run_version()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "2.1.326")


if __name__ == "__main__":
    unittest.main()
