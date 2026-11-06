"""Network rebuilding with an injected OS. No real network commands or sudo."""
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "core/claude-switch.sh"
SOURCE = CORE.read_text().split("<<'PY_NETWORK_REBUILD'\n", 1)[1].split("\nPY_NETWORK_REBUILD\n", 1)[0]
MODULE = {"__name__": "network_rebuild_tests"}
exec(compile(SOURCE, str(CORE) + ":network-rebuild", "exec"), MODULE)
Backend, Error = MODULE["NetworkRebuild"], MODULE["NetworkError"]
NET = MODULE["NET"]


def initial_state():
    return {
        "current": "Automatic",
        "locations": {
            "Automatic": [
                {"name": "Wi-Fi", "hardware": "Wi-Fi", "device": "en0", "enabled": True},
                {"name": "USB LAN", "hardware": "USB Ethernet", "device": "en7", "enabled": True},
                {"name": "Spare LAN", "hardware": "Ethernet", "device": "en3", "enabled": False},
                {"name": "VM Bridge", "hardware": "Bridge", "device": "bridge0", "enabled": True},
            ]
        },
        "hardware": {"Wi-Fi": "en0", "USB Ethernet": "en7", "Ethernet": "en3"},
        "wifi": "Preferred networks on en0:\n\tFixture Wi-Fi\n\t已保存网络",
        "dns": "203.0.113.70", "pac": "URL: https://private.example/pac?token=fixture-secret\nEnabled: Yes",
        "processes": "", "vpn": "Available network connection services in the current set:",
        "interfaces": "lo0 en0 en7 en3 bridge0 utun9",
    }


# A separate process uses this exact fake OS for elevated-script integration tests.
FAKE_OS = r'''
import json, os, sys
from pathlib import Path
state_path = Path(os.environ["FIXTURE_STATE"])
state = json.loads(state_path.read_text())
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with Path(os.environ["FIXTURE_CALLS"]).open("a") as log:
    log.write(json.dumps([name] + args) + "\n")
if name == "pgrep":
    sys.exit(0 if state.get("afterAuthClaude") else 1)
if name == "scutil":
    print(state["vpn"]); sys.exit(0)
if name == "ps":
    print(state["processes"]); sys.exit(0)
if name in ("dscacheutil", "killall"):
    sys.exit(0)
if name != "networksetup":
    sys.exit(99)
option = args[0]
if state.get("failOn") == args:
    print("** Error: fixture error containing 203.0.113.99 private-secret")
    sys.exit(0 if state.get("softFailure") else 9)
services = state["locations"][state["current"]]
output = ""
if option == "-getcurrentlocation": output = state["current"]
elif option == "-listlocations": output = "\n".join(state["locations"])
elif option == "-listallnetworkservices":
    output = "An asterisk (*) denotes that a network service is disabled.\n" + "\n".join(("" if s["enabled"] else "*") + s["name"] for s in services)
elif option == "-listnetworkserviceorder":
    output = "An asterisk (*) denotes that a network service is disabled.\n" + "\n".join("(%d) %s\n(Hardware Port: %s, Device: %s)" % (i + 1, s["name"], s["hardware"], s["device"]) for i, s in enumerate(services))
elif option == "-listpreferredwirelessnetworks": output = state["wifi"]
elif option == "-getinfo": output = state.get("address", "DHCP Configuration\nIP address: 192.0.2.8")
elif option == "-getdnsservers": output = state["dns"]
elif option == "-getsearchdomains": output = "private.example"
elif option == "-getautoproxyurl": output = state["pac"]
elif option in ("-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy"):
    output = "Enabled: Yes\nServer: 203.0.113.71\nPort: 7890\nAuthenticated Proxy Enabled: 0"
elif option == "-getproxyautodiscovery": output = "Auto Proxy Discovery: On"
elif option == "-getproxybypassdomains": output = "*.private.example"
elif option == "-createlocation": state["locations"][args[1]] = []
elif option == "-switchtolocation":
    if args[1] not in state["locations"]: sys.exit(7)
    state["current"] = args[1]
elif option == "-deletelocation":
    del state["locations"][args[1]]
elif option == "-createnetworkservice":
    state["locations"][state["current"]].append({"name": args[1], "hardware": args[2], "device": state["hardware"][args[2]], "enabled": True})
elif option == "-setnetworkserviceenabled":
    next(s for s in services if s["name"] == args[1])["enabled"] = args[2] == "on"
elif option in ("-setdnsservers", "-setsearchdomains", "-setproxybypassdomains",
                 "-setwebproxystate", "-setsecurewebproxystate", "-setsocksfirewallproxystate",
                 "-setautoproxystate", "-setproxyautodiscovery", "-setdhcp", "-setv6automatic"):
    state.setdefault("parameters", {})[state["current"] + "/" + args[1] + "/" + option] = args[2:]
else: sys.exit(98)
state_path.write_text(json.dumps(state))
if output: print(output)
'''


