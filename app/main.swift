import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 模型

enum RowState { case pending, ok, warn, fail, skip }

struct CheckRow: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    var state: RowState = .pending
    var detail: String = ""
}

enum Phase { case checking, ready, failed, switching, done, fixing }

struct CoreResult {
    let output: String
    let succeeded: Bool
}

struct AccountStamp: Equatable {
    let size: String
    let date: String
}

// 超时回调与 waitUntilExit 在不同队列上执行。
private final class ProcessDeadline {
    private let lock = NSLock()
    private var expired = false

    func expire(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        expired = true
        process.terminate()
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }
}

final class VM: ObservableObject {
    @Published var rows: [CheckRow] = [
        CheckRow(name: "代理内核", icon: "cpu"),
        CheckRow(name: "TUN 网卡", icon: "cable.connector"),
        CheckRow(name: "出口 IP", icon: "globe.americas"),
        CheckRow(name: "IP 与上次一致", icon: "checkmark.seal"),
        CheckRow(name: "时区", icon: "clock"),
        CheckRow(name: "地区", icon: "flag"),
        CheckRow(name: "IPv6 关闭", icon: "6.circle"),
        CheckRow(name: "DNS 走隧道", icon: "magnifyingglass"),
        CheckRow(name: "WebRTC", icon: "eye.slash"),
        CheckRow(name: "保镖在线", icon: "hand.raised"),
        CheckRow(name: "规则置顶", icon: "list.number"),
        CheckRow(name: "客户端语言", icon: "abc"),
        CheckRow(name: "ASN 属性", icon: "building.columns"),
        CheckRow(name: "生态可达性", icon: "antenna.radiowaves.left.and.right"),
    ]
    @Published var phase: Phase = .checking
    @Published var current = "?"
    @Published var archived: Set<String> = []
    @Published var stamps: [String: AccountStamp] = [:]
    @Published var banner = ""
    @Published var note = ""
    @Published var fingerprint = ""
    @Published private(set) var isBusy = false
    @Published private(set) var lastCheckSummary = "尚未检查"
    @Published var updateText = ""
    @Published var showUpdateSheet = false
    @Published private(set) var checkingUpdate = false
    @Published private(set) var updating = false
    @Published private(set) var coreMissing = false
    @Published private(set) var currentClient = ""
    @Published private(set) var isSwitchingClient = false
    @Published var disabledChecks: Set<String> = []
    @Published var allowOptionalFailures = false
    @Published var loggingEnabled = true
    @Published var settingsMessage = ""
    @Published private(set) var settingsBusy = false
    @Published var showSettingsSheet = false
    @Published var showToolsSheet = false
    @Published private(set) var toolRunning = false
    @Published private(set) var toolOutput = ""
    @Published private(set) var toolFailed = false
    @Published var keepPaths = ""
    @Published var webrtcPolicy = "proxy"
    @Published private(set) var regionTarget = "尚未读取"
    var terminalLauncher: ((String, @escaping (CoreResult) -> Void) -> Void)?

    static let optionalChecks: [(key: String, label: String)] = [
        ("IP一致", "IP 与上次一致"),
        ("DNS", "DNS 走隧道"),
        ("WebRTC", "WebRTC"),
        ("客户端语言", "客户端语言"),
        ("ASN属性", "ASN 属性"),
        ("生态可达性", "生态可达性"),
    ]

    static let clientChoices: [(key: String, label: String)] = [
        ("tag", "TAG"),
        ("clash-verge", "Clash Verge"),
        ("flclash", "FlClash"),
        ("shadowrocket", "Shadowrocket"),
        ("sing-box", "sing-box"),
        ("clashx", "ClashX"),
        ("surge", "Surge"),
    ]

    let core: String
    private let checkTimeout: TimeInterval
    private let operationTimeout: TimeInterval
    private let updateTimeout: TimeInterval
    private var started = false
    private var switchRequested = false
    private var hideAfterSwitch: DispatchWorkItem?
    var onSwitchCompleted: (() -> Void)?
    var onRelaunchRequested: (() -> Void)?

    init(core: String = NSHomeDirectory() + "/.local/bin/claude-switch.sh",
         checkTimeout: TimeInterval = 45, operationTimeout: TimeInterval = 180,
         updateTimeout: TimeInterval = 600) {
        self.core = core
        self.checkTimeout = checkTimeout
        self.operationTimeout = operationTimeout
        self.updateTimeout = updateTimeout
    }

    var canQuit: Bool { !toolRunning && !switchRequested && !updating && phase != .fixing && phase != .switching }

    func start() {
        guard !started else { return }
        started = true
        refresh()
    }

    func prepareToShow() {
        hideAfterSwitch?.cancel()
        if phase == .done { phase = .ready }
    }

    private func run(_ args: [String], timeout: TimeInterval? = 45, input: Data? = nil,
                     environment: [String: String] = [:], done: @escaping (CoreResult) -> Void) {
        execute("/bin/bash", [core] + args, timeout: timeout, input: input, environment: environment, done: done)
    }

