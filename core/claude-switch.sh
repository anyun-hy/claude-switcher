#!/bin/bash
# Claude 账号切换器 - 核心脚本 (通用版)
# 用法: claude-switch.sh check | status | switch A|B|C|D | checkdetail | fix | set-region | update [--check|--auto] | diagnose-proxy | network-rebuild
set -u
export LC_ALL=en_US.UTF-8

if [ "${1:-}" = "_network-rebuild" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_NETWORK_REBUILD'
"""Mac-wide maintenance. Only fixed Apple binaries run with administrator privileges.

Wi-Fi profiles/passwords are never edited. Tests inject Runner; production has no test mode.
"""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import stat
import subprocess
import sys
import tempfile

NET = "/usr/sbin/networksetup"
ROOT_LOCK = Path("/var/run/local.claude-switcher.network-rebuild.lock")
PRESERVED = ["Wi-Fi 已保存网络、密码、自动加入偏好", "代理订阅和节点", "Claude 账号与个人文件"]
QUERIES = ("-getinfo", "-getdnsservers", "-getsearchdomains", "-getwebproxy",
           "-getsecurewebproxy", "-getsocksfirewallproxy", "-getautoproxyurl",
           "-getproxyautodiscovery", "-getproxybypassdomains")
MUTATIONS = {"-setnetworkserviceenabled", "-setdnsservers", "-setsearchdomains",
             "-setwebproxystate", "-setsecurewebproxystate", "-setsocksfirewallproxystate",
             "-setautoproxystate", "-setproxyautodiscovery", "-setproxybypassdomains",
             "-createlocation", "-switchtolocation", "-createnetworkservice",
             "-setdhcp", "-setv6automatic", "-deletelocation"}
NETWORK_APPS = {"FlClash": "FlClash", "FlClashCore": "FlClash", "verge-mihomo": "Clash Verge",
                "Clash Verge": "Clash Verge", "clash-verge": "Clash Verge", "TAG": "TAG",
                "Shadowrocket": "Shadowrocket", "Surge": "Surge", "ClashX": "ClashX",
                "sing-box": "sing-box", "mihomo": "Mihomo", "clash": "Clash 内核",
                "clash-meta": "Clash 内核"}


class NetworkError(Exception):
    pass


def safe_name(value):
    if (not isinstance(value, str) or not value or len(value.encode("utf-8")) > 240
            or value.startswith(("-", "*")) or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise NetworkError("网络服务名称无法安全识别，请在系统设置中手动处理。")
    return value


def command_error(output):
    return bool(re.search(r"(?mi)^(?:\*\* [Ee]rror|Error:|You cannot|.* is not a recognized network)", output))


class Runner:
    def __init__(self):
        if platform.system() != "Darwin" or os.geteuid() == 0:
            raise NetworkError("请在 Mac 上以普通用户运行，由系统对重置操作请求管理员授权。")

    @staticmethod
    def environment():
        return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C",
                "HOME": str(Path.home())}

    def query(self, args):
        try:
            result = subprocess.run(args, env=self.environment(), stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=12)
        except (OSError, subprocess.SubprocessError):
            raise NetworkError("系统网络信息读取失败，请检查权限后重新预检。")
        if result.returncode or command_error(result.stdout):
            raise NetworkError("系统未能完整读取网络配置，未生成可执行计划。")
        return result.stdout.rstrip("\n")

    def authorize(self, shell):
        # Never save an elevated helper in a user-writable directory.
        literal = shell.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        script = ('do shell script "' + literal
                  + '" with prompt "Mac 网络重建将修改全机网络设置，并保留 Wi-Fi 密码"'
                  + ' with administrator privileges\n')
        try:
            result = subprocess.run(["/usr/bin/osascript"], input=script, env=self.environment(),
                                    capture_output=True, text=True)
        except (OSError, subprocess.SubprocessError):
            return {"ok": False, "output": "", "cancelled": False}
        return {"ok": result.returncode == 0, "output": result.stdout,
                "cancelled": result.returncode != 0 and "(-128)" in result.stderr}

    def root_busy(self):
        return ROOT_LOCK.exists()


class NetworkRebuild:
    def __init__(self, runner, home=None, uid=None):
        self.runner = runner
        self.home = Path.home() if home is None else Path(home)
        self.uid = os.getuid() if uid is None else uid
        self.base = self.home / ".claude-switcher"
        self.pending = self.base / "network-rebuild-pending.json"
        self.lock = self.base / "network-rebuild.lock"

    def _safe_file(self, path):
        for item in (self.home, self.base):
            if item.is_symlink():
                raise NetworkError("网络重建状态目录不能是符号链接。")
        if self.base.exists() and (not self.base.is_dir() or self.base.stat().st_uid != self.uid):
            raise NetworkError("网络重建状态目录的权限无效。")
        if path.exists() or path.is_symlink():
            value = path.lstat()
            if (not stat.S_ISREG(value.st_mode) or value.st_uid != self.uid
                    or stat.S_IMODE(value.st_mode) & 0o077):
                raise NetworkError("网络重建状态文件的权限无效。")

    def state(self):
        self._safe_file(self.pending)
        if not self.pending.exists():
            return {"pending": False, "phase": "idle", "canRollback": False}
        try:
            value = json.loads(self.pending.read_text(encoding="utf-8"))
            if (value["schema"] != 1 or value["level"] not in (1, 2, 3)
                    or not re.fullmatch(r"[0-9a-f]{64}", value["token"])
                    or value["phase"] not in ("authorizing", "awaiting_validation", "failed")):
                raise ValueError()
            for key in ("oldLocation", "newLocation"):
                if value.get(key):
                    safe_name(value[key])
        except (OSError, ValueError, KeyError, TypeError):
            raise NetworkError("网络重建记录无效，启动保护保持锁定；请手动检查记录。")
        return dict(value, pending=True, canRollback=value["level"] == 3
                    and bool(value.get("newLocation")))

    def busy(self):
        self._safe_file(self.lock)
        operation_lock = self.base / "cli-operation.lock"
        if self.runner.root_busy() or operation_lock.exists() or operation_lock.is_symlink():
            return True
        if not self.lock.exists():
            return False
        with self.lock.open("r") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(handle, fcntl.LOCK_UN)
                return False
            except BlockingIOError:
                return True

    @contextlib.contextmanager
    def exclusive(self):
        self._safe_file(self.lock)
        self.base.mkdir(mode=0o700, exist_ok=True)
        descriptor = os.open(self.lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise NetworkError("另一个网络重建操作正在进行。")
            if self.runner.root_busy():
                raise NetworkError("系统网络重建仍在进行；若上次异常中断，请重启 Mac 后再检查。")
            # Share the existing desktop/CLI/browser launch lock. This closes the
            # race where a launch passed its first guard just before preview/apply.
            operation_lock = self.base / "cli-operation.lock"
            try:
                operation_lock.mkdir(mode=0o700)
            except FileExistsError:
                raise NetworkError("账号切换或启动正在进行，请等待完成后重新预检。")
            try:
                yield
            finally:
                operation_lock.rmdir()

    def save(self, value):
        self._safe_file(self.pending)
        descriptor, name = tempfile.mkstemp(prefix=".network-rebuild-", dir=self.base)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(value, handle, ensure_ascii=False)
                handle.write("\n")
            os.replace(name, self.pending)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def inventory(self):
        captured = []

        def query(args):
            output = self.runner.query(args)
            captured.append((args, output))
            return output

        location = safe_name(query([NET, "-getcurrentlocation"]))
        locations = query([NET, "-listlocations"]).splitlines()
        if location not in locations:
            raise NetworkError("无法确认当前网络位置，未生成可执行计划。")
        all_services = query([NET, "-listallnetworkservices"]).splitlines()
        if not all_services or "asterisk" not in all_services[0].lower():
            raise NetworkError("系统网络服务列表格式不受支持。")
        enabled = {}
        for name in all_services[1:]:
            if not name:
                continue
            disabled = name.startswith("*")
            name = safe_name(name[1:] if disabled else name)
            if name in enabled:
                raise NetworkError("系统网络服务名称重复，需手动检查。")
            enabled[name] = not disabled
        order = query([NET, "-listnetworkserviceorder"])
        services = []
        name = None
        for line in order.splitlines():
            entry = re.fullmatch(r"\((?:\d+|\*)\)\s+(.+)", line)
            if entry:
                candidate = entry[1]
                name = candidate if candidate in enabled else candidate.lstrip("*")
            port = re.fullmatch(r"\(Hardware Port: (.*), Device:\s*([^)]*)\)", line)
            if port and name in enabled:
                services.append({"name": name, "hardware": safe_name(port[1] or "Unknown"), "device": port[2],
                                 "enabled": enabled[name]})
                name = None
        if not services or len(services) != len(enabled) or {s["name"] for s in services} != set(enabled):
            raise NetworkError("网络服务与接口无法完整对应，请在系统设置中检查。")
        physical = [s for s in services if re.fullmatch(r"en\d+", s["device"])
                    and "bluetooth" not in s["hardware"].lower()]
        manual = [s["name"] + "：虚拟或特殊网络服务需在所属软件中处理。"
                  for s in services if s not in physical]
        if not physical:
            raise NetworkError("未识别到可以安全重建的 Wi-Fi／以太网服务。")
        wifi_queries = []
        for device in sorted({s["device"] for s in physical
                              if s["hardware"].lower() in ("wi-fi", "airport")}):
            args = [NET, "-listpreferredwirelessnetworks", device]
            output = query(args)
            if "Preferred networks on" not in output:
                raise NetworkError("无法验证 Wi-Fi 已保存网络，已禁止自动重建。")
            wifi_queries.append((args, output))
        for service in physical:
            values = {option: query([NET, option, service["name"]]) for option in QUERIES}
            service["staticAddress"] = bool(re.search(r"(?mi)^(?:Manual|BOOTP|DHCP with manual)", values["-getinfo"]))
        process_output = self.runner.query(["/bin/ps", "-axww", "-o", "uid=,comm="])
        claude_running = False
        running_apps = set()
        for line in process_output.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) != 2 or not fields[0].isdigit():
                continue
            executable = Path(fields[1]).name
            if int(fields[0]) == self.uid and (executable in ("Claude", "claude")
                                              or "/.local/share/claude/versions/" in fields[1]):
                claude_running = True
            if executable in NETWORK_APPS:
                running_apps.add(NETWORK_APPS[executable])
        # npm/bun installations use node/bun as comm; inspect args only in memory.
        cli_output = self.runner.query(["/bin/ps", "-axww", "-o", "uid=,args="])
        isolated_running = False
        for line in cli_output.splitlines():
            fields = line.strip().split(None, 1)
            if (len(fields) == 2 and fields[0] == str(self.uid)
                    and re.search(r"@anthropic-ai/claude-code/(?:cli\.js|bin/claude(?:\.exe)?)", fields[1])):
                claude_running = True
            if (len(fields) == 2 and fields[0] == str(self.uid)
                    and "--user-data-dir=" in fields[1] and "claude-switcher-safe." in fields[1]):
                isolated_running = True
        vpn = self.runner.query(["/usr/sbin/scutil", "--nc", "list"])
        connected_vpn = bool(re.search(r"\((?:Connected|Connecting|Disconnecting)\)", vpn))
        if connected_vpn:
            manual.append("系统 VPN 正在连接：请先在系统设置中断开，确认不会自动重连。")
        interfaces = self.runner.query(["/sbin/ifconfig", "-l"]).split()
        if any(re.fullmatch(r"(?:utun|tun|tap|bridge)\d+", device) for device in interfaces):
            manual.append("检测到虚拟网络接口：由所属软件管理；本功能不强行删除系统隧道或网桥。")
        return {"location": location, "services": physical, "captured": captured,
                "wifi": wifi_queries, "manual": manual, "claudeRunning": claude_running,
                "runningApps": sorted(running_apps), "connectedVPN": connected_vpn,
                "isolatedRunning": isolated_running}

    @staticmethod
    def digest(captured):
        value = "".join(str(i) + "\n" + output + "\n" for i, (_, output) in enumerate(captured))
        return hashlib.sha256(value.encode("utf-8")).hexdigest()

    def token(self, inventory, level):
        return hashlib.sha256((str(self.uid) + ":" + str(level) + ":v1:"
                               + self.digest(inventory["captured"])).encode()).hexdigest()

    def preview(self, level):
        inventory = self.inventory()
        current = self.state()
        blocked = []
        if inventory["claudeRunning"]:
            blocked.append("请先正常退出 Claude 和 Claude Code；本功能不会强制终止会话。")
        if inventory["isolatedRunning"]:
            blocked.append("请先关闭切换器打开的隔离浏览器窗口，避免重建时失去代理保护。")
        if self.busy() or current["pending"]:
            blocked.append("已有网络重建尚未验收，请先恢复网络并检查，或切回旧位置。")
        if level >= 2 and inventory["runningApps"]:
            blocked.append("请先退出会重新写入网络设置的软件：" + "、".join(inventory["runningApps"]) + "。")
        if level >= 2 and inventory["connectedVPN"]:
            blocked.append("请先断开系统 VPN，避免重建时自动恢复旧配置。")
        manual = list(inventory["manual"])
        automatic = ["刷新全机 DNS 缓存", "按原配置重新连接所有已启用的 Wi-Fi／以太网服务"]
        if level >= 2:
            automatic = ["清除全部已识别服务的手动 DNS 和搜索域",
                         "关闭 HTTP／HTTPS／SOCKS、PAC 和自动代理发现，清空代理绕过列表",
                         "刷新 DNS 缓存并重新连接；保留服务名称、IP 接入方式和启停状态"]
        if level == 3:
            automatic = ["建立干净网络位置，重新创建全部已识别的 Wi-Fi／以太网服务",
                         "IPv4 使用 DHCP、IPv6 使用自动配置；代理与手动 DNS 回到新服务默认值",
                         "保留接口顺序、原启停状态和旧网络位置，供失败或验收前切回",
                         "由系统重新建立动态路由，刷新 DNS 缓存"]
            manual.append("特殊虚拟服务不复制到新位置；如需使用，请在所属软件中重新启用。")
            manual.append("确认联网正常后，可在系统网络位置设置中手动移除不再需要的旧位置。")
            if any(s["staticAddress"] for s in inventory["services"]):
                manual.append("存在手动地址：此层将改为 DHCP，请先确认网络支持自动获取并记下所需参数。")
        manual.append("若系统要求登录网络或重新授权连接，请手动完成；必要时重启 Mac。")
        return {"schema": 1, "kind": "network_rebuild", "level": level,
                "token": self.token(inventory, level), "location": inventory["location"],
                "services": [{"name": s["name"], "device": s["device"], "enabled": s["enabled"]}
                             for s in inventory["services"]],
                "automatic": automatic, "manual": manual, "blocked": blocked,
                "preserved": PRESERVED, "canApply": not blocked, "pending": current["pending"]}

    @staticmethod
    def shell_digest(captured):
        lines = ["{"]
        for i, (args, _) in enumerate(captured):
            lines.append("v=$(" + shlex.join(args) + ") || exit 71")
            lines.append("printf '%s\\n%s\\n' " + shlex.quote(str(i)) + ' "$v"')
        lines.append("} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'")
        return "\n".join(lines)

    def script(self, inventory, level, new_location="", rollback=""):
        def net(action, *args):
            if action not in MUTATIONS:
                raise NetworkError("未授权的网络操作。")
            return shlex.join([NET, action, *args])

        lines = [
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH",
            "LC_ALL=C; LANG=C; export LC_ALL LANG", "unset BASH_ENV ENV CDPATH", "set -eu",
            "/bin/mkdir " + shlex.quote(str(ROOT_LOCK)) + " || exit 72",
            "restore_service=''; created=''",
            "cleanup() {", "rc=$?; trap - EXIT HUP INT TERM; set +e",
            'if [ -n "$restore_service" ]; then ' + NET + ' -setnetworkserviceenabled "$restore_service" on >/dev/null 2>&1; fi',
        ]
        if new_location:
            lines += [
                'if [ "$rc" -ne 0 ] && [ -n "$created" ]; then',
                "if " + net("-switchtolocation", inventory["location"]) + " >/dev/null 2>&1; then",
                net("-deletelocation", new_location) + " >/dev/null 2>&1",
                "printf 'NETWORK_ROLLBACK_OK\\n'",
                "else printf 'NETWORK_ROLLBACK_FAILED\\n'; fi; fi",
            ]
        lines += ["/bin/rmdir " + shlex.quote(str(ROOT_LOCK)) + ' >/dev/null 2>&1; exit "$rc"; }',
                  "trap cleanup EXIT; trap 'exit 130' HUP INT TERM",
                  "current=$(" + self.shell_digest(inventory["captured"]) + ")",
                  '[ "$current" = ' + shlex.quote(self.digest(inventory["captured"])) + " ] || exit 73",
                  "if /usr/bin/pgrep -u " + str(self.uid) + " -x 'Claude|claude' >/dev/null; then exit 74; else rc=$?; [ \"$rc\" -eq 1 ] || exit 74; fi",
                  "processes=$(/bin/ps -axww -o uid=,comm=,args=) || exit 74",
                  'if printf "%s\\n" "$processes" | /usr/bin/awk -v uid=' + str(self.uid)
                  + r""" '$1 == uid && ($0 ~ /\/\.local\/share\/claude\/versions\// || $0 ~ /@anthropic-ai\/claude-code\/(cli\.js|bin\/claude)/ || ($0 ~ /--user-data-dir=/ && $0 ~ /claude-switcher-safe\./)) { found=1 } END { exit(found ? 0 : 1) }'; then exit 74; fi""",
                  "step() {",
                  'index=$1; shift; if out=$("$@" 2>&1); then :; else printf "NETWORK_STEP:%s:fail\\n" "$index"; return 1; fi',
                  'case "$out" in *"** Error"*|*"Error:"*|*"not a recognized network"*|*"You cannot"*) printf "NETWORK_STEP:%s:fail\\n" "$index"; return 1;; esac',
                  'printf "NETWORK_STEP:%s:ok\\n" "$index"; }', "printf 'NETWORK_STARTED\\n'"]
        # Check again after the administrator dialog; a preview is not a lasting lock.
        if level >= 2:
            check = ("if /usr/bin/pgrep -x " + shlex.quote("|".join(re.escape(name) for name in NETWORK_APPS))
                     + ' >/dev/null; then exit 74; else rc=$?; [ "$rc" -eq 1 ] || exit 74; fi')
            lines.insert(-1, check)
            lines.insert(-1, 'vpn=$(/usr/sbin/scutil --nc list) || exit 74')
            lines.insert(-1, 'if printf "%s" "$vpn" | /usr/bin/grep -Eq "\\((Connected|Connecting|Disconnecting)\\)"; then exit 74; fi')
        count = 0

        def step(command):
            nonlocal count
            count += 1
            lines.append("step " + str(count) + " " + command)

        if rollback:
            step(net("-switchtolocation", rollback))
        elif level == 3:
            step(net("-createlocation", new_location))
            lines.append("created=1")
            step(net("-switchtolocation", new_location))
            for service in inventory["services"]:
                name = service["name"]
                step(net("-createnetworkservice", name, service["hardware"]))
                step(net("-setdhcp", name))
                step(net("-setv6automatic", name))
                if not service["enabled"]:
                    step(net("-setnetworkserviceenabled", name, "off"))
        else:
            for service in inventory["services"]:
                name = service["name"]
                if level == 2:
                    for action in ("-setdnsservers", "-setsearchdomains", "-setproxybypassdomains"):
                        step(net(action, name, "Empty"))
                    for action in ("-setwebproxystate", "-setsecurewebproxystate",
                                   "-setsocksfirewallproxystate", "-setautoproxystate", "-setproxyautodiscovery"):
                        step(net(action, name, "off"))
                if service["enabled"]:
                    lines.append("restore_service=" + shlex.quote(name))
                    step(net("-setnetworkserviceenabled", name, "off"))
                    step(net("-setnetworkserviceenabled", name, "on"))
                    lines.append("restore_service=''")
        step("/usr/bin/dscacheutil -flushcache")
        step("/usr/bin/killall -HUP mDNSResponder")
        if inventory["wifi"]:
            lines += ["wifi=$(" + self.shell_digest(inventory["wifi"]) + ")",
                      '[ "$wifi" = ' + shlex.quote(self.digest(inventory["wifi"])) + " ] || exit 75"]
        lines.append("printf 'NETWORK_DONE\\n'")
        return "\n".join(lines) + "\n"

    def apply(self, level, token):
        if not re.fullmatch(r"[0-9a-f]{64}", token):
            raise NetworkError("请先预检，再确认对应层级的执行清单。")
        with self.exclusive():
            if self.state()["pending"]:
                raise NetworkError("上一次网络重建尚未验收，不能覆盖恢复记录。")
            inventory = self.inventory()
            if token != self.token(inventory, level):
                raise NetworkError("网络配置或所选层级已变化，请重新预检；未执行修改。")
            if (inventory["claudeRunning"] or inventory["isolatedRunning"]
                    or (level >= 2 and (inventory["runningApps"] or inventory["connectedVPN"]))):
                raise NetworkError("请先退出 Claude／Claude Code，以及会写回设置的代理或 VPN 软件，再重新预检。")
            new_location = "Claude-Network-" + os.urandom(8).hex() if level == 3 else ""
            record = {"schema": 1, "level": level, "token": token, "phase": "authorizing",
                      "oldLocation": inventory["location"], "newLocation": new_location}
            self.save(record)
            result = self.runner.authorize(self.script(inventory, level, new_location))
            started = "NETWORK_STARTED" in result["output"]
            successful = result["ok"] and "NETWORK_DONE" in result["output"]
            if not started:
                self.pending.unlink()
                return {"schema": 1, "kind": "network_rebuild", "success": False, "pending": False,
                        "message": ("已取消管理员授权，未修改网络。"
                                    if result["cancelled"] else "授权或执行前复核未通过，未修改网络；请重新预检。")}
            record["phase"] = "awaiting_validation" if successful else "failed"
            self.save(record)
            completed = len(re.findall(r"(?m)^NETWORK_STEP:\d+:ok$", result["output"]))
            return {"schema": 1, "kind": "network_rebuild", "success": successful, "pending": True,
                    "completedSteps": completed, "canRollback": level == 3,
                    "message": ("所选网络操作已完成，Wi-Fi 已保存网络列表复核一致。请恢复代理，再检查保护环境；尚未允许启动 Claude。"
                                if successful else "网络操作未全部完成，启动保护保持锁定。请检查网络；已启用服务会尽力恢复，第 3 层失败会尝试切回旧位置。")}

    def rollback(self):
        with self.exclusive():
            state = self.state()
            if not state["pending"] or not state["canRollback"]:
                raise NetworkError("没有可以自动切回的旧网络位置。")
            inventory = self.inventory()
            if (inventory["location"] != state["newLocation"] or inventory["claudeRunning"]
                    or inventory["isolatedRunning"] or inventory["runningApps"] or inventory["connectedVPN"]):
                raise NetworkError("当前网络位置已变化，或相关软件仍在运行；请退出软件并在系统设置中确认。")
            result = self.runner.authorize(self.script(inventory, 1, rollback=state["oldLocation"]))
            successful = result["ok"] and "NETWORK_DONE" in result["output"]
            state = {key: value for key, value in state.items() if key not in ("pending", "canRollback")}
            state["phase"] = "awaiting_validation" if successful else "failed"
            self.save(state)
            return {"schema": 1, "kind": "network_rebuild", "success": successful, "pending": True,
                    "message": ("已切回旧网络位置，请重新检查保护环境。" if successful
                                else "未能完成切回，记录已保留；请在系统网络位置设置中手动切回。")}

    def finish(self):
        # The shell bridge calls this only after its ordinary full safety check succeeds.
        with self.exclusive():
            if not self.state()["pending"]:
                raise NetworkError("当前没有待验收的网络重建。")
            self.pending.unlink()
        return {"schema": 1, "kind": "network_rebuild", "success": True, "pending": False,
                "message": "已通过现有安全检查并解除重建锁定；跳过项仍表示未验证。"}


def network_main(args):
    if (not args or args[0] not in ("preview", "apply", "state", "busy", "has-pending", "finish", "rollback")
            or (args[0] in ("preview", "apply") and (len(args) < 2 or args[1] not in ("1", "2", "3")))
            or len(args) != {"preview": 2, "apply": 3, "state": 1, "busy": 1,
                            "has-pending": 1, "finish": 1, "rollback": 1}.get(args[0], 0)):
        raise NetworkError("用法：network-rebuild preview <1|2|3>；apply <层级> <预检令牌>；state；validate；rollback")
    backend = NetworkRebuild(Runner())
    if args[0] == "busy":
        return 0 if backend.busy() else 1
    if args[0] == "has-pending":
        return 0 if backend.state()["pending"] else 1
    if args[0] == "preview":
        value = backend.preview(int(args[1]))
    elif args[0] == "apply":
        value = backend.apply(int(args[1]), args[2])
    elif args[0] == "state":
        value = dict(backend.state(), schema=1, kind="network_rebuild")
    elif args[0] == "rollback":
        value = backend.rollback()
    else:
        value = backend.finish()
    print(json.dumps(value, ensure_ascii=False))
    return 0 if value.get("success", True) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(network_main(sys.argv[1:]))
    except (NetworkError, OSError, ValueError, TypeError, KeyError):
        error = sys.exc_info()[1]
        message = str(error) if isinstance(error, NetworkError) else "网络重建状态或系统操作失败，请重新预检；未确认完成。"
        print(json.dumps({"schema": 1, "kind": "network_rebuild", "success": False,
                          "message": message}, ensure_ascii=False))
        raise SystemExit(2)
PY_NETWORK_REBUILD
fi

if [ "${1:-}" = "_support" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_SUPPORT'
import datetime
import json
import os
from pathlib import Path
import platform
import re
import sys
import tempfile
import zipfile


OPTIONAL = ("IP一致", "DNS", "WebRTC", "客户端语言", "ASN属性", "生态可达性")
ALL_CHECKS = ("代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS",
              "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性")
DEFAULTS = {"disabled": [], "allowOptionalFailures": False, "logging": True}
LOG_LIMIT = 512 * 1024


def fail():
    print("配置或诊断参数无效", file=sys.stderr)
    raise SystemExit(2)


def paths():
    home = Path.home()
    return home / ".claude-switcher", home / "Library/Logs/claude-switcher/client.log"


def validate(value):
    if not isinstance(value, dict) or set(value) - set(DEFAULTS):
        fail()
    result = dict(DEFAULTS)
    disabled = value.get("disabled", [])
    if (not isinstance(disabled, list)
            or any(not isinstance(item, str) or item not in OPTIONAL for item in disabled)
            or len(disabled) != len(set(disabled))):
        fail()
    result["disabled"] = [name for name in OPTIONAL if name in disabled]
    for key in ("allowOptionalFailures", "logging"):
        if key in value:
            if type(value[key]) is not bool:
                fail()
            result[key] = value[key]
    return result


def load_config():
    base, _ = paths()
    path = base / "checks.json"
    if not path.exists():
        return dict(DEFAULTS)
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        fail()
    return validate(value)


def app_version():
    value = os.environ.get("CLAUDE_SWITCHER_VERSION", "").strip()
    if value and re.fullmatch(r"[A-Za-z0-9._-]{1,40}", value):
        return value
    base, _ = paths()
    try:
        value = (base / "version.txt").read_text(encoding="utf-8").strip()
    except OSError:
        value = ""
    return value if re.fullmatch(r"[A-Za-z0-9._-]{1,40}", value) else "unknown"


def write_log(args):
    config = load_config()
    if not config["logging"]:
        return
    if len(args) != 4 or not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", args[0]):
        fail()
    if not re.fullmatch(r"\d{1,3}", args[1]) or not 0 <= int(args[1]) <= 255:
        fail()
    if not re.fullmatch(r"\d{1,12}", args[2]):
        fail()
    tokens = args[3].split()
    checks = {}
    for token in tokens:
        match = re.fullmatch(r"([A-Za-z0-9\u4e00-\u9fff]+)=(ok|warn|fail|skip)", token)
        if not match or match.group(1) not in ALL_CHECKS or match.group(1) in checks:
            fail()
        checks[match.group(1)] = match.group(2)
    summary = " ".join(name + "=" + checks[name] for name in ALL_CHECKS if name in checks)
    line = (datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
            + " version=" + app_version() + " command=" + args[0]
            + " exit=" + str(int(args[1])) + " duration_ms=" + str(int(args[2]))
            + ((" " + summary) if summary else "") + "\n")
    _, log_path = paths()
    log_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(log_path.parent, 0o700)
        if log_path.exists() and log_path.stat().st_size + len(line.encode("utf-8")) > LOG_LIMIT:
            os.replace(log_path, log_path.with_name("client.log.1"))
        with log_path.open("a", encoding="utf-8") as handle:
            os.chmod(log_path, 0o600)
            handle.write(line)
    except OSError:
        fail()


def recent_status():
    base, _ = paths()
    result = {}
    try:
        lines = (base / "last-check.txt").read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    for line in lines:
        match = re.fullmatch(r"([^=]+)=(ok|warn|fail|skip)(?::.*)?", line)
        if match and match.group(1) in ALL_CHECKS and match.group(1) not in result:
            result[match.group(1)] = match.group(2)
    return result


def safe_log_lines():
    _, log_path = paths()
    try:
        lines = log_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    allowed = re.compile(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00 version=[A-Za-z0-9._-]+ "
        r"command=[a-z][a-z0-9-]{0,31} exit=\d{1,3} duration_ms=\d{1,12}"
        r"(?: (?:[A-Za-z0-9\u4e00-\u9fff]+=(?:ok|warn|fail|skip) ?)*)?")
    return [line for line in lines[-2000:] if allowed.fullmatch(line)]


def export_diagnostics(args):
    if len(args) != 1 or not args[0] or "\x00" in args[0]:
        fail()
    destination = Path(args[0]).expanduser()
    base, _ = paths()
    environment = {"schema_version": 1, "platform": platform.system(),
                   "app_version": app_version(),
                   "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, value in (("environment.json", environment),
                                ("recent-status.json", {"checks": recent_status()}),
                                ("checks.json", load_config())):
                archive.writestr(name, json.dumps(value, ensure_ascii=False, indent=2) + "\n")
            archive.writestr("client.log", "\n".join(safe_log_lines()) + "\n")
        os.chmod(destination, 0o600)
    except OSError:
        fail()
    print("OK:诊断日志已导出（不含 IP、凭据、账号或代理配置）")


def main(args):
    if not args:
        fail()
    action = args[0]
    if action == "config" and len(args) == 1:
        config = load_config()
        print("disabled=" + ",".join(config["disabled"]))
        print("allowOptionalFailures=" + str(int(config["allowOptionalFailures"])))
        print("logging=" + str(int(config["logging"])))
    elif action == "config-get" and len(args) == 1:
        print(json.dumps(load_config(), ensure_ascii=False))
    elif action == "config-set" and len(args) == 2:
        raw = args[1].encode("utf-8")
        if len(raw) > 16384:
            fail()
        try:
            config = validate(json.loads(raw.decode("utf-8")))
        except (ValueError, UnicodeError):
            fail()
        base, _ = paths()
        try:
            base.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd, temporary = tempfile.mkstemp(prefix=".checks-", dir=base)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(config, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
            os.chmod(temporary, 0o600)
            os.replace(temporary, base / "checks.json")
        except OSError:
            fail()
    elif action == "tools-get" and len(args) == 5:
        base, _ = paths()
        keep, policy = base / "keep-in-workspace.txt", base / "webrtc-policy"
        if base.is_symlink() or keep.is_symlink() or policy.is_symlink():
            fail()
        try:
            text = keep.read_text(encoding="utf-8") if keep.exists() else ""
            mode = policy.read_text(encoding="utf-8").strip() if policy.exists() else "proxy"
            if len(text.encode("utf-8")) > 16384 or mode not in ("proxy", "reject"):
                fail()
            print(json.dumps(dict(keepPaths=text, policy=mode, country=args[1],
                                  timezone=args[2], locale=args[3], client=args[4]), ensure_ascii=False))
        except (OSError, UnicodeError):
            fail()
    elif action == "keep-set" and len(args) == 2:
        base, _ = paths()
        destination = base / "keep-in-workspace.txt"
        try:
            text = json.loads(args[1])
            if (not isinstance(text, str) or len(text.encode("utf-8")) > 16384
                    or "\x00" in text or base.is_symlink() or destination.is_symlink()):
                fail()
            data = Path.home() / "Library/Application Support/Claude"
            for line in text.splitlines():
                if not line or line.lstrip().startswith("#"):
                    continue
                if line.startswith("/") or ".." in line or not Path(line).parts:
                    fail()
                current = data
                if current.is_symlink():
                    fail()
                for part in Path(line).parts:
                    current = current / part
                    if current.is_symlink():
                        fail()
            base.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd, temporary = tempfile.mkstemp(prefix=".keep-", dir=base)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as handle:
                    handle.write(text.rstrip("\r\n") + "\n" if text else "")
                os.chmod(temporary, 0o600)
                os.replace(temporary, destination)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        except (OSError, ValueError, UnicodeError):
            fail()
        print("OK:跨账号保留列表已保存，下次切换时生效")
    elif action == "log":
        write_log(args[1:])
    elif action == "export-diagnostics":
        export_diagnostics(args[1:])
    else:
        fail()


if __name__ == "__main__":
    main(sys.argv[1:])
PY_SUPPORT
fi

# 随现有单脚本更新分发;在任何账号状态读写、审计/修复/启动之前分派。
if [ "${1:-}" = "diagnose-proxy" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_PROXY_DIAGNOSE'
"""Read-only transport diagnostics for an explicitly selected HTTP/SOCKS proxy."""
import argparse
import concurrent.futures
import ipaddress
import json
import math
import os
import subprocess
from urllib.parse import urlsplit


TARGETS = (
    ("anthropic_api", "https://api.anthropic.com/v1/models"),
    ("claude_web", "https://claude.ai/"),
)


def select_proxy(args, environ):
    if args.proxy is not None:
        value, source = args.proxy, "argument"
    elif args.config is not None:
        with open(args.config, encoding="utf-8") as handle:
            config = json.load(handle)
        if not isinstance(config, dict):
            raise ValueError("invalid config")
        value, source = config.get("proxy_url"), "config"
    else:
        value, source = environ.get("CLAUDE_SWITCHER_PROXY_URL"), "environment"
    if not isinstance(value, str) or not value.strip():
        raise ValueError("proxy required")
    value = value.strip()
    if any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("invalid proxy")
    parsed = urlsplit(value)
    if (parsed.scheme not in ("http", "https", "socks5", "socks5h")
            or not parsed.hostname or parsed.port is None
            or not 0 < parsed.port < 65536
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        raise ValueError("invalid proxy")
    try:
        loopback = ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        loopback = parsed.hostname.lower() == "localhost"
    # Do not include proxy addresses, credentials, or private config paths in reports.
    public = {"scheme": parsed.scheme, "port": parsed.port,
              "host_scope": "loopback" if loopback else "remote",
              "authentication_configured": parsed.username is not None,
              "source": source}
    return value, public


def probe(name, url, proxy, environ):
    # -q ignores curlrc. Pass proxy credentials over stdin, never in argv/reports.
    quoted = proxy.replace("\\", "\\\\").replace('"', '\\"')
    config = 'proxy = "' + quoted + '"\n'
    args = ["curl", "-q", "--config", "-", "-sS", "-o", os.devnull,
            "--proto", "=https", "--noproxy", "", "--connect-timeout", "6",
            "--max-time", "12", "-w",
            "%{http_code}\t%{http_connect}\t%{ssl_verify_result}\t%{time_appconnect}\t%{time_total}",
            url]
    keep = {"PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "SYSTEMROOT"}
    clean_env = {k: v for k, v in environ.items() if k in keep}
    result = {"name": name, "url": url, "transport_reached": False,
              "access": "unknown"}
    try:
        process = subprocess.run(args, input=config, env=clean_env, capture_output=True,
                                 text=True, timeout=15)
        fields = process.stdout.strip().split()
        status, connect, verify = map(int, fields[:3])
        tls, elapsed = map(float, fields[3:5])
        if (not 0 <= status <= 599 or not 0 <= connect <= 599 or verify < 0
                or not math.isfinite(tls) or not math.isfinite(elapsed)
                or tls < 0 or elapsed < 0):
            raise ValueError("invalid probe metrics")
        reached = process.returncode == 0 and status > 0 and verify == 0 and tls > 0
        access = ("unauthenticated" if status == 401 else
                  "access_restricted" if status in (403, 407) else
                  "server_error" if status >= 500 else "http_response")
        result.update(curl_exit=process.returncode, http_status=status,
                      proxy_connect_status=connect, tls_verified=reached,
                      elapsed_seconds=elapsed, transport_reached=reached,
                      access=access if reached else "unknown")
    except subprocess.TimeoutExpired:
        result["error"] = "probe_timeout"
    except OSError:
        result["error"] = "curl_unavailable"
    except (ValueError, IndexError):
        result["error"] = "invalid_probe_output"
    return result


class DiagnosticParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default error can echo private URLs or paths from argv.
        raise ValueError("invalid arguments")


def main(argv=None, environ=None):
    parser = DiagnosticParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument("--proxy", help="explicit proxy URL including a port")
    choice.add_argument("--config", help="private JSON file containing proxy_url")
    environ = os.environ if environ is None else environ
    report = {"schema_version": 1, "mode": "proxy_diagnostics",
              "scope": "unauthenticated_transport_only",
              "account_status": "not_evaluated", "leak_protection": "not_evaluated",
              "launch_allowed": None, "application_started": False,
              "system_modified": False}
    try:
        args = parser.parse_args(argv)
        proxy, public = select_proxy(args, environ)
    except (OSError, ValueError, TypeError):
        report.update(state="configuration_error", error="invalid_or_missing_proxy",
                      hint="Use --proxy, --config, or CLAUDE_SWITCHER_PROXY_URL; an explicit port is required.")
        print(json.dumps(report, ensure_ascii=False))
        return 2
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(probe, name, url, proxy, environ) for name, url in TARGETS]
        checks = [f.result() for f in futures]
    reached = all(check["transport_reached"] for check in checks)
    report.update(proxy=public, checks=checks,
                  state="transport_reached" if reached else "transport_failed")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if reached else 1


if __name__ == "__main__":
    raise SystemExit(main())
PY_PROXY_DIAGNOSE
fi

if [ "${1:-}" = "flclash-repair" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_FLCLASH_REPAIR'
import datetime
import json
import re
import secrets
import shutil
import sqlite3
import sys
from pathlib import Path


DOMAINS = (
    "claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com",
    "challenges.cloudflare.com", "datadoghq.com", "segment.io", "stripe.com",
    "stripe.network", "stripecdn.com", "intercom.io", "intercomcdn.com",
    "intercomassets.com",
)
PORTS = (3478, 5349, 19302)
REQUIRED_RULE_COLUMNS = {
    "id", "profile_id", "rule_action", "content", "rule_target",
    "rule_provider", "sub_rule", "no_resolve", "src", "order",
}


def fail(message):
    print(f"FAIL:{message}", file=sys.stderr)
    raise SystemExit(1)


def clean_scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        value = value[1:-1]
    if not value or re.search(r"[,\r\n\x00-\x1f]", value):
        fail("代理组名无效")
    return value


def select_group(config, configured):
    groups = []
    in_groups = False
    current = None
    for line in config.splitlines():
        if re.match(r"^proxy-groups:\s*(?:#.*)?$", line):
            in_groups = True
            continue
        if in_groups and re.match(r"^[A-Za-z_]", line):
            break
        if not in_groups:
            continue
        name = re.match(r"^\s*-\s*name:\s*(.+?)\s*$", line)
        if name:
            current = clean_scalar(name.group(1))
            continue
        if re.match(r"^\s*type:\s*select\s*$", line) and current:
            groups.append(current)
            current = None
    if configured in groups:
        return configured
    return groups[0] if groups else "GLOBAL"


def current_profile(home):
    import subprocess

    path = home / "shared_preferences.json"
    try:
        if path.is_file():
            values = json.loads(path.read_text(encoding="utf-8"))
            profile_id = values.get("flutter.currentProfileId")
        elif home.resolve() == (Path.home() / "Library/Application Support/com.follow.clash").resolve():
            # macOS Flutter preferences use CFPreferences, not shared_preferences.json.
            result = subprocess.run(
                ["/usr/bin/defaults", "read", "com.follow.clash", "flutter.config"],
                capture_output=True, text=True, timeout=5, check=True,
            )
            profile_id = json.loads(result.stdout).get("currentProfileId")
        else:
            fail("无法读取当前 Profile，已保留原配置")
        if type(profile_id) is not int or profile_id <= 0:
            fail("无法识别当前 Profile，已保留原配置")
        return profile_id
    except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
        fail("无法读取当前 Profile，已保留原配置")


def repair(home, configured):
    if not home.is_dir():
        fail("FlClash 配置目录不存在")
    database = home / "database.sqlite"
    config_path = home / "config.yaml"
    if not database.is_file() or not config_path.is_file():
        fail("缺少 FlClash 数据库或运行配置")
    profile_id = current_profile(home)
    config = config_path.read_text(encoding="utf-8")
    if not re.search(r"enhanced-mode:\s*[\"\']?fake-ip\b|fake-ip:\s*true\b", config, re.I):
        fail("请先在 FlClash 中启用 fake-IP，再执行修复")
    target = select_group(config, configured)
    backup = None
    try:
        with sqlite3.connect(database, timeout=5) as db:
            db.execute("PRAGMA busy_timeout=5000")
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if version < 17 or version > 21:
                fail("FlClash 数据库版本不受支持，已保留原配置")
            columns = {row[1] for row in db.execute("PRAGMA table_info(rules)")}
            if not REQUIRED_RULE_COLUMNS.issubset(columns):
                fail("FlClash 规则表结构不受支持，已保留原配置")
            if not db.execute("SELECT 1 FROM profiles WHERE id=?", (profile_id,)).fetchone():
                fail("当前 Profile 不在数据库中，已保留原配置")
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            backup = home / f".claude-switcher-backup-{stamp}-{secrets.token_hex(4)}.sqlite"
            db.execute("VACUUM INTO ?", (str(backup),))
        with sqlite3.connect(database, timeout=5) as db:
            db.execute("PRAGMA busy_timeout=5000")
            db.execute("BEGIN IMMEDIATE")
            try:
                for action, content in [("DOMAIN_SUFFIX", value) for value in DOMAINS] + [("DST_PORT", str(value)) for value in PORTS]:
                    exists = db.execute(
                        "SELECT 1 FROM rules WHERE profile_id=? AND rule_action=? AND content=? AND rule_target=?",
                        (profile_id, action, content, target),
                    ).fetchone()
                    if exists:
                        continue
                    while True:
                        rule_id = secrets.randbits(62)
                        if not db.execute("SELECT 1 FROM rules WHERE id=?", (rule_id,)).fetchone():
                            break
                    db.execute(
                        'INSERT INTO rules (id, profile_id, rule_action, content, rule_target, rule_provider, sub_rule, no_resolve, src, "order") '
                        "VALUES (?, ?, ?, ?, ?, NULL, NULL, 0, 0, NULL)",
                        (rule_id, profile_id, action, content, target),
                    )
                db.commit()
            except Exception:
                db.rollback()
                raise
        print(f"BACKUP={backup}")
    except SystemExit:
        raise
    except Exception as error:
        if backup and backup.exists():
            shutil.copyfile(backup, database)
        fail(f"写入 FlClash 规则失败:{type(error).__name__}")


def rollback(home, backup_name):
    backup = Path(backup_name).resolve()
    if backup.parent != home.resolve() or not backup.name.startswith(".claude-switcher-backup-") or backup.suffix != ".sqlite" or not backup.is_file():
        fail("回滚备份无效")
    database = home / "database.sqlite"
    try:
        for suffix in ("-wal", "-shm"):
            (home / f"database.sqlite{suffix}").unlink(missing_ok=True)
        shutil.copyfile(backup, database)
        print("OK:已回滚 FlClash 配置")
    except OSError as error:
        fail(f"回滚失败:{type(error).__name__}")


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "repair":
        repair(Path(sys.argv[2]), sys.argv[3])
        return
    if len(sys.argv) == 4 and sys.argv[1] == "rollback":
        rollback(Path(sys.argv[2]), sys.argv[3])
        return
    fail("用法: flclash-repair repair <配置目录> <代理组> | rollback <配置目录> <备份>")


if __name__ == "__main__":
    main()
PY_FLCLASH_REPAIR
fi

if [ "${1:-}" = "clash-rules" ]; then
    shift
    exec "${CLAUDE_SWITCHER_PYTHON:-python3}" - "$@" <<'PY_CLASH_RULES'
"""Install and verify the Clash Verge global script without trusting Merge.yaml text."""
import http.client
import ipaddress
import json
import os
import re
import shutil
import socket
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit


DOMAINS = (
    "claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com",
    "challenges.cloudflare.com", "datadoghq.com", "segment.io", "stripe.com",
    "stripe.network", "stripecdn.com", "intercom.io", "intercomcdn.com",
    "intercomassets.com",
)
PORTS = (3478, 5349, 19302)
SCRIPT_BEGIN = "// >>> claude-switcher managed rules >>>"
SCRIPT_END = "// <<< claude-switcher managed rules <<<"
MERGE_BEGIN = "# >>> claude-switcher pinned rules >>>"
MERGE_END = "# <<< claude-switcher pinned rules <<<"


def fail(message):
    print("FAIL:" + message, file=sys.stderr)
    raise SystemExit(1)


def read_yaml_scalar(path, key):
    if not path.exists():
        return ""
    match = re.search(r"^" + re.escape(key) + r":[ \t]*(.*)$", read_text(path), re.M)
    if not match:
        return ""
    value = match.group(1).strip()
    if value.startswith('"'):
        return json.JSONDecoder().raw_decode(value)[0]
    if value.startswith("'"):
        match = re.fullmatch(r"'((?:[^']|'')*)'\s*(?:#.*)?", value)
        if not match:
            fail("无法读取 Clash 控制接口配置")
        return match.group(1).replace("''", "'")
    value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
    if value in {"", "null", "~"}:
        return ""
    if value.startswith(("|", ">", "*", "&", "[", "{")):
        fail("Clash 控制接口需要普通标量配置")
    return value


def read_text(path):
    return path.read_bytes().decode("utf-8-sig")


def controller_config(clash_dir):
    for name in ("clash-verge.yaml", "verge.yaml"):
        path = clash_dir / name
        unix_path = read_yaml_scalar(path, "external-controller-unix")
        secret = read_yaml_scalar(path, "secret")
        if "\r" in secret or "\n" in secret:
            fail("Clash 控制接口密钥格式无效")
        if unix_path and hasattr(socket, "AF_UNIX"):
            if not os.path.isabs(unix_path):
                fail("Clash Unix socket 路径必须为绝对路径")
            # 生成的配置可能记着已失效的临时 socket(Clash Verge 重启后路径会变);
            # 依次探测配置路径与服务实际使用的用户级 socket,跳过已失效的残留文件
            candidates = [unix_path]
            if hasattr(os, "getuid"):
                candidates.append(
                    "/var/run/clash-verge-service/users/%d/verge-mihomo.sock" % os.getuid())
            for candidate in candidates:
                if not os.path.isabs(candidate) or not Path(candidate).exists():
                    continue
                probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    probe.settimeout(0.2)
                    probe.connect(candidate)
                except OSError:
                    continue
                finally:
                    probe.close()
                return ("unix", candidate, None), secret
        endpoint = read_yaml_scalar(path, "external-controller")
        if endpoint:
            if not endpoint.startswith(("http://", "https://")):
                endpoint = "http://" + endpoint
            parsed = urlsplit(endpoint)
            host = parsed.hostname
            if host in {"0.0.0.0", "::"}:
                host = "127.0.0.1" if host == "0.0.0.0" else "::1"
            if host != "localhost":
                try:
                    local = ipaddress.ip_address(host).is_loopback
                except ValueError:
                    local = False
                if not local:
                    fail("只允许验证本机 Clash 控制接口")
            if (parsed.scheme not in {"http", "https"} or not parsed.port
                    or parsed.username or parsed.password or parsed.path not in {"", "/"}
                    or parsed.query or parsed.fragment):
                fail("Clash 控制接口地址格式无效")
            return (parsed.scheme, host, parsed.port), secret
    fail("未找到本机 Clash 控制接口，无法验证内核规则")


def api_get(endpoint, secret, path):
    headers = {"Accept": "application/json"}
    if secret:
        headers["Authorization"] = "Bearer " + secret
    scheme, host, port = endpoint
    connection = None
    try:
        if scheme == "unix":
            connection = http.client.HTTPConnection("localhost", timeout=2)
            connection.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.sock.settimeout(2)
            connection.sock.connect(host)
        else:
            cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
            connection = cls(host, port, timeout=2)
        # http.client connects directly; inherited proxy variables are never used.
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        if response.status != 200:
            fail("Clash 内核接口未返回成功状态")
        data = response.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            fail("Clash 内核接口响应过大")
        value = json.loads(data.decode("utf-8"))
        if not isinstance(value, dict):
            fail("Clash 内核接口返回格式异常")
        return value
    except (http.client.HTTPException, OSError, ValueError) as exc:
        fail("Clash 内核接口不可用(" + exc.__class__.__name__ + ")")
    finally:
        if connection:
            connection.close()


def selected_proxy(proxies, name, seen=None):
    seen = set() if seen is None else seen
    if name in seen:
        fail("代理组存在循环引用")
    seen.add(name)
    item = proxies.get(name)
    if not isinstance(item, dict):
        fail("代理组不存在:" + name)
    if "all" in item or "now" in item:
        current = item.get("now")
        if not current or current == name:
            fail("代理组没有可用的当前节点:" + name)
        return selected_proxy(proxies, current, seen)
    return item


def validate_group(state, group, policy):
    proxies = state.get("proxies", {}).get("proxies", {})
    if not isinstance(proxies, dict) or group in {"DIRECT", "REJECT", "GLOBAL", "PASS"}:
        fail("请选择实际的代理组")
    if not isinstance(proxies.get(group), dict) or "all" not in proxies[group]:
        fail("配置的代理组不存在")
    selected = selected_proxy(proxies, group)
    selected_type = str(selected.get("type", "")).lower()
    if selected_type in {"direct", "reject", "block"}:
        fail("代理组当前节点为直连或拒绝，请选择代理节点")
    if policy == "proxy" and selected.get("udp") is not True:
        fail("当前节点未确认支持 UDP，请更换节点或选择 reject 策略")


def norm(value):
    return re.sub(r"[\s()_-]+", "", str(value).upper()).replace("&&", ",")


def expected_rules():
    rules = [("port", p) for p in PORTS]
    rules.extend(("domain", d) for d in DOMAINS)
    return rules


def verify_runtime(clash_dir, group, policy, allow_global=False):
    base, secret = controller_config(clash_dir)
    mode = str(api_get(base, secret, "/configs").get("mode", "")).lower()
    if allow_global and mode == "global":
        proxies = api_get(base, secret, "/proxies").get("proxies", {})
        selected = selected_proxy(proxies, "GLOBAL")
        if str(selected.get("type", "")).lower() in {"", "direct", "pass", "reject", "rejectdrop", "block"}:
            fail("全局模式：GLOBAL 未选择代理节点")
        return "全局模式：流量走全局代理（不使用置顶规则）"
    if mode != "rule":
        fail("直连模式：置顶规则不生效" if mode == "direct" else "Clash 当前不是 rule 模式")
    state = {"rules": api_get(base, secret, "/rules"), "proxies": api_get(base, secret, "/proxies")}
    validate_group(state, group, policy)
    rules = state["rules"].get("rules")
    if not isinstance(rules, list):
        fail("Clash /rules 返回格式异常")
    expected = expected_rules()
    if len(rules) < len(expected):
        fail("运行中的规则数量不足")
    for index, (kind, value) in enumerate(expected):
        if kind == "port":
            rule = rules[index]
            target = "REJECT" if policy == "reject" else group
            payload = norm(rule.get("payload", "")) if isinstance(rule, dict) else ""
            if (not isinstance(rule, dict) or str(rule.get("type", "")).upper() != "AND"
                    or payload != "NETWORK,UDP,DSTPORT," + str(value)
                    or rule.get("proxy") != target
                    or (rule.get("extra") or {}).get("disabled") is True):
                fail("运行规则未按策略置顶:UDP/" + str(value))
        else:
            rule = rules[index]
            if (not isinstance(rule, dict)
                    or str(rule.get("type", "")).upper().replace("_", "-") not in {"DOMAIN-SUFFIX", "DOMAINSUFFIX"}
                    or str(rule.get("payload", "")).strip().lower() != value
                    or rule.get("proxy") != group
                    or (rule.get("extra") or {}).get("disabled") is True):
                fail("运行规则未按策略置顶:" + value)
    return f"规则模式：{len(DOMAINS)} 个域名、{len(PORTS)} 条 UDP 规则已置顶"


def rule_strings(group, policy):
    target = "REJECT" if policy == "reject" else group
    return ([f"AND,((NETWORK,UDP),(DST-PORT,{port})),{target}" for port in PORTS] +
            [f"DOMAIN-SUFFIX,{domain},{group}" for domain in DOMAINS])


def managed_block(group, policy):
    encoded = json.dumps(rule_strings(group, policy), ensure_ascii=False)
    group_json = json.dumps(group, ensure_ascii=False)
    return f"""{SCRIPT_BEGIN}
;(function () {{
  const originalMain = main;
  const pinnedRules = {encoded};
  const group = {group_json};
  main = function (config, ...args) {{
    const result = originalMain(config, ...args);
    if (!result || typeof result !== \"object\" || Array.isArray(result)) throw new Error(\"claude-switcher: original main must return a config object\");
    if (!Array.isArray(result[\"proxy-groups\"]) || !result[\"proxy-groups\"].some((item) => item && item.name === group)) throw new Error(\"claude-switcher: configured proxy group missing\");
    if (result.rules !== undefined && !Array.isArray(result.rules)) throw new Error(\"claude-switcher: rules must be an array\");
    result.rules = pinnedRules.concat((result.rules || []).filter((rule) => !pinnedRules.includes(rule)));
    return result;
  }};
}})();
{SCRIPT_END}"""


def script_text(path, group, policy):
    old = read_text(path) if path.exists() else ""
    block = managed_block(group, policy)
    if SCRIPT_BEGIN in old:
        if old.count(SCRIPT_BEGIN) != 1 or old.count(SCRIPT_END) != 1:
            fail("Script.js 中存在未闭合的 claude-switcher 管理块")
        pattern = re.compile(re.escape(SCRIPT_BEGIN) + r".*?" + re.escape(SCRIPT_END), re.S)
        if old.index(SCRIPT_END) < old.index(SCRIPT_BEGIN):
            fail("Script.js 中的管理块顺序无效")
        return pattern.sub(lambda _: block, old, count=1)
    if SCRIPT_END in old:
        fail("Script.js 中存在孤立的 claude-switcher 管理块")
    if not old.strip():
        old = "function main(config) { return config; }\n"
    match = re.search(r"function\s+main\s*\(", old)
    if not match:
        fail("现有 Script.js 没有可组合的 main(config)，已停止以免覆盖用户脚本")
    return old + ("" if old.endswith("\n") else "\n") + block + "\n"


def migrate_merge(path):
    if not path.exists():
        return None
    old = read_text(path)
    if MERGE_BEGIN not in old:
        if MERGE_END in old:
            fail("Merge.yaml 中存在孤立的 claude-switcher 管理块")
        return old
    if old.count(MERGE_BEGIN) != 1 or old.count(MERGE_END) != 1 or old.index(MERGE_END) < old.index(MERGE_BEGIN):
        fail("Merge.yaml 中存在未闭合的 claude-switcher 管理块")
    pattern = re.compile(r"(?ms)^[ \t]*" + re.escape(MERGE_BEGIN) + r"[ \t]*\r?\n.*?^[ \t]*" + re.escape(MERGE_END) + r"[ \t]*\r?\n?")
    new = pattern.sub("", old, count=1)
    return new


def write_changes(changes):
    changes = {path: data.encode("utf-8") for path, data in changes.items()
               if not path.exists() or path.read_bytes() != data.encode("utf-8")}
    originals, staged, replaced = {}, {}, []
    try:
        for path, data in changes.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            originals[path] = path.read_bytes() if path.exists() else None
            if path.exists():
                shutil.copy2(path, path.with_name(path.name + ".bak." + str(time.time_ns())))
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".claude-switcher-", delete=False) as handle:
                staged[path] = Path(handle.name)
                handle.write(data)
            if path.exists():
                staged[path].chmod(path.stat().st_mode & 0o777)
        for path, temp in staged.items():
            os.replace(temp, path)
            replaced.append(path)
    except OSError:
        for path in reversed(replaced):
            if originals[path] is None:
                path.unlink()
            else:
                path.write_bytes(originals[path])
        raise
    finally:
        for temp in staged.values():
            if temp.exists():
                temp.unlink()


def assess_probe(policy, expected_ip, output, exit_code):
    if exit_code != "0":
        return "fail:STUN 探测执行失败，未确认 UDP 出口"
    try:
        expected = ipaddress.IPv4Address(expected_ip)
    except ValueError:
        return "fail:未获取有效的 IPv4 出口，无法比对 STUN 结果"
    if output == "RESULT:NONE":
        if policy == "reject":
            return "ok:常见 STUN UDP 拒绝规则已验证，探测无响应"
        return "fail:STUN 无响应，无法确认 UDP 是否经过代理"
    if not output.startswith("RESULT:"):
        return "fail:STUN 探测结果格式异常"
    try:
        addresses = [ipaddress.IPv4Address(value) for value in output[7:].split(",")]
    except ValueError:
        return "fail:STUN 探测结果格式异常"
    if policy == "reject":
        return "fail:拒绝策略下仍收到 STUN 响应，请检查运行规则"
    if any(address != expected for address in addresses):
        return "fail:STUN 暴露了非代理出口地址"
    return "ok:STUN 仅返回代理出口地址"


def main():
    if len(sys.argv) < 5:
        fail("内部参数不足")
    action, clash_dir, base_dir, group = sys.argv[1:5]
    clash_dir = Path(clash_dir)
    base_dir = Path(base_dir)
    policy_path = base_dir / "webrtc-policy"
    policy = sys.argv[5] if len(sys.argv) > 5 else ""
    policy = policy or (read_text(policy_path).strip() if policy_path.exists() else "proxy")
    if policy not in {"proxy", "reject"}:
        fail("WEBRTC_POLICY 只能是 proxy 或 reject")
    if action == "policy":
        print(policy)
        return 0
    if action == "assess" and len(sys.argv) == 9:
        print(assess_probe(policy, *sys.argv[6:9]))
        return 0
    if action == "mode":
        base, secret = controller_config(clash_dir)
        print(str(api_get(base, secret, "/configs").get("mode", "")).lower())
        return 0
    if action == "status":
        print(verify_runtime(clash_dir, group, policy, allow_global=True))
        return 0
    if not group or any(char in group for char in ",\r\n"):
        fail("代理组名为空或包含规则分隔符")
    if action == "verify":
        verify_runtime(clash_dir, group, policy)
        print("OK:运行时规则已验证(" + policy + ")")
        return 0
    if action != "write":
        fail("未知内部动作")

    base, secret = controller_config(clash_dir)
    state = {"configs": api_get(base, secret, "/configs"),
             "proxies": api_get(base, secret, "/proxies")}
    if str(state["configs"].get("mode", "")).lower() != "rule":
        fail("Clash 当前不是 rule 模式")
    validate_group(state, group, policy)
    profiles = clash_dir / "profiles"
    script_path = profiles / "Script.js"
    merge_path = profiles / "Merge.yaml"
    new_script = script_text(script_path, group, policy)
    new_merge = migrate_merge(merge_path)
    changes = {script_path: new_script, policy_path: policy + "\n"}
    if new_merge is not None:
        changes[merge_path] = new_merge
    write_changes(changes)
    print("OK:全局脚本已写入(" + policy + ")")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, TypeError, AttributeError):
        fail("规则配置处理失败，未确认修复；请检查配置格式与权限")
PY_CLASH_RULES
fi

# ============ 安装时可配置项(默认兜底值;实际运行优先读取 ~/.claude-switcher/config.env) ============
PROXY_MODE="clash-verge"       # 代理客户端: tag|clash-verge|flclash|bettbox|shadowrocket|sing-box|clashx|surge|auto
PROXY_GROUP="IpEqual"          # Clash 代理组名(安装时自动探测)
COUNTRY_TARGET="US"            # 目标出口国家(安装时按出口自动识别)
TZ_TARGET="America/New_York"   # 锁定时区,应与出口IP所在城市一致
LOCALE_TARGET="en_US"          # 锁定地区格式
# ============================================================

# 发行来源与代理客户端独立；自有 main 保留上游更新和 TAG 适配。
UPDATE_REPOSITORY="anyun-hy/claude-switcher"
UPDATE_BRANCH="main"

DATA="$HOME/Library/Application Support/Claude"
BASE="$HOME/.claude-switcher"
CONFIG_ENV="$BASE/config.env"
LOG="$HOME/Library/Logs/claude-switch.log"
CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
ROUTE_MISSED=""
KEEP_STAGED=0
# Maintenance is a persistent launch interlock, not a substitute for the safety audit.
# Check it before account initialization, and never stop the installed bodyguard.
NETWORK_PENDING="$BASE/network-rebuild-pending.json"
case "${1:-}" in
    switch|cli|open-safe)
        if [ -e "$NETWORK_PENDING" ] || [ -L "$NETWORK_PENDING" ] || [ -e /var/run/local.claude-switcher.network-rebuild.lock ]; then
            echo "FAIL:网络重建尚未验收，请恢复代理并在工具中检查保护环境；暂不允许启动 Claude"
            exit 1
        fi
        ;;
    fix|set-client|set-region|update|check|checkdetail)
        if [ -e "$NETWORK_PENDING" ] || [ -L "$NETWORK_PENDING" ] || [ -e /var/run/local.claude-switcher.network-rebuild.lock ]; then
            "$0" _network-rebuild busy >/dev/null 2>&1
            busy_rc=$?
            if [ "$busy_rc" -ne 1 ]; then
                echo "FAIL:网络重建正在执行或状态无效，请等待完成后再操作"
                exit 1
            fi
        fi
        ;;
esac
case "${1:-}" in
    detect-client|get-tool-config|set-keep-paths|network-rebuild) ;;  # 状态探测不初始化账号目录。
    *) mkdir -p "$BASE/accounts" ;;
