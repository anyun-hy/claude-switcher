"""Windows account/client/check parity contracts; no PowerShell is executed."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "windows/claude-switch.ps1"
BODYGUARD = ROOT / "windows/claude-bodyguard.ps1"
INSTALL = ROOT / "windows/install.ps1"


class WindowsFeatureParityStaticTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.core = CORE.read_text(encoding="utf-8-sig")
        cls.bodyguard = BODYGUARD.read_text(encoding="utf-8-sig")
        cls.install = INSTALL.read_text(encoding="utf-8-sig")

    def test_status_reports_all_accounts_and_archive_metadata(self):
        body = self.core[self.core.index("function Invoke-Status"):]
        body = body[:body.index("\nfunction ")]
        self.assertIn("foreach ($slot in @('A','B','C','D'))", body)
        self.assertIn('"has$slot=', body)
        self.assertIn('"acc$slot=', body)
        self.assertIn("accounts=", body)
        self.assertIn("LastWriteTime", body)

    def test_silent_check_blocks_on_any_fail_result(self):
        start = self.core.index("function Invoke-Check {")
        body = self.core[start:self.core.index("\nfunction ", start)]
        self.assertIn("Invoke-CheckDetail", body)
        self.assertIn("$states[$_] -eq 'fail'", body)
        self.assertIn("$script:exitCode = 1", body)
        self.assertRegex(self.core, r"(?m)^\s*'check'\s*\{\s*Invoke-Check\s*\}")

    def test_ip_history_is_bounded_and_skipped_when_disabled(self):
        self.assertIn("iphistory.log", self.core)
        self.assertIn("172800", self.core)
        disabled = self.core.index("if (Test-CheckDisabled 'IP一致')")
        history = self.core.index("Add-IpHistory", disabled)
        timezone = self.core.index("$tz = (Get-TimeZone).Id", disabled)
        self.assertLess(disabled, history)
        self.assertLess(history, timezone)

    def test_ip_history_threshold_is_a_visible_warning_not_a_green_pass(self):
        start = self.core.index("$ipCount = Add-IpHistory")
        body = self.core[start:self.core.index("$tz = (Get-TimeZone).Id", start)]
        self.assertIn("$ipState = if ($ipCount -ge 3) { 'warn' } else { 'ok' }", body)
        self.assertIn("Format-OptionalResult 'IP一致' $ipState", body)

    def test_keep_paths_preserve_recovery_copies_and_block_reparse_points(self):
        for name in ("Test-KeepPathSafe", "Stage-KeepPaths", "Restore-KeepPaths"):
            self.assertIn(f"function {name}", self.core)
        self.assertIn("ReparsePoint", self.core)
        self.assertIn("keep-stage", self.core)
        switch = self.core[self.core.index("function Invoke-Switch"):]
        switch = switch[:switch.index("\nfunction ")]
        self.assertLess(switch.index("Stage-KeepPaths"), switch.index("Save-Account"))
        self.assertLess(switch.index("Restore-KeepPaths"), switch.index("Start-ClaudeApp"))

    def test_client_switch_updates_core_and_bodyguard_mode(self):
        start = self.core.index("function Set-ClientMode")
        body = self.core[start:self.core.index("\nfunction ", start)]
        self.assertIn("proxy-mode.txt", body)
        self.assertIn("Set-ScriptConfigValue", body)
        self.assertIn("UTF8Encoding($true)", body)
        for mode in ("clash-verge", "flclash", "sing-box", "clashx", "surge", "wireguard", "other", "auto"):
            self.assertIn(f"'{mode}'", body)
        self.assertRegex(self.core, r"(?m)^\s*'get-client'\s*\{\s*Get-Client\s*\}")

    def test_flclash_is_detected_everywhere_windows_supports_it(self):
        for text in (self.core, self.bodyguard, self.install):
            self.assertIn("flclash", text)
            self.assertIn("FlClashCore", text)

    def test_msix_data_directory_is_discovered(self):
        self.assertIn("function Find-ClaudeDataPath", self.core)
        self.assertIn("Get-AppxPackage -Name 'Claude'", self.core)
        self.assertIn('Join-Path $env:LOCALAPPDATA "Claude-Data"', self.core)
        self.assertIn("$pkg.PackageFamilyName", self.core)
        self.assertIn("$DATA = Find-ClaudeDataPath", self.core)

    def test_installer_checks_claude_before_system_changes(self):
        self.assertIn("未找到 Claude 桌面版", self.install)
        preflight = self.install.index("未找到 Claude 桌面版")
        self.assertIn("Get-AppxPackage -Name 'Claude'", self.install)
        self.assertLess(preflight, self.install.index("Set-TimeZone"))
        self.assertLess(preflight, self.install.index("Register-ScheduledTask"))


if __name__ == "__main__":
    unittest.main()
