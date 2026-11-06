import Foundation
import AppKit
import SwiftUI

private let auditKeys = ["代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS", "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性"]

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func spin(until condition: () -> Bool, timeout: TimeInterval = 6) throws {
    let limit = Date().addingTimeInterval(timeout)
    while !condition(), Date() < limit {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try expect(condition(), "等待异步结果超时")
}

private func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

private final class Fixture {
    let root: URL
    let core: URL

    init() throws {
        let trash = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("_trash")
        root = trash.appendingPathComponent("menu-bar-model-\(UUID().uuidString)")
        core = root.appendingPathComponent("fake-core.sh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("audit", auditKeys.map { "\($0)=ok" }.joined(separator: "\n") + "\n")
        try write("status", "current=A hasA=1 hasB=0\n")
        try write("switch-output", "OK:已切换到账号 B\n")
        try write("core-script", """
        #!/bin/bash
        root="$(cd "$(dirname "$0")" && pwd)"
        printf '%s\\n' "$*" >> "$root/calls"
        delay() { if [ -f "$root/$1-delay" ]; then /bin/sleep "$(cat "$root/$1-delay")"; fi; }
        result() { if [ -f "$root/$1-exit" ]; then exit "$(cat "$root/$1-exit")"; fi; }
        case "$1" in
          checkdetail) delay check; cat "$root/audit"; result check ;;
          status) cat "$root/status"; result status ;;
          get-client) if [ -f "$root/client" ]; then cat "$root/client"; else echo 'client=clash-verge'; fi ;;
          get-check-config) cat "$root/check-config"; result get-config ;;
          set-check-config) printf '%s\n' "$2" > "$root/saved-config"; result set-config ;;
          switch) delay switch; cat "$root/switch-output"; result switch ;;
          update) delay update; cat "$root/update-output"; result update ;;
          fix) delay fix; echo 'FIX:演示修复完成'; result fix ;;
          fingerprint) delay fingerprint; echo 'GPU=ok:演示设备' ;;
          get-tool-config) cat "$root/tool-config"; result tool-config ;;
          set-keep-paths) printf '%s' "$2" > "$root/saved-keep"; echo 'OK:已保存' ;;
          cli-info|cli-current) echo 'current=A config=fixture'; result tools ;;
          cli) pwd > "$root/cli-pwd"; printf '%s' "$2" > "$root/cli-args" ;;
          snapshot-export|snapshot-import) cat > "$root/snapshot-input"; echo 'OK:快照操作完成' ;;
          open-safe) echo 'OK:已打开' ;;
          diagnose-proxy) printf '%s' "$CLAUDE_SWITCHER_PROXY_URL" > "$root/proxy-env"; cat "$root/diagnostics" ;;
          set-region) delay tools; echo 'OK:地区已更新'; result tools ;;
          *) exit 2 ;;
        esac
        """)
        try FileManager.default.moveItem(at: root.appendingPathComponent("core-script"), to: core)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ name: String, _ value: String) throws {
        try value.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func audit(_ changes: [String: String] = [:]) throws {
        try write("audit", auditKeys.map { "\($0)=\(changes[$0] ?? "ok")" }.joined(separator: "\n") + "\n")
    }

    func vm(checkTimeout: TimeInterval = 2, operationTimeout: TimeInterval = 2) -> VM {
        VM(core: core.path, checkTimeout: checkTimeout, operationTimeout: operationTimeout)
    }

    var calls: [String] {
        ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func idle(_ vm: VM) throws { try spin { !vm.isBusy } }

    func deniedSwitch(_ vm: VM) throws {
        vm.switchTo("B")
        try idle(vm)
        try expect(vm.phase == .failed, "审计异常应阻断切换")
        try expect(!calls.contains { $0.hasPrefix("switch ") }, "审计异常仍执行了 switch")
        try expect(vm.canQuit, "失败后应该可以退出")
    }
}

@main
struct MenuBarModelTests {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw TestFailure(description: "缺少测试场景") }
            let name = CommandLine.arguments[1]
            let f = try Fixture()
            switch name {
            case "startup_once":
                let vm = f.vm()
                vm.start(); vm.start()
                try f.idle(vm)
                try expect(f.calls == ["checkdetail", "get-client", "status"], "启动不应重复检查")
                try expect(vm.phase == .ready && vm.lastCheckSummary == "通过" && vm.current == "A", "初始状态不一致")
            case "audit_success_details":
                try f.audit(["TUN网卡": "ok:检测通过", "IP一致": "ok:与上次一致",
                             "时区": "ok:Asia/Tokyo", "地区": "ok:ja_JP"])
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                for (name, detail) in [("TUN 网卡", "检测通过"), ("IP 与上次一致", "与上次一致"),
                                       ("时区", "Asia/Tokyo"), ("地区", "ja_JP")] {
                    guard let row = vm.rows.first(where: { $0.name == name }) else {
                        throw TestFailure(description: "缺少检查项：\(name)")
                    }
                    try expect(row.state == .ok && row.detail == detail, "检查项详情不正确：\(name)")
                }
            case "tools_config":
                try f.write("tool-config", "{\"keepPaths\":\"settings.json\\n\",\"policy\":\"proxy\",\"country\":\"JP\",\"timezone\":\"Asia/Tokyo\",\"locale\":\"ja_JP\",\"client\":\"tag\"}")
                let vm = f.vm()
                vm.loadTools(); try f.idle(vm)
                try expect(f.calls == ["get-tool-config"], "打开工具不能触发修复、网络检查或启动")
                try expect(vm.keepPaths == "settings.json\n" && vm.regionTarget == "JP · Asia/Tokyo · ja_JP", "工具配置应来自核心")
                try expect(!vm.supportsWebRTCPolicy, "TAG 不能使用托管策略")
                vm.saveKeepPaths(); try f.idle(vm)
                let saved = try String(contentsOf: f.root.appendingPathComponent("saved-keep"), encoding: .utf8)
                let decoded = try JSONSerialization.jsonObject(with: Data(saved.utf8), options: [.fragmentsAllowed]) as? String
                try expect(decoded == "settings.json\n", "列表必须作为一个 JSON 参数传递")
            case "tools_snapshot_password":
                try f.write("status", "current=A hasA=1 hasB=1 hasC=0 hasD=0 accounts=A,B\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                vm.transferSnapshot(importing: false, account: "B", file: f.root.appendingPathComponent("snapshot.dmg"), password: "secret pass", confirmation: "secret pass")
                try f.idle(vm)
                let input = try String(contentsOf: f.root.appendingPathComponent("snapshot-input"), encoding: .utf8)
                try expect(input == "secret pass\n", "密码必须经标准输入传递")
                try expect(!f.calls.joined().contains("secret pass") && !vm.toolOutput.contains("secret pass"), "密码不能进入参数或结果")
                try expect(f.calls.last?.hasSuffix("--password-stdin") == true, "必须选择非交互密码入口")
                try f.write("status", "current=A hasA=1 hasB=1 hasC=1 hasD=0 accounts=A,B,C\n")
                vm.transferSnapshot(importing: true, account: "C", file: f.root.appendingPathComponent("snapshot-c.dmg"), password: "secret pass")
                try f.idle(vm)
                try expect(vm.archived.contains("C") && f.calls.last == "status", "导入成功后必须刷新账号状态")
            case "tools_invalid_inputs":
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                let before = f.calls
                for address in ["file:///etc/passwd", "https://", "https://user:password@example.com", "https://example.com\n"] {
                    // Trailing whitespace is intentionally normalized; embedded newlines are rejected.
                    vm.openIsolated(address == "https://example.com\n" ? "https://example.com\npath" : address)
                }
                vm.transferSnapshot(importing: false, account: "A", file: f.root, password: "secret pass", confirmation: "secret pass")
                vm.transferSnapshot(importing: true, account: "A", file: f.root, password: "secret pass")
                vm.transferSnapshot(importing: true, account: "C", file: f.root, password: "one\ntwo")
                try expect(f.calls == before, "无效或危险输入不能启动核心")
                try f.write("tool-config", "{\"keepPaths\":\"\",\"policy\":\"proxy\",\"country\":\"JP\",\"timezone\":\"Asia/Tokyo\",\"locale\":\"ja_JP\",\"client\":\"tag\"}")
                vm.loadTools(); try f.idle(vm)
                let tagCalls = f.calls
                vm.webrtcPolicy = "reject"; vm.applyWebRTCPolicy()
                try expect(f.calls == tagCalls && vm.toolFailed, "TAG 必须在启动修复前拒绝策略修改")
            case "tools_proxy_privacy":
                try f.write("diagnostics", "{\"mode\":\"proxy_diagnostics\",\"checks\":[{\"name\":\"anthropic_api\",\"transport_reached\":true,\"http_status\":401},{\"name\":\"claude_web\",\"transport_reached\":true,\"http_status\":403}]}")
                let vm = f.vm()
                let proxy = "http://user:private-password@127.0.0.1:18080"
                vm.diagnoseProxy(address: proxy, config: nil); try f.idle(vm)
                let value = try String(contentsOf: f.root.appendingPathComponent("proxy-env"), encoding: .utf8)
                try expect(value == proxy && f.calls == ["diagnose-proxy"], "代理凭据只能经环境传给脱敏诊断")
                try expect(!vm.toolOutput.contains("private-password") && vm.toolOutput.contains("尚未认证") && vm.toolOutput.contains("访问受限"), "认证和访问限制不能显示为账号可用")
            case "tools_mutation_reaudit":
                try f.write("tools-delay", "0.1")
                let vm = f.vm()
                vm.resetRegion()
                try expect(vm.toolRunning && !vm.canQuit, "配置变更期间不能退出")
                vm.refresh(); vm.fixAll()
                try f.idle(vm)
                try expect(f.calls == ["set-region", "checkdetail", "get-client", "status"], "地区变更要串行完成再重新审计")
                try f.write("tools-exit", "1")
                vm.resetRegion(); try f.idle(vm)
                try expect(vm.toolFailed && f.calls.last == "status", "失败可能部分写入，仍须重新审计且保留失败状态")
            case "tools_terminal_quoting":
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                let project = f.root.appendingPathComponent("project ' $(touch INJECTED)")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                var command = ""
                vm.terminalLauncher = { value, done in command = value; done(CoreResult(output: "", succeeded: true)) }
                vm.launchCLI(project: project, resume: true)
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", command]
                try p.run(); p.waitUntilExit()
                let cwd = try String(contentsOf: f.root.appendingPathComponent("cli-pwd"), encoding: .utf8).trimmingCharacters(in: .newlines)
                let args = try String(contentsOf: f.root.appendingPathComponent("cli-args"), encoding: .utf8)
                try expect(p.terminationStatus == 0 && cwd == project.path && args == "--resume", "项目路径必须原样引用且保留会话参数")
                try expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("INJECTED").path), "项目路径不得执行命令替换")
                vm.terminalLauncher = { _, done in done(CoreResult(output: "终端授权被拒绝", succeeded: false)) }
                vm.launchCLI(project: project, resume: false)
                try expect(vm.toolFailed && vm.toolOutput == "终端授权被拒绝" && vm.canQuit, "终端失败不能显示为启动成功")
            case "tools_shell_isolation":
                let startup = f.root.appendingPathComponent("startup.sh")
                let marker = f.root.appendingPathComponent("startup-ran")
                try "touch \(VM.shellQuote(marker.path))\n".write(to: startup, atomically: true, encoding: .utf8)
                setenv("BASH_ENV", startup.path, 1)
                defer { unsetenv("BASH_ENV") }
                let vm = f.vm()
                vm.inspectCLISlot(); try f.idle(vm)
                try expect(f.calls == ["cli-current"] && !FileManager.default.fileExists(atPath: marker.path), "界面子进程不能继承覆盖命令的 Bash 启动配置")
            case "tools_layout":
                try f.write("tool-config", "{\"keepPaths\":\"# 通用配置\\nsettings.json\\nskills/\\n\",\"policy\":\"proxy\",\"country\":\"JP\",\"timezone\":\"Asia/Tokyo\",\"locale\":\"ja_JP\",\"client\":\"tag\"}")
                _ = NSApplication.shared
                let vm = f.vm()
                for section in ["cli", "snapshot", "network", "keep"] {
                    let view = NSHostingView(rootView: ToolsView(vm: vm, initialSection: section))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = view
                    pump(0.1); try f.idle(vm)
                    view.layoutSubtreeIfNeeded()
                    try expect(view.fittingSize.width <= 681 && view.fittingSize.height <= 661, "工具布局不能撑出窗口")
                    if let directory = ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_TEST_RENDER_DIR"],
                       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        let data = bitmap.representation(using: .png, properties: [:])
                        try data?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tools-\(section).png"))
                    }
                    window.contentView = nil
                }
            case "tag_client_recognized":
                try f.write("client", "client=tag\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.currentClient == "tag", "应读取 TAG 客户端")
                try expect(VM.clientChoices.contains { $0.key == "tag" && $0.label == "TAG" }, "客户端列表应包含 TAG")
            case "in_app_update_relaunch":
                try f.write("update-output", "OK:已是最新版本\n")
                let vm = f.vm()
                var relaunches = 0
                vm.onRelaunchRequested = { relaunches += 1 }
                vm.performUpdate(); try f.idle(vm)
                try expect(f.calls == ["update --gui"], "立即更新应调用 update --gui")
                try expect(relaunches == 0, "已是最新版本时不应重启应用")
                try f.write("update-output", "OK:核心脚本更新完成 2026-11-05；App 与系统守护由安装器更新\n")
                vm.performUpdate(); try f.idle(vm)
                try expect(relaunches == 0, "仅更新核心时不应重启界面")
                try expect(!vm.updateText.contains("正在重启"), "仅更新核心不应显示正在重启")
                try expect(Array(f.calls.suffix(4)) == ["update --gui", "checkdetail", "get-client", "status"],
                           "更新核心后应刷新检查和账号状态")
                try f.write("update-output", "OK:核心脚本更新完成 2026-11-04（已同步更新：界面App）\n")
                vm.performUpdate(); try f.idle(vm)
                try expect(relaunches == 1, "更新成功后应请求自动重启应用")
                try expect(vm.updateText.contains("正在重启 Claude 切换器"), "应提示正在重启")
                try f.write("update-exit", "1")
                try f.write("update-output", "FAIL:新版自检未通过,已自动回滚\n")
                vm.performUpdate(); try f.idle(vm)
                try expect(relaunches == 1, "更新失败时不应重启应用")
                try f.write("update-exit", "0")
                try f.write("update-output", "OK:核心脚本更新完成（已同步更新：界面App）\n")
                let withoutRelaunch = f.vm()
                withoutRelaunch.performUpdate(); try f.idle(withoutRelaunch)
                try expect(withoutRelaunch.updateText.contains("无法自动重启"), "缺少重启处理时应提示用户")
            case "multi_account_status":
                try f.write("status", "current=A hasA=1 hasB=1 hasC=1 hasD=0 accounts=A,B,C accA=1.2G@2026-10-20 accB=900M@2026-10-19 accC=2.0G@2026-10-18\n")
                try f.write("switch-output", "OK:已切换到账号 C\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.archived == Set(["A", "B", "C"]), "应解析三个已建档账号")
                try expect(vm.stamps["A"] == AccountStamp(size: "1.2G", date: "2026-10-20"), "应解析账号大小与日期")
                let card = ContentView(vm: vm)
                try expect(card.accountSubtitle("A") == "当前", "当前账号副标题不正确")
                try expect(card.accountSubtitle("B") == "已建档 · 900M · 10-19", "已建档副标题应带大小与日期")
                try expect(card.accountSubtitle("D") == "未初始化", "空槽位副标题不正确")
                vm.switchTo("C"); try f.idle(vm)
                try expect(vm.current == "C" && vm.note.isEmpty, "已建档的 C 不应提示首次登录")
                try expect(f.calls.contains("switch C"), "C 应被允许切换")
            case "first_use_cd_note":
                try f.write("status", "current=A hasA=1 hasB=1 hasC=1 hasD=0 accounts=A,B,C\n")
                try f.write("switch-output", "OK:已切换到账号 D\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                vm.switchTo("D"); try f.idle(vm)
                try expect(vm.current == "D", "D 应被允许切换")
                try expect(vm.note.contains("D 号首次使用") && vm.note.contains("登录"), "D 首次使用应提示登录")
            case "legacy_status_fallback":
                try f.write("status", "current=B hasA=1 hasB=1\n")
                let vm = f.vm()
                vm.start(); try f.idle(vm)
                try expect(vm.current == "B" && vm.archived == Set(["A", "B"]), "旧版 status 应回退为 A/B")
            case "invalid_multi_account_status":
                try f.write("status", "current=A hasA=1 hasB=0 hasC=0 hasD=0 accounts=A,E\n")
                let vm = f.vm()
                try f.deniedSwitch(vm)
                try expect(vm.current == "未知", "非法账号列表不可进入界面")
            case "warnings_allowed":
                try f.audit(["ASN属性": "warn:演示机房"])
                let vm = f.vm()
                vm.switchTo("B")
                try f.idle(vm)
                try expect(vm.lastCheckSummary == "有警告" && vm.current == "B", "警告应展示并允许切换")
                try expect(f.calls == ["checkdetail", "get-client", "status", "switch B"], "切换前必须先完整审计")
            case "skipped_optional_allowed":
                try f.audit(["DNS": "skip:用户已禁用", "WebRTC": "skip:用户已禁用"])
                let vm = f.vm()
                vm.switchTo("B")
                try f.idle(vm)
                try expect(vm.phase == .done && vm.current == "B", "显式跳过的非关键项不应阻断切换")
                try expect(vm.rows.first { $0.name == "DNS 走隧道" }?.state == .skip, "跳过项必须显示 skip")
            case "settings_round_trip":
                try f.write("check-config", #"{"disabled":["DNS"],"allowOptionalFailures":true,"logging":false}"#)
                let vm = f.vm()
                vm.loadCheckConfig()
                try spin { !vm.settingsBusy }
                try expect(vm.disabledChecks == Set(["DNS"]), "应读取已禁用的 DNS 检查")
                try expect(vm.allowOptionalFailures && !vm.loggingEnabled, "应读取非关键失败与日志设置")
                vm.disabledChecks.insert("WebRTC")
                vm.saveCheckConfig()
                try spin { !vm.settingsBusy }
                try f.idle(vm)
                let saved = try String(contentsOf: f.root.appendingPathComponent("saved-config"), encoding: .utf8)
                guard let data = saved.data(using: .utf8) else { throw TestFailure(description: "配置不是有效 UTF-8") }
                let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let disabled = config?["disabled"] as? [String]
                try expect(Set(disabled ?? []) == Set(["DNS", "WebRTC"]), "保存必须保留已有禁用项并加入 WebRTC")
                try expect(config?["allowOptionalFailures"] as? Bool == true, "保存必须保留非关键失败设置")
                try expect(config?["logging"] as? Bool == false, "保存必须保留日志开关")
                try expect(f.calls.contains("checkdetail"), "保存成功后必须重新检查")
            case "local_status_refresh":
                let vm = f.vm()
                vm.refreshAccountStatus()
                try expect(f.calls.isEmpty, "菜单提前出现时不可抢占启动审计")
                vm.start(); try f.idle(vm)
                try f.write("status", "current=B hasA=1 hasB=1\n")
                vm.refreshAccountStatus(); try f.idle(vm)
                try expect(f.calls == ["checkdetail", "get-client", "status", "status"], "展开菜单只应读取本地状态")
                try expect(vm.current == "B" && vm.lastCheckSummary == "通过", "账号更新不应改变上次审计结果")
            case "fresh_audit":
                let vm = f.vm()
                vm.refresh(); try f.idle(vm)
                try f.audit(["TUN网卡": "fail:已断开"])
                try f.deniedSwitch(vm)
                try expect(f.calls.filter { $0 == "checkdetail" }.count == 2, "不可复用上次通过结果")
            case "failed_check":
                try f.audit(["WebRTC": "fail:演示失败"])
                try f.deniedSwitch(f.vm())
            case "incomplete_check":
                try f.write("audit", auditKeys.dropLast().map { "\($0)=ok" }.joined(separator: "\n"))
                try f.deniedSwitch(f.vm())
            case "duplicate_check":
                try f.write("audit", auditKeys.dropLast().map { "\($0)=ok" }.joined(separator: "\n") + "\n代理内核=ok\n")
                try f.deniedSwitch(f.vm())
            case "duplicate_overwrite":
                try f.audit(["TUN网卡": "fail:断开"])
                let s = try String(contentsOf: f.root.appendingPathComponent("audit"), encoding: .utf8)
                try f.write("audit", s + "TUN网卡=ok\n")
                try f.deniedSwitch(f.vm())
            case "empty_check":
                try f.write("audit", "")
                try f.deniedSwitch(f.vm())
            case "unknown_check_code":
                try f.audit(["TUN网卡": "unknown"])
                try f.deniedSwitch(f.vm())
            case "empty_check_code":
                try f.audit(["TUN网卡": ""])
                try f.deniedSwitch(f.vm())
            case "nonzero_check":
                try f.write("check-exit", "7")
                try f.deniedSwitch(f.vm())
            case "timeout_check":
                try f.write("check-delay", "3")
                let vm = f.vm(checkTimeout: 0.1)
                try f.deniedSwitch(vm)
                try expect(vm.lastCheckSummary == "失败" && vm.banner.contains("超时"), "超时不可展示通过")
            case "invalid_status":
                try f.write("status", "current=B hasB=1")
                let vm = f.vm()
                try f.deniedSwitch(vm)
                try expect(vm.current == "未知", "账号读取失败不可沿用旧状态")
                try expect(vm.lastCheckSummary == "失败", "账号读取失败时菜单不可显示通过")
            case "nonzero_status":
                try f.write("status-exit", "1")
                try f.deniedSwitch(f.vm())
            case "switch_note_then_failure":
                try f.write("switch-output", "NOTE:开始切换\nFAIL:模拟归档失败\n")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A", "NOTE 后的 FAIL 不可当作成功")
            case "empty_switch":
                try f.write("switch-output", "")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A", "空切换结果不可当作成功")
            case "nonzero_switch":
                try f.write("switch-exit", "4")
                let vm = f.vm()
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A", "非零退出即使打印 OK 也不可当作成功")
            case "timeout_switch":
                try f.write("switch-delay", "3")
                let vm = f.vm(operationTimeout: 0.1)
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .failed && vm.current == "A" && vm.canQuit, "切换超时应恢复可操作状态")
            case "busy_guard":
                try f.write("switch-delay", "0.2")
                let vm = f.vm()
                vm.switchTo("B")
                try expect(!vm.canQuit, "切换请求开始后不可退出")
                vm.switchTo("A"); vm.refresh(); vm.fixAll(); vm.inspectFingerprint()
                try f.idle(vm)
                try expect(f.calls == ["checkdetail", "get-client", "status", "switch B"], "忙碌时应忽略重复操作")
                try expect(vm.canQuit && vm.current == "B", "切换完成后应允许退出")
            case "fix_guard":
                try f.write("fix-delay", "0.2")
                let vm = f.vm()
                vm.fixAll()
                try expect(!vm.canQuit, "修复期间不可退出")
                vm.refresh(); vm.switchTo("B"); vm.fixAll()
                try f.idle(vm)
                try expect(f.calls == ["fix", "checkdetail", "get-client", "status"], "修复结束必须重新检查，不能并行执行")
                try expect(vm.canQuit && vm.phase == .ready, "修复后应该可以退出")
            case "failed_fix":
                try f.write("fix-exit", "1")
                let vm = f.vm()
                vm.fixAll(); try f.idle(vm)
                try expect(vm.phase == .failed && vm.canQuit && f.calls == ["fix"], "修复失败不可被后续状态覆盖")
            case "checking_allows_quit":
                try f.write("check-delay", "0.2")
                let vm = f.vm()
                vm.refresh()
                try expect(vm.canQuit, "普通检查期间应允许退出")
                try f.idle(vm)
            case "hide_after_success":
                let vm = f.vm()
                var hidden = false
                vm.onSwitchCompleted = { hidden = true }
                vm.switchTo("B"); try f.idle(vm)
                try expect(vm.phase == .done && !hidden, "成功提示应该短暂保留")
                try spin(until: { hidden })
                try expect(vm.phase == .ready && vm.current == "B", "成功后应恢复就绪，不应退出进程")
            case "reopen_cancels_hide":
                let vm = f.vm()
                var hidden = false
                vm.onSwitchCompleted = { hidden = true }
                vm.switchTo("B"); try f.idle(vm)
                vm.prepareToShow()
                pump(2.4)
                try expect(!hidden && vm.phase == .ready, "主动重开窗口后不能被旧回调隐藏")
            case "window_lifecycle":
                let vm = f.vm()
                let app = NSApplication.shared
                let delegate = AppDelegate(vm: vm)
                app.setActivationPolicy(.accessory)
                delegate.showMainWindow()
                let first = delegate.mainWindow
                try expect(first?.isVisible == true, "首次启动应该显示窗口")
                first?.performClose(nil)
                try expect(first?.isVisible == false, "关窗应该隐藏")
                try expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(app), "关窗不应退出")
                delegate.showMainWindow()
                try expect(delegate.mainWindow === first && first?.isVisible == true, "重开应该复用同一窗口")
                delegate.mainWindow?.miniaturize(nil)
                delegate.showMainWindow()
                try expect(first?.isMiniaturized == false, "重开应该恢复最小化窗口")
                first?.orderOut(nil)
            case "termination_guard":
                let vm = f.vm()
                let delegate = AppDelegate(vm: vm)
                let app = NSApplication.shared
                try expect(delegate.applicationShouldTerminate(app) == .terminateNow, "空闲时应该允许退出")
                try f.write("fix-delay", "0.2")
                vm.fixAll()
                try expect(delegate.applicationShouldTerminate(app) == .terminateCancel, "系统退出也必须保护修复操作")
                try f.idle(vm)
                try expect(delegate.applicationShouldTerminate(app) == .terminateNow, "修复结束应该解除退出保护")
            default:
                throw TestFailure(description: "未知测试场景：\(name)")
            }
            print("PASS \(name)")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