    private func execute(_ executable: String, _ args: [String], timeout: TimeInterval? = 45,
                         input: Data? = nil, environment: [String: String] = [:],
                         done: @escaping (CoreResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-out-\(UUID().uuidString).txt")
            guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let fh = try? FileHandle(forWritingTo: tmp) else {
                DispatchQueue.main.async { done(CoreResult(output: "无法创建检查输出文件", succeeded: false)) }
                return
            }
            defer {
                try? fh.close()
                try? FileManager.default.removeItem(at: tmp)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "BASH_ENV")
            env.removeValue(forKey: "ENV")
            env.merge(environment) { _, new in new }
            p.environment = env
            p.standardInput = FileHandle.nullDevice
            // Snapshot passwords are bounded by the form and never enter argv or files.
            let stdin = input.map { _ in Pipe() }
            if let input = input, let stdin = stdin {
                guard input.count <= 4096 else {
                    DispatchQueue.main.async { done(CoreResult(output: "输入内容过长", succeeded: false)) }
                    return
                }
                p.standardInput = stdin.fileHandleForReading
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
            defer { try? stdin?.fileHandleForReading.close() }
            p.standardOutput = fh
            p.standardError = fh
            do { try p.run() } catch {
                DispatchQueue.main.async { done(CoreResult(output: "无法启动脚本：\(error.localizedDescription)", succeeded: false)) }
                return
            }
            let deadline = ProcessDeadline()
            let watchdog = DispatchWorkItem { deadline.expire(p) }
            if let timeout = timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            }
            p.waitUntilExit()
            watchdog.cancel()
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let result: CoreResult
            if deadline.timedOut {
                result = CoreResult(output: "操作超时，请重试", succeeded: false)
            } else if p.terminationStatus != 0 {
                result = CoreResult(output: "脚本执行失败（退出码 \(p.terminationStatus)）\n\(out)", succeeded: false)
            } else {
                result = CoreResult(output: out, succeeded: true)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    private var isPollingClient = false
    private var lastObservedState = ""

    func refresh() {
        guard !isBusy else { return }
        hideAfterSwitch?.cancel()
        if !coreAvailable() { markCoreMissing(); return }
        isBusy = true
        checkEnvironment { _ in self.isBusy = false }
    }

    // 只读检测客户端是否关闭、是否开启了多个 TUN 或其他代理软件;发现状态变化时仅触发重新检查,绝不自动切换客户端配置
    func pollClientStateIfNeeded() {
        guard started, !isBusy, !updating, !isSwitchingClient, !isPollingClient, coreAvailable() else { return }
        isPollingClient = true
        run(["detect-client"], timeout: 5) { result in
            self.isPollingClient = false
            guard result.succeeded, !self.isBusy, !self.updating, !self.isSwitchingClient else { return }
            let snapshot = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !snapshot.isEmpty else { return }
            if self.lastObservedState.isEmpty {
                self.lastObservedState = snapshot
                return
            }
            if snapshot != self.lastObservedState {
                self.lastObservedState = snapshot
                self.refresh()
            }
        }
    }

    private func coreAvailable() -> Bool {
        FileManager.default.isReadableFile(atPath: core)
    }

    private func markCoreMissing() {
        coreMissing = true
        phase = .failed
        lastCheckSummary = "未安装核心脚本"
        banner = "未安装核心脚本：请下载 installer-kit 安装包并双击 installer/安装.command，或运行源码安装"
        for i in rows.indices {
            rows[i].state = .fail
            rows[i].detail = "未安装核心脚本"
        }
    }

    func refreshAccountStatus() {
        // 菜单展开时只读取本地账号状态，不触发网络审计；启动审计优先。
        guard started, !isBusy else { return }
        isBusy = true
        run(["status"], timeout: checkTimeout) { result in
            self.updateStatus(result)
            self.isBusy = false
        }
    }

    private func checkEnvironment(done: @escaping (Bool) -> Void) {
        if !coreAvailable() {
            markCoreMissing()
            done(false)
            return
        }
        coreMissing = false
        phase = .checking
        lastCheckSummary = "检查中"
        banner = ""
        note = ""
        for i in rows.indices { rows[i].state = .pending; rows[i].detail = "" }
        run(["checkdetail"], timeout: checkTimeout) { result in
            var allOk = result.succeeded
            var matched = Set<Int>()
            var duplicated = false
            let keyMap: [String: String] = [
                "代理内核": "代理内核", "TUN网卡": "TUN 网卡", "出口IP": "出口 IP",
                "IP一致": "IP 与上次一致", "时区": "时区", "地区": "地区",
                "IPv6": "IPv6 关闭", "DNS": "DNS 走隧道", "WebRTC": "WebRTC",
                "保镖": "保镖在线", "规则置顶": "规则置顶",
                "客户端语言": "客户端语言", "ASN属性": "ASN 属性", "生态可达性": "生态可达性",
            ]
            for line in result.output.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, let rowName = keyMap[parts[0]],
                      let idx = self.rows.firstIndex(where: { $0.name == rowName }) else { continue }
                // 重复行不能补齐缺失项，也不能用后来的 ok 覆盖先前的 fail。
                guard matched.insert(idx).inserted else { allOk = false; duplicated = true; continue }
                let status = parts[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                switch status.first ?? "" {
                case "ok": self.rows[idx].state = .ok
                case "warn": self.rows[idx].state = .warn
                case "skip": self.rows[idx].state = .skip
                default: self.rows[idx].state = .fail; allOk = false
                }
                self.rows[idx].detail = status.count > 1 ? status[1] : ""
            }
            if !result.succeeded {
                self.banner = result.output.isEmpty ? "核心脚本执行失败" : result.output
                for i in self.rows.indices where self.rows[i].state == .pending {
                    self.rows[i].state = .fail
                    self.rows[i].detail = "核心脚本执行失败"
                }
            } else if duplicated {
                self.banner = "检测输出存在重复项，请重新检查"
            } else if matched.count != self.rows.count {
                self.banner = "检测输出不完整(\(matched.count)/\(self.rows.count))，请点重新检查"
            }
            let passed = allOk && matched.count == self.rows.count
            self.lastCheckSummary = passed
                ? (self.rows.contains { $0.state == .warn }
                    ? "有警告"
                    : (self.rows.contains { $0.state == .skip } ? "通过（含跳过）" : "通过"))
                : "失败"
            self.run(["get-client"], timeout: self.checkTimeout) { clientResult in
                self.updateClient(clientResult)
                self.run(["status"], timeout: self.checkTimeout) { status in
                    let statusOK = self.updateStatus(status)
                    if !statusOK {
                        if !passed || self.banner.isEmpty {
                            self.banner = "无法读取账号状态，请重新检查"
                        }
                        self.lastCheckSummary = "失败"
                    }
                    self.phase = passed && statusOK ? .ready : .failed
                    done(passed && statusOK)
                }
            }
        }
    }

    @discardableResult
    private func updateStatus(_ result: CoreResult) -> Bool {
        let fields = result.output.split(whereSeparator: { $0.isWhitespace }).reduce(into: [String: String]()) { values, field in
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        func reset() -> Bool {
            current = "未知"; archived = []; stamps = [:]
            return false
        }
        guard result.succeeded, let account = fields["current"],
              ["A", "B", "C", "D", "none"].contains(account) else {
            return reset()
        }
        var known = Set<String>()
        if let list = fields["accounts"] {
            if list != "none" {
                for piece in list.split(separator: ",", omittingEmptySubsequences: true) {
                    let letter = String(piece)
                    guard Self.accountLetters.contains(letter) else { return reset() }
                    known.insert(letter)
                }
            }
        } else {
            // 旧版核心只输出 current/hasA/hasB,继续兼容已安装的旧脚本。
            for letter in ["A", "B"] {
                guard let flag = fields["has\(letter)"], ["0", "1"].contains(flag) else { return reset() }
                if flag == "1" { known.insert(letter) }
            }
        }
        var parsed: [String: AccountStamp] = [:]
        for letter in Self.accountLetters {
            guard let raw = fields["acc\(letter)"] else { continue }
            let parts = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return reset() }
            parsed[letter] = AccountStamp(size: String(parts[0]), date: String(parts[1]))
        }
        current = account == "none" ? "未初始化" : account
        stamps = parsed
        archived = known
        return true
    }

    static let accountLetters = ["A", "B", "C", "D"]

    private func updateClient(_ result: CoreResult) {
        guard result.succeeded else { return }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 && parts[0] == "client" {
                currentClient = parts[1]
            }
        }
    }

    func loadCheckConfig() {
        guard !settingsBusy, coreAvailable() else { return }
        settingsBusy = true
        settingsMessage = "正在读取设置…"
        run(["get-check-config"]) { result in
            self.settingsBusy = false
            guard result.succeeded,
                  let data = result.output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let config = object as? [String: Any],
                  let disabled = config["disabled"] as? [String],
                  let allow = config["allowOptionalFailures"] as? Bool,
                  let logging = config["logging"] as? Bool,
                  Set(disabled).count == disabled.count,
                  disabled.allSatisfy({ name in Self.optionalChecks.contains { $0.key == name } }) else {
                self.settingsMessage = "读取检查设置失败，请恢复默认后重试"
                return
            }
            self.disabledChecks = Set(disabled)
            self.allowOptionalFailures = allow
            self.loggingEnabled = logging
            self.settingsMessage = ""
        }
    }

    func saveCheckConfig() {
        guard !isBusy, !settingsBusy, coreAvailable() else { return }
        let allowed = Set(Self.optionalChecks.map { $0.key })
        guard disabledChecks.isSubset(of: allowed) else {
            settingsMessage = "包含不允许关闭的安全检查"
            return
        }
        let config: [String: Any] = [
            "disabled": Self.optionalChecks.map { $0.key }.filter { disabledChecks.contains($0) },
            "allowOptionalFailures": allowOptionalFailures,
            "logging": loggingEnabled,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        settingsBusy = true
        settingsMessage = "正在保存…"
        run(["set-check-config", json]) { result in
            self.settingsBusy = false
            self.settingsMessage = result.succeeded ? "设置已保存，正在重新检查" : result.output
            if result.succeeded { self.refresh() }
        }
    }

    func restoreCheckDefaults() {
        disabledChecks = []
        allowOptionalFailures = false
        loggingEnabled = true
        settingsMessage = "已恢复默认选项，点击保存后生效"
    }

    func exportDiagnostics() {
        guard !settingsBusy, coreAvailable() else { return }
        let panel = NSSavePanel()
        panel.title = "导出脱敏诊断日志"
        panel.message = "仅包含检查状态、设置和脱敏操作日志，不含 IP、凭据、账号或代理配置。"
        panel.nameFieldStringValue = "claude-switcher-diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        settingsBusy = true
        settingsMessage = "正在导出诊断日志…"
        run(["export-diagnostics", destination.path], timeout: operationTimeout) { result in
            self.settingsBusy = false
            let message = result.succeeded ? result.output : "导出失败：\(result.output)"
            self.settingsMessage = message
            let alert = NSAlert()
            alert.messageText = result.succeeded ? "诊断日志已导出" : "诊断日志导出失败"
            alert.informativeText = message
            alert.alertStyle = result.succeeded ? .informational : .warning
            alert.runModal()
        }
    }

    func setClient(_ key: String) {
        guard !isBusy, !isSwitchingClient else { return }
        guard Self.clientChoices.contains(where: { $0.key == key }) else { return }
        guard key != currentClient else { return }
        guard coreAvailable() else { markCoreMissing(); return }
        isBusy = true
        isSwitchingClient = true
        banner = "正在切换代理客户端（若弹出密码框请授权同步系统保镖）…"
        run(["set-client", key, "--gui"], timeout: operationTimeout) { result in
            self.isSwitchingClient = false
            guard result.succeeded else {
                self.banner = result.output
                self.isBusy = false
                return
            }
            // 切换后重新完成环境审计,刷新「代理内核」等检查项
            self.currentClient = key
            self.lastObservedState = ""
            self.checkEnvironment { _ in self.isBusy = false }
        }
    }

    func fixAll() {
        guard !isBusy else { return }
        guard coreAvailable() else { markCoreMissing(); return }
        hideAfterSwitch?.cancel()
        isBusy = true
        phase = .fixing
        banner = "正在修复…（若弹出密码框请输入开机密码）"
        run(["fix"], timeout: operationTimeout) { result in
            guard result.succeeded else {
                self.banner = result.output; self.phase = .failed; self.isBusy = false
                return
            }
            self.lastObservedState = ""
            self.checkEnvironment { _ in self.isBusy = false }
        }
    }

    func inspectFingerprint() {
        guard !isBusy else { return }
        isBusy = true
        fingerprint = "正在体检…"
        run(["fingerprint"], timeout: 90) { result in
            self.fingerprint = result.output
            self.isBusy = false
        }
    }

    func checkUpdate() {
        guard !checkingUpdate, !updating else { return }
        checkingUpdate = true
        updateText = "正在检查更新…"
        run(["update-check"], timeout: 120) { result in
            self.updateText = result.output.isEmpty
                ? (result.succeeded ? "检查完成，核心脚本没有返回结果" : "检查失败，请重试")
                : result.output
            self.checkingUpdate = false
        }
    }

    func performUpdate() {
        guard !isBusy, !checkingUpdate, !updating else { return }
        guard coreAvailable() else { markCoreMissing(); return }
        hideAfterSwitch?.cancel()
        isBusy = true
        updating = true
        updateText = "正在更新（下载校验、按需重编界面与同步守护，若弹出密码框请输入开机密码）…"
        run(["update", "--gui"], timeout: updateTimeout) { result in
            self.updating = false
            self.isBusy = false
            self.updateText = result.output.isEmpty
                ? (result.succeeded ? "更新完成" : "更新失败，请重试")
                : result.output
            guard result.succeeded else { return }
            // 只有界面 App 被替换时才需要重启；仅更新核心或守护无需中断界面。
            if result.output.contains("已同步更新："), result.output.contains("界面App") {
                self.updateText += "\n正在重启 Claude 切换器…"
                if let relaunch = self.onRelaunchRequested {
                    relaunch()
                } else {
                    self.updateText += "\n无法自动重启，请退出并重新打开切换器。"
                }
            } else if !result.output.contains("已是最新版本") {
                // 核心或守护发生变化时刷新界面结果，等同于原先重启后的首次检查。
                self.lastObservedState = ""
                self.refresh()
            }
        }
    }

    private func rejectTool(_ message: String) {
        toolOutput = message
        toolFailed = true
    }

    private func finishTool(_ result: CoreResult) {
        toolOutput = result.output.isEmpty ? "操作未返回结果" : result.output
        toolFailed = !result.succeeded
        toolRunning = false
        isBusy = false
    }

    private func tool(_ args: [String], timeout: TimeInterval? = 180, input: Data? = nil,
                      environment: [String: String] = [:], reaudit: Bool = false,
                      reloadStatus: Bool = false, completed: ((CoreResult) -> Void)? = nil) {
        guard !isBusy, !checkingUpdate, coreAvailable() else { return }
        hideAfterSwitch?.cancel()
        isBusy = true
        toolRunning = true
        toolFailed = false
        toolOutput = "正在处理，请稍候…"
        run(args, timeout: timeout, input: input, environment: environment) { result in
            self.toolOutput = result.output.isEmpty ? "操作未返回结果" : result.output
            self.toolFailed = !result.succeeded
            completed?(result)
            if reaudit {
                self.checkEnvironment { _ in self.toolRunning = false; self.isBusy = false }
            } else if reloadStatus && result.succeeded {
                self.run(["status"]) { status in
                    if !self.updateStatus(status) {
                        self.toolFailed = true
                        self.toolOutput += "\n账号状态刷新失败，请重新检查。"
                    }
                    self.toolRunning = false; self.isBusy = false
                }
            } else {
                self.toolRunning = false; self.isBusy = false
            }
        }
    }

    func loadTools() {
        tool(["get-tool-config"]) { result in
            guard result.succeeded, let data = result.output.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let keep = value["keepPaths"], let policy = value["policy"],
                  ["proxy", "reject"].contains(policy), let country = value["country"],
                  let timezone = value["timezone"], let locale = value["locale"] else {
                self.rejectTool("工具配置读取失败；请确认核心已更新并重试。")
                return
            }
            self.keepPaths = keep
            self.webrtcPolicy = policy
            self.regionTarget = "\(country) · \(timezone) · \(locale)"
            if let client = value["client"], Self.clientChoices.contains(where: { $0.key == client }) {
                self.currentClient = client
            }
            self.toolOutput = "工具已就绪。选择功能后查看执行结果。"
        }
    }

    func inspectCLI() {
        let home = NSHomeDirectory()
        let path = [home + "/.local/bin", home + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin",
                    ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        tool(["cli-info"], environment: ["PATH": path])
    }

    func inspectCLISlot() { tool(["cli-current"]) }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func launchCLI(project: URL, resume: Bool) {
        guard !isBusy, !checkingUpdate, coreAvailable() else { return }
        guard Self.accountLetters.contains(current) else {
            rejectTool("请先在主窗口初始化并确认当前账号。")
            return
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &directory), directory.boolValue else {
            rejectTool("请选择存在的项目文件夹。")
            return
        }
        let command = "cd -- \(Self.shellQuote(project.path)) && /bin/bash \(Self.shellQuote(core)) cli" + (resume ? " --resume" : "")
        hideAfterSwitch?.cancel()
        isBusy = true; toolRunning = true; toolFailed = false
        toolOutput = "正在打开终端…"
        let done: (CoreResult) -> Void = { result in
            self.finishTool(result.succeeded
                ? CoreResult(output: "已打开终端。Claude Code 会先检查环境，再启动当前槽位；首次使用需在终端登录。", succeeded: true)
                : result)
        }
        if let terminalLauncher = terminalLauncher {
            terminalLauncher(command, done)
        } else {
            let script = "on run argv\ntell application \"Terminal\"\nactivate\ndo script (item 1 of argv)\nend tell\nend run"
            execute("/usr/bin/osascript", ["-e", script, command], timeout: 30, done: done)
        }
    }

    func resetRegion() { tool(["set-region"], reaudit: true) }

    func openIsolated(_ address: String) {
        guard !isBusy else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: address), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), !(url.host ?? "").isEmpty,
              url.user == nil, url.password == nil, !address.contains("\n"), !address.contains("\r") else {
            rejectTool("请输入完整的 http 或 https 网址。")
            return
        }
        tool(["open-safe", address])
    }

    func diagnoseProxy(address: String, config: URL?) {
        guard !isBusy else { return }
        let summarize: (CoreResult) -> Void = { result in
            if let text = Self.proxySummary(result.output) { self.toolOutput = text }
        }
        if let config = config {
            tool(["diagnose-proxy", "--config", config.path], completed: summarize)
        } else {
            let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { rejectTool("请输入代理地址或选择私有 JSON 配置。") ; return }
            tool(["diagnose-proxy"], environment: ["CLAUDE_SWITCHER_PROXY_URL": address], completed: summarize)
        }
    }

    static func proxySummary(_ output: String) -> String? {
        guard let start = output.firstIndex(of: "{"), let data = String(output[start...]).data(using: .utf8),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              report["mode"] as? String == "proxy_diagnostics" else { return nil }
        if report["state"] as? String == "configuration_error" {
            return "代理配置无效：请确认协议、地址、端口或私有 JSON 内容。"
        }
        guard let checks = report["checks"] as? [[String: Any]], checks.count == 2 else { return nil }
        let lines = checks.map { check -> String in
            let name = check["name"] as? String == "claude_web" ? "Claude 网页" : "Claude API"
            guard check["transport_reached"] as? Bool == true else { return name + "：传输未确认，请检查代理和网络。" }
            let status = check["http_status"] as? Int ?? 0
            let access = status == 401 ? "，尚未认证" : (status == 403 || status == 407 ? "，访问受限" : "")
            return "\(name)：已收到响应（HTTP \(status)\(access)）"
        }
        return (lines + ["仅验证传输，未验证账号登录或完整防泄漏保护。"]).joined(separator: "\n")
    }

    func transferSnapshot(importing: Bool, account: String, file: URL, password: String, confirmation: String = "") {
        guard !isBusy else { return }
        guard Self.accountLetters.contains(account), account != current else {
            rejectTool("请选择当前未使用的 A–D 槽位。")
            return
        }
        guard importing ? !archived.contains(account) : archived.contains(account) else {
            rejectTool(importing ? "目标槽位已有存档，不能覆盖。" : "此槽位还没有归档快照。")
            return
        }
        guard !password.isEmpty, password.utf8.count <= 1024,
              !password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }),
              importing || (password.count >= 8 && password == confirmation) else {
            rejectTool(importing ? "请输入有效的镜像密码。" : "密码至少 8 位，两次输入须一致。")
            return
        }
        let args = importing ? ["snapshot-import", file.path, account, "--password-stdin"]
                             : ["snapshot-export", account, file.path, "--password-stdin"]
        // Do not terminate a disk-image operation midway through copy/mount/cleanup.
        tool(args, timeout: nil, input: Data((password + "\n").utf8), reloadStatus: importing)
    }