esac

load_runtime_config() {
    local cfg="${1:-$CONFIG_ENV}" line key val
    [ -f "$cfg" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            ''|'#'*) continue ;;
            *=*)
                key="${line%%=*}"
                val="${line#*=}"
                val="${val#\"}"
                val="${val%\"}"
                case "$key" in
                    PROXY_MODE)     PROXY_MODE="$val" ;;
                    PROXY_GROUP)    PROXY_GROUP="$val" ;;
                    COUNTRY_TARGET) COUNTRY_TARGET="$val" ;;
                    TZ_TARGET)      TZ_TARGET="$val" ;;
                    LOCALE_TARGET)  LOCALE_TARGET="$val" ;;
                esac
                ;;
        esac
    done < "$cfg"
}

save_runtime_config() {
    local cfg="${1:-$CONFIG_ENV}" tmp
    mkdir -p "$(dirname "$cfg")" || return 1
    tmp="${cfg}.tmp.$$"
    {
        printf 'PROXY_MODE="%s"\n' "$PROXY_MODE"
        printf 'PROXY_GROUP="%s"\n' "$PROXY_GROUP"
        printf 'COUNTRY_TARGET="%s"\n' "$COUNTRY_TARGET"
        printf 'TZ_TARGET="%s"\n' "$TZ_TARGET"
        printf 'LOCALE_TARGET="%s"\n' "$LOCALE_TARGET"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$cfg"
}

load_runtime_config

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG"; }

CHECKS_DISABLED=""
ALLOW_OPTIONAL_FAILURES=0
load_check_config() {
    local config key value
    config=$("$0" _support config 2>/dev/null) || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            disabled) CHECKS_DISABLED="$value" ;;
            allowOptionalFailures) ALLOW_OPTIONAL_FAILURES="$value" ;;
        esac
    done <<< "$config"
}
check_disabled() { case ",$CHECKS_DISABLED," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
optional_failure() {
    [ "$ALLOW_OPTIONAL_FAILURES" = "1" ] || fails="$fails;$1"
}
optional_result() {
    local name="$1" state="$2" detail="${3:-}"
    if check_disabled "$name"; then
        echo "$name=skip:用户已禁用"
    elif [ "$state" = "fail" ] && [ "$ALLOW_OPTIONAL_FAILURES" = "1" ]; then
        echo "$name=warn:非关键失败已忽略${detail:+($detail)}"
    else
        echo "$name=$state${detail:+:$detail}"
    fi
}
log_result() {
    local started="$1" command="$2" rc="$3" summary="${4:-}"
    "$0" _support log "$command" "$rc" "$(( ($(date +%s) - started) * 1000 ))" "$summary" >/dev/null 2>&1 || true
}

# TUN 在线判定:统计 fake-ip 网段地址数量,仅 1 个时视为正常接管,>1 视为多 TUN 冲突
tun_count() {
    local c
    c=$(ifconfig 2>/dev/null | grep -c 'inet 198\.18\.') || c=0
    echo "${c:-0}"
}
tun_up() { [ "$(tun_count)" -eq 1 ]; }

# 代理客户端显示名(供检查细节输出)
proxy_name() {
    case "${1:-$PROXY_MODE}" in
        tag)          echo "TAG" ;;
        clash-verge)  echo "Clash Verge" ;;
        flclash)      echo "FlClash" ;;
        bettbox)      echo "Bettbox" ;;
        shadowrocket) echo "Shadowrocket" ;;
        sing-box)     echo "sing-box" ;;
        clashx)       echo "ClashX" ;;
        surge)        echo "Surge" ;;
        auto)         echo "代理客户端" ;;
        *)            echo "${1:-$PROXY_MODE}" ;;
    esac
}