class FakeRunner:
    def __init__(self, root):
        self.root = root
        self.data = initial_state()
        self.queries, self.scripts = [], []
        self.result = {"ok": True, "output": "NETWORK_STARTED\nNETWORK_STEP:1:ok\nNETWORK_DONE\n", "cancelled": False}
        self.root_locked = False
        self.execute = False
        self.before_authorize = None

    def query(self, args):
        self.queries.append(args)
        if args[0] == "/bin/ps":
            return self.data["processes"]
        if args[0] == "/usr/sbin/scutil":
            return self.data["vpn"]
        if args[0] == "/sbin/ifconfig":
            return self.data["interfaces"]
        option, services = args[1], self.data["locations"][self.data["current"]]
        if option == "-getcurrentlocation": return self.data["current"]
        if option == "-listlocations": return "\n".join(self.data["locations"])
        if option == "-listallnetworkservices":
            return "An asterisk (*) denotes that a network service is disabled.\n" + "\n".join(
                ("" if s["enabled"] else "*") + s["name"] for s in services)
        if option == "-listnetworkserviceorder":
            return "An asterisk (*) denotes that a network service is disabled.\n" + "\n".join(
                "(%d) %s\n(Hardware Port: %s, Device: %s)" % (i + 1, s["name"], s["hardware"], s["device"])
                for i, s in enumerate(services))
        if option == "-listpreferredwirelessnetworks": return self.data["wifi"]
        if option == "-getinfo": return self.data.get("address", "DHCP Configuration\nIP address: 192.0.2.8")
        if option == "-getdnsservers": return self.data["dns"]
        if option == "-getsearchdomains": return "private.example"
        if option == "-getautoproxyurl": return self.data["pac"]
        if option in ("-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy"):
            return "Enabled: Yes\nServer: 203.0.113.71\nPort: 7890\nAuthenticated Proxy Enabled: 0"
        if option == "-getproxyautodiscovery": return "Auto Proxy Discovery: On"
        if option == "-getproxybypassdomains": return "*.private.example"
        raise AssertionError("unexpected read: " + repr(args))

    def root_busy(self):
        return self.root_locked

    def authorize(self, script):
        self.scripts.append(script)
        if self.before_authorize:
            self.before_authorize()
        if not self.execute:
            return self.result
        bin_dir = self.root / "fake-bin"
        bin_dir.mkdir(exist_ok=True)
        replacements = {
            NET: "networksetup", "/usr/bin/pgrep": "pgrep", "/usr/sbin/scutil": "scutil",
            "/usr/bin/dscacheutil": "dscacheutil", "/usr/bin/killall": "killall", "/bin/ps": "ps",
        }
        for original, name in replacements.items():
            target = bin_dir / name
            target.write_text("#!" + sys.executable + "\n" + FAKE_OS)
            target.chmod(0o700)
            script = script.replace(original, shlex.quote(str(target)))
        script = script.replace(str(MODULE["ROOT_LOCK"]), str(self.root / "fake-root-lock"))
        # Fail the fixture before spawning anything if even one real system mutation remains.
        for forbidden in (*replacements, str(MODULE["ROOT_LOCK"])):
            assert forbidden not in script, forbidden
        self.state_file = self.root / "fake-os.json"
        self.state_file.write_text(json.dumps(self.data))
        self.calls_file = self.root / "fake-os-calls.jsonl"
        self.calls_file.write_text("")
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.root), "LC_ALL": "C",
               "FIXTURE_STATE": str(self.state_file), "FIXTURE_CALLS": str(self.calls_file)}
        result = subprocess.run(["/bin/bash", "-c", script], cwd=self.root, env=env,
                                capture_output=True, text=True, timeout=30)
        self.data = json.loads(self.state_file.read_text())
        return {"ok": result.returncode == 0, "output": result.stdout, "cancelled": False}

    def mutations(self):
        values = [json.loads(line) for line in self.calls_file.read_text().splitlines()]
        return [args for args in values if args[0] == "networksetup"
                and args[1] in MODULE["MUTATIONS"]]