    func saveKeepPaths() {
        guard let data = try? JSONSerialization.data(withJSONObject: keepPaths, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        tool(["set-keep-paths", json])
    }

    var supportsWebRTCPolicy: Bool { ["clash-verge", "flclash"].contains(currentClient) }

    func applyWebRTCPolicy() {
        guard !isBusy else { return }
        guard supportsWebRTCPolicy, ["proxy", "reject"].contains(webrtcPolicy) else {
            rejectTool("当前客户端不支持由切换器修改 WebRTC 策略，请在代理客户端中管理。")
            return
        }
        tool(["fix"], environment: ["WEBRTC_POLICY": webrtcPolicy], reaudit: true)
    }

    var aiPrompt: String {
        let home = NSHomeDirectory()
        let agents = home + "/.claude-switcher/AGENTS.md"
        let agentsLine = FileManager.default.fileExists(atPath: agents)
            ? "本机交接文档：\(agents)"
            : "本机交接文档：\(agents)（~/.claude-switcher 不存在或其中没有 AGENTS.md，请从仓库根目录读取 AGENTS.md）"
        return """
        这是「Claude 切换器」的 AI 交接提示词。请先完整阅读交接文档，再开始安装、配置或排障。

        仓库地址：https://github.com/anyun-hy/claude-switcher
        \(agentsLine)

        执行要求：
        1. 先读 AGENTS.md，按其中的安装步骤、验收标准与安全红线执行，不要只凭本段提示词猜测。
        2. 安装或排障时先跑环境审计：硬性安全项必须通过；只有显式配置的非关键项可跳过或降为警告，skip 不表示检查通过。
        3. 账号切换前先完全退出 Claude；账号快照按 AGENTS.md 的规则保留，不要改动 ~/.claude-switcher/accounts/ 的结构。
        4. 保镖等常驻脚本只放在 root 所有的系统目录，不要改回用户可写路径；需要变更时引导我重跑安装器。
        5. 不要未经我明确同意更新、覆盖或重装已安装版本（~/.local/bin、应用程序及旧版桌面 App、launchd 与系统目录），也不要执行 update 或安装器；先说明影响并征得同意。
        6. 检查新版本只运行 `~/.local/bin/claude-switch.sh update-check`，看到结果后先问我是否执行更新。
        7. 不要在日志、文档或回复里暴露我的出口 IP、代理地址或任何凭据。
        """
    }

    func switchTo(_ target: String) {
        guard !isBusy, Self.accountLetters.contains(target) else { return }
        hideAfterSwitch?.cancel()
        isBusy = true
        switchRequested = true
        // 常驻后旧检查可能已经过期。每次切换都重新审计，不使用落盘的旧结果放行。
        checkEnvironment { passed in
            guard passed else {
                self.switchRequested = false; self.isBusy = false
                return
            }
            self.performSwitch(target)
        }
    }

    private func performSwitch(_ target: String) {
        phase = .switching
        banner = "正在切换到账号 \(target)…"
        run(["switch", target], timeout: operationTimeout) { [self] result in
            let lines = result.output.split(separator: "\n").map(String.init)
            let failure = lines.first { $0.hasPrefix("FAIL:") }
            let success = lines.contains { $0.hasPrefix("OK:") || $0.hasPrefix("INFO:") }
            guard result.succeeded, failure == nil, success else {
                self.phase = .failed
                self.banner = failure.map { String($0.dropFirst(5)) } ?? (result.output.isEmpty ? "切换未返回成功结果，请重新检查" : result.output)
                self.switchRequested = false; self.isBusy = false
                return
            }
            var extra = ""
            if target != "A" && !self.archived.contains(target) {
                extra = "\(target) 号首次使用：请在打开的 Claude 里登录 \(target) 账号，登录一次即可。"
            }
            let unchanged = lines.contains { $0.hasPrefix("INFO:") }
            if unchanged { extra = "" }
            self.current = target
            self.phase = .done
            self.banner = unchanged ? "当前已是账号 \(target)" : "已切换到账号 \(target)"
            self.note = extra
            self.switchRequested = false; self.isBusy = false
            let hide = DispatchWorkItem { [weak self] in
                guard let self = self, self.phase == .done, !self.isBusy else { return }
                self.onSwitchCompleted?()
                self.phase = .ready
            }
            self.hideAfterSwitch = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: hide)
        }
    }
}