# 可 open -a 启动的客户端 App 名(sing-box/auto 无标准 App,返回空)
proxy_app_name() {
    case "$PROXY_MODE" in
        tag)          echo "TAG" ;;
        clash-verge)  echo "Clash Verge" ;;
        flclash)      echo "FlClash" ;;
        bettbox)      echo "Bettbox" ;;
        shadowrocket) echo "Shadowrocket" ;;
        clashx)       echo "ClashX" ;;
        surge)        echo "Surge" ;;
        *)            echo "" ;;
    esac
}

# Shadowrocket 在 Mac 上表现为 VPN 配置;launchd/非图形环境下 scutil 可能查不到该行,此时以 TUN 判定为准(避免误杀)
shadowrocket_up() {
    nc=$(scutil --nc list 2>/dev/null)
    if echo "$nc" | grep -q 'com.liguangming.Shadowrocket'; then
        echo "$nc" | grep 'com.liguangming.Shadowrocket' | grep -q '(Connected)'
    else
        tun_up
    fi
}

# Keep the process probe and classifier in sync with daemons/claude-bodyguard.sh.
# macOS ps comm can report argv[0]. Use the kernel's executable path instead.
macos_process_paths() {
    /usr/bin/python3 -I -S -B - <<'PY'
import ctypes
import sys

lib = ctypes.CDLL("/usr/lib/libproc.dylib")
lib.proc_listallpids.argtypes = (ctypes.c_void_p, ctypes.c_int)
lib.proc_listallpids.restype = ctypes.c_int
lib.proc_pidpath.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
lib.proc_pidpath.restype = ctypes.c_int
count = lib.proc_listallpids(None, 0)
if count <= 0:
    sys.exit(1)
pids = (ctypes.c_int * (count + 256))()
count = lib.proc_listallpids(pids, ctypes.sizeof(pids))
if not 0 < count < len(pids):
    sys.exit(1)
buf = ctypes.create_string_buffer(4096)
readable = False
for pid in pids[:count]:
    if pid <= 0 or lib.proc_pidpath(pid, buf, len(buf)) <= 0:
        continue
    path = buf.value
    if path.startswith(b"/") and not any(c in path for c in (b"\t", b"\r", b"\n")):
        sys.stdout.buffer.write(str(pid).encode() + b"\t" + path + b"\n")
        readable = True
sys.exit(0 if readable else 1)
PY
}

