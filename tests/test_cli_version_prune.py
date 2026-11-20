"""切换时内置 CLI 旧版本清理(prune_cli_versions)回归测试。

只提取核心脚本的命名函数,在隔离 HOME 下运行;不访问真实 Claude 安装、
账号数据、网络或保镖。
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "core" / "claude-switch.sh"
TRASH = PROJECT / "_trash"

FUNCTIONS = (
    "prune_cli_versions",
)


def function_source(name):
    text = SOURCE.read_text(encoding="utf-8")
    pattern = rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}"
    match = re.search(pattern, text)
    if match is None:
        raise AssertionError(f"Missing shell function: {name}")
    return match.group(0)


class PruneCliVersionsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        TRASH.mkdir(exist_ok=True)
        cls.functions = "\n\n".join(
            function_source(name) for name in FUNCTIONS
        )

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(
            prefix="cli-prune-", dir=str(TRASH)
        )
        self.addCleanup(self.tmp.cleanup)
        self.fixture = Path(self.tmp.name)
        self.data = self.fixture / "live"
        self.data.mkdir()
        self.log = self.fixture / "switch.log"

    def run_shell(self, code, *, no_prune="0"):
        env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.fixture),
            "BASE": str(self.fixture / "state"),
            "DATA": str(self.data),
            "LOG": str(self.log),
            "CLAUDE_SWITCHER_NO_PRUNE_CLI": no_prune,
            "LC_ALL": "C",
        }
        nl = chr(10)
        bsn = chr(92) + "n"
        harness = ("set -u" + nl
                   + "log() { printf '%s" + bsn + "' \"$1\" >> \"$LOG\"; }" + nl)
        return subprocess.run(
            ["/bin/bash", "-c", harness + "\n" + self.functions + "\n" + code],
            env=env,
            cwd=self.fixture,
            text=True,
            capture_output=True,
            check=False,
            timeout=20,
        )

    def make_versions(self, *names):
        root = self.data / "claude-code"
        root.mkdir(parents=True, exist_ok=True)
        for name in names:
            (root / name).mkdir(parents=True, exist_ok=True)
            (root / name / "cli.js").write_text("stub", encoding="utf-8")
        return root

    def surviving(self):
        root = self.data / "claude-code"
        if not root.is_dir():
            return []
        return sorted(
            p.name
            for p in root.iterdir()
            if p.is_dir() and not p.is_symlink()
            and re.fullmatch(r"[0-9]+(\.[0-9]+)*", p.name)
        )

    def test_prune_keeps_latest_only(self):
        self.make_versions("2.1.317", "2.1.321", "2.1.326")
        result = self.run_shell('prune_cli_versions "$DATA"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.surviving(), ["2.1.326"])
        log_text = self.log.read_text(encoding="utf-8")
        self.assertIn("2.1.317", log_text)
        self.assertIn("2.1.321", log_text)

    def test_prune_sorts_version_order_not_lexical(self):
        # 2.1.9 < 2.1.10 数值序,字典序会误判
        self.make_versions("2.1.9", "2.1.10")
        result = self.run_shell('prune_cli_versions "$DATA"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.surviving(), ["2.1.10"])

    def test_prune_noop_with_single_or_missing(self):
        self.make_versions("2.1.328")
        result = self.run_shell('prune_cli_versions "$DATA"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.surviving(), ["2.1.328"])
        self.assertFalse(self.log.exists())

        empty = self.fixture / "empty-live"
        empty.mkdir()
        result = self.run_shell(f'prune_cli_versions "{empty}"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_prune_ignores_non_numeric_and_symlinks(self):
        root = self.make_versions("2.1.326", "2.1.328")
        (root / "c141a31688d6").mkdir()          # 非纯数字:安装哈希目录
        (root / "nightly").mkdir()                # 非版本名
        (root / "2.1.330").symlink_to("2.1.328")  # 符号链接:不参与比较、不删
        result = self.run_shell('prune_cli_versions "$DATA"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # 只清数字版本目录:最新 2.1.328 保留,旧 2.1.326 删除;
        # 哈希目录、nightly、符号链接一律不动
        self.assertEqual(self.surviving(), ["2.1.328"])
        names = {p.name for p in root.iterdir()}
        self.assertIn("c141a31688d6", names)
        self.assertIn("nightly", names)
        self.assertIn("2.1.330", names)
        self.assertTrue((root / "2.1.330").is_symlink())

    def test_prune_respects_disable_flag(self):
        self.make_versions("2.1.317", "2.1.328")
        result = self.run_shell('prune_cli_versions "$DATA"', no_prune="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.surviving(), ["2.1.317", "2.1.328"])


if __name__ == "__main__":
    unittest.main()