// MARK: - Claude 风格外观

enum ClaudeTheme {
    // 纸感暖色基底 (Warm Parchment / Alabaster)
    static let bgTop = Color(red: 0.984, green: 0.976, blue: 0.961)         // #FAF9F5
    static let bgBottom = Color(red: 0.957, green: 0.945, blue: 0.925)      // #F4F1EC
    static let card = Color.white                                           // #FFFFFF
    static let cardBorder = Color(red: 0.898, green: 0.882, blue: 0.855)   // #E5E1DA
    static let divider = Color(red: 0.941, green: 0.929, blue: 0.910)      // #F0ECE8
    static let iconWell = Color(red: 0.965, green: 0.953, blue: 0.937)     // #F6F3EF

    // 字体色阶 (Editorial Ink & Warm Stone)
    static let ink = Color(red: 0.165, green: 0.153, blue: 0.141)          // #2A2724
    static let muted = Color(red: 0.455, green: 0.435, blue: 0.412)        // #746F69

    // Claude 标志性陶土橙 (Anthropic Claude Terracotta)
    static let terracotta = Color(red: 0.847, green: 0.447, blue: 0.329)   // #D87254
    static let terracottaDeep = Color(red: 0.761, green: 0.369, blue: 0.259) // #C25E42
    static let terracottaTint = Color(red: 0.847, green: 0.447, blue: 0.329).opacity(0.09)

    // 自然柔和状态色
    static let success = Color(red: 0.180, green: 0.490, blue: 0.322)       // #2E7D52 (Sage Green)

    static let warning = Color(red: 0.722, green: 0.431, blue: 0.094)       // #B86E18 (Warm Amber)
    static let warningBorder = Color(red: 0.961, green: 0.863, blue: 0.718) // #F5DCB7

    static let error = Color(red: 0.761, green: 0.282, blue: 0.212)         // #C24836 (Claude Terracotta Red)
}

// MARK: - Claude 优雅背景