proxy_processes() {
    local paths
    paths=$(macos_process_paths 2>/dev/null) || return 1
    printf '%s\n' "$paths" | awk -F '\t' '
        NF == 2 && $1 ~ /^[1-9][0-9]*$/ && $2 ~ /^\// {
            name = $2; sub(/^.*\//, "", name)
            if ($2 == "/Applications/TAG.app/Contents/Resources/bin/mihomo-universal-tag-darwin") mode = "tag"
            else if (name ~ /^verge-mihomo(-[[:alnum:]_.-]+)?$/) mode = "clash-verge"
            else if (name == "FlClashCore" || name == "FlClash") mode = "flclash"
            else if (name == "BettboxCore" || name == "Bettbox") mode = "bettbox"
            else if (name == "sing-box") mode = "sing-box"
            else if (name ~ /^ClashX( Pro| Meta)?$/) mode = "clashx"
            else if (name == "Surge" || $2 ~ /\/Surge[.]app\/Contents\//) mode = "surge"
            else next
            printf "%s\t%s\n", mode, $1
        }'
}

proxy_seen() {
    [[ $'\n'$1 == *$'\n'"$2"$'\t'* ]]
}

# 代理内核在线判定:按安装时识别的客户端分派;auto 时任一命中即活
proxy_alive() {
    [ "$PROXY_MODE" != "shadowrocket" ] || { shadowrocket_up; return; }
    local processes="${1-}"
    [ "$#" -gt 0 ] || processes=$(proxy_processes) || return 1
    case "$PROXY_MODE" in
        tag|clash-verge|flclash|bettbox|sing-box|clashx|surge) proxy_seen "$processes" "$PROXY_MODE" ;;
        auto) [ -n "$processes" ] || shadowrocket_up ;;
        *) proxy_seen "$processes" clash-verge ;;
    esac
}

# 只读探测除当前配置客户端外,系统中是否还有其他代理客户端在运行(绝不自动修改 PROXY_MODE)
detect_other_clients() {
    [ "$PROXY_MODE" = "auto" ] && return 0
    local processes="${1-}" list="" mode
    [ "$#" -gt 0 ] || processes=$(proxy_processes) || return 1
    for mode in tag clash-verge flclash bettbox sing-box clashx surge; do
        if [ "$mode" != "$PROXY_MODE" ] && proxy_seen "$processes" "$mode"; then
            list="${list:+$list/}$(proxy_name "$mode")"
        fi
    done
    printf '%s\n' "$list"
}

detect_client_state() {
    local alive=0 tcnt others="" processes probe_error=0
    if processes=$(proxy_processes); then
        proxy_alive "$processes" && alive=1
        others=$(detect_other_clients "$processes")
    else
        probe_error=1
    fi
    tcnt=$(tun_count)
    echo "configured=$PROXY_MODE"
    echo "alive=$alive"
    echo "tun_count=$tcnt"
    echo "others=${others:-none}"
    [ "$probe_error" -eq 0 ] || echo "process_probe=error"
}

# 单文件内嵌 Python 的隔离入口;策略从 WEBRTC_POLICY 或持久化文件读取。
clash_rules() {
    local action="$1"
    shift
    "${BASH:-/bin/bash}" "$0" clash-rules "$action" "$CLASH_DIR" "$BASE" "$PROXY_GROUP" "${WEBRTC_POLICY:-}" "$@"
}

# 只接受运行中内核加载的规则，不再用配置文本或 fake-ip 代替。
merge_ok() { clash_rules verify >/dev/null 2>&1; }
stun_ok() { merge_ok; }
# 当前 Clash 模式(rule/global/direct);读取失败返回空
clash_mode() { clash_rules mode 2>/dev/null; }

# 置顶规则行为检测:三个生态域名全部解析到 fake-ip 段(198.18.x.x)即视为已置顶;未命中域名记入 ROUTE_MISSED
route_ok() {
    ROUTE_MISSED=""
    local d a
    for d in claude.ai api.anthropic.com claudeusercontent.com; do
        a=$(dig +short +time=3 +tries=1 "$d" 2>/dev/null | head -1)
        case "$a" in
            198.18.*) ;;
            *) ROUTE_MISSED="$ROUTE_MISSED $d" ;;
        esac
    done
    [ -z "$ROUTE_MISSED" ]
}

# 国家代码 → 默认 IANA 时区(cloudflare trace 等来源不带时区时使用)
default_tz_for() {
    case "$1" in
        US) echo America/New_York ;; JP) echo Asia/Tokyo ;; TW) echo Asia/Taipei ;;
        HK) echo Asia/Hong_Kong ;; SG) echo Asia/Singapore ;; GB) echo Europe/London ;;
        DE) echo Europe/Berlin ;; FR) echo Europe/Paris ;; KR) echo Asia/Seoul ;;
        AU) echo Australia/Sydney ;; CA) echo America/Toronto ;;
        *) echo America/New_York ;;
    esac
}

# 出口探测辅助:严格校验两位大写国家码与 IANA 时区格式
_geo_valid_country() {
    case "$1" in [A-Z][A-Z]) return 0 ;; *) return 1 ;; esac
}
_geo_valid_tz() {
    [[ "$1" =~ ^[A-Za-z_]+/[A-Za-z_]+(/[A-Za-z_]+)?$ ]]
}
_geo_json_field() {
    printf '%s\n' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}
_geo_diag_add() {
    GEO_DIAG="${GEO_DIAG:+$GEO_DIAG; }$1"
    if [ -n "${GEO_DIAG_FILE:-}" ]; then
        printf '%s\n' "$1" >>"$GEO_DIAG_FILE"
    fi
}
# 取一个源;失败把简短原因(HTTP 码/超时)记进诊断,不打印
_geo_fetch() {
    local out rc code
    _GEO_BODY=""
    out=$(curl -s --max-time 8 -w '\n%{http_code}' "$1" 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then
        _geo_diag_add "$2 超时/连接失败"
        return 1
    fi
    if [ -z "$out" ]; then
        _geo_diag_add "$2 无响应"
        return 1
    fi
    code=$(printf '%s\n' "$out" | tail -n 1)
    case "$code" in
        200)
            _GEO_BODY=$(printf '%s\n' "$out" | sed '$d')
            return 0 ;;
        [0-9][0-9][0-9])
            _geo_diag_add "$2 HTTP $code"
            return 1 ;;
        *)
            # 没有 -w 状态行时按成功处理(兼容 curl 替身/中间层)
            _GEO_BODY="$out"
            return 0 ;;
    esac
}
# 记录一个成功源;首个成功源优先,后续来源国家不一致只告警
_geo_consider() {
    [ -z "$1" ] && return 0
    if [ -z "$_GEO_CC" ]; then
        _GEO_CC="$1"; _GEO_TZ="$2"; _GEO_SRC="$3"
    elif [ "$1" != "$_GEO_CC" ]; then
        printf 'WARN:出口国家不一致(%s=%s %s=%s),采用优先级更高的 %s\n' \
            "$_GEO_SRC" "$_GEO_CC" "$3" "$1" "$_GEO_SRC" >&2
    fi
}

# 多源出口探测:ipinfo → ipapi → ifconfig → cloudflare trace,成功源按此优先级取首个;
# 全部失败输出 "||",各源失败原因写入 GEO_DIAG_FILE(命令替换会丢子 shell 变量)。
geo_lookup() {
    local cc tz loc
    local _GEO_BODY="" _GEO_CC="" _GEO_TZ="" _GEO_SRC=""
    GEO_DIAG=""

    if _geo_fetch "https://ipinfo.io/json" ipinfo; then
        cc=$(_geo_json_field "$_GEO_BODY" country)
        tz=$(_geo_json_field "$_GEO_BODY" timezone)
        if _geo_valid_country "$cc"; then
            _geo_valid_tz "$tz" || tz=$(default_tz_for "$cc")
            _geo_consider "$cc" "$tz" ipinfo
        else
            _geo_diag_add "ipinfo 国家字段无效"
        fi
    fi

    if _geo_fetch "https://ipapi.co/json/" ipapi; then
        cc=$(_geo_json_field "$_GEO_BODY" country_code)
        tz=$(_geo_json_field "$_GEO_BODY" timezone)
        if _geo_valid_country "$cc"; then
            _geo_valid_tz "$tz" || tz=$(default_tz_for "$cc")
            _geo_consider "$cc" "$tz" ipapi
        else
            _geo_diag_add "ipapi 国家字段无效"
        fi
    fi

    if _geo_fetch "https://ifconfig.co/json" ifconfig; then
        cc=$(_geo_json_field "$_GEO_BODY" country_iso)
        tz=$(_geo_json_field "$_GEO_BODY" timezone)
        if _geo_valid_country "$cc"; then
            _geo_valid_tz "$tz" || tz=$(default_tz_for "$cc")
            _geo_consider "$cc" "$tz" ifconfig
        else
            _geo_diag_add "ifconfig 国家字段无效"
        fi
    fi

    if _geo_fetch "https://www.cloudflare.com/cdn-cgi/trace" cloudflare; then
        loc=$(printf '%s\n' "$_GEO_BODY" | tr -d '\r' | sed -n 's/^loc=\([A-Za-z][A-Za-z]\)$/\1/p' | head -n 1 | tr 'a-z' 'A-Z')
        if _geo_valid_country "$loc"; then
            _geo_consider "$loc" "$(default_tz_for "$loc")" cloudflare
        else
            _geo_diag_add "cloudflare loc 无效"
        fi
    fi

    if [ -z "$_GEO_CC" ]; then
        printf '||\n'
        return 1
    fi
    printf '%s|%s|%s\n' "$_GEO_CC" "$_GEO_TZ" "$_GEO_SRC"
    return 0
}

# 国家代码 → 地区格式映射(未收录的国家回退 en_US)
locale_for() {
    case "$1" in
        US) echo en_US ;; JP) echo ja_JP ;; TW) echo zh_TW ;; HK) echo zh_HK ;;
        SG) echo en_SG ;; GB) echo en_GB ;; DE) echo de_DE ;; FR) echo fr_FR ;;
        KR) echo ko_KR ;; AU) echo en_AU ;; CA) echo en_CA ;; *) echo en_US ;;
    esac
}

# IP 审查:记录出口IP并统计最近48h内不同IP个数(账号画像风险指标)
iphist_count() {
    [ -z "$1" ] && { echo 0; return; }
    local HIST="$BASE/iphistory.log"
    local now=$(date +%s)
    echo "$1 $now" >>"$HIST"
    # 裁掉48小时(172800秒)以前的记录
    awk -v cutoff=$((now-172800)) '$2>=cutoff' "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
    # 统计48h内不同IP个数
    awk '{print $1}' "$HIST" | sort -u | wc -l | tr -d ' '
}

# ---------- 安全检查 ----------
check() {
    load_check_config || { echo "FAIL:检查配置无效，请恢复默认设置"; return 1; }
    fails=""

    local others tcnt processes
    if ! processes=$(proxy_processes); then
        fails="$fails;无法核验代理进程"
    else
        others=$(detect_other_clients "$processes")
        if ! proxy_alive "$processes"; then
            fails="$fails;代理内核未运行${others:+(检测到 $others 运行中)}"
        elif [ -n "$others" ]; then
            fails="$fails;检测到多个代理客户端同时运行($(proxy_name) 与 $others)"
        fi
    fi
    tcnt=$(tun_count)
    if [ "$tcnt" -gt 1 ]; then
        fails="$fails;检测到多个TUN网卡冲突(${tcnt}个)"
    elif [ "$tcnt" -ne 1 ]; then
        fails="$fails;TUN网卡不在线"
    fi

    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    [ "$loc" = "$COUNTRY_TARGET" ] || fails="$fails;出口IP异常(${ip:-无}/${loc:-未知},期望$COUNTRY_TARGET)"
    ipwarn=""
    if ! check_disabled "IP一致"; then
        lastip=""; [ -f "$BASE/lastip" ] && lastip=$(cat "$BASE/lastip")
        if [ -n "$ip" ] && [ -n "$lastip" ] && [ "$ip" != "$lastip" ]; then
            ipwarn="注意:出口IP与上次不同($lastip -> $ip)"
        fi
        [ -n "$ip" ] && echo "$ip" > "$BASE/lastip"

        # IP 审查:48h 内出口 IP 变化 ≥3 次追加警告(只 warn 不 fail)
        ipn=$(iphist_count "$ip")
        if [ "$ipn" -ge 3 ] 2>/dev/null; then
            ipwarn="${ipwarn:+$ipwarn; }注意:48h内出口IP变化${ipn}次,账号画像有风险,建议固定节点"
        fi
    fi

    tz=$(readlink /etc/localtime 2>/dev/null)
    [ "$tz" = "/var/db/timezone/zoneinfo/$TZ_TARGET" ] || fails="$fails;时区异常($tz)"

    locale=$(defaults read -g AppleLocale 2>/dev/null)
    [ "$locale" = "$LOCALE_TARGET" ] || fails="$fails;地区异常($locale)"

    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    echo "$v6" | grep -qi 'off' || fails="$fails;IPv6未关闭"

    if ! check_disabled "DNS"; then
        dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
        case "$dnsip" in
            198.18.*) ;;
            *) optional_failure "DNS未走隧道" ;;
        esac
    fi

    if ! check_disabled "WebRTC"; then
        wr=$(webrtc_status "$ip")
        case "$wr" in fail:*) optional_failure "WebRTC:${wr#fail:}" ;; esac
    fi

    guard_state=$(bodyguard_status)
    case "$guard_state" in
        ok:*) ;;
        fail:*) fails="$fails;保镖:${guard_state#fail:}" ;;
        *) fails="$fails;保镖:状态无法验证" ;;
    esac

    # 置顶规则:Clash Verge 验证运行内核;全局模式下全部流量走代理,规则不适用;其他客户端只看行为检测
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        [ "$(clash_mode)" = "global" ] || merge_ok || fails="$fails;运行中置顶规则未验证"
    else
        route_ok || fails="$fails;置顶规则缺失(未命中:${ROUTE_MISSED# })"
    fi

    if ! check_disabled "客户端语言"; then
        defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | grep -q 'en-US' || {
            syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
            [[ "$syslang" == en* ]] || optional_failure "客户端语言为中文"
        }
    fi

    if ! check_disabled "生态可达性"; then
        r1=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null)
        r2=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models 2>/dev/null)
        { [ "$r1" = "000" ] || [ "$r2" = "000" ]; } && optional_failure "Anthropic生态不可达($r1/$r2)"
    fi

    if [ -n "$fails" ]; then
        echo "FAIL:${fails#;}"
        return 1
    fi
    echo "OK:$ip${ipwarn:+|$ipwarn}"
    return 0
}

# WebRTC/STUN 探测:返回 RESULT:ip,ip 或 RESULT:NONE 或空
webrtc_test() {
    python3 "$BASE/stun-probe.py" 2>/dev/null
}

# 日常检查与修复共用此判断。先确认规则，再允许探测，避免向已知直连路径发包。
webrtc_status() {
    local verified result probe_rc assessment mode leak wips w
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        mode=$(clash_mode)
        # 全局模式不经过规则匹配,直接按"STUN 结果是否等于当前出口"判断
        if [ "$mode" = "global" ]; then
            result=$(webrtc_test)
            probe_rc=$?
            [ "$probe_rc" -ne 0 ] && { echo "fail:STUN 探测执行失败，未确认 UDP 出口"; return; }
            case "$result" in
                RESULT:NONE) echo "warn:UDP 无响应,全局模式下无法验证(可能已被节点拦截)" ;;
                RESULT:*)
                    leak=""
                    wips=${result#RESULT:}
                    OLDIFS=$IFS; IFS=','
                    for w in $wips; do [ -n "$1" ] && [ "$w" != "$1" ] && leak="$leak $w"; done
                    IFS=$OLDIFS
                    if [ -n "$leak" ]; then
                        echo "fail:暴露非代理IP:${leak# }"
                    else
                        echo "ok:仅暴露代理出口IP(全局模式)"
                    fi ;;
                *) echo "fail:STUN 探测结果格式异常" ;;
            esac
            return
        fi
        if ! verified=$(clash_rules verify 2>&1); then
            echo "fail:运行规则未验证:${verified#FAIL:}"
            return
        fi
    fi
    result=$(webrtc_test)
    probe_rc=$?
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        assessment=$(clash_rules assess "$1" "$result" "$probe_rc" 2>/dev/null)
    elif [ "$PROXY_MODE" = "flclash" ]; then
        # FlClash 规则由本工具写入，因此允许用户显式选择 reject；默认仍按 proxy 评估。
        local flclash_policy="${WEBRTC_POLICY:-}"
        if [ -z "$flclash_policy" ] && [ -r "$BASE/webrtc-policy" ]; then
            flclash_policy=$(cat "$BASE/webrtc-policy" 2>/dev/null)
        fi
        case "$flclash_policy" in
            reject) assessment=$(WEBRTC_POLICY=reject clash_rules assess "$1" "$result" "$probe_rc" 2>/dev/null) ;;
            *) assessment=$(WEBRTC_POLICY=proxy clash_rules assess "$1" "$result" "$probe_rc" 2>/dev/null) ;;
        esac
    else
        # 其他客户端的规则由用户管理，不能把 reject 的无响应视为已验证。
        assessment=$(WEBRTC_POLICY=proxy clash_rules assess "$1" "$result" "$probe_rc" 2>/dev/null)
    fi
    case "$assessment" in
        ok:*|warn:*|fail:*) echo "$assessment" ;;
        *) echo 'fail:无法评估 STUN 结果' ;;
    esac
}