class NetworkRebuildTests(unittest.TestCase):
    def setUp(self):
        trash = ROOT / "_trash"
        trash.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="network-rebuild-tests-", dir=trash)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.runner = FakeRunner(self.root)
        self.backend = Backend(self.runner, self.home)

    def preview(self, level=2):
        return self.backend.preview(level)

    def apply(self, level=2):
        return self.backend.apply(level, self.preview(level)["token"])

    def test_preflight_is_readonly_whole_mac_and_redacted(self):
        report = self.preview()
        self.assertEqual([s["device"] for s in report["services"]], ["en0", "en7", "en3"])
        self.assertFalse(report["services"][2]["enabled"])
        self.assertTrue(report["canApply"])
        self.assertFalse(self.backend.base.exists())
        self.assertEqual(self.runner.scripts, [])
        serialized = json.dumps(report, ensure_ascii=False)
        for secret in ("203.0.113.70", "203.0.113.71", "192.0.2.8", "fixture-secret", "Fixture Wi-Fi"):
            self.assertNotIn(secret, serialized)
        self.assertFalse(any(call[0] in ("curl", "dig", "/usr/bin/osascript") for call in self.runner.queries))

    def test_changed_configuration_and_wrong_level_cannot_execute(self):
        token = self.preview(2)["token"]
        with self.assertRaises(Error): self.backend.apply(3, token)
        self.runner.data["dns"] = "203.0.113.72"
        with self.assertRaises(Error): self.backend.apply(2, token)
        self.assertFalse(self.backend.pending.exists())
        self.assertEqual(self.runner.scripts, [])

    def test_running_claude_or_code_blocks_all_levels(self):
        self.runner.data["processes"] = f"{os.getuid()} /Applications/Claude.app/Contents/MacOS/Claude"
        for level in (1, 2, 3):
            self.assertFalse(self.preview(level)["canApply"])
            with self.assertRaises(Error): self.apply(level)
        self.assertEqual(self.runner.scripts, [])

    def test_native_and_node_cli_installations_also_block_preflight(self):
        for executable in ("/Users/fixture/.local/share/claude/versions/2.0.0",
                           "/usr/bin/node /opt/lib/node_modules/@anthropic-ai/claude-code/cli.js"):
            self.runner.data["processes"] = f"{os.getuid()} {executable}"
            self.assertFalse(self.preview(1)["canApply"])
            self.assertFalse(self.preview(3)["canApply"])

    def test_network_software_and_connected_vpn_block_persistent_changes(self):
        self.runner.data["processes"] = "0 /Applications/FlClash.app/Contents/MacOS/FlClashCore"
        self.assertTrue(self.preview(1)["canApply"])
        self.assertFalse(self.preview(2)["canApply"])
        self.runner.data["processes"] = ""
        self.runner.data["vpn"] = "(Connected) fixture-vpn"
        self.assertFalse(self.preview(3)["canApply"])

    def test_static_address_has_explicit_deep_reset_warning(self):
        self.runner.data["address"] = "Manual Configuration\nIP address: 192.0.2.8"
        self.assertTrue(any("DHCP" in line and "手动地址" in line for line in self.preview(3)["manual"]))
        self.assertFalse(any("手动地址" in line for line in self.preview(2)["manual"]))

    def test_passwords_profiles_accounts_and_logs_never_enter_mutation_plan(self):
        for level in (1, 2, 3):
            inv = self.backend.inventory()
            script = self.backend.script(inv, level, "Claude-Network-fixture" if level == 3 else "")
            for forbidden in ("security ", "find-generic-password", "removepreferred", "removeallpreferred",
                              "airport.preferences", "known-networks", "Keychains", "accounts/",
                              "kill -9", "route flush", "pfctl", "rm -rf", ".local/bin"):
                self.assertNotIn(forbidden, script)
            for binary in re.findall(r"(?<!\w)(/(?:usr/(?:bin|sbin)|bin|sbin)/[A-Za-z0-9_-]+)", script):
                self.assertIn(binary, {NET, "/usr/bin/shasum", "/usr/bin/awk", "/usr/bin/pgrep",
                                       "/usr/sbin/scutil", "/usr/bin/grep", "/usr/bin/dscacheutil",
                                       "/usr/bin/killall", "/bin/mkdir", "/bin/rmdir", "/bin/ps"})

    def test_all_three_generated_scripts_execute_only_against_fake_os(self):
        for level in (1, 2, 3):
            with self.subTest(level=level):
                self.runner.data = initial_state()
                self.runner.execute = True
                result = self.apply(level)
                self.assertTrue(result["success"], result)
                calls = self.runner.mutations()
                self.assertTrue(calls)
                if level == 1:
                    self.assertEqual({call[1] for call in calls}, {"-setnetworkserviceenabled"})
                    self.assertFalse(any("Spare LAN" in call for call in calls))
                elif level == 2:
                    for name in ("Wi-Fi", "USB LAN", "Spare LAN"):
                        self.assertIn(["networksetup", "-setdnsservers", name, "Empty"], calls)
                    self.assertFalse(any(call[1] == "-setdhcp" for call in calls))
                else:
                    self.assertTrue(self.runner.data["current"].startswith("Claude-Network-"))
                    self.assertEqual(self.runner.data["locations"]["Automatic"], initial_state()["locations"]["Automatic"])
                    created = self.runner.data["locations"][self.runner.data["current"]]
                    self.assertEqual([s["name"] for s in created], ["Wi-Fi", "USB LAN", "Spare LAN"])
                    self.assertFalse(created[2]["enabled"])
                self.assertEqual(self.runner.data["wifi"], initial_state()["wifi"])
                self.backend.finish()

    def test_cancelled_authorization_leaves_no_pending_record(self):
        self.runner.result = {"ok": False, "output": "", "cancelled": True}
        result = self.apply()
        self.assertFalse(result["success"])
        self.assertFalse(result["pending"])
        self.assertFalse(self.backend.pending.exists())

    def test_partial_failure_keeps_persistent_launch_interlock(self):
        self.runner.result = {"ok": False, "output": "NETWORK_STARTED\nNETWORK_STEP:1:ok\n", "cancelled": False}
        result = self.apply()
        self.assertFalse(result["success"])
        self.assertTrue(self.backend.state()["pending"])
        self.assertEqual(self.backend.state()["phase"], "failed")
        with self.assertRaises(Error): self.apply()
        self.assertEqual(stat.S_IMODE(self.backend.pending.stat().st_mode), 0o600)

    def test_error_after_disabling_service_restores_its_enabled_state(self):
        self.runner.execute = True
        self.runner.data["failOn"] = ["-setnetworkserviceenabled", "Wi-Fi", "on"]
        result = self.apply(1)
        self.assertFalse(result["success"])
        # Cleanup tries "on" again; the fixture fails it as well, so it must report failure.
        self.assertEqual(sum(c == ["networksetup", "-setnetworkserviceenabled", "Wi-Fi", "on"]
                             for c in self.runner.mutations()), 2)
        self.assertTrue(self.backend.state()["pending"])

    def test_deep_soft_error_rolls_back_without_deleting_old_location(self):
        self.runner.execute = True
        self.runner.data["failOn"] = ["-setdhcp", "USB LAN"]
        self.runner.data["softFailure"] = True
        result = self.apply(3)
        self.assertFalse(result["success"])
        self.assertEqual(self.runner.data["current"], "Automatic")
        self.assertEqual(set(self.runner.data["locations"]), {"Automatic"})
        self.assertEqual(self.runner.data["wifi"], initial_state()["wifi"])
        self.assertNotIn("private-secret", json.dumps(result))

    def test_configuration_changed_during_admin_dialog_fails_before_mutation(self):
        self.runner.execute = True
        self.runner.before_authorize = lambda: self.runner.data.update(dns="203.0.113.73")
        result = self.apply(2)
        self.assertFalse(result["success"])
        self.assertEqual(self.runner.mutations(), [])
        self.assertFalse(self.backend.pending.exists())

    def test_claude_started_during_admin_dialog_blocks_mutation(self):
        self.runner.execute = True
        self.runner.data["afterAuthClaude"] = True
        result = self.apply(3)
        self.assertFalse(result["success"])
        self.assertEqual(self.runner.mutations(), [])

    def test_pending_record_survives_restart_and_explicit_rollback(self):
        self.runner.execute = True
        self.assertTrue(self.apply(3)["success"])
        reopened = Backend(self.runner, self.home)
        self.assertTrue(reopened.state()["canRollback"])
        self.assertTrue(reopened.rollback()["success"])
        self.assertEqual(self.runner.data["current"], "Automatic")
        self.assertTrue(reopened.state()["pending"])
        reopened.finish()
        self.assertFalse(reopened.state()["pending"])

    def test_existing_symlinks_and_invalid_records_fail_closed(self):
        self.backend.base.mkdir()
        target = self.root / "untouched"
        target.write_text("keep")
        self.backend.pending.symlink_to(target)
        with self.assertRaises(Error): self.preview()
        with self.assertRaises(Error): self.apply()
        self.assertEqual(target.read_text(), "keep")
        self.backend.pending.unlink()
        self.backend.pending.write_text("broken")
        self.backend.pending.chmod(0o600)
        with self.assertRaises(Error): self.backend.state()

    def test_existing_live_lock_is_not_removed_or_overwritten(self):
        self.backend.base.mkdir()
        self.backend.lock.write_text("")
        self.backend.lock.chmod(0o600)
        with self.backend.lock.open("r") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertTrue(self.backend.busy())
            with self.assertRaises(Error): self.apply()
        self.runner.root_locked = True
        self.assertFalse(self.preview()["canApply"])

    def test_inflight_account_launch_and_isolated_browser_block_rebuild(self):
        self.backend.base.mkdir()
        operation = self.backend.base / "cli-operation.lock"
        operation.mkdir()
        self.assertFalse(self.preview()["canApply"])
        with self.assertRaises(Error):
            self.backend.apply(1, "a" * 64)
        self.assertTrue(operation.is_dir(), "must not remove another operation's lock")
        operation.rmdir()
        self.runner.data["processes"] = f"{os.getuid()} Chrome --user-data-dir=/tmp/claude-switcher-safe.fixture"
        self.assertFalse(self.preview(1)["canApply"])
        self.assertEqual(self.runner.scripts, [])

    def test_empty_device_virtual_service_is_manual_not_a_reset_target(self):
        self.runner.data["locations"]["Automatic"][-1]["device"] = ""
        report = self.preview(3)
        self.assertTrue(report["canApply"])
        self.assertEqual(len(report["services"]), 3)
        self.assertTrue(any("VM Bridge" in line for line in report["manual"]))

    def test_inventory_read_failure_does_not_create_state(self):
        with patch.object(self.runner, "query", side_effect=Error("fixture failure")):
            with self.assertRaises(Error):
                self.preview()
        self.assertFalse(self.backend.base.exists())
        self.assertEqual(self.runner.scripts, [])

    def test_authorization_receives_script_over_stdin_with_clean_environment(self):
        runner = MODULE["Runner"].__new__(MODULE["Runner"])
        result = subprocess.CompletedProcess([], 0, "NETWORK_DONE\n", "")
        with patch.object(MODULE["subprocess"], "run", return_value=result) as execute:
            response = runner.authorize("printf 'NETWORK_DONE\\n'\n")
        self.assertTrue(response["ok"])
        args, kwargs = execute.call_args
        self.assertEqual(args[0], ["/usr/bin/osascript"])
        self.assertIn("with administrator privileges", kwargs["input"])
        self.assertNotIn("BASH_ENV", kwargs["env"])
        self.assertNotIn("PYTHONPATH", kwargs["env"])

    def test_failed_bridge_validation_cannot_clear_pending_record(self):
        self.backend.base.mkdir()
        self.backend.pending.write_text("fixture pending sentinel")
        fake_python = self.root / "python"
        fake_python.write_text(
            "#!/bin/sh\ncat >/dev/null\n"
            'case "$2" in has-pending) exit 0;; busy) exit 1;; '
            'finish) printf finish > "$HOME/unexpected-finish";; *) exit 98;; esac\n')
        fake_python.chmod(0o700)
        fixture_core = self.root / "fixture-core.sh"
        source = CORE.read_text().replace('operation="${1:-}"',
                                         'check() { return 1; }\noperation="${1:-}"')
        fixture_core.write_text(source)
        fixture_core.chmod(0o700)
        env = {**os.environ, "HOME": str(self.home), "CLAUDE_SWITCHER_PYTHON": str(fake_python)}
        env.pop("BASH_ENV", None)
        env.pop("ENV", None)
        result = subprocess.run(["/bin/bash", str(fixture_core), "network-rebuild", "validate"],
                                env=env, capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.backend.pending.read_text(), "fixture pending sentinel")
        self.assertFalse((self.home / "unexpected-finish").exists())
        self.assertFalse((self.backend.base / "accounts").exists())

    def test_hostile_service_names_are_quoted_not_executed(self):
        service = self.runner.data["locations"]["Automatic"][0]
        service["name"] = "Wi-Fi ' $(touch INJECTED)"
        self.runner.execute = True
        result = self.apply(2)
        self.assertTrue(result["success"])
        self.assertFalse((self.root / "INJECTED").exists())
        self.assertIn(["networksetup", "-setdnsservers", service["name"], "Empty"], self.runner.mutations())

    def test_core_launch_interlock_precedes_network_and_account_initialization(self):
        self.backend.base.mkdir()
        self.backend.pending.write_text("invalid-but-must-block")
        env = {**os.environ, "HOME": str(self.home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
        env.pop("BASH_ENV", None)
        env.pop("ENV", None)
        for args in (["switch", "B"], ["cli"], ["open-safe", "https://example.test"]):
            result = subprocess.run(["/bin/bash", str(CORE)] + args, env=env,
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("网络重建", result.stdout)
        self.assertFalse((self.backend.base / "accounts").exists())
        self.assertFalse((self.home / "Library").exists())

    def test_public_bridge_never_exposes_finish_or_creates_accounts(self):
        fake_python = self.root / "python"
        fake_python.write_text("#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"schema\":1,\"kind\":\"network_rebuild\",\"pending\":false}'\n")
        fake_python.chmod(0o700)
        env = {**os.environ, "HOME": str(self.home), "CLAUDE_SWITCHER_PYTHON": str(fake_python)}
        env.pop("BASH_ENV", None)
        env.pop("ENV", None)
        state = subprocess.run(["/bin/bash", str(CORE), "network-rebuild", "state"], env=env,
                               capture_output=True, text=True, timeout=5)
        self.assertEqual(state.returncode, 0, state.stderr)
        denied = subprocess.run(["/bin/bash", str(CORE), "network-rebuild", "finish"], env=env,
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(denied.returncode, 0)
        self.assertFalse(self.backend.base.exists())


if __name__ == "__main__":
    unittest.main()