struct ClaudeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [ClaudeTheme.bgTop, ClaudeTheme.bgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [ClaudeTheme.terracotta.opacity(0.04), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 辅助样式组件

struct ClaudeIconButton: View {
    let systemName: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isHovered ? ClaudeTheme.ink : ClaudeTheme.muted)
                .frame(width: 28, height: 28)
                .background(isHovered ? ClaudeTheme.iconWell : ClaudeTheme.card.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 7.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 7.5)
                        .stroke(isHovered ? ClaudeTheme.cardBorder : ClaudeTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(help)
        .help(help)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 视图

struct ContentView: View {
    @ObservedObject var vm: VM
    var height: CGFloat = 900
    @State private var showNotice = false
    @State private var showFingerprint = false
    @State private var showAIPrompt = false

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(spacing: 12) {
                header
                HStack {
                    Text("环境检查").font(.caption.weight(.semibold)).foregroundColor(ClaudeTheme.muted)
                    Spacer()
                    statusPill
                }
                // 小屏上窗口高度会被系统可见区域压缩,让卡片区可滚动而不是被裁切
                ScrollView {
                    VStack(spacing: 16) {
                        checksCard
                        clientCard
                        if vm.phase == .ready || vm.phase == .switching || vm.phase == .done {
                            accountCard
                        } else if vm.coreMissing {
                            setupCard
                        } else if vm.phase == .failed || vm.phase == .fixing {
                            retryCard
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                footer
            }
            .padding(16)
        }
        .sheet(isPresented: $showAIPrompt) { AIPromptSheet(text: vm.aiPrompt) }
        .sheet(isPresented: $vm.showSettingsSheet) { CheckSettingsView(vm: vm) }
        .sheet(isPresented: $vm.showToolsSheet) { ToolsView(vm: vm) }
        .frame(width: 440, height: height)
        .preferredColorScheme(.light)
    }

    var header: some View {
        HStack(spacing: 11) {
            // Claude 风格陶土盾牌徽标
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: ClaudeTheme.terracotta.opacity(0.24), radius: 3.5, x: 0, y: 1.5)

                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Claude 账号切换器")
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundColor(ClaudeTheme.ink)
                Text("安全检查 · 切换 · 启动")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(ClaudeTheme.muted)
            }

            Spacer()

            ClaudeIconButton(
                systemName: "waveform.path.ecg",
                help: "设备指纹体检(字体/GPU/虚拟机)",
                disabled: vm.isBusy
            ) {
                showFingerprint = true
                vm.inspectFingerprint()
            }

            ClaudeIconButton(
                systemName: "gearshape",
                help: "检查设置与诊断日志"
            ) {
                vm.showSettingsSheet = true
            }

            ClaudeIconButton(
                systemName: "info.circle",
                help: "安全防护体系公告"
            ) {
                showNotice = true
            }

        }
        .sheet(isPresented: $showNotice) { NoticeView() }
        .sheet(isPresented: $showFingerprint) { FingerprintView(text: vm.fingerprint) }
    }

    var statusPill: some View {
        let (txt, color): (String, Color) = {
            switch vm.phase {
            case .checking: return ("检查中", ClaudeTheme.terracottaDeep)
            case .ready: return ("环境安全", ClaudeTheme.success)
            case .failed: return ("检查未过", ClaudeTheme.error)
            case .switching: return ("切换中", ClaudeTheme.terracottaDeep)
            case .fixing: return ("修复中", ClaudeTheme.terracottaDeep)
            case .done: return ("完成", ClaudeTheme.success)
            }
        }()
        return Text(txt)
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    var checksCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(vm.rows.enumerated()), id: \.element.id) { idx, row in
                HStack(spacing: 10) {
                    // 左侧图标容器
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(ClaudeTheme.iconWell)
                            .frame(width: 24, height: 24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(ClaudeTheme.divider, lineWidth: 0.5)
                            )
                        Image(systemName: row.icon)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(ClaudeTheme.muted)
                    }

                    Text(row.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ClaudeTheme.ink)

                    Spacer(minLength: 8)

                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: 11.5, weight: .regular, design: isMonospace(row.detail) ? .monospaced : .default))
                            .foregroundColor(row.state == .warn ? ClaudeTheme.warning : ClaudeTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    stateIcon(row.state)
                }
                .padding(.vertical, 5.5)
                .padding(.horizontal, 12)

                if idx < vm.rows.count - 1 {
                    Divider()
                        .overlay(ClaudeTheme.divider)
                        .padding(.leading, 46)
                }
            }
        }
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(ClaudeTheme.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color(red: 0.2, green: 0.16, blue: 0.12).opacity(0.035), radius: 6, x: 0, y: 2)
    }

    private func isMonospace(_ str: String) -> Bool {
        str.contains(".") || str.contains(":") || str.contains("/")
    }

    var clientCard: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(ClaudeTheme.iconWell)
                    .frame(width: 24, height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ClaudeTheme.divider, lineWidth: 0.5))
                Image(systemName: "network")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(ClaudeTheme.muted)
            }
            Text("代理客户端").font(.system(size: 13, weight: .medium)).foregroundColor(ClaudeTheme.ink)
            Spacer()
            if vm.isSwitchingClient {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            }
            Picker("", selection: Binding(
                get: { vm.currentClient },
                set: { vm.setClient($0) }
            )) {
                ForEach(VM.clientChoices, id: \.key) { choice in
                    Text(choice.label).tag(choice.key)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(vm.isBusy || vm.isSwitchingClient)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(ClaudeTheme.cardBorder, lineWidth: 1))
        .shadow(color: Color(red: 0.2, green: 0.16, blue: 0.12).opacity(0.035), radius: 6, x: 0, y: 2)
    }

    func stateIcon(_ s: RowState) -> some View {
        Group {
            switch s {
            case .pending: ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundColor(ClaudeTheme.success)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(ClaudeTheme.warning)
            case .fail: Image(systemName: "xmark.octagon.fill").foregroundColor(ClaudeTheme.error)
            case .skip: Image(systemName: "minus.circle").foregroundColor(ClaudeTheme.muted)
            }
        }
        .font(.callout)
    }

    var accountCard: some View {
        VStack(spacing: 12) {
            if vm.phase == .switching {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(vm.banner).font(.callout).foregroundColor(ClaudeTheme.ink)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else if vm.phase == .done {
                VStack(spacing: 4) {
                    Label(vm.banner, systemImage: "checkmark.circle.fill").foregroundColor(ClaudeTheme.success).font(.callout.bold())
                    if !vm.note.isEmpty { Text(vm.note).font(.caption).foregroundColor(ClaudeTheme.warning).multilineTextAlignment(.center) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            } else {
                HStack(spacing: 6) {
                    Text("当前账号").font(.caption).foregroundColor(ClaudeTheme.muted)
                    Text(vm.current).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(ClaudeTheme.terracottaTint).foregroundColor(ClaudeTheme.terracottaDeep)
                        .clipShape(Capsule())
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(VM.accountLetters, id: \.self) { t in
                        accountButton(t, subtitle: accountSubtitle(t))
                    }
                }
            }
        }
        .padding(12)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.cardBorder))
    }

    func accountSubtitle(_ t: String) -> String {
        if vm.current == t { return "当前" }
        guard vm.archived.contains(t) else { return "未初始化" }
        guard let stamp = vm.stamps[t] else { return "已建档" }
        return "已建档 · \(stamp.size) · \(shortDate(stamp.date))"
    }

    func shortDate(_ value: String) -> String {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4 else { return value }
        return "\(parts[1])-\(parts[2])"
    }

    func accountButton(_ t: String, subtitle: String) -> some View {
        Button { vm.switchTo(t) } label: {
            VStack(spacing: 4) {
                Text("账号 \(t)").font(.headline).foregroundColor(vm.current == t ? .white : ClaudeTheme.ink)
                Text(subtitle).font(.caption2).foregroundColor(vm.current == t ? .white.opacity(0.9) : ClaudeTheme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(
                vm.current == t
                ? LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [ClaudeTheme.iconWell, ClaudeTheme.iconWell], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(vm.current == t ? ClaudeTheme.terracotta : ClaudeTheme.cardBorder, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy)
    }

    var setupCard: some View {
        VStack(spacing: 10) {
            Text("还差一步：安装核心脚本").font(.callout.bold()).foregroundColor(ClaudeTheme.ink)
            Text(vm.banner).font(.caption).foregroundColor(ClaudeTheme.muted).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button { openURL("https://github.com/YOURSJEYO/claude-switcher/releases/latest") } label: {
                    Label("打开下载页", systemImage: "arrow.down.circle")
                        .font(.callout.bold())
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Button { openURL("https://github.com/YOURSJEYO/claude-switcher#安装") } label: {
                    Label("安装说明", systemImage: "book")
                        .font(.callout.bold())
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(ClaudeTheme.iconWell)
                        .foregroundColor(ClaudeTheme.ink)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(ClaudeTheme.error.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.error.opacity(0.25)))
    }

    private func openURL(_ text: String) {
        if let url = URL(string: text) { NSWorkspace.shared.open(url) }
    }

    var retryCard: some View {
        VStack(spacing: 10) {
            if vm.phase == .fixing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(vm.banner).font(.callout).foregroundColor(ClaudeTheme.ink)
                }
            } else {
                if !vm.banner.isEmpty {
                    Text(vm.banner).font(.callout).foregroundColor(ClaudeTheme.error).multilineTextAlignment(.center)
                }
                Text("存在未通过项，可一键修复或手动处理后重试").font(.caption).foregroundColor(ClaudeTheme.muted)
                HStack(spacing: 10) {
                    Button { vm.fixAll() } label: {
                        Label("一键修复", systemImage: "wand.and.stars")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isBusy)
                    Button { vm.refresh() } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(ClaudeTheme.iconWell)
                            .foregroundColor(ClaudeTheme.ink)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isBusy)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.warningBorder))
    }

    var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.caption2)
            Text("硬性安全项必须通过；灰色跳过不表示检查通过").font(.caption2)
            Spacer()
            Button {
                vm.checkUpdate()
                vm.showUpdateSheet = true
            } label: {
                Text("检查更新").font(.caption2).foregroundColor(ClaudeTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("检查更新")
            Button { vm.showToolsSheet = true } label: {
                Text("工具").font(.caption2).foregroundColor(ClaudeTheme.muted)
            }
            .buttonStyle(.plain)
            .disabled(vm.isBusy || vm.checkingUpdate)
            Button { showAIPrompt = true } label: {
                Text("AI 配置").font(.caption2).foregroundColor(ClaudeTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AI 配置")
        }
        .foregroundColor(ClaudeTheme.muted)
        .sheet(isPresented: $vm.showUpdateSheet) { UpdateSheet(vm: vm) }
    }
}

// MARK: - 检查设置与诊断

struct ToolsView: View {
    @ObservedObject var vm: VM
    @Environment(\.dismiss) private var dismiss
    @State private var section = "cli"
    @State private var project: URL?
    @State private var importing = false
    @State private var account = "B"
    @State private var password = ""
    @State private var repeatedPassword = ""
    @State private var address = ""
    @State private var proxyAddress = ""
    @State private var proxyConfig: URL?
    @State private var pending: Confirmation?

    private enum Confirmation: String, Identifiable {
        case region, policy, keep
        var id: String { rawValue }
    }

    init(vm: VM, initialSection: String = "cli") {
        self.vm = vm
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("工具").font(.system(size: 22, weight: .bold, design: .serif))
                        Text("Claude Code、账号快照与环境维护").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button("关闭") { dismiss() }.disabled(vm.toolRunning)
                        .keyboardShortcut(.cancelAction)
                }
                Picker("工具分类", selection: $section) {
                    Text("Claude Code").tag("cli")
                    Text("账号快照").tag("snapshot")
                    Text("网络与地区").tag("network")
                    Text("共享设置").tag("keep")
                }
                .pickerStyle(.segmented)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch section {
                        case "cli": cliSection
                        case "snapshot": snapshotSection
                        case "network": networkSection
                        default: keepSection
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(2)
                    .disabled(vm.isBusy || vm.checkingUpdate || vm.coreMissing)
                }
                Divider()
                HStack {
                    if vm.toolRunning { ProgressView().controlSize(.small) }
                    Text(vm.toolRunning ? "正在执行" : (vm.toolFailed ? "操作未完成" : "执行结果"))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(vm.toolFailed ? ClaudeTheme.error : ClaudeTheme.muted)
                    Spacer()
                    Button("刷新工具配置") { vm.loadTools() }.disabled(vm.isBusy || vm.checkingUpdate)
                        .font(.caption)
                }
                ScrollView {
                    Text(vm.toolOutput.isEmpty ? "选择工具后，这里会显示结果。" : vm.toolOutput)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(height: 110)
                .background(ClaudeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(24)
        }
        .frame(width: 680, height: 660)
        .foregroundColor(ClaudeTheme.ink)
        .tint(ClaudeTheme.terracottaDeep)
        .preferredColorScheme(.light)
        .interactiveDismissDisabled(vm.toolRunning)
        .onAppear { vm.loadTools() }
        .onDisappear { password = ""; repeatedPassword = ""; proxyAddress = "" }
        .alert(item: $pending) { action in
            switch action {
            case .region:
                return Alert(title: Text("按当前出口重设地区？"),
                             message: Text("将探测当前出口，修改目标国家、系统地区格式和时区，并同步时区看门狗。可能请求管理员授权；完成后会重新检查。"),
                             primaryButton: .default(Text("重设地区")) { vm.resetRegion() }, secondaryButton: .cancel())
            case .policy:
                return Alert(title: Text("应用 WebRTC 策略并修复？"),
                             message: Text("将调用一键修复，可能修改当前客户端的规则、重启代理并请求管理员授权。拒绝 UDP 策略可能影响语音、视频或 P2P。"),
                             primaryButton: .default(Text("应用并修复")) { vm.applyWebRTCPolicy() }, secondaryButton: .cancel())
            case .keep:
                return Alert(title: Text("保存跨账号保留列表？"),
                             message: Text("列出的文件将在以后切换账号时共享。请只保留通用配置，不要加入登录凭据、Cookie、设备标识或缓存。留空表示关闭。"),
                             primaryButton: .default(Text("保存列表")) { vm.saveKeepPaths() }, secondaryButton: .cancel())
            }
        }
    }

    private func description(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(ClaudeTheme.muted).fixedSize(horizontal: false, vertical: true)
    }

    private var cliSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Claude Code", systemImage: "terminal").font(.headline)
            description("检查命令行版的安装与版本，按当前桌面槽位打开 Claude Code。B–D 的 CLI 需要分别登录，桌面快照不包含 CLI 数据。")
            HStack {
                Button("检查安装与版本") { vm.inspectCLI() }
                Button("查看当前 CLI 槽位") { vm.inspectCLISlot() }
            }
            Divider()
            Text("项目文件夹").font(.subheadline.weight(.semibold))
            HStack {
                Text(project?.path ?? "请选择 Claude Code 要使用的项目文件夹")
                    .font(.caption).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("选择文件夹…") { project = selectFile(directory: true) ?? project }
            }
            HStack {
                Button("启动 Claude Code") { if let project = project { vm.launchCLI(project: project, resume: false) } }
                    .buttonStyle(.borderedProminent)
                Button("选择历史会话") { if let project = project { vm.launchCLI(project: project, resume: true) } }
            }
            .disabled(project == nil)
            description("交互式对话和登录会在终端中进行，启动前仍由核心检查环境。首次打开终端时，macOS 可能请求自动化授权。")
        }
    }

    private var snapshotSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("加密账号快照", systemImage: "externaldrive.badge.person.crop").font(.headline)
            Picker("操作", selection: $importing) {
                Text("导出快照").tag(false)
                Text("导入快照").tag(true)
            }.pickerStyle(.segmented)
            Picker("账号槽位", selection: $account) {
                ForEach(VM.accountLetters, id: \.self) { slot in
                    Text("账号 \(slot) · \(slot == vm.current ? "当前" : (vm.archived.contains(slot) ? "已归档" : "未归档"))").tag(slot)
                }
            }
            description(importing
                ? "只导入到未使用、没有存档的槽位；镜像中的账号标记须与目标一致。服务端登录过期时仍需重新登录。"
                : "只能导出已归档、当前未使用的槽位。当前槽位需先在主窗口切换到其他账号后再导出。")
            SecureField(importing ? "镜像密码" : "设置密码（至少 8 位）", text: $password)
            if !importing { SecureField("再次输入密码", text: $repeatedPassword) }
            Button(importing ? "选择镜像并导入…" : "选择位置并导出…") { transferSnapshot() }
                .buttonStyle(.borderedProminent)
                .disabled(account == vm.current || (importing ? vm.archived.contains(account) : !vm.archived.contains(account)) || password.isEmpty || (!importing && (password.count < 8 || password != repeatedPassword)))
            description("采用 macOS 加密 DMG；不包含独立 Claude Code 配置。密码无法找回。导入或导出期间请等待完成。")
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: importing) { _ in password = ""; repeatedPassword = "" }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("地区目标") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(vm.regionTarget).font(.caption).textSelection(.enabled)
                    description("更换其他国家的节点后，按当前出口重新锁定目标。")
                    Button("按当前出口重设地区…") { pending = .region }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("隔离浏览器") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("https://…", text: $address)
                    HStack {
                        Button("隔离打开链接") { vm.openIsolated(address); address = "" }
                        Button("打开 Web 指纹检测") { vm.openIsolated("https://yoursjeyo.github.io/claude-switcher/") }
                    }
                    description("使用一次性浏览器配置；窗口关闭后会话丢弃。Web 检测页可补充 Canvas 和 WebGL 检查。")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("指定代理诊断") {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("代理地址（含协议和端口）", text: $proxyAddress)
                        .disabled(proxyConfig != nil)
                    HStack {
                        Button("选择私有 JSON…") { proxyConfig = selectFile(directory: false, types: [.json]) ?? proxyConfig }
                        if let config = proxyConfig {
                            Text(config.lastPathComponent).font(.caption).lineLimit(1)
                            Button("清除文件") { proxyConfig = nil }
                        }
                        Spacer()
                        Button("诊断代理") { vm.diagnoseProxy(address: proxyAddress, config: proxyConfig); proxyAddress = "" }
                    }
                    description("只测试所选代理到 Claude 网页和 API 的传输。401/403 是认证或访问限制，不表示账号可用；此诊断不提供启动许可。")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("WebRTC 修复策略") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("UDP 策略", selection: $vm.webrtcPolicy) {
                        Text("走代理（保留通话能力）").tag("proxy")
                        Text("拒绝相关端口（可能影响通话）").tag("reject")
                    }
                    Button("应用策略并修复…") { pending = .policy }
                    description(vm.supportsWebRTCPolicy ? "仅影响支持的客户端；应用后重新检查。" : "当前客户端需自行管理规则，切换器不会修改 TAG 等客户端的策略。")
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(!vm.supportsWebRTCPolicy)
            }
        }.textFieldStyle(.roundedBorder)
    }

    private var keepSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("跨账号保留", systemImage: "doc.on.doc").font(.headline)
            description("每行一个相对于 Claude 数据目录的路径，例如 settings.json 或 skills/。# 开头为注释，留空关闭。保存后从下次切换开始生效。")
            TextEditor(text: $vm.keepPaths)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(ClaudeTheme.divider))
                .accessibilityLabel("跨账号保留路径列表")
            description("只共享通用配置。绝对路径、包含 .. 的路径和符号链接会被拒绝；不要放登录凭据、Cookie、设备标识或缓存。")
            Button("保存保留列表…") { pending = .keep }.buttonStyle(.borderedProminent)
        }
    }

    private func selectFile(directory: Bool, types: [UTType]? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        if let types = types { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func transferSnapshot() {
        let destination: URL?
        if importing {
            destination = selectFile(directory: false, types: [.diskImage])
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "account-\(account.lowercased()).dmg"
            panel.allowedContentTypes = [.diskImage]
            panel.canCreateDirectories = true
            destination = panel.runModal() == .OK ? panel.url : nil
        }
        guard let destination = destination else { return }
        vm.transferSnapshot(importing: importing, account: account, file: destination,
                            password: password, confirmation: repeatedPassword)
        password = ""; repeatedPassword = ""
    }
}

struct CheckSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: VM

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("检查设置").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("安全项始终强制执行；跳过不等于通过").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox("可自定义的非关键检查") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(VM.optionalChecks, id: \.key) { item in
                                    Toggle(item.label, isOn: Binding(
                                        get: { !vm.disabledChecks.contains(item.key) },
                                        set: { enabled in
                                            if enabled { vm.disabledChecks.remove(item.key) }
                                            else { vm.disabledChecks.insert(item.key) }
                                        }
                                    ))
                                }
                                Text("关闭后会真正跳过对应探测，并以灰色“已跳过”显示。出口国家、代理/TUN、Kill-Switch、保镖、账号归档和更新校验不可关闭。")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
                            }
                            .padding(.vertical, 6)
                        }

                        GroupBox("失败处理与日志") {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("将上述非关键项的失败降为警告", isOn: $vm.allowOptionalFailures)
                                Text("只影响这 6 项；不会放宽任何硬性安全项，也不会自动关闭检测。")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
                                Toggle("记录脱敏客户端日志", isOn: $vm.loggingEnabled)
                                Text("仅记录版本、命令、退出码、耗时和检查状态，不记录 IP、凭据或账号内容。")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
                            }
                            .padding(.vertical, 6)
                        }

                        GroupBox("问题排查") {
                            VStack(alignment: .leading, spacing: 9) {
                                Button("导出脱敏诊断日志…") { vm.exportDiagnostics() }
                                    .disabled(vm.settingsBusy)
                                Text("日志：~/Library/Logs/claude-switcher/client.log")
                                    .font(.caption2).foregroundColor(ClaudeTheme.muted).textSelection(.enabled)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                if !vm.settingsMessage.isEmpty {
                    Text(vm.settingsMessage).font(.caption).foregroundColor(ClaudeTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("恢复默认") { vm.restoreCheckDefaults() }.disabled(vm.settingsBusy)
                    Spacer()
                    if vm.settingsBusy { ProgressView().scaleEffect(0.65) }
                    Button("保存并重新检查") { vm.saveCheckConfig() }
                        .buttonStyle(.borderedProminent).tint(ClaudeTheme.terracottaDeep)
                        .disabled(vm.settingsBusy || vm.isBusy)
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 610)
        .preferredColorScheme(.light)
        .onAppear { vm.loadCheckConfig() }
    }
}

// MARK: - 设备指纹体检

struct FingerprintView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设备指纹体检").font(.headline).foregroundColor(ClaudeTheme.ink)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.borderedProminent).tint(ClaudeTheme.terracottaDeep)
            }
            Text("字体地区特征 + GPU/虚拟机特征；Canvas/WebGL 请用 Web 检测页")
                .font(.caption).foregroundColor(ClaudeTheme.muted)
            ScrollView {
                Text(text.isEmpty ? "正在体检…" : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(ClaudeTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .preferredColorScheme(.light)
        .background(ClaudeTheme.bgTop)
    }
}

// MARK: - 版本更新

struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: VM
    @State private var copied = false

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("版本更新").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("检查并在应用内直接更新核心、界面与系统守护").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.updating)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    Text(vm.updateText.isEmpty ? "尚未检查" : vm.updateText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(ClaudeTheme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(height: 110)
                .background(ClaudeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ClaudeTheme.cardBorder))

                HStack(spacing: 10) {
                    Button { vm.performUpdate() } label: {
                        Label(vm.updating ? "正在更新…" : "立即更新", systemImage: "arrow.down.circle.fill")
                            .font(.callout.bold())
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.checkingUpdate || vm.updating || vm.isBusy)

                    Button { vm.checkUpdate() } label: {
                        Label(vm.checkingUpdate ? "检查中…" : "重新检查", systemImage: "arrow.clockwise")
                            .font(.callout.bold())
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(ClaudeTheme.iconWell)
                            .foregroundColor(ClaudeTheme.ink)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.checkingUpdate || vm.updating || vm.isBusy)

                    Button { copyUpdateCommand() } label: {
                        Label(copied ? "已复制" : "复制更新命令", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.callout.bold())
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(ClaudeTheme.iconWell)
                            .foregroundColor(ClaudeTheme.ink)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                Text("点击「立即更新」将在应用内完成 SHA256 校验、核心与界面更新（守护脚本变更时会请求管理员授权），更新后自动重启；自检不通过会自动回滚。")
                    .font(.caption2).foregroundColor(ClaudeTheme.muted)
            }
            .padding(20)
        }
        .frame(width: 520, height: 300)
        .preferredColorScheme(.light)
    }

    private func copyUpdateCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString("~/.local/bin/claude-switch.sh update", forType: .string)
        copied = true
    }
}