# 保镖脚本由 root 安装，MODE 在安装时写死。核心切客户端后必须检测模式一致性，
# 否则旧保镖可能按错误的代理进程状态关闭 Claude，单看 launchctl 在线会误报成功。
bodyguard_status() {
    local snapshot
    if ! snapshot=$(launchctl print system/local.claude-bodyguard 2>/dev/null); then
        echo 'fail:保镖离线（系统服务未注册或不可访问）'
        return
    fi
    local guard="/Library/Application Support/claude-switcher/claude-bodyguard.sh"
    if [ ! -r "$guard" ]; then
        echo 'fail:守护脚本不可读或缺失(请重新运行安装器)'
        return
    fi
    local guard_mode
    guard_mode=$(sed -n 's/^MODE="\([^"]*\)".*/\1/p' "$guard" | head -1)
    if [ -z "$guard_mode" ]; then
        echo 'fail:守护模式无法识别(请重新运行安装器)'
        return
    fi
    if [ "$guard_mode" != "$PROXY_MODE" ]; then
        echo "fail:客户端不一致(核心=$PROXY_MODE,保镖=$guard_mode;请点一键修复或重新运行安装器同步)"
        return
    fi
    local heartbeat="${guard%/*}/claude-bodyguard-health" modern=0
    local attempt last_exit runs baseline="" state reason="未收到有效巡检记录"
    local record fields schema stamp mode result now age attributes
    grep -q '^HEALTH_SCHEMA=1$' "$guard" && modern=1
    # New daemons publish a root-owned completion heartbeat. Legacy installations
    # remain compatible only when an actual successful run is observed, never
    # merely because launchd knows the service. All observation is read-only.
    for attempt in $(seq 0 15); do
        last_exit=$(printf '%s\n' "$snapshot" | awk '$1=="last" && $2=="exit" && $3=="code" && $4=="=" && $5 ~ /^-?[0-9]+$/ {print $5; exit}')
        if [ -n "$last_exit" ] && [ "$last_exit" -ne 0 ]; then
            echo "fail:保镖巡检异常（最近退出码 ${last_exit}）"
            return
        fi
        if [ "$modern" -eq 1 ]; then
            if [ -L "$heartbeat" ] || { [ -e "$heartbeat" ] && [ ! -f "$heartbeat" ]; }; then
                echo 'fail:保镖巡检记录类型异常'
                return
            fi
            if [ -r "$heartbeat" ]; then
                attributes=$(stat -f '%u:%Lp' "$heartbeat" 2>/dev/null)
                if [ "$attributes" != "0:644" ]; then
                    echo 'fail:保镖巡检记录权限异常（应为 root 所有、644）'
                    return
                fi
                record=$(cat "$heartbeat")
                fields=$(printf '%s\n' "$record" | awk -F= '
                    NF!=2 {bad=1}
                    $1=="schema" {s=$2; a++}
                    $1=="time" {t=$2; b++}
                    $1=="mode" {m=$2; c++}
                    $1=="result" {r=$2; d++}
                    END {if(!bad && NR==4 && a==1 && b==1 && c==1 && d==1) print s "|" t "|" m "|" r}')
                IFS='|' read -r schema stamp mode result <<< "$fields"
                case "$stamp" in
                    ''|*[!0-9]*) echo 'fail:保镖巡检记录无效'; return ;;
                esac
                if [ "$schema" != "1" ] || [ "${#stamp}" -gt 12 ] ||
                   { [ "$result" != "ok" ] && [ "$result" != "error" ]; }; then
                    echo 'fail:保镖巡检记录无效'
                    return
                fi
                now=$(date +%s)
                age=$((now - 10#$stamp))
                if [ "$mode" = "$PROXY_MODE" ] && [ "$age" -ge 0 ] && [ "$age" -le 30 ]; then
                    if [ "$result" = "error" ]; then
                        echo 'fail:保镖最近巡检或保护操作失败'
                    else
                        echo "ok:巡检在线（${age}秒前完成）"
                    fi
                    return
                fi
                reason="保镖离线或巡检超时（30秒内无当前客户端的成功记录）"
            fi
        else
            runs=$(printf '%s\n' "$snapshot" | awk '/^[[:space:]]*runs = [0-9]+[[:space:]]*$/ {print $3; exit}')
            state=$(printf '%s\n' "$snapshot" | sed -n 's/^[[:space:]]*state = //p' | head -1)
            case "$runs" in
                ''|*[!0-9]*) echo 'fail:旧保镖运行状态无法验证，请更新系统守护'; return ;;
            esac
            if [ -z "$baseline" ]; then
                baseline="$runs"
            elif [ "$runs" -lt "$baseline" ]; then
                echo 'fail:保镖服务在检查期间重新载入，请重查'
                return
            elif [ "$runs" -gt "$baseline" ] && [ "$last_exit" = "0" ]; then
                case "$state" in
                    "not running"|waiting|exited)
                        echo 'ok:巡检在线（本轮执行成功；兼容旧保镖）'
                        return ;;
                esac
            fi
            reason="保镖离线或巡检停滞（15秒内未观察到成功完成）"
        fi
        [ "$attempt" -eq 15 ] && break
        sleep 1
        if ! snapshot=$(launchctl print system/local.claude-bodyguard 2>/dev/null); then
            echo 'fail:保镖离线（检查期间服务不可访问）'
            return
        fi
    done
    echo "fail:$reason"
}

# Historical enforcement is separate from live health, and only known,
# credential-free event formats are exposed as an optional UI comment.
bodyguard_last_event() {
    local line timestamp
    line=$(tail -1 "$HOME/Library/Logs/claude-bodyguard.log" 2>/dev/null)
    timestamp=$(printf '%s\n' "$line" | sed -n 's/^\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\) .*/\1/p')
    [ -n "$timestamp" ] || return 0
    case "$line" in
        *" 保镖处置("*",结果=已发送终止信号")
            printf '#保镖事件=%s 检测到保护异常，已发送终止信号\n' "$timestamp" ;;
        *" 保镖处置("*",结果=发送失败")
            printf '#保镖事件=%s 检测到保护异常，终止信号发送失败\n' "$timestamp" ;;
        *"代理离线(内核或TUN丢失),已自动关闭 Claude"*|*"检测到代理/TUN状态变化("*"已自动关闭 Claude"*)
            printf '#保镖事件=%s 检测到代理或TUN异常，执行关闭保护\n' "$timestamp" ;;
    esac
}

# 同步 root 保镖脚本中的 MODE(需管理员权限;仅允许白名单客户端名称)
sync_bodyguard_mode() {
    local mode="${1:-$PROXY_MODE}"
    local guard="/Library/Application Support/claude-switcher/claude-bodyguard.sh"
    case "$mode" in
        tag|clash-verge|flclash|bettbox|shadowrocket|sing-box|clashx|surge|auto) ;;
        *) return 1 ;;
    esac
    [ -r "$guard" ] || return 1
    osascript <<ASEOF >/dev/null 2>&1
do shell script "/usr/bin/sed -i '' 's/^MODE=\"[^\"]*\"/MODE=\"$mode\"/' '$guard' && /usr/sbin/chown root:wheel '$guard' && /bin/chmod 755 '$guard'" with prompt "切换代理客户端需要同步系统保镖守护进程" with administrator privileges
ASEOF
    local new_mode
    new_mode=$(sed -n 's/^MODE="\([^"]*\)".*/\1/p' "$guard" 2>/dev/null | head -1)
    [ "$new_mode" = "$mode" ]
}

# 逐项输出检查结果(供UI使用): 名称=ok|fail:细节
checkdetail() {
    load_check_config || { echo "检查配置无效，请恢复默认设置"; return 1; }
    local others tcnt processes
    if ! processes=$(proxy_processes); then
        echo '代理内核=fail:无法核验代理进程'
    else
        others=$(detect_other_clients "$processes")
        if proxy_alive "$processes"; then
            if [ -n "$others" ]; then
                echo "代理内核=fail:检测到多个代理软件同时运行($(proxy_name) 与 $others,请彻底退出多余软件)"
            else
                case "$PROXY_MODE" in
                    shadowrocket) echo '代理内核=ok:Shadowrocket 已连接' ;;
                    *) echo "代理内核=ok:$(proxy_name) 运行中" ;;
                esac
            fi
        elif [ -n "$others" ]; then
            echo "代理内核=fail:$(proxy_name) 未运行(检测到 $others 运行中,请手动切换客户端或启动 $(proxy_name))"
        else
            echo "代理内核=fail:$(proxy_name) 未运行"
        fi
    fi
    tcnt=$(tun_count)
    if [ "$tcnt" -eq 1 ]; then
        echo 'TUN网卡=ok:检测通过'
    elif [ "$tcnt" -gt 1 ]; then
        echo "TUN网卡=fail:检测到多个TUN网卡(${tcnt}个,请关闭多余VPN软件)"
    else
        echo 'TUN网卡=fail:不在线'
    fi
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    if [ "$loc" = "$COUNTRY_TARGET" ]; then echo "出口IP=ok:$ip/$loc"; else echo "出口IP=fail:${ip:-无}/${loc:-未知}(期望$COUNTRY_TARGET)"; fi
    if check_disabled "IP一致"; then
        optional_result "IP一致" ok
    else
        lastip=""; [ -f "$BASE/lastip" ] && lastip=$(cat "$BASE/lastip")
        ipst=""; ipdt=""
        if [ -z "$ip" ]; then ipst="fail"; ipdt="未获取到出口IP"
        elif [ -z "$lastip" ]; then ipst="ok"; ipdt="首次记录"
        elif [ "$ip" = "$lastip" ]; then ipst="ok"; ipdt="与上次一致"
        else ipst="warn"; ipdt="$lastip → $ip"; fi
        [ -n "$ip" ] && echo "$ip" > "$BASE/lastip"
        # IP 审查:48h 内出口 IP 变化 ≥3 次提示账号画像风险(只 warn 不 fail)
        ipn=$(iphist_count "$ip")
        if [ "$ipn" -ge 3 ] 2>/dev/null; then
            if [ "$ipst" = "ok" ]; then
                ipst="warn"; ipdt="48h内出口IP变化${ipn}次,账号画像有风险,建议固定节点"
            else
                ipdt="$ipdt;48h内出口IP变化${ipn}次,账号画像有风险,建议固定节点"
            fi
        fi
        optional_result "IP一致" "$ipst" "$ipdt"
    fi
    tz=$(readlink /etc/localtime 2>/dev/null)
    if [ "$tz" = "/var/db/timezone/zoneinfo/$TZ_TARGET" ]; then echo "时区=ok:${tz#/var/db/timezone/zoneinfo/}"; else echo "时区=fail:$tz"; fi
    locale=$(defaults read -g AppleLocale 2>/dev/null)
    if [ "$locale" = "$LOCALE_TARGET" ]; then echo "地区=ok:$locale"; else echo "地区=fail:$locale"; fi
    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    if echo "$v6" | grep -qi 'off'; then echo 'IPv6=ok:已关闭'; else echo 'IPv6=fail:未关闭'; fi
    if check_disabled "DNS"; then
        optional_result "DNS" ok
    else
        dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
        case "$dnsip" in
            198.18.*) optional_result "DNS" ok "走隧道" ;;
            *) optional_result "DNS" fail "未走隧道(${dnsip:-空})" ;;
        esac
    fi
    if check_disabled "WebRTC"; then
        optional_result "WebRTC" ok
    else
        wr=$(webrtc_status "$ip")
        wrst=${wr%%:*}; wrdt=""
        case "$wr" in *:*) wrdt=${wr#*:} ;; esac
        optional_result "WebRTC" "$wrst" "$wrdt"
    fi
    echo "保镖=$(bodyguard_status)"
    if declare -F bodyguard_last_event >/dev/null; then bodyguard_last_event; fi
    # 置顶规则:Clash Verge 验证运行内核;全局模式下规则不适用(全部流量已走代理)
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if [ "$(clash_mode)" = "global" ]; then
            echo '规则置顶=ok:全局模式(全部流量走代理)'
        elif merge_ok; then
            echo '规则置顶=ok'
        else
            echo '规则置顶=fail:未生效'
        fi
    else
        if route_ok; then
            echo '规则置顶=ok:行为检测通过'
        else
            echo "规则置顶=fail:未命中(${ROUTE_MISSED# }),请在 $(proxy_name) 中自行加置顶规则"
        fi
    fi
    # 12. Claude 客户端语言(单独设为英文,或系统首选语言为英文均可;防止 JS 层读出中文)
    if check_disabled "客户端语言"; then
        optional_result "客户端语言" ok
    else
        clang=$(defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | head -2)
        syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
        if echo "$clang" | grep -q 'en-US'; then
            optional_result "客户端语言" ok "en-US"
        elif [[ "$syslang" == en* ]]; then
            optional_result "客户端语言" ok "跟随系统(英文)"
        else
            optional_result "客户端语言" fail "跟随系统(中文)"
        fi
    fi
    # 13. ASN 网络属性(住宅宽带 vs 机房,按目标地区收录主流运营商)
    if check_disabled "ASN属性"; then
        optional_result "ASN属性" ok
    else
        org=$(curl -s --max-time 6 https://ipinfo.io/json 2>/dev/null | grep '"org"' | cut -d'"' -f4)
        case "$org" in
            '') optional_result "ASN属性" warn "未获取" ;;
            *Comcast*|*AT\&T*|*Verizon*|*Spectrum*|*Charter*|*Cox*|*T-Mobile*|*Cable*|*esidential*|\
            *NTT*|*KDDI*|*SoftBank*|*IIJ*|*OCN*|*So-net*|\
            *HiNet*|*Chunghwa*|*CHT*|*kbro*|*Taiwan*|*FarEasTone*|*Data\ Communication*|\
            *Singtel*|*StarHub*|*M1*|\
            *HKT*|*PCCW*|*HKBN*|*HGC*|\
            *BT*|*Sky*|*Virgin*|*TalkTalk*|*Vodafone*|\
            *Deutsche\ Telekom*|*1\&1*|*O2*) optional_result "ASN属性" ok "$org" ;;
            *) optional_result "ASN属性" warn "疑似机房($org)" ;;
        esac
    fi
    # 14. Anthropic 生态可达性
    if check_disabled "生态可达性"; then
        optional_result "生态可达性" ok
    else
        r1=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null)
        r2=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models 2>/dev/null)
        if [ "$r1" != "000" ] && [ "$r2" != "000" ]; then
            optional_result "生态可达性" ok "claude.ai:$r1 api:$r2"
        else
            optional_result "生态可达性" fail "claude.ai:$r1 api:$r2"
        fi
    fi
}

# 保留隐藏入口供安装器调用;现在生成全局 Script.js 并迁移旧管理块。
write_merge_rules() { clash_rules write; }

flclash_repair() {
    "${BASH:-/bin/bash}" "$0" flclash-repair "$@"
}

fix_flclash() {
    local dir="$HOME/Library/Application Support/com.follow.clash"
    local result backup trace ip wr i
    [ -d "$dir" ] || { echo "FIX:FlClash 配置目录不存在，无法自动修复"; return 1; }
    if proxy_alive; then
        osascript -e 'tell application "FlClash" to quit' >/dev/null 2>&1
        for i in $(seq 1 15); do
            proxy_alive || break
            sleep 1
        done
    fi
    if proxy_alive; then
        echo "FIX:FlClash 未能退出，请手动退出后重试"
        return 1
    fi
    if ! result=$(flclash_repair repair "$dir" "$PROXY_GROUP" 2>&1); then
        echo "$result"
        echo "FIX:FlClash 未修改配置"
        return 1
    fi
    backup=$(printf '%s\n' "$result" | sed -n 's/^BACKUP=//p' | head -1)
    [ -n "$backup" ] || { echo "FIX:FlClash 未生成有效备份，已中止"; return 1; }
    open -a "FlClash"
    for i in $(seq 1 30); do
        if proxy_alive && tun_up; then break; fi
        sleep 1
    done
    sleep 2
    if route_ok; then
        trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
        ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
        wr=$(webrtc_status "$ip")
        case "$wr" in
            ok:*) echo "FIX:FlClash 域名与 STUN 规则已生效 ✓"; return 0 ;;
            warn:*) echo "FIX:FlClash 规则已写入，但 STUN 状态未确认($wr)"; return 0 ;;
        esac
    fi
    osascript -e 'tell application "FlClash" to quit' >/dev/null 2>&1
    for i in $(seq 1 15); do
        proxy_alive || break
        sleep 1
    done
    local rollback_result
    if ! rollback_result=$(flclash_repair rollback "$dir" "$backup" 2>&1); then
        echo "$rollback_result"
        echo "FIX:FlClash 回滚失败，请手动恢复备份 $backup"
        return 1
    fi
    open -a "FlClash"
    echo "FIX:FlClash 验证失败，已回滚；请检查 fake-IP、代理组及节点 UDP 支持"
    return 1
}

# 一键修复:按项自动修复,每步输出结果
fix() {
    if [ "$PROXY_MODE" = "flclash" ]; then
        fix_flclash || return 1
    fi
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        local policy_result
        if ! policy_result=$(clash_rules policy 2>&1); then
            echo "FIX:WebRTC 策略无效 ✗ $policy_result"
            return 1
        fi
        WEBRTC_POLICY="$policy_result"
    fi
    echo "FIX:开始一键修复"

    # A. 代理内核 + TUN
    if [ "$PROXY_MODE" = "clash-verge" ]; then
        if ! proxy_alive; then
            echo "FIX:正在启动 Clash Verge..."
            open -a "Clash Verge"
        fi
        for i in $(seq 1 40); do
            proxy_alive && tun_up && break
            sleep 1
        done
        if proxy_alive && tun_up; then
            echo "FIX:代理内核+TUN ✓"
        else
            V="$CLASH_DIR/verge.yaml"
            if [ -f "$V" ] && grep -q '^enable_tun_mode: false' "$V"; then
                echo "FIX:检测到 TUN 开关被关闭,正在恢复..."
                osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
                sleep 3
                sed -i '' 's/^enable_tun_mode: false/enable_tun_mode: true/' "$V"
                open -a "Clash Verge"
                for i in $(seq 1 40); do
                    tun_up && break
                    sleep 1
                done
            fi
            if proxy_alive && tun_up; then
                echo "FIX:代理内核+TUN ✓(已恢复TUN开关)"
            else
                echo "FIX:代理内核/TUN ✗(请打开 Clash Verge 检查节点/线路)"
            fi
        fi
    else
        app=$(proxy_app_name)
        if ! proxy_alive && [ -n "$app" ]; then
            echo "FIX:正在启动 $app..."
            open -a "$app" >/dev/null 2>&1
        fi
        for i in $(seq 1 40); do
            proxy_alive && tun_up && break
            sleep 1
        done
        if proxy_alive && tun_up; then
            echo "FIX:代理内核+TUN ✓"
        else
            echo "FIX:代理内核/TUN ✗(请打开 $(proxy_name) 手动检查节点/线路及TUN模式)"
        fi
    fi

    # B. 时区/IPv6/DNS缓存/保镖(需管理员权限,会弹一次密码框)
    tz=$(readlink /etc/localtime 2>/dev/null)
    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    guard_state=$(bodyguard_status)
    adminCmds=""
    [ "$tz" != "/var/db/timezone/zoneinfo/$TZ_TARGET" ] && adminCmds="${adminCmds}/usr/sbin/systemsetup -settimezone $TZ_TARGET; "
    echo "$v6" | grep -qi 'off' || adminCmds="${adminCmds}networksetup -setv6off Wi-Fi; "
    if ! launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        adminCmds="${adminCmds}if [ ! -f /Library/LaunchDaemons/local.claude-bodyguard.plist ]; then cp -X $HOME/.local/bin/local.claude-bodyguard.plist /Library/LaunchDaemons/ || exit 1; fi; /usr/bin/xattr -d com.apple.quarantine /Library/LaunchDaemons/local.claude-bodyguard.plist 2>/dev/null || true; chown root:wheel /Library/LaunchDaemons/local.claude-bodyguard.plist || exit 1; chmod 644 /Library/LaunchDaemons/local.claude-bodyguard.plist || exit 1; launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist || exit 1; launchctl print system/local.claude-bodyguard >/dev/null 2>&1 || exit 1; "
    fi
    case "$guard_state" in
        fail:客户端不一致*)
            case "$PROXY_MODE" in
                tag|clash-verge|flclash|bettbox|shadowrocket|sing-box|clashx|surge|auto)
                    adminCmds="${adminCmds}/usr/bin/sed -i '' 's/^MODE=\"[^\"]*\"/MODE=\"$PROXY_MODE\"/' '/Library/Application Support/claude-switcher/claude-bodyguard.sh' || exit 1; chown root:wheel '/Library/Application Support/claude-switcher/claude-bodyguard.sh' || exit 1; chmod 755 '/Library/Application Support/claude-switcher/claude-bodyguard.sh' || exit 1; "
                    ;;
            esac
            ;;
    esac
    if [ -n "$adminCmds" ]; then
        adminCmds="${adminCmds}dscacheutil -flushcache; killall -HUP mDNSResponder"
        echo "FIX:修复时区/IPv6/DNS/保镖(需要密码)..."
        if osascript <<ASEOF >/dev/null 2>&1
do shell script "$adminCmds" with prompt "一键修复需要管理员权限" with administrator privileges
ASEOF
        then
            echo "FIX:时区/IPv6/DNS/保镖 ✓"
        else
            echo "FIX:时区/IPv6/保镖 ✗(取消或失败)"
        fi
    else
        echo "FIX:时区/IPv6/保镖 无需修复 ✓"
    fi

    # B3. Claude 客户端单独设英文(用户级,无需密码;系统首选语言已是英文则跳过)
    syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
    if ! defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | grep -q 'en-US' && [[ "$syslang" != en* ]]; then
        defaults write com.anthropic.claudefordesktop AppleLanguages -array en-US
        echo "FIX:Claude 客户端语言 → en-US ✓(重启 Claude 后生效)"
    fi

    # B4. 地区格式(用户级,无需密码)
    locale=$(defaults read -g AppleLocale 2>/dev/null)
    if [ "$locale" != "$LOCALE_TARGET" ]; then
        defaults write -g AppleLocale "$LOCALE_TARGET"
        echo "FIX:地区格式 → $LOCALE_TARGET ✓"
    fi

    # B2. 更新全局脚本并检查运行规则;写入失败或未加载均不能报成功。全局模式下规则不适用。
    if [ "$PROXY_MODE" = "clash-verge" ] && [ "$(clash_mode)" = "global" ]; then
        echo "FIX:全局模式,置顶规则不适用(全部流量已走代理) ✓"
    elif [ "$PROXY_MODE" = "clash-verge" ]; then
        echo "FIX:写入全局扩展脚本(保留已有 main 与无关配置)..."
        local rules_result
        if ! rules_result=$(write_merge_rules 2>&1); then
            echo "FIX:置顶规则 ✗ $rules_result"
            return 1
        fi
        osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
        sleep 3
        open -a "Clash Verge"
        for i in $(seq 1 40); do tun_up && break; sleep 1; done
        local loaded=0
        for i in $(seq 1 5); do
            if rules_result=$(clash_rules verify 2>&1); then loaded=1; break; fi
            sleep 1
        done
        if [ "$loaded" -ne 1 ]; then
            echo "FIX:置顶规则 ✗ 未验证内核加载:$rules_result"
            echo "FIX:请检查全局扩展脚本是否启用、代理组是否存在，以及节点 UDP 支持"
            return 1
        fi
        echo "FIX:置顶规则 ✓ 已验证内核实际加载"
    elif [ "$PROXY_MODE" != "flclash" ] && ! route_ok; then
        echo "FIX:置顶规则 ✗ 请在 $(proxy_name) 中自行添加 DOMAIN-SUFFIX 置顶规则"
    fi

    # C. 复测与日常审计共用判断，空结果、非零退出及无响应不会冒充代理成功。
    local fix_failed=0
    wrip=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep '^ip=' | cut -d= -f2)
    wr=$(webrtc_status "$wrip")
    case "$wr" in
        ok:*) echo "FIX:WebRTC ✓ ${wr#ok:}" ;;
        *) echo "FIX:WebRTC ✗ ${wr#fail:}"; fix_failed=1 ;;
    esac

    # D. 出口IP最终验证
    sleep 2
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    if [ "$loc" = "$COUNTRY_TARGET" ]; then
        echo "FIX:出口IP ✓ ($ip/$loc)"
    else
        echo "FIX:出口IP ✗ (${ip:-无}/${loc:-未知},期望$COUNTRY_TARGET) — 可能是节点故障,请到 $(proxy_name) 里换条线路"
    fi
    echo "FIX:修复流程结束"
    return "$fix_failed"
}