// MARK: - AI 交接提示词

struct AIPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    @State private var copied = false

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 交接提示词").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("复制后粘贴给本地 AI，让它先读 AGENTS.md 再动手").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(ClaudeTheme.ink)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(ClaudeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ClaudeTheme.cardBorder))

                HStack {
                    Button { copyPrompt() } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.callout.bold())
                            .padding(.horizontal, 18).padding(.vertical, 7)
                            .background(LinearGradient(colors: [ClaudeTheme.terracotta, ClaudeTheme.terracottaDeep], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 480)
        .preferredColorScheme(.light)
    }

    private func copyPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        copied = true
    }
}

// MARK: - 公告页

struct NoticeView: View {
    @Environment(\.dismiss) private var dismiss

    let sections: [(String, String)] = [
        ("Full-Tunnel 全流量接管", "基于 TUN 虚拟网卡的内核级流量劫持，配合 Fake-IP DNS 解析机制，包括 UDP 在内的全部出站流量在网络栈底层被强制路由至加密隧道，应用层无法旁路。"),
        ("Environment Audit 环境一致性审计", "每次启动前执行 14 项环境指纹审计：Egress IP 归属地与 ASN 属性、时区与 Geo-location 一致性、Locale、IPv6 双栈旁路、DNS Leak、WebRTC/STUN 多节点交叉探测等。硬性安全项失败即 Block-on-Fail；仅显式配置的非关键项可跳过或降级，skip 不表示通过。"),
        ("Kill-Switch 断网急停", "常驻守护进程以 10 秒周期巡检隧道健康度，隧道中断即刻终止受保护进程，将裸连窗口压缩到秒级。进程级急停，非防火墙级保证，边界详见 SECURITY.md。"),
        ("Pinned Routing 域名置顶路由", "目标服务全家族域名及其生态依赖（Turnstile 人机验证、Telemetry 遥测、Payment 支付、Support 组件）置顶锁定代理路由，优先级高于任何第三方分流规则集，免疫规则库误判。"),
        ("Session Isolation 会话隔离快照", "多账号采用完整快照隔离：各账号持有独立的 Device Fingerprint、OAuth Credential 与本地状态，切换即物理交换数据卷，账号间零交叉污染。"),
        ("Drift Self-Healing 配置漂移自愈", "针对系统时区漂移、代理组件升级导致的配置重置等常见问题，内置 Watchdog 周期性校验并自动回滚至基线状态，全程留痕、可审计。"),
        ("Anti-Tracking 反追踪卫生", "验证链接（Magic Link）闭环于受保护环境内打开；邮件追踪像素（Tracking Pixel）经由邮箱服务商代理层屏蔽；全程固定单一住宅出口，不产生 Geo 跳变。"),
    ]

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安全防护体系公告").font(.title3.bold()).foregroundColor(ClaudeTheme.ink)
                        Text("Security Architecture Bulletin").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)

                ScrollView {
                    VStack(spacing: 10) {
                        Text("本产品面向对账号环境一致性有严格要求的专业用户，基于 Fail-Closed（故障即断）原则构建，针对目标平台的 Risk Control 体系提供全链路防护，确保本地真实出口在任何场景下零暴露。")
                            .font(.callout)
                            .foregroundColor(ClaudeTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6)

                        ForEach(Array(sections.enumerated()), id: \.offset) { idx, s in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(idx + 1). \(s.0)").font(.callout.bold()).foregroundColor(ClaudeTheme.terracottaDeep)
                                Text(s.1).font(.caption).foregroundColor(ClaudeTheme.muted).lineSpacing(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(ClaudeTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Text("本防护体系基于对目标平台风控机制的持续逆向分析与实战经验迭代。")
                            .font(.caption2)
                            .foregroundColor(ClaudeTheme.muted)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .frame(width: 460, height: 620)
        .preferredColorScheme(.light)
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let vm: VM
    private(set) var mainWindow: NSWindow?
    private var monitorTimer: Timer?
    private var relaunchProcess: Process?

    override init() {
        vm = VM()
        super.init()
    }

    // 隔离测试可注入假核心脚本，不需要修改 HOME 或接触真实账号。
    init(vm: VM) {
        self.vm = vm
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        vm.onSwitchCompleted = { [weak self] in self?.mainWindow?.orderOut(nil) }
        vm.onRelaunchRequested = { [weak self] in self?.relaunchApp() }
        showMainWindow()
        vm.start()
        startClientMonitor()
    }

    private func startClientMonitor() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.vm.pollClientStateIfNeeded()
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.vm.pollClientStateIfNeeded()
                }
            }
        }
    }

    func relaunchApp() {
        guard vm.canQuit else {
            vm.updateText += "\n当前操作尚未结束，无法自动重启；请稍后退出并重新打开切换器。"
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let installed = "/Applications/Claude Switcher.app"
        let appPath = FileManager.default.fileExists(atPath: installed) ? installed : Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // 旧进程未退出时不能 open，否则只会重新激活旧实例。
        p.arguments = ["-c", "for i in $(seq 1 50); do if ! kill -0 \(pid) 2>/dev/null; then open \"$1\"; exit $?; fi; sleep 0.1; done; exit 1", "_", appPath]
        p.terminationHandler = { [weak self] process in
            guard process.terminationReason != .exit || process.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.relaunchProcess = nil
                self.vm.updateText += "\n自动重启未完成，请从菜单栏退出并重新打开切换器。"
                self.vm.showUpdateSheet = true
            }
        }
        relaunchProcess = p
        do {
            try p.run()
        } catch {
            relaunchProcess = nil
            vm.updateText += "\n无法启动自动重启，请从菜单栏退出并重新打开切换器。"
            return
        }
        // 活动 sheet 会让 AppKit 的退出请求无法完成；先结束 sheet，再在下一轮主循环退出。
        vm.showUpdateSheet = false
        if let window = mainWindow, let sheet = window.attachedSheet { window.endSheet(sheet) }
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    func showMainWindow() {
        vm.prepareToShow()
        if mainWindow == nil {
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
            let titleHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: style).height
            let height = min(CGFloat(900), (NSScreen.main?.visibleFrame.height ?? 900) - titleHeight)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: height),
                styleMask: style,
                backing: .buffered, defer: false
            )
            window.title = "Claude切换器"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.contentView = NSHostingView(rootView: ContentView(vm: vm, height: height))
            window.delegate = self
            window.center()
            mainWindow = window
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        vm.canQuit ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }
}