# 更换代理客户端:写入 ~/.claude-switcher/config.env(兼容显式指定 CLAUDE_SWITCHER_CORE 的旧测试)
set_client() {
    mode="${1:-}"
    local gui_mode=0
    [ "${2:-}" = "--gui" ] && gui_mode=1
    case "$mode" in
        tag|clash-verge|flclash|bettbox|shadowrocket|sing-box|clashx|surge|auto) ;;
        *) echo "FAIL:用法: claude-switch.sh set-client <tag|clash-verge|flclash|bettbox|shadowrocket|sing-box|clashx|surge|auto>"; return 1 ;;
    esac
    PROXY_MODE="$mode"
    save_runtime_config || { echo "FAIL:写入配置失败"; return 1; }
    if [ -n "${CLAUDE_SWITCHER_CORE:-}" ] && [ -f "$CLAUDE_SWITCHER_CORE" ] && [ -w "$CLAUDE_SWITCHER_CORE" ]; then
        sed -i '' "s|^PROXY_MODE=\"[^\"]*\"|PROXY_MODE=\"$mode\"|" "$CLAUDE_SWITCHER_CORE" || { echo "FAIL:写入失败"; return 1; }
        grep -q "^PROXY_MODE=\"$mode\"" "$CLAUDE_SWITCHER_CORE" || { echo "FAIL:校验失败"; return 1; }
    fi
    echo "OK:代理客户端已设为 $mode"
    guard_state=$(bodyguard_status)
    if [ "$gui_mode" -eq 1 ]; then
        case "$guard_state" in
            fail:客户端不一致*)
                if sync_bodyguard_mode "$mode"; then
                    echo "OK:系统保镖守护已同步为 $mode"
                    guard_state=$(bodyguard_status)
                fi
                ;;
        esac
    fi
    case "$guard_state" in
        fail:未安装) echo "INFO:保镖尚未安装,checkdetail 会提示未安装" ;;
        fail:*) echo "WARN:保镖校验未通过(${guard_state#fail:});请点击「一键修复」或重新运行安装器同步 root 守护脚本(需管理员权限),完成前不要启动 Claude" ;;
    esac
    echo "INFO:重新运行 checkdetail 生效;非 Clash 客户端请在应用内自行添加 Claude 域名置顶规则"
    return 0
}

# 只读输出当前代理客户端(供 UI 下拉高亮),同时列出全部支持项
get_client() {
    echo "client=$PROXY_MODE"
    echo "clients=tag,clash-verge,flclash,bettbox,shadowrocket,sing-box,clashx,surge"
}

# 地区自适应:按当前出口国家一键重设 国家/时区/地区格式(换了国家节点后运行)
set_region() {
    local geo gfile ctry ntz src nlocale rc
    gfile=$(mktemp "${TMPDIR:-/tmp}/claude-geo.XXXXXX" 2>/dev/null) || gfile=""
    GEO_DIAG_FILE="$gfile"
    geo=$(geo_lookup); rc=$?
    if [ -n "$gfile" ]; then
        GEO_DIAG=$(tr '\n' ';' < "$gfile" 2>/dev/null | sed 's/;$//')
        rm -f "$gfile"
    else
        GEO_DIAG=""
    fi
    unset GEO_DIAG_FILE
    if [ "$rc" -ne 0 ] || [ -z "$geo" ] || [ "${geo%%|*}" = "" ]; then
        echo "FAIL:所有出口探测源均失败(${GEO_DIAG:-无诊断信息})"
        echo "INFO:请确认代理已开启;若代理规则把 ipinfo/ipapi 判直连,可改为手动设置或稍后重试"
        return 1
    fi
    ctry=${geo%%|*}; geo=${geo#*|}
    ntz=${geo%%|*}; src=${geo#*|}
    if [ "$ctry" = "CN" ]; then
        echo "FAIL:出口国家为 CN(来源 $src),已中止;请先切换节点再重试"
        return 1
    fi
    [ -n "$ntz" ] || ntz=$(default_tz_for "$ctry")
    [ "$src" = "cloudflare" ] && echo "INFO:时区使用国家默认(可手动改)"
    nlocale=$(locale_for "$ctry")

    # 写入运行配置到 ~/.claude-switcher/config.env(保持核心脚本自身不被改写)
    COUNTRY_TARGET="$ctry"; TZ_TARGET="$ntz"; LOCALE_TARGET="$nlocale"
    save_runtime_config || { echo "FAIL:写入配置失败"; return 1; }

    # 地区格式(用户级,无需密码)
    defaults write -g AppleLocale "$nlocale"

    # 时区(需管理员权限,会弹一次授权框);看门狗脚本在 root 目录下,顺道用同一次授权同步目标值
    WD="/Library/Application Support/claude-switcher/tz-watchdog.sh"
    adminCmds="/usr/sbin/systemsetup -settimezone $ntz"
    wdsync=0
    if [ -f "$WD" ] && [ ! -w "$WD" ]; then
        adminCmds="$adminCmds; /usr/bin/sed -i '' 's|^TARGET=.*|TARGET=$ntz|' '$WD'"
        wdsync=1
    fi
    if ! osascript <<ASEOF >/dev/null 2>&1
do shell script "$adminCmds" with prompt "set-region 需要管理员权限以锁定时区" with administrator privileges
ASEOF
    then
        echo "FAIL:时区设置被取消或失败(国家/地区格式已更新为 $ctry/$nlocale)"
        return 1
    fi
    # 看门狗目标同步兜底(可写的老版本安装直接 sed;失败则提示运行安装器刷新)
    if [ -f "$WD" ] && [ "$wdsync" -eq 0 ]; then
        sed -i '' "s|^TARGET=.*|TARGET=$ntz|" "$WD" 2>/dev/null || echo "WARN:看门狗目标未同步,请运行安装器刷新"
    fi

    echo "OK:region=$ctry tz=$ntz locale=$nlocale source=$src"
}

# 应用内/命令行更新:拉取自有 main,SHA256 校验+config.env 持久化+自检+按需重编 App/同步守护+trap 失败回滚
# --check 只检查不写入;--auto 供 LaunchAgent 每12小时调用(静默写 update.log);--gui 供界面「立即更新」调用
replace_app_bundle() {
    local source="$1" target="$2" parent="${2%/*}" stage old=0
    mkdir -p "$parent" 2>/dev/null || true
    stage=$(mktemp -d "$parent/.claude-switcher.XXXXXXXX") || return 1
    if ! ditto "$source" "$stage/new.app" || ! codesign --verify --deep --strict "$stage/new.app" >/dev/null 2>&1; then
        rm -rf "$stage"
        return 1
    fi
    if [ -e "$target" ]; then
        if ! mv "$target" "$stage/previous.app"; then
            rm -rf "$stage"
            return 1
        fi
        old=1
    fi
    if ! mv "$stage/new.app" "$target"; then
        [ "$old" -eq 1 ] && mv "$stage/previous.app" "$target" 2>/dev/null
        rm -rf "$stage"
        return 1
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
    rm -rf "$stage" 2>/dev/null || true
    return 0
}

update_lock_acquire() {
    [ "${UPDATE_LOCK_HELD:-0}" -eq 1 ] && return 0
    local lockdir="$BASE/update.lock" lockpid
    mkdir -p "$BASE" 2>/dev/null || true
    if mkdir "$lockdir" 2>/dev/null; then
        echo "$$" > "$lockdir/pid"
        UPDATE_LOCK_HELD=1
        return 0
    fi
    if [ -f "$lockdir/pid" ]; then
        lockpid=$(cat "$lockdir/pid" 2>/dev/null)
        if [ -n "$lockpid" ] && ! kill -0 "$lockpid" 2>/dev/null; then
            rm -rf "$lockdir" 2>/dev/null
            if mkdir "$lockdir" 2>/dev/null; then
                echo "$$" > "$lockdir/pid"
                UPDATE_LOCK_HELD=1
                return 0
            fi
        fi
    fi
    echo "FAIL:另一个更新进程正在运行，请稍后重试"
    return 1
}

update_lock_release() {
    if [ "${UPDATE_LOCK_HELD:-0}" -eq 1 ]; then
        rm -rf "$BASE/update.lock" 2>/dev/null || true
        UPDATE_LOCK_HELD=0
    fi
}

# 原子安装脚本文件:先写同目录临时文件,再 rename 覆盖目标。
# 绝不能直接 cp 覆盖目标:更新时正在运行的 bash 持有旧脚本的 fd,并按字节偏移继续读后续语句,
# 若用 cp 原地覆盖同一 inode(截断后重写),bash 会从新内容中间开始解析。
install_staged() {  # $1=源文件 $2=目标文件
    _src="$1"; _dst="$2"
    _stage="$(dirname "$_dst")/.$(basename "$_dst").new.$$"
    if ! cp "$_src" "$_stage"; then rm -f "$_stage"; return 1; fi
    chmod +x "$_stage" 2>/dev/null
    if ! mv -f "$_stage" "$_dst"; then rm -f "$_stage"; return 1; fi
    return 0
}

# Serialized into the authorized root update script. Keep the previous schedule
# in a protected same-directory staging area until the new service is verified.
replace_bodyguard_schedule() {
    local source="$1" expected="$2" target="$3" stage had_old=0
    [ ! -L "$target" ] && { [ ! -e "$target" ] || [ -f "$target" ]; } || return 1
    stage=$(mktemp -d "${target%/*}/.claude-bodyguard.XXXXXXXX") || return 1
    if [ -f "$target" ]; then
        cp -X "$target" "$stage/previous.plist" || { rm -rf "$stage"; return 1; }
        had_old=1
    fi
    if ! cp -X "$source" "$stage/new.plist" ||
       ! verify_sha256 "$stage/new.plist" "$expected" ||
       ! chown root:wheel "$stage/new.plist" || ! chmod 644 "$stage/new.plist" ||
       ! mv -f "$stage/new.plist" "$target"; then
        rm -rf "$stage"; return 1
    fi
    launchctl bootout system/local.claude-bodyguard 2>/dev/null || true
    if launchctl bootstrap system "$target" && launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        rm -rf "$stage"; return 0
    fi
    launchctl bootout system/local.claude-bodyguard 2>/dev/null || true
    if [ "$had_old" -eq 1 ]; then
        if ! mv -f "$stage/previous.plist" "$target"; then
            echo "保镖调度恢复失败，原配置保留在 $stage/previous.plist" >&2
            return 1
        fi
        if ! launchctl bootstrap system "$target" || ! launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
            echo '原保镖调度配置已恢复，但服务未能重新注册，请运行安装器恢复' >&2
        fi
    else
        rm -f "$target"
    fi
    rm -rf "$stage"
    return 1
}

self_update() {
    auto=0; check=0; gui=0
    case "${1:-}" in
        '') ;;
        --auto) auto=1 ;;
        --check) check=1 ;;
        --gui) gui=1 ;;
        *) echo "FAIL:用法: claude-switch.sh update [--check|--auto|--gui]"; return 1 ;;
    esac
    # 路径全部从脚本自身位置推导,兼容旧版 LaunchDaemon(root) 混跑时 $HOME 不可靠的场景
    BIN=$(cd "$(dirname "$0")" && pwd)
    UHOME="${BIN%/.local/bin}"
    [ "$UHOME" = "$BIN" ] && UHOME="$HOME"
    if [ "$auto" -eq 1 ]; then
        mkdir -p "$BASE"
        exec >>"$BASE/update.log" 2>&1
        echo "# $(date '+%F %T') update --auto 开始"
    fi

    # 写入类更新必须先拿互斥锁,防止后台 --auto 与手动/界面 --gui 并发踩踏
    if [ "$check" -eq 0 ]; then
        update_lock_acquire || return 1
    fi

    UPDATE_COMMITTED=0
    core_replaced=0; had_core=0
    stun_replaced=0; had_stun=0
    cfg_replaced=0; had_cfg=0
    tmpd=""

    rollback_update() {
        local rc=0
        if [ "${core_replaced:-0}" -eq 1 ]; then
            if [ "${had_core:-0}" -eq 1 ] && [ -f "$BIN/claude-switch.sh.bak" ]; then
                install_staged "$BIN/claude-switch.sh.bak" "$BIN/claude-switch.sh" || rc=1
            else
                rm -f "$BIN/claude-switch.sh" 2>/dev/null || true
            fi
            core_replaced=0
        fi
        if [ "${stun_replaced:-0}" -eq 1 ]; then
            if [ "${had_stun:-0}" -eq 1 ] && [ -f "$BASE/stun-probe.py.bak" ]; then
                install_staged "$BASE/stun-probe.py.bak" "$BASE/stun-probe.py" || rc=1
            else
                rm -f "$BASE/stun-probe.py" 2>/dev/null || true
            fi
            rm -f "$BASE/stun-probe.py.bak" 2>/dev/null || true
            stun_replaced=0
        fi
        if [ "${cfg_replaced:-0}" -eq 1 ]; then
            if [ "${had_cfg:-0}" -eq 1 ] && [ -f "$CONFIG_ENV.bak" ]; then
                cp "$CONFIG_ENV.bak" "$CONFIG_ENV" 2>/dev/null || true
            else
                rm -f "$CONFIG_ENV" 2>/dev/null || true
            fi
            rm -f "$CONFIG_ENV.bak" 2>/dev/null || true
            cfg_replaced=0
        fi
        return $rc
    }

    cleanup_update() {
        if [ "${UPDATE_COMMITTED:-0}" -ne 1 ]; then
            rollback_update || true
        else
            rm -f "$BASE/stun-probe.py.bak" "$CONFIG_ENV.bak" 2>/dev/null || true
        fi
        [ -n "${tmpd:-}" ] && rm -rf "$tmpd" 2>/dev/null || true
        tmpd=""
        update_lock_release
    }

    if [ "$check" -eq 0 ]; then
        trap 'cleanup_update' EXIT
        trap 'cleanup_update; exit 130' INT
        trap 'cleanup_update; exit 143' TERM
    fi

    tmpd=$(mktemp -d) || { echo "FAIL:无法创建临时目录"; cleanup_update; return 1; }
    if ! curl -fsSL --max-time 30 "https://codeload.github.com/$UPDATE_REPOSITORY/zip/refs/heads/$UPDATE_BRANCH" -o "$tmpd/main.zip" \
        || ! unzip -q "$tmpd/main.zip" -d "$tmpd" 2>/dev/null; then
        echo "FAIL:下载或解压失败(网络问题,稍后再试)"; cleanup_update; return 1
    fi
    NEW="$tmpd/${UPDATE_REPOSITORY##*/}-$UPDATE_BRANCH"
    if [ ! -f "$NEW/core/claude-switch.sh" ]; then
        echo "FAIL:远程包结构异常,已中止"; cleanup_update; return 1
    fi

    # 清单与工件来自同一归档，避免 main 在两次下载间更新；信任根为自有 GitHub 仓库 HTTPS。
    if [ ! -s "$NEW/SHA256SUMS" ]; then
        echo "FAIL:无法获取校验清单(SHA256SUMS),已中止"; cleanup_update; return 1
    fi
    bad=0; saw_core=0; saw_stun=0; saw_app=0; saw_build=0; saw_guard_plist=0; bg_plist_sha=""
    while read -r sum rel; do
        [ -z "$sum" ] && continue
        [ "$rel" = "core/claude-switch.sh" ] && saw_core=1
        [ "$rel" = "core/stun-probe.py" ] && saw_stun=1
        [ "$rel" = "app/main.swift" ] && saw_app=1
        [ "$rel" = "scripts/build-app.sh" ] && saw_build=1
        if [ "$rel" = "daemons/local.claude-bodyguard.plist" ]; then
            saw_guard_plist=1; bg_plist_sha="$sum"
        fi
        if [ ! -f "$NEW/$rel" ] || [ "$(shasum -a 256 "$NEW/$rel" | awk '{print $1}')" != "$sum" ]; then
            bad=1; break
        fi
    done < "$NEW/SHA256SUMS"
    if [ "$bad" -eq 1 ] || [ "$saw_core" -ne 1 ] \
        || { [ -f "$NEW/core/stun-probe.py" ] && [ "$saw_stun" -ne 1 ]; } \
        || { [ -f "$NEW/app/main.swift" ] && [ "$saw_app" -ne 1 ]; } \
        || { [ -f "$NEW/scripts/build-app.sh" ] && [ "$saw_build" -ne 1 ]; } \
        || { [ -f "$NEW/daemons/local.claude-bodyguard.plist" ] && [ "$saw_guard_plist" -ne 1 ]; }; then
        echo "FAIL:工件校验失败,已中止(不排除网络篡改,可稍后重试或手动 update)"; cleanup_update; return 1
    fi

    # 读取现有运行配置:优先从 config.env 读取,老版本从已安装脚本头部兜底读取
    candidate="$NEW/core/claude-switch.sh"
    PM=""; PG=""; CT=""; TZV=""; LCT=""
    if [ -f "$BIN/claude-switch.sh" ]; then
        get_cfg() { grep "^$1=\"" "$BIN/claude-switch.sh" | head -1 | cut -d'"' -f2; }
        PM=$(get_cfg PROXY_MODE); PG=$(get_cfg PROXY_GROUP); CT=$(get_cfg COUNTRY_TARGET)
        TZV=$(get_cfg TZ_TARGET); LCT=$(get_cfg LOCALE_TARGET)
    fi
    if [ -f "$CONFIG_ENV" ]; then
        get_env_cfg() { grep "^$1=\"" "$CONFIG_ENV" | head -1 | cut -d'"' -f2; }
        [ -n "$(get_env_cfg PROXY_MODE)" ] && PM=$(get_env_cfg PROXY_MODE)
        [ -n "$(get_env_cfg PROXY_GROUP)" ] && PG=$(get_env_cfg PROXY_GROUP)
        [ -n "$(get_env_cfg COUNTRY_TARGET)" ] && CT=$(get_env_cfg COUNTRY_TARGET)
        [ -n "$(get_env_cfg TZ_TARGET)" ] && TZV=$(get_env_cfg TZ_TARGET)
        [ -n "$(get_env_cfg LOCALE_TARGET)" ] && LCT=$(get_env_cfg LOCALE_TARGET)
    fi

    # 跳过判断:已迁移 config.env 时直接比对字节,老版本剔除头部5个配置行后比对;并检查 stun-probe/App/守护
    strip_cfg() { grep -vE '^(PROXY_MODE|PROXY_GROUP|COUNTRY_TARGET|TZ_TARGET|LOCALE_TARGET)="' "$1"; }
    core_changed=0
    if [ ! -f "$BIN/claude-switch.sh" ]; then
        core_changed=1
    elif [ -f "$CONFIG_ENV" ]; then
        cmp -s "$BIN/claude-switch.sh" "$NEW/core/claude-switch.sh" || core_changed=1
    elif ! diff <(strip_cfg "$BIN/claude-switch.sh") <(strip_cfg "$NEW/core/claude-switch.sh") >/dev/null 2>&1; then
        core_changed=1
    fi

    stun_changed=0
    if [ -f "$NEW/core/stun-probe.py" ]; then
        if [ ! -f "$BASE/stun-probe.py" ] || ! cmp -s "$BASE/stun-probe.py" "$NEW/core/stun-probe.py"; then
            stun_changed=1
        fi
    fi

    APPDIR="/Library/Application Support/claude-switcher"
    DAEMON_DIR="${CLAUDE_SWITCHER_DAEMONS:-/Library/LaunchDaemons}"
    daemon_changed=0
    daemon_scripts_changed=0
    guard_plist_changed=0
    if [ -f "$APPDIR/claude-bodyguard.sh" ] || [ -f "$APPDIR/tz-watchdog.sh" ]; then
        [ -z "$PM" ] && PM="clash-verge"
        [ -z "$TZV" ] && TZV="America/New_York"
        sed -e "s|__HOME__|$UHOME|g" -e "s|__PROXY_MODE__|$PM|g" "$NEW/daemons/claude-bodyguard.sh" > "$tmpd/bg.new"
        sed -e "s|__HOME__|$UHOME|g" -e "s|__TZ_TARGET__|$TZV|g" "$NEW/daemons/tz-watchdog.sh" > "$tmpd/tz.new"
        if ! diff -q "$tmpd/bg.new" "$APPDIR/claude-bodyguard.sh" >/dev/null 2>&1 || \
           ! diff -q "$tmpd/tz.new" "$APPDIR/tz-watchdog.sh" >/dev/null 2>&1; then
            daemon_changed=1
            daemon_scripts_changed=1
        fi
        if [ -f "$NEW/daemons/local.claude-bodyguard.plist" ] &&
           ! cmp -s "$NEW/daemons/local.claude-bodyguard.plist" "$DAEMON_DIR/local.claude-bodyguard.plist"; then
            cp -X "$NEW/daemons/local.claude-bodyguard.plist" "$tmpd/bg.plist" || {
                echo "FAIL:无法暂存保镖调度配置"; cleanup_update; return 1;
            }
            guard_plist_changed=1
            daemon_changed=1
        fi
    fi

    APP_TARGET="${CLAUDE_SWITCHER_APP:-/Applications/Claude Switcher.app}"
    app_changed=0; remote_app_sha=""
    if [ -f "$NEW/app/main.swift" ] && [ "$auto" -eq 0 ]; then
        remote_app_sha=$(shasum -a 256 "$NEW/app/main.swift" | awk '{print $1}')
        if [ -e "$APP_TARGET" ] || [ -L "$APP_TARGET" ]; then
            installed_app_sha=$(/usr/libexec/PlistBuddy -c 'Print :ClaudeSwitcherSourceSHA256' "$APP_TARGET/Contents/Info.plist" 2>/dev/null)
            [ "$installed_app_sha" = "$remote_app_sha" ] || app_changed=1
        elif [ "$gui" -eq 1 ]; then
            app_changed=1
        fi
    fi

    if [ "$auto" -eq 1 ]; then
        if [ "$core_changed" -eq 0 ] && [ "$stun_changed" -eq 0 ]; then
            UPDATE_COMMITTED=1; echo "OK:已是最新版本"; cleanup_update; return 0
        fi
    elif [ "$core_changed" -eq 0 ] && [ "$stun_changed" -eq 0 ] && [ "$app_changed" -eq 0 ] && { [ "$daemon_changed" -eq 0 ] || { [ "$check" -eq 0 ] && [ "$gui" -eq 0 ]; }; }; then
        UPDATE_COMMITTED=1; echo "OK:已是最新版本"; cleanup_update; return 0
    fi

    # 只读检查:不备份、不写文件、不物化守护脚本、不触发自检/回滚
    if [ "$check" -eq 1 ]; then
        stamp=$(stat -f '%Sm' -t '%Y-%m-%d' "$NEW/core/claude-switch.sh" 2>/dev/null)
        [ -z "$stamp" ] && stamp=$(date '+%F')
        echo "INFO:发现新版本 $stamp"
        cleanup_update; return 0
    fi

    # 1. 若需更新 App,先在临时目录通过统一脚本编译并签名校验,确保失败时不改动任何已安装文件
    app_built=""
    need_admin_app=0
    if [ "$app_changed" -eq 1 ] && [ "$auto" -eq 0 ]; then
        if [ -L "$APP_TARGET" ]; then
            echo "FAIL:应用目标是符号链接,拒绝覆盖: $APP_TARGET"; cleanup_update; return 1
        fi
        if [ -e "$APP_TARGET" ]; then
            bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_TARGET/Contents/Info.plist" 2>/dev/null)
            if [ "$bundle_id" != "local.claude-switcher" ]; then
                echo "FAIL:目标不是 Claude 切换器,拒绝覆盖: $APP_TARGET"; cleanup_update; return 1
            fi
        fi
        if ! command -v swiftc >/dev/null 2>&1; then
            echo "FAIL:未检测到 swiftc,无法编译新版界面 App"; cleanup_update; return 1
        fi
        app_built="$tmpd/Claude Switcher.app"
        build_script="$NEW/scripts/build-app.sh"
        [ -f "$build_script" ] || build_script="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/scripts/build-app.sh"
        if ! /bin/bash "$build_script" "$NEW" "$app_built" "1.0" "$APP_TARGET/Contents/Resources/AppIcon.icns" >/dev/null 2>&1; then
            echo "FAIL:新版 App 编译或签名校验失败,已中止更新"; cleanup_update; return 1
        fi
        app_parent="${APP_TARGET%/*}"
        if [ ! -w "$app_parent" ] || { [ -e "$APP_TARGET" ] && [ ! -w "$APP_TARGET" ]; }; then
            need_admin_app=1
        fi
    fi

    # 2. 备份并更新核心脚本、用户态配置文件与 STUN 探针(核心脚本原样复制,保持与 SHA256SUMS 字节一致)
    if [ "$core_changed" -eq 1 ]; then
        if [ -f "$BIN/claude-switch.sh" ]; then
            if ! cp "$BIN/claude-switch.sh" "$BIN/claude-switch.sh.bak"; then
                echo "FAIL:备份现有核心脚本失败,已中止"; cleanup_update; return 1
            fi
            had_core=1
        fi
        # 必须原子替换:当前进程正在执行的就是该文件
        if ! install_staged "$candidate" "$BIN/claude-switch.sh"; then
            echo "FAIL:无法写入核心脚本,已自动回滚"; cleanup_update; return 1
        fi
        core_replaced=1
    fi

    if [ -n "$PM" ]; then
        if [ -f "$CONFIG_ENV" ]; then
            if ! cp "$CONFIG_ENV" "$CONFIG_ENV.bak"; then
                echo "FAIL:备份配置文件失败,已中止"; cleanup_update; return 1
            fi
            had_cfg=1
        fi
        PROXY_MODE="$PM"; PROXY_GROUP="$PG"; COUNTRY_TARGET="$CT"; TZ_TARGET="$TZV"; LOCALE_TARGET="$LCT"
        if ! save_runtime_config "$CONFIG_ENV"; then
            echo "FAIL:无法写入配置文件 $CONFIG_ENV"; cleanup_update; return 1
        fi
        cfg_replaced=1
    fi

    if [ "$stun_changed" -eq 1 ]; then
        if [ -f "$BASE/stun-probe.py" ]; then
            if ! cp "$BASE/stun-probe.py" "$BASE/stun-probe.py.bak"; then
                echo "FAIL:备份 STUN 探针失败,已中止"; cleanup_update; return 1
            fi
            had_stun=1
        fi
        if ! install_staged "$NEW/core/stun-probe.py" "$BASE/stun-probe.py"; then
            echo "FAIL:无法写入 STUN 探针,已自动回滚"; cleanup_update; return 1
        fi
        stun_replaced=1
    fi

    # 3. 先跑更新后自检(在替换 App 或提权同步守护之前执行,保证自检失败时无需回滚系统目录与 App)
    # root(旧版 LaunchDaemon)下切回真实用户执行,避免 defaults 读到 root 的配置
    check_rc=0
    if [ "$(id -u)" -eq 0 ]; then
        owner=$(stat -f '%Su' "$UHOME" 2>/dev/null)
        if [ -n "$owner" ]; then out=$(sudo -H -u "$owner" "$BIN/claude-switch.sh" checkdetail 2>&1) || check_rc=$?; else out=""; check_rc=1; fi
    else
        out=$("$BIN/claude-switch.sh" checkdetail 2>&1) || check_rc=$?
    fi
    check_out="$out"
    if [ "$gui" -eq 1 ] && [ "$daemon_changed" -eq 1 ]; then
        check_out=$(printf '%s\n' "$out" | grep -v '^保镖=fail:客户端不一致')
    fi
    if [ "$check_rc" -ne 0 ] || [ -z "$out" ] || printf '%s\n' "$check_out" | grep -q '=fail'; then
        failed_items=$(printf '%s\n' "$check_out" | sed -n 's/=fail.*//p' | tr '\n' ',' | sed 's/,$//')
        fail_reason=""
        if [ -n "$failed_items" ]; then
            fail_reason="($failed_items)"
        elif [ "$check_rc" -ne 0 ]; then
            fail_reason="(退出码 $check_rc)"
        fi
        rollback_failed=0
        rollback_update || rollback_failed=1
        if [ "$rollback_failed" -ne 0 ]; then
            echo "FAIL:新版自检未通过${fail_reason},回滚失败;请从 $BIN/claude-switch.sh.bak 手动恢复"
        else
            echo "FAIL:新版自检未通过${fail_reason},已自动回滚"
        fi
        cleanup_update
        return 1
    fi

    # 4. 自检通过后,统一执行 App 替换与 root 守护进程同步(root 执行前二次校验临时文件 SHA256)
    daemon_updated=0
    app_updated=0
    if [ "$gui" -eq 1 ] && { [ "$daemon_changed" -eq 1 ] || [ "$need_admin_app" -eq 1 ]; }; then
        admin_script="$tmpd/admin-update.sh"
        {
            echo '#!/bin/bash'
            echo 'set -e'
            echo 'verify_sha256() { [ -f "$1" ] && [ "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '\''{print $1}'\'')" = "$2" ]; }'
            declare -f replace_app_bundle
            [ "$guard_plist_changed" -eq 1 ] && declare -f replace_bodyguard_schedule
            if [ "$need_admin_app" -eq 1 ]; then
                bin_sha=$(shasum -a 256 "$app_built/Contents/MacOS/ClaudeSwitcher" | awk '{print $1}')
                printf 'verify_sha256 %q %q\n' "$app_built/Contents/MacOS/ClaudeSwitcher" "$bin_sha"
                printf 'replace_app_bundle %q %q\n' "$app_built" "$APP_TARGET"
            fi
            if [ "$daemon_changed" -eq 1 ]; then
                bg_sha=$(shasum -a 256 "$tmpd/bg.new" | awk '{print $1}')
                tz_sha=$(shasum -a 256 "$tmpd/tz.new" | awk '{print $1}')
                printf 'verify_sha256 %q %q\n' "$tmpd/bg.new" "$bg_sha"
                printf 'verify_sha256 %q %q\n' "$tmpd/tz.new" "$tz_sha"
                if [ "$guard_plist_changed" -eq 1 ]; then
                    printf 'verify_sha256 %q %q\n' "$tmpd/bg.plist" "$bg_plist_sha"
                fi
                printf 'mkdir -p %q\n' "$APPDIR"
                if [ "$daemon_scripts_changed" -eq 1 ]; then
                    printf 'cp %q %q\n' "$tmpd/bg.new" "$APPDIR/claude-bodyguard.sh"
                    printf 'cp %q %q\n' "$tmpd/tz.new" "$APPDIR/tz-watchdog.sh"
                    printf 'chown root:wheel %q %q\n' "$APPDIR/claude-bodyguard.sh" "$APPDIR/tz-watchdog.sh"
                    printf 'chmod 755 %q %q\n' "$APPDIR/claude-bodyguard.sh" "$APPDIR/tz-watchdog.sh"
                    printf '/usr/bin/xattr -d com.apple.quarantine %q %q 2>/dev/null || true\n' "$APPDIR/claude-bodyguard.sh" "$APPDIR/tz-watchdog.sh"
                fi
                if [ "$guard_plist_changed" -eq 1 ]; then
                    printf 'mkdir -p %q\n' "$DAEMON_DIR"
                    printf 'replace_bodyguard_schedule %q %q %q\n' "$tmpd/bg.plist" "$bg_plist_sha" "$DAEMON_DIR/local.claude-bodyguard.plist"
                else
                    printf 'if [ -f %q ]; then launchctl bootout system/local.claude-bodyguard 2>/dev/null || true; launchctl bootstrap system %q; launchctl print system/local.claude-bodyguard >/dev/null 2>&1; fi\n' "$DAEMON_DIR/local.claude-bodyguard.plist" "$DAEMON_DIR/local.claude-bodyguard.plist"
                fi
                if [ "$daemon_scripts_changed" -eq 1 ]; then
                    printf 'if [ -f %q ]; then launchctl bootout system/local.tz-watchdog 2>/dev/null || true; launchctl bootstrap system %q; launchctl print system/local.tz-watchdog >/dev/null 2>&1; fi\n' "$DAEMON_DIR/local.tz-watchdog.plist" "$DAEMON_DIR/local.tz-watchdog.plist"
                fi
            fi
        } > "$admin_script"
        chmod 700 "$admin_script"
        if ! osascript - "$admin_script" <<'ASEOF' >/dev/null 2>&1