struct MenuBarContent: View {
    @ObservedObject var vm: VM
    let showWindow: () -> Void

    var body: some View {
        Text("Claude 切换器")
        Text("当前账号：\(vm.current)")
        Text("最近检查：\(vm.lastCheckSummary)")
        if vm.phase == .fixing { Text("正在修复…") }
        if vm.phase == .switching { Text("正在切换账号…") }
        Divider()
        Button("打开主窗口", action: showWindow)
            .keyboardShortcut("o")
        Button("重新检查") {
            showWindow()
            vm.refresh()
        }
        .disabled(vm.isBusy)
        Button("检查更新") {
            showWindow()
            vm.checkUpdate()
            vm.showUpdateSheet = true
        }
        Button("检查设置") {
            showWindow()
            vm.showSettingsSheet = true
        }
        Button("工具…") {
            showWindow()
            vm.showToolsSheet = true
        }
        .disabled(vm.isBusy || vm.checkingUpdate)
        Button("导出诊断日志") { vm.exportDiagnostics() }
            .disabled(vm.settingsBusy)
        Divider()
        Button("退出 Claude 切换器") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
            .disabled(!vm.canQuit)
            .onAppear { vm.refreshAccountStatus() }
    }
}

// 生产应用与 UI 测试共用完全相同的菜单和窗口管理。
struct SwitcherMenu: Scene {
    @ObservedObject var vm: VM
    let controller: AppDelegate

    private static let statusImage: NSImage = {
        let image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Claude 切换器")!
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(vm: vm, showWindow: controller.showMainWindow)
        } label: {
            Image(nsImage: Self.statusImage)
                .accessibilityLabel("Claude 切换器")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Claude 切换器") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .disabled(!vm.canQuit)
            }
        }
    }
}

#if !CLAUDE_SWITCHER_TESTS
@main
struct SwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        SwitcherMenu(vm: appDelegate.vm, controller: appDelegate)
    }
}
#endif