on run argv
    do shell script "/bin/bash " & quoted form of item 1 of argv with prompt "Claude 切换器更新需要管理员权限" with administrator privileges
end run
ASEOF
        then
            echo "FAIL:管理员授权取消或系统组件更新失败,已自动回滚用户态文件;请重新检查系统守护,必要时运行安装器恢复"
            cleanup_update
            return 1
        fi
        [ "$need_admin_app" -eq 1 ] && app_updated=1
        [ "$daemon_changed" -eq 1 ] && daemon_updated=1
    elif [ "$daemon_changed" -eq 1 ]; then
        echo "INFO:守护脚本或调度配置有更新,请运行 installer/安装.command 刷新(需要密码)"
    fi

    if [ -n "$app_built" ] && [ "$need_admin_app" -eq 0 ]; then
        if ! replace_app_bundle "$app_built" "$APP_TARGET"; then
            echo "FAIL:新版 App 替换失败,已自动回滚"
            cleanup_update
            return 1
        fi
        app_updated=1
    fi

    UPDATE_COMMITTED=1
    cleanup_update

    extras=""
    [ "$stun_changed" -eq 1 ] && extras="${extras}、STUN探针"
    [ "$app_updated" -eq 1 ] && extras="${extras}、界面App"
    [ "$daemon_updated" -eq 1 ] && extras="${extras}、守护进程"
    if [ -n "$extras" ]; then
        echo "OK:核心脚本更新完成 $(date '+%Y-%m-%d')（已同步更新：${extras#、}）"
    else
        echo "OK:核心脚本更新完成 $(date '+%Y-%m-%d')；App 与系统守护由安装器更新"
    fi
    return 0
}

# 设备指纹体检:字体地区特征 + GPU/虚拟机特征(Canvas/WebGL 由 Web 检测页覆盖)
fingerprint() {
    echo "# 设备指纹体检 $(date '+%F %T')"
    hits=""
    for d in /Library/Fonts "$HOME/Library/Fonts"; do
        [ -d "$d" ] || continue
        while IFS= read -r f; do
            b=$(basename "$f" | tr '[:upper:]' '[:lower:]')
            case "$b" in
                *simsun*|*simhei*|*simkai*|*simfang*|*msyh*|*msjh*|*dengxian*|*wqy*|*fzshu*|*fzkai*|*fzhei*|*fangsong*) hits="$hits $b" ;;
            esac
        done < <(find "$d" -type f \( -iname '*.ttf' -o -iname '*.ttc' -o -iname '*.otf' \) 2>/dev/null)
    done
    if [ -n "$hits" ]; then
        echo "字体=warn:检测到地区特征字体:${hits# }"
        echo "建议=上述字体通常随中文办公软件安装,美区环境很少出现;不用的可在字体册停用"
    else
        echo "字体=ok:未发现中文办公字体(仅系统自带字体)"
    fi

    gpu=$(system_profiler SPDisplaysDataType 2>/dev/null)
    chip=$(echo "$gpu" | grep -m1 'Chipset Model' | sed 's/.*: //')
    res=$(echo "$gpu" | grep -m1 'Resolution' | sed 's/.*: //')
    [ -z "$chip" ] && chip="未知"
    echo "GPU=ok:${chip}"
    echo "显示=ok:${res:-未知}"
    virt=$(sysctl -n kern.hv_vmm_present 2>/dev/null)
    case "$chip" in
        *Virtual*|*VMware*|*Parallels*|*VirtualBox*|*SwiftShader*|*llvmpipe*)
            echo "虚拟机=warn:检测到虚拟 GPU($chip),这是强指纹" ;;
        *)
            [ "$virt" = "1" ] && echo "虚拟机=warn:运行在虚拟机中" || echo "虚拟机=ok:物理机" ;;
    esac
    echo "CanvasWebGL=info:原生检查读不到 Claude Electron 的渲染特征,请打开 Web 检测页 https://yoursjeyo.github.io/claude-switcher/ 查看 Canvas/WebGL 指纹"
}

# 账号快照加密导出/导入(macOS):AES-256 加密 DMG,密码只经 stdin 传递
# 一次性隔离浏览器:独立临时 profile,禁用非代理 UDP,关闭后销毁;URL 仅允许 http/https
# Claude Code CLI 体检:只读检测安装方式/版本/多份安装冲突,不执行卸载或重装
cli_info() {
    echo "# Claude Code CLI 体检 $(date '+%F %T')"
    path=$(command -v claude 2>/dev/null)
    if [ -n "$path" ]; then
        real=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || echo "$path")
        ver=$(perl -e 'alarm 4; exec @ARGV' "$real" --version 2>/dev/null | head -1)
        [ -z "$ver" ] && ver=$(perl -e 'alarm 4; exec @ARGV' "$path" --version 2>/dev/null | head -1)
        echo "CLI=ok:$path"
        [ "$real" != "$path" ] && echo "CLI真实路径=info:$real"
        echo "版本=ok:${ver:-未获取}"
        case "$real" in
            *".claude/local"*|*".local/share/claude"*) method="native(官方安装脚本)" ;;
            *"/opt/homebrew/"*|*"/usr/local/Cellar/"*|*"/home/linuxbrew/"*) method="homebrew" ;;
            *"node_modules"*|*".npm-global"*|*"/.bun/"*) method="npm/bun" ;;
            *) method="未知(建议核对 PATH)" ;;
        esac
        echo "安装方式=info:$method"
    else
        echo "CLI=warn:PATH 中没有 claude 命令"
        echo "安装方式=info:未安装(桌面版可能自带内置 CLI,见下)"
    fi

    bundled=$(ls -d "$HOME/Library/Application Support/Claude/claude-code"/* 2>/dev/null | tail -1)
    if [ -n "$bundled" ]; then
        echo "桌面版内置=ok:$(basename "$bundled")"
    else
        echo "桌面版内置=info:未发现(Claude 桌面版未安装或版本较旧)"
    fi

    if command -v npm >/dev/null 2>&1 && npm ls -g --depth=0 @anthropic-ai/claude-code >/dev/null 2>&1; then
        echo "npm全局包=warn:检测到 @anthropic-ai/claude-code"
    else
        echo "npm全局包=ok:未检测到"
    fi
    if command -v brew >/dev/null 2>&1 && brew list --versions claude-code >/dev/null 2>&1; then
        echo "Homebrew包=warn:$(brew list --versions claude-code 2>/dev/null | head -1)"
    else
        echo "Homebrew包=ok:未检测到"
    fi

    cfg="$HOME/.claude"
    if [ -d "$cfg" ]; then
        echo "配置目录=ok:$cfg ($(du -sh "$cfg" 2>/dev/null | cut -f1))"
    else
        echo "配置目录=info:未创建(尚未运行过 CLI)"
    fi

    [ -n "$path" ] && echo "建议=info:升级用对应包管理器(brew upgrade claude-code / npm i -g @anthropic-ai/claude-code@latest);卸载前先确认桌面版是否依赖它"
    return 0
}

open_safe() {
    url="${1:-}"
    case "$url" in
        http://*|https://*) ;;
        '') echo "FAIL:用法: claude-switch.sh open-safe <http(s)://链接>"; return 1 ;;
        *) echo "FAIL:只允许 http/https 链接"; return 1 ;;
    esac
    cli_lock_acquire || return 1
    if [ "${CLAUDE_SWITCHER_SKIP_NET_CHECK:-0}" != "1" ] && ! tun_up && ! proxy_alive; then
        echo "FAIL:代理未就绪(TUN 未接管且客户端未运行),拒绝打开以免直连"
        return 1
    fi
    chrome="${CLAUDE_SWITCHER_CHROME:-}"
    if [ -z "$chrome" ]; then
        for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                 "/Applications/Chromium.app/Contents/MacOS/Chromium" \
                 "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
                 "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"; do
            [ -x "$c" ] && chrome="$c" && break
        done
    fi
    [ -n "$chrome" ] && [ -x "$chrome" ] || { echo "FAIL:未找到 Chrome/Chromium/Edge/Brave"; return 1; }

    profile=$(mktemp -d "${TMPDIR:-/tmp}/claude-switcher-safe.XXXXXX") || { echo "FAIL:无法创建临时 profile"; return 1; }
    chmod 700 "$profile"
    lang="${LOCALE_TARGET:-en_US}"; lang="${lang/_/-}"
    nohup "$chrome" \
        --user-data-dir="$profile" \
        --no-first-run --no-default-browser-check \
        --disable-sync --disable-extensions \
        --force-webrtc-ip-handling-policy=disable_non_proxied_udp \
        --lang="$lang" \
        "$url" >/dev/null 2>&1 &
    pid=$!
    nohup bash -c 'while kill -0 "$1" 2>/dev/null; do sleep 5; done; rm -rf "$2"' _ "$pid" "$profile" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    echo "OK:已在一次性隔离浏览器打开(profile 将在窗口关闭后销毁)"
    echo "INFO:该窗口不继承你日常浏览器的 cookies/插件;在其中登录产生的会话会随窗口关闭一并丢弃"
}

snapshot_export() {
    target="${1:-}"; out="${2:-}"; mode="${3:-}"
    case "$target" in A|B|C|D) ;; *) echo "FAIL:账号必须是 A、B、C 或 D"; return 1 ;; esac
    [ -d "$BASE/accounts/$target" ] || { echo "FAIL:账号$target 没有已归档快照(先切换一次让它归档)"; return 1; }
    [ -n "$out" ] || { echo "FAIL:请指定导出文件路径"; return 1; }
    case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
    [ -e "$out" ] && { echo "FAIL:目标文件已存在,请换一个路径"; return 1; }
    if [ "$(cat "$BASE/current" 2>/dev/null)" = "$target" ]; then
        echo "FAIL:账号$target 正在使用中,当前数据在运行目录;请先切换到另一账号(会自动归档)再导出"
        return 1
    fi

    if [ "$mode" = "--password-stdin" ]; then
        IFS= read -r pass || true
    else
        printf '设置导出密码(至少 8 位): '; stty -echo 2>/dev/null; IFS= read -r pass; stty echo 2>/dev/null; echo
        printf '再次输入: '; stty -echo 2>/dev/null; IFS= read -r pass2; stty echo 2>/dev/null; echo
        [ "$pass" = "$pass2" ] || { echo "FAIL:两次密码不一致"; return 1; }
    fi
    if [ ${#pass} -lt 8 ]; then
        unset pass pass2
        echo "FAIL:密码至少 8 位"; return 1
    fi

    stage=$(mktemp -d)
    if ! ditto "$BASE/accounts/$target/" "$stage/"; then
        rm -rf "$stage"; unset pass pass2
        echo "FAIL:复制快照失败"; return 1
    fi
    cat > "$stage/.claude-switcher-snapshot.json" <<EOF
{"format":"claude-switcher-snapshot","version":1,"account":"$target","created":"$(date '+%F %T')"}
EOF
    if ! printf '%s\n' "$pass" | hdiutil create -srcfolder "$stage" -volname "ClaudeSnapshot-$target" \
        -encryption AES-256 -stdinpass "$out" >/dev/null 2>&1; then
        rm -rf "$stage"; rm -f "$out"; unset pass pass2
        echo "FAIL:创建加密镜像失败"; return 1
    fi
    rm -rf "$stage"
    # 加密镜像校验必须带密码,否则 macOS 会弹出图形密码框
    if ! printf '%s\n' "$pass" | hdiutil verify -stdinpass "$out" >/dev/null 2>&1; then
        rm -f "$out"; unset pass pass2
        echo "FAIL:镜像校验失败"; return 1
    fi
    unset pass pass2
    chmod 600 "$out"
    echo "OK:账号$target 已加密导出到 $out"
}

snapshot_import() {
    file="${1:-}"; target="${2:-}"; mode="${3:-}"
    case "$target" in A|B|C|D) ;; *) echo "FAIL:账号必须是 A、B、C 或 D"; return 1 ;; esac
    [ -f "$file" ] || { echo "FAIL:找不到镜像文件: $file"; return 1; }
    [ -e "$BASE/accounts/$target" ] && { echo "FAIL:账号$target 已有快照,请先导出或删除后再导入"; return 1; }

    if [ "$mode" = "--password-stdin" ]; then
        IFS= read -r pass || true
    else
        printf '输入镜像密码: '; stty -echo 2>/dev/null; IFS= read -r pass; stty echo 2>/dev/null; echo
    fi
    [ -n "$pass" ] || { echo "FAIL:密码为空"; return 1; }

    mnt=$(mktemp -d)
    attached=0
    if ! printf '%s\n' "$pass" | hdiutil attach -stdinpass -nobrowse -readonly -mountpoint "$mnt" "$file" >/dev/null 2>&1; then
        unset pass; rm -rf "$mnt"
        echo "FAIL:密码错误或镜像损坏"; return 1
    fi
    attached=1
    unset pass

    cleanup_import() {
        [ "$attached" = "1" ] && hdiutil detach "$mnt" >/dev/null 2>&1
        rm -rf "$mnt" "$BASE/accounts/$target.new"
    }

    marker="$mnt/.claude-switcher-snapshot.json"
    if [ ! -f "$marker" ]; then
        cleanup_import
        echo "FAIL:不是本项目导出的快照镜像"; return 1
    fi
    if ! python3 - "$marker" "$target" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: meta = json.load(f)
assert meta.get("format") == "claude-switcher-snapshot"
assert meta.get("version") == 1
assert meta.get("account") in ("A", "B", "C", "D")
sys.exit(0 if meta.get("account") == sys.argv[2] else 1)
PY
    then
        cleanup_import
        echo "FAIL:镜像元数据校验失败(账号不匹配或格式不支持)"; return 1
    fi

    rm -rf "$BASE/accounts/$target.new"
    if ! ditto "$mnt" "$BASE/accounts/$target.new"; then
        cleanup_import
        echo "FAIL:复制到账号目录失败"; return 1
    fi
    rm -f "$BASE/accounts/$target.new/.claude-switcher-snapshot.json"
    chmod 700 "$BASE/accounts/$target.new"
    if ! mv "$BASE/accounts/$target.new" "$BASE/accounts/$target"; then
        cleanup_import
        echo "FAIL:写入账号目录失败"; return 1
    fi
    cleanup_import
    echo "OK:已导入为账号$target(切换时生效)"
}

status() {
    local cur="none" hasA=0 hasB=0 hasC=0 hasD=0 a dir size stamp accounts="" extras=""
    [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    [ -d "$BASE/accounts/A" ] && hasA=1
    [ -d "$BASE/accounts/B" ] && hasB=1
    [ -d "$BASE/accounts/C" ] && hasC=1
    [ -d "$BASE/accounts/D" ] && hasD=1
    for a in A B C D; do
        dir="$BASE/accounts/$a"
        [ -d "$dir" ] || continue
        accounts="${accounts:+$accounts,}$a"
        size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
        stamp=$(date -r "$dir" '+%Y-%m-%d' 2>/dev/null)
        extras="$extras acc$a=${size:-?}@${stamp:-?}"
    done
    if [ -e "$BASE/network-rebuild-pending.json" ] || [ -L "$BASE/network-rebuild-pending.json" ]; then extras="$extras network_rebuild=1"; fi
    echo "current=$cur hasA=$hasA hasB=$hasB hasC=$hasC hasD=$hasD accounts=${accounts:-none}$extras"
}

quit_claude() {
    pgrep -f "/Applications/Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
    osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1
    for i in $(seq 1 15); do
        pgrep -f "/Applications/Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
        sleep 1
    done
    return 1
}

cli_config_dir() {
    case "${1:-}" in
        A) printf '%s\n' "$HOME/.claude" ;;
        B|C|D) printf '%s\n' "$BASE/cli-accounts/$1" ;;
        *) return 1 ;;
    esac
}

cli_pids() {
    local uid="${1:-$(id -u)}"
    ps -axo pid=,uid=,comm=,args= | awk -v uid="$uid" '
        $2 == uid && ($3 ~ /(^|\/)(claude|claude\.exe)$/ ||
        ($3 ~ /(^|\/)(node|bun)$/ && $5 ~ /(^|\/)@anthropic-ai\/claude-code\/(bin\/claude(\.exe)?|cli\.js)$/)) { print $1 }'
}

quit_cli() {
    local uid="${1:-$(id -u)}" pids i
    pids=$(cli_pids "$uid")
    [ -z "$pids" ] && return 0
    kill -TERM $pids 2>/dev/null || true
    for i in $(seq 1 10); do
        pids=$(cli_pids "$uid")
        [ -z "$pids" ] && return 0
        sleep 1
    done
    return 1
}

cli_lock_acquire() {
    [ "${CLI_LOCK_HELD:-0}" -eq 1 ] && return 0
    if mkdir "$BASE/cli-operation.lock" 2>/dev/null; then
        CLI_LOCK_HELD=1
        trap cli_lock_release EXIT
        return 0
    fi
    echo "FAIL:另一个 CLI 启动或账号切换正在进行，请稍后重试"
    return 1
}

cli_lock_release() {
    if [ "${CLI_LOCK_HELD:-0}" -eq 1 ]; then
        rmdir "$BASE/cli-operation.lock" 2>/dev/null || true
        CLI_LOCK_HELD=0
    fi
}

run_cli() {
    local cur dir cli_path audit var pid
    cli_lock_acquire || return 1
    [ -f "$BASE/current" ] || { echo "FAIL:请先在桌面切换器中初始化账号"; return 1; }
    cur=$(cat "$BASE/current")
    dir=$(cli_config_dir "$cur") || { echo "FAIL:当前账号无效，请先重新切换账号"; return 1; }
    for var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
        CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_PROFILE; do
        if [ -n "${!var-}" ]; then
            echo "FAIL:检测到认证环境变量 $var，无法保证账号隔离，已拒绝启动"
            return 1
        fi
    done
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$dir" ]; then
        echo "FAIL:CLAUDE_CONFIG_DIR 与当前账号不一致，请修正后重试"
        return 1
    fi
    cli_path=$(command -v claude) || { echo "FAIL:未找到 Claude Code CLI"; return 1; }
    case "$cli_path" in
        /*) ;;
        *) echo "FAIL:无法解析 Claude Code CLI 的真实路径"; return 1 ;;
    esac
    audit=$(check) || { printf '%s\n' "$audit" >&2; echo "FAIL:环境审计未通过，已阻止启动 Claude Code"; return 1; }
    [ "$(cat "$BASE/current")" = "$cur" ] || { echo "FAIL:审计期间账号已变化，请重新启动 Claude Code"; return 1; }
    if [ "$cur" != "A" ]; then
        if [ -L "$BASE/cli-accounts" ] || [ -L "$dir" ]; then
            echo "FAIL:CLI 账号目录不能是符号链接"
            return 1
        fi
        mkdir -p "$BASE/cli-accounts" "$dir" || { echo "FAIL:无法创建 CLI 账号目录"; return 1; }
        chmod 700 "$BASE/cli-accounts" "$dir" || { echo "FAIL:无法保护 CLI 账号目录"; return 1; }
    fi
    CLAUDE_CONFIG_DIR="$dir" "$cli_path" "$@" &
    pid=$!
    cli_lock_release
    wait "$pid"
}

cli_current() {
    local cur dir
    [ -f "$BASE/current" ] || { echo "FAIL:请先在桌面切换器中初始化账号"; return 1; }
    cur=$(cat "$BASE/current")
    dir=$(cli_config_dir "$cur") || { echo "FAIL:当前账号无效"; return 1; }
    echo "current=$cur config=$dir"
}

archive_current() {
    local cur="$1"
    local t0 staged current previous moved=0 had_old=0
    t0=$(date +%s)
    staged="$BASE/accounts/$cur.new"
    current="$BASE/accounts/$cur"
    previous="$BASE/accounts/$cur.previous"

    # An interrupted archive may be the only remaining copy. Never clear it
    # automatically, or delete the previous snapshot before the new one commits.
    if [ -e "$staged" ] || [ -L "$staged" ] || [ -e "$previous" ] || [ -L "$previous" ]; then
        log "FAIL:账号$cur 存在待恢复快照，拒绝覆盖"
        return 1
    fi
    if mv "$DATA" "$staged" 2>/dev/null; then
        moved=1
    else
        # A cross-volume move may leave a partial destination on failure.
        if [ -e "$staged" ] || [ -L "$staged" ]; then
            log "FAIL:账号$cur 归档移动不完整，保留现场"
            return 1
        fi
        if ! copy_tree "$DATA" "$staged"; then
            log "FAIL:账号$cur 归档复制失败，保留现场"
            return 1
        fi
    fi

    if [ -e "$current" ] || [ -L "$current" ]; then
        if ! mv "$current" "$previous"; then
            if [ "$moved" -eq 1 ]; then
                mv "$staged" "$DATA" || log "WARN:账号$cur 数据保留在暂存位置"
            fi
            log "FAIL:账号$cur 旧快照无法安全转存"
            return 1
        fi
        had_old=1
    fi
    if ! mv "$staged" "$current"; then
        if [ "$had_old" -eq 1 ]; then
            mv "$previous" "$current" || log "WARN:账号$cur 旧快照保留在恢复位置"
        fi
        if [ "$moved" -eq 1 ]; then
            mv "$staged" "$DATA" || log "WARN:账号$cur 当前数据保留在暂存位置"
        fi
        log "FAIL:账号$cur 归档提交失败"
        return 1
    fi
    if [ "$had_old" -eq 1 ]; then
        rm -rf "$previous" || log "WARN:账号$cur 旧快照副本需手动清理"
    fi
    log "已存档账号$cur ($(( $(date +%s) - t0 ))s)"
}

# 快照复制:APFS 上用 clonefile(COW) 近乎瞬时,不改写已有快照;不支持时回退 ditto 全量复制
copy_tree() {
    src="$1"; dst="$2"
    if [ "${CLAUDE_SWITCHER_NO_CLONE:-0}" != "1" ] && cp -cRp "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    rm -rf "$dst"
    ditto "$src" "$dst"
}

# 只接受 A-D 四个账号槽位
valid_account() {
    case "${1:-}" in
        A|B|C|D) return 0 ;;
        *) echo "FAIL:账号必须是 A、B、C 或 D"; return 1 ;;
    esac
}

# ---------- 跨身份保留(可选) ----------
# 校验相对路径的每个分量都不是符号链接,避免把 DATA 外的内容带进快照
keep_path_safe() {
    local rel="$1" prefix="$DATA" part
    while [ -n "$rel" ]; do
        part="${rel%%/*}"
        if [ "$part" = "$rel" ]; then rel=""; else rel="${rel#*/}"; fi
        [ -z "$part" ] && continue
        prefix="$prefix/$part"
        [ -L "$prefix" ] && return 1
    done
    return 0
}

# 归档当前账号之前,把 keep 列表里存在的路径收进暂存目录
stage_keep_paths() {
    local keepf="$BASE/keep-in-workspace.txt"
    local stage="$BASE/keep-stage"
    local rel src dst count=0
    KEEP_STAGED=0
    [ -f "$keepf" ] || return 0
    # 上次还原失败时 stage 可能是唯一完整副本,不自动覆盖
    if [ -e "$stage" ] || [ -L "$stage" ]; then
        log "FAIL:跨身份保留暂存目录已存在，请检查或重试上次切换: $stage"
        return 1
    fi
    while IFS= read -r rel || [ -n "$rel" ]; do
        rel="${rel%$'\r'}"
        case "$rel" in
            ''|'#'*|[[:space:]]*'#'*) continue ;;
            /*) log "WARN:keep 路径必须是相对路径，已跳过: $rel"; continue ;;
            *..*) log "WARN:keep 路径不能包含 ..，已跳过: $rel"; continue ;;
        esac
        while [ "${rel%/}" != "$rel" ]; do rel="${rel%/}"; done
        while [ "${rel#./}" != "$rel" ]; do rel="${rel#./}"; done
        if [ -z "$rel" ] || [ "$rel" = "." ]; then
            log "WARN:keep 路径为空或指向数据目录本身，已跳过: $rel"
            continue
        fi
        if ! keep_path_safe "$rel"; then
            log "WARN:keep 路径含符号链接，已跳过: $rel"
            continue
        fi
        src="$DATA/$rel"
        [ -e "$src" ] || continue
        dst="$stage/$rel"
        if ! mkdir -p "$(dirname "$dst")" || ! ditto "$src" "$dst"; then
            rm -rf "$stage"
            log "FAIL:跨身份保留暂存失败"
            return 1
        fi
        count=$((count + 1))
    done < "$keepf"
    if [ "$count" -eq 0 ]; then
        rm -rf "$stage"
        log "跨身份保留:没有需要保留的路径"
        return 0
    fi
    KEEP_STAGED=$count
    log "跨身份保留:已收起 $count 条路径"
    return 0
}

# 还原目标账号后,把暂存内容合并回 DATA;失败时保留 stage 供排查
restore_keep_paths() {
    local stage="$BASE/keep-stage"
    [ -d "$stage" ] || return 0
    if ! ditto "$stage/" "$DATA/"; then
        log "FAIL:跨身份保留还原失败，暂存保留在 $stage"
        return 1
    fi
    rm -rf "$stage"
    log "跨身份保留:已还原 ${KEEP_STAGED:-0} 条路径到新账号"
    return 0
}

switch_to() {
    target="${1:-}"
    valid_account "$target" || return 1
    cli_lock_acquire || return 1
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    just_archived=0

    # 首次运行:把当前登录中的状态收编为账号A
    if [ "$cur" = "none" ] && [ -d "$DATA" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
        cli_lock_acquire || return 1
        quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }
        quit_cli || { echo "FAIL:Claude Code 未能退出，请手动退出后重试"; return 1; }
        if [ -s "$BASE/keep-in-workspace.txt" ]; then
            stage_keep_paths || { echo "FAIL:跨身份保留暂存失败，已停止切换"; return 1; }
        fi
        archive_current A || {
            rm -rf "$BASE/keep-stage"
            echo "FAIL:首次账号归档失败，已停止切换"; return 1
        }
        just_archived=1
        cur="A"; echo "$cur" > "$BASE/current"
        log "首次运行:当前登录状态已收编为账号A"
        echo "NOTE:已将当前登录收编为账号A"
    fi

    if [ "$cur" = "$target" ]; then
        # 归档是移动语义;首次收编或上次切换中断后,先用存档恢复 DATA
        if [ ! -d "$DATA" ]; then
            if [ ! -d "$BASE/accounts/$target" ]; then
                echo "FAIL:账号$target 数据目录缺失，已停止切换"; return 1
            fi
            if ! copy_tree "$BASE/accounts/$target" "$DATA"; then
                echo "FAIL:账号$target 还原失败，已停止切换"; return 1
            fi
        fi
        # 上次还原失败留下的 stage,在当前账号上重试合并
        if [ -d "$BASE/keep-stage" ]; then
            restore_keep_paths || { echo "FAIL:跨身份保留还原失败，暂存保留在 $BASE/keep-stage"; return 1; }
        fi
        open -a "Claude"
        echo "INFO:当前已是账号$target"
        return 0
    fi

    cli_lock_acquire || return 1
    quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }
    quit_cli || { echo "FAIL:Claude Code 未能退出，请手动退出后重试"; return 1; }

    if [ "$just_archived" = "0" ] && [ "$cur" != "none" ] && [ -d "$DATA" ]; then
        if [ -s "$BASE/keep-in-workspace.txt" ]; then
            stage_keep_paths || { echo "FAIL:跨身份保留暂存失败，已停止切换"; return 1; }
        fi
        archive_current "$cur" || {
            rm -rf "$BASE/keep-stage"
            echo "FAIL:账号$cur 归档失败，已停止切换"; return 1
        }
    fi

    rm -rf "$DATA.new"
    t0=$(date +%s)
    if [ -d "$BASE/accounts/$target" ]; then
        if ! copy_tree "$BASE/accounts/$target" "$DATA.new"; then
            log "FAIL:账号$target 存档载入失败"
            echo "FAIL:账号$target 存档载入失败，暂存保留在 $BASE/keep-stage"
            return 1
        fi
        log "已载入账号$target 存档 ($(( $(date +%s) - t0 ))s)"
    else
        if ! mkdir -p "$DATA.new"; then
            log "FAIL:无法创建账号$target 数据目录"
            echo "FAIL:无法创建账号$target 数据目录"
            return 1
        fi
        log "账号$target 无存档，将以全新状态初始化"
    fi
    if ! { rm -rf "$DATA" && mv "$DATA.new" "$DATA"; }; then
        log "FAIL:载入账号$target 失败"
        echo "FAIL:载入账号$target 失败，暂存保留在 $BASE/keep-stage"
        return 1
    fi
    echo "$target" > "$BASE/current"

    if [ -d "$BASE/keep-stage" ]; then
        if ! restore_keep_paths; then
            echo "FAIL:跨身份保留还原失败，暂存保留在 $BASE/keep-stage"
            return 1
        fi
    fi

    open -a "Claude"
    log "已切换到账号$target 并启动 ($(( $(date +%s) - t0 ))s)"
    echo "OK:已切换到账号$target ($(( $(date +%s) - t0 ))s)"
    return 0
}

operation="${1:-}"
started_at=$(date +%s)
summary=""
case "$operation" in
    network-rebuild)
        case "${2:-}" in
            preview|apply|state|rollback) "$0" _network-rebuild "${@:2}" ;;
            validate)
                if [ "$#" -ne 2 ] || ! "$0" _network-rebuild has-pending >/dev/null 2>&1; then
                    echo '{"schema":1,"kind":"network_rebuild","success":false,"message":"当前没有有效的待验收记录。"}'
                    exit 1
                fi
                "$0" _network-rebuild busy >/dev/null 2>&1
                busy_rc=$?
                if [ "$busy_rc" -ne 1 ] || ! check >/dev/null 2>&1; then
                    echo '{"schema":1,"kind":"network_rebuild","success":false,"pending":true,"message":"保护环境尚未恢复或操作仍在执行。请先启用代理、TUN 和原有安全设置，再检查；启动锁定保留。"}'
                    exit 1
                fi
                "$0" _network-rebuild finish
                ;;
            *) echo '{"schema":1,"kind":"network_rebuild","success":false,"message":"请使用 preview <1|2|3>、apply <层级> <预检令牌>、state、validate 或 rollback。"}'; exit 2 ;;
        esac
        ;;
    check)  check ;;
    checkdetail)
        OUT_FILE="$BASE/last-check.txt"
        {
            echo "# $(date '+%F %T') pid=$$ 开始"
            checkdetail
            rc=$?
            echo "# 结束"
        } > "$OUT_FILE" 2>&1
        cat "$OUT_FILE"
        summary=$(awk -F= '{ split($2, s, ":"); if ($1 != "" && s[1] ~ /^(ok|warn|fail|skip)$/) print $1 "=" s[1] }' "$OUT_FILE" | tr '\n' ' ')
        ;;
    fix) fix ;;
    status) status ;;
    switch) switch_to "${2:-}" ;;
    set-region) set_region ;;
    set-client) set_client "${2:-}" "${3:-}" ;;
    get-client) get_client ;;
    detect-client) detect_client_state ;;
    update) self_update "${2:-}" ;;
    update-check) self_update --check ;;  # 只读检查;独立入口,避免旧版核心把 --check 当成真实更新
    open-safe) open_safe "${2:-}" ;;
    cli-info) cli_info ;;
    cli) run_cli "${@:2}" ;;
    cli-current) cli_current ;;
    snapshot-export) snapshot_export "${2:-}" "${3:-}" "${4:-}" ;;
    snapshot-import) snapshot_import "${2:-}" "${3:-}" "${4:-}" ;;
    export-diagnostics) "$0" _support export-diagnostics "${2:-}" ;;
    get-check-config) "$0" _support config-get ;;
    set-check-config) "$0" _support config-set "${2:-}" ;;
    get-tool-config) "$0" _support tools-get "$COUNTRY_TARGET" "$TZ_TARGET" "$LOCALE_TARGET" "$PROXY_MODE" ;;
    set-keep-paths) "$0" _support keep-set "${2:-}" ;;
    write-merge-rules) write_merge_rules ;;  # 隐藏入口:供安装器调用,保证两处合并逻辑一致
    fingerprint) fingerprint ;;
    *) echo "用法: claude-switch.sh check|checkdetail|fix|status|switch A|B|C|D|set-region|set-client <mode>|update [--check|--auto|--gui]|update-check|fingerprint|snapshot-export <A|B|C|D> <file>|snapshot-import <file> <A|B|C|D>|open-safe <url>|cli-info|cli [args...]|cli-current|export-diagnostics <file>|get-check-config|set-check-config <json>|diagnose-proxy [--proxy URL|--config FILE]|network-rebuild <preview|apply|state|validate|rollback> [args...]"; exit 2 ;;
esac
# checkdetail 分支内部已保存返回码;其他分支取 case 的最终状态。
# 判断本身会改变 $?，所以必须先捕获 dispatch_rc，再按操作类型落 rc。
dispatch_rc=$?
if [ "$operation" != "checkdetail" ]; then
    rc=$dispatch_rc
fi
case "$operation" in
    get-check-config|set-check-config|get-tool-config|set-keep-paths|export-diagnostics|detect-client|network-rebuild) ;;
    *) log_result "$started_at" "$operation" "$rc" "$summary" ;;
esac
exit "$rc"
