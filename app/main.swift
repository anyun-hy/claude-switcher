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

enum NoticePage: String, Identifiable {
    case officialRelease, security
    var id: String { rawValue }
}

enum OfficialReleaseReminder {
    static let seenKey = "officialReleaseReminderSeen.v1"

    static func shouldShow(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: seenKey)
    }

    static func markSeen(in defaults: UserDefaults) {
        defaults.set(true, forKey: seenKey)
    }
}

struct CoreResult {
    let output: String
    let succeeded: Bool
}

struct AccountStamp: Equatable {
    let size: String
    let date: String
}

struct NetworkRebuildPlan: Decodable {
    struct Service: Decodable, Identifiable {
        let name: String
        let device: String
        let enabled: Bool
        var id: String { name + ":" + device }
    }
    let schema: Int
    let kind: String
    let level: Int
    let token: String
    let location: String
    let services: [Service]
    let automatic: [String]
    let manual: [String]
    let blocked: [String]
    let preserved: [String]
    let canApply: Bool
    let pending: Bool
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
    @Published private(set) var guardLastEvent = ""
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
    @Published var networkLevel = 1 {
        didSet { if oldValue != networkLevel { networkPlan = nil } }
    }
    @Published private(set) var networkPlan: NetworkRebuildPlan?
    @Published private(set) var networkPending = false
    @Published private(set) var networkCanRollback = false
    var terminalLauncher: ((String, @escaping (CoreResult) -> Void) -> Void)?
    @Published var activeNotice: NoticePage?
    @Published var showFingerprint = false
    @Published var showAIPrompt = false

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
        ("bettbox", "Bettbox"),
        ("shadowrocket", "Shadowrocket"),
        ("sing-box", "sing-box"),
        ("clashx", "ClashX"),
        ("surge", "Surge"),
    ]

    let core: String
    private let checkTimeout: TimeInterval
    private let operationTimeout: TimeInterval
    private let updateTimeout: TimeInterval
    private let noticeDefaults: UserDefaults
    private var consideredStartupNotice = false
    private var started = false
    private var switchRequested = false
    private var hideAfterSwitch: DispatchWorkItem?
    var onSwitchCompleted: (() -> Void)?
    var onRelaunchRequested: (() -> Void)?

    init(core: String = NSHomeDirectory() + "/.local/bin/claude-switch.sh",
         checkTimeout: TimeInterval = 65, operationTimeout: TimeInterval = 180,
         updateTimeout: TimeInterval = 600, noticeDefaults: UserDefaults = .standard) {
        self.core = core
        self.checkTimeout = checkTimeout
        self.operationTimeout = operationTimeout
        self.updateTimeout = updateTimeout
        self.noticeDefaults = noticeDefaults
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

    var hasPresentedSheet: Bool {
        activeNotice != nil || showToolsSheet || showSettingsSheet || showUpdateSheet || showFingerprint || showAIPrompt
    }

    func prepareOfficialReleaseNotice() {
        guard !consideredStartupNotice else { return }
        consideredStartupNotice = true
        if OfficialReleaseReminder.shouldShow(in: noticeDefaults) {
            presentNotice(.officialRelease)
        }
    }

    func presentNotice(_ page: NoticePage) {
        guard !hasPresentedSheet else { return }
        activeNotice = page
    }

    func acknowledgeOfficialReleaseNotice() {
        guard activeNotice == .officialRelease else { return }
        OfficialReleaseReminder.markSeen(in: noticeDefaults)
        activeNotice = nil
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
        guard started, !isBusy, !updating, !networkPending, !isSwitchingClient, !isPollingClient, coreAvailable() else { return }
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
        guardLastEvent = ""
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
                if line.hasPrefix("#保镖事件=") {
                    self.guardLastEvent = String(line.dropFirst("#保镖事件=".count))
                    continue
                }
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
                if rowName == "保镖在线", self.rows[idx].state == .warn || self.rows[idx].state == .skip {
                    self.rows[idx].state = .fail
                    self.rows[idx].detail = "保镖必须在线，不能跳过或降级为警告"
                    allOk = false
                }
                if rowName == "保镖在线", self.rows[idx].state == .ok,
                   (self.rows[idx].detail == "待命" ||
                    self.rows[idx].detail.range(of: #"^\d{4}-\d{2}-\d{2} "#, options: .regularExpression) != nil) {
                    self.guardLastEvent = self.rows[idx].detail == "待命" ? "" : self.rows[idx].detail
                    self.rows[idx].state = .fail
                    self.rows[idx].detail = "旧核心未验证巡检在线，请更新核心后重查"
                    allOk = false
                }
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
                    if self.networkPending {
                        self.banner = "网络重建尚未验收。请在“工具 → Mac 网络重建”恢复并检查保护环境。"
                        self.lastCheckSummary = "待验收"
                    }
                    self.phase = passed && statusOK && !self.networkPending ? .ready : .failed
                    done(passed && statusOK && !self.networkPending)
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
        guard ["0", "1"].contains(fields["network_rebuild"] ?? "0") else { return reset() }
        networkPending = fields["network_rebuild"] == "1"
        if networkPending { phase = .failed }
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
        guard !isBusy, !networkPending, !checkingUpdate, coreAvailable() else { return }
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

    private static func networkObject(_ output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"), let data = String(output[start...]).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["schema"] as? Int == 1, value["kind"] as? String == "network_rebuild" else { return nil }
        return value
    }

    func loadNetworkState() {
        tool(["network-rebuild", "state"]) { result in
            guard result.succeeded, let value = Self.networkObject(result.output),
                  let pending = value["pending"] as? Bool else {
                self.rejectTool("无法读取网络重建状态。请更新核心后重试；不会执行清理。")
                return
            }
            self.networkPending = pending
            self.networkCanRollback = value["canRollback"] as? Bool ?? false
            self.toolOutput = pending
                ? "存在待验收的网络重建。请先恢复网络、启用代理，再检查保护环境。"
                : "尚未执行网络重建。选择层级后，先预检并查看清单。"
        }
    }

    func previewNetworkRebuild() {
        guard !isBusy, (1...3).contains(networkLevel) else { return }
        networkPlan = nil
        let level = networkLevel
        tool(["network-rebuild", "preview", String(level)]) { result in
            guard result.succeeded, let value = Self.networkObject(result.output),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let plan = try? JSONDecoder().decode(NetworkRebuildPlan.self, from: data),
                  plan.level == level, self.networkLevel == level,
                  plan.token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  !plan.services.isEmpty, plan.canApply == plan.blocked.isEmpty else {
                let message = Self.networkObject(result.output)?["message"] as? String
                self.rejectTool(message ?? "预检结果不完整，不能执行。请重新预检。")
                return
            }
            self.networkPlan = plan
            self.networkPending = plan.pending
            self.toolOutput = plan.canApply ? "预检完成。请核对自动处理项、手动事项与保留项，再确认执行。"
                : plan.blocked.joined(separator: "\n")
        }
    }

    func applyNetworkRebuild(confirmed: Bool) {
        guard !isBusy, !checkingUpdate, coreAvailable() else { return }
        guard confirmed, let plan = networkPlan, plan.canApply, !plan.pending,
              plan.level == networkLevel, !networkPending else {
            rejectTool("请先完成当前层级预检，并确认已了解断网和参数变化。")
            return
        }
        networkPlan = nil
        networkPending = true
        phase = .failed
        lastCheckSummary = "待验收"
        for i in rows.indices { rows[i].state = .pending; rows[i].detail = "网络重建后需重新检查" }
        banner = "网络重建期间及验收前，暂不允许启动 Claude。"
        // Never terminate an authorized network operation midway through service reconfiguration.
        tool(["network-rebuild", "apply", String(plan.level), plan.token], timeout: nil) { result in
            self.receiveNetworkResult(result)
        }
    }

    private func receiveNetworkResult(_ result: CoreResult) {
        guard let value = Self.networkObject(result.output), let message = value["message"] as? String else {
            rejectTool("未收到完整的网络操作结果。请读取重建状态；启动保护暂不解除。")
            return
        }
        if let pending = value["pending"] as? Bool { networkPending = pending }
        networkCanRollback = value["canRollback"] as? Bool ?? networkCanRollback
        if !networkPending { networkCanRollback = false }
        toolOutput = message
        toolFailed = !result.succeeded || value["success"] as? Bool != true
        if networkPending { phase = .failed; lastCheckSummary = "待验收" }
    }

    func rollbackNetworkRebuild() {
        guard networkPending, networkCanRollback else { rejectTool("没有可以切回的旧位置。"); return }
        networkPlan = nil
        tool(["network-rebuild", "rollback"], timeout: nil) { result in self.receiveNetworkResult(result) }
    }

    func validateNetworkProtection() {
        guard networkPending else { rejectTool("当前没有待验收的网络重建。"); return }
        tool(["network-rebuild", "validate"], timeout: nil, reaudit: true) { result in
            self.receiveNetworkResult(result)
        }
    }

    func openIsolated(_ address: String) {
        guard !isBusy, !networkPending else { return }
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
        guard !isBusy, !networkPending, Self.accountLetters.contains(target) else { return }
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
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
    static let bgTop = adaptive(0xF6F5F1, 0x1E211F)
    static let bgBottom = bgTop
    static let card = adaptive(0xFFFEFC, 0x292D29)
    static let cardBorder = adaptive(0xDFE2DB, 0x444A43)
    static let divider = adaptive(0xEBEDE7, 0x3A403A)
    static let iconWell = adaptive(0xEFEFE9, 0x343A33)
    static let sidebar = adaptive(0xEEEFE9, 0x242823)
    static let ink = adaptive(0x292F29, 0xECEDE7)
    static let muted = adaptive(0x687166, 0xB0B9AD)
    static let terracotta = adaptive(0xB45A42, 0xDC947B)
    static let terracottaDeep = adaptive(0xA94E38, 0xE4A38D)
    static let terracottaTint = adaptive(0xF4E5DD, 0x44332B)
    static let onAccent = adaptive(0xFFFFFF, 0x242823)
    static let success = adaptive(0x326B4C, 0x92C5A2)
    static let warning = adaptive(0x94661D, 0xE1BA78)
    static let warningBorder = adaptive(0xE8D7B4, 0x645436)
    static let error = adaptive(0xB0463C, 0xF0A096)
}

// MARK: - Claude 优雅背景

struct ClaudeBackground: View {
    var body: some View {
        ClaudeTheme.bgTop
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
                .frame(width: 36, height: 36)
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

struct ClaudeActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundColor(!isEnabled ? ClaudeTheme.muted : (primary ? ClaudeTheme.onAccent : ClaudeTheme.ink))
            .background(!isEnabled ? ClaudeTheme.iconWell : (primary ? ClaudeTheme.terracotta : ClaudeTheme.card))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(primary ? Color.clear : ClaudeTheme.cardBorder))
            .opacity(configuration.isPressed && isEnabled ? 0.72 : 1)
    }
}

struct ClaudeSurface<Content: View>: View {
    var title: String
    var subtitle: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundColor(ClaudeTheme.muted) }
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.cardBorder))
    }
}

extension RowState {
    var label: String {
        switch self { case .pending: return "检查中"; case .ok: return "通过"; case .warn: return "警告"; case .fail: return "未通过"; case .skip: return "已跳过" }
    }
    var color: Color {
        switch self { case .ok: return ClaudeTheme.success; case .warn: return ClaudeTheme.warning; case .fail: return ClaudeTheme.error; case .pending, .skip: return ClaudeTheme.muted }
    }
    var symbol: String {
        switch self { case .ok: return "checkmark.circle.fill"; case .warn: return "exclamationmark.triangle.fill"; case .fail: return "xmark.circle.fill"; case .skip: return "minus.circle"; case .pending: return "clock" }
    }
}

// MARK: - 视图

struct ContentView: View {
    @ObservedObject var vm: VM
    var height: CGFloat = 760

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 20) {
                header
                overview
                ScrollView {
                    HStack(alignment: .top, spacing: 20) {
                        checksCard.frame(maxWidth: .infinity)
                        VStack(spacing: 16) {
                            clientCard
                            if vm.coreMissing { setupCard }
                            else {
                                if vm.phase == .failed || vm.phase == .fixing { retryCard }
                                accountCard
                            }
                        }
                        .frame(width: 292)
                    }
                    .padding(1)
                }
                footer
            }
            .padding(24)
        }
        .font(.system(size: 13))
        .foregroundColor(ClaudeTheme.ink)
        .buttonStyle(ClaudeActionStyle())
        .tint(ClaudeTheme.terracottaDeep)
        .sheet(isPresented: $vm.showAIPrompt) { AIPromptSheet(text: vm.aiPrompt) }
        .sheet(isPresented: $vm.showSettingsSheet) { CheckSettingsView(vm: vm) }
        .sheet(isPresented: $vm.showToolsSheet) { ToolsView(vm: vm) }
        .sheet(item: $vm.activeNotice) { page in
            switch page {
            case .officialRelease:
                OfficialReleaseNoticeView(onAcknowledge: vm.acknowledgeOfficialReleaseNotice)
            case .security:
                NoticeView()
            }
        }
        .sheet(isPresented: $vm.showFingerprint) { FingerprintView(text: vm.fingerprint) }
        .sheet(isPresented: $vm.showUpdateSheet) { UpdateSheet(vm: vm) }
        .frame(minWidth: 860, idealWidth: 1060, maxWidth: .infinity,
               minHeight: 620, idealHeight: height, maxHeight: .infinity)
    }

    var summaryState: RowState {
        if vm.phase == .checking || vm.phase == .fixing || vm.phase == .switching { return .pending }
        if vm.phase == .failed { return .fail }
        if vm.rows.contains(where: { $0.state == .fail }) { return .fail }
        if vm.rows.contains(where: { $0.state == .warn }) { return .warn }
        if vm.rows.contains(where: { $0.state == .pending }) { return .pending }
        if vm.rows.contains(where: { $0.state == .skip }) { return .skip }
        return .ok
    }

    var summaryTitle: String {
        if vm.networkPending { return "网络重建后等待验收" }
        switch vm.phase {
        case .checking: return "正在检查环境"
        case .failed: return vm.coreMissing ? "需要安装核心脚本" : "环境检查未通过"
        case .switching: return "正在切换账号"
        case .fixing: return "正在修复环境"
        default:
            switch summaryState {
            case .warn: return "检查完成，有项目需要留意"
            case .skip: return "硬性检查通过，部分项目已跳过"
            case .ok: return "检查通过，可以选择账号"
            case .pending: return "等待检查结果"
            case .fail: return "环境检查未通过"
            }
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 23, weight: .medium))
                .foregroundColor(ClaudeTheme.terracottaDeep)
                .frame(width: 48, height: 48)
                .background(ClaudeTheme.terracottaTint)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude 切换器").font(.system(size: 24, weight: .bold, design: .serif))
                Text("环境检查与账号启动").font(.caption).foregroundColor(ClaudeTheme.muted)
            }
            Spacer()
            Button { vm.refresh() } label: { Label("重新检查", systemImage: "arrow.clockwise") }
                .disabled(vm.isBusy)
            Button { vm.showToolsSheet = true } label: { Label("工具箱", systemImage: "square.grid.2x2") }
                .buttonStyle(ClaudeActionStyle(primary: true))
                .disabled(vm.isBusy || vm.checkingUpdate || vm.hasPresentedSheet)
            ClaudeIconButton(systemName: "gearshape", help: "检查设置与诊断日志", disabled: vm.hasPresentedSheet) { vm.showSettingsSheet = true }
        }
    }

    private var overview: some View {
        HStack(spacing: 16) {
            if summaryState == .pending {
                ProgressView().controlSize(.regular).frame(width: 28, height: 28)
            } else {
                Image(systemName: summaryState.symbol).font(.system(size: 26)).foregroundColor(summaryState.color)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(summaryTitle).font(.system(size: 16, weight: .semibold))
                Text("最近检查：\(vm.lastCheckSummary)").font(.caption).foregroundColor(ClaudeTheme.muted)
            }
            Spacer()
            ForEach([RowState.ok, .warn, .fail, .skip], id: \.label) { state in
                VStack(spacing: 4) {
                    Text("\(vm.rows.filter { $0.state == state }.count)")
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(state.label).font(.caption2)
                }
                .foregroundColor(state.color)
                .frame(width: 52)
            }
        }
        .padding(20)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.cardBorder))
    }

    var checksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("环境检查").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(vm.rows.count) 项").font(.caption).foregroundColor(ClaudeTheme.muted)
                Button { vm.showFingerprint = true; vm.inspectFingerprint() } label: {
                    Label("设备指纹", systemImage: "waveform.path.ecg")
                }.disabled(vm.isBusy || vm.hasPresentedSheet)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(ClaudeTheme.divider)
            ForEach(Array(vm.rows.enumerated()), id: \.element.id) { index, row in
                let wrapsDetail = row.name == "IP 与上次一致" && row.state == .warn
                HStack(spacing: 12) {
                    Image(systemName: row.icon)
                        .font(.system(size: 13)).foregroundColor(ClaudeTheme.muted)
                        .frame(width: 20)
                    Text(row.name).font(.system(size: 12.5, weight: .medium))
                        .frame(width: 116, alignment: .leading)
                    Text(row.detail.isEmpty ? "—" : row.detail)
                        .font(.system(size: 12))
                        .foregroundColor(row.state == .warn ? ClaudeTheme.warning : ClaudeTheme.muted)
                        .lineLimit(wrapsDetail ? nil : 1).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: wrapsDetail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(row.name == "保镖在线" && !vm.guardLastEvent.isEmpty
                              ? row.detail + "\n上次保护事件：" + vm.guardLastEvent : row.detail)
                    Label(row.state.label, systemImage: row.state.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(row.state.color)
                        .frame(width: 62, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, wrapsDetail ? 4 : 0)
                .frame(minHeight: 31)
                .accessibilityElement(children: .combine)
                if index < vm.rows.count - 1 {
                    Divider().overlay(ClaudeTheme.divider).padding(.leading, 48)
                }
            }
        }
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.cardBorder))
    }

    var clientCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("代理客户端").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Picker("代理客户端", selection: Binding(get: { vm.currentClient }, set: { vm.setClient($0) })) {
                    ForEach(VM.clientChoices, id: \.key) { Text($0.label).tag($0.key) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 142).controlSize(.regular)
                .disabled(vm.isBusy || vm.isSwitchingClient)
            }
            if vm.isSwitchingClient { Label("正在同步客户端…", systemImage: "clock").font(.caption) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.cardBorder))
    }

    var accountCard: some View {
        ClaudeSurface(title: "账号", subtitle: "每次启动前重新完成环境检查") {
            HStack {
                Text("当前账号").font(.caption).foregroundColor(ClaudeTheme.muted)
                Spacer()
                Text(VM.accountLetters.contains(vm.current) ? "账号 \(vm.current)" : "待确认")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(ClaudeTheme.terracottaDeep)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(VM.accountLetters, id: \.self) { accountButton($0, subtitle: accountSubtitle($0)) }
            }
            if vm.phase == .switching || vm.phase == .done {
                Text(vm.banner).font(.caption).foregroundColor(vm.phase == .done ? ClaudeTheme.success : ClaudeTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !vm.note.isEmpty { Text(vm.note).font(.caption).foregroundColor(ClaudeTheme.warning) }
            }
        }
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(t).font(.system(size: 24, weight: .medium, design: .serif))
                    Spacer()
                    if vm.current == t { Image(systemName: "checkmark.circle.fill").font(.caption) }
                }
                Text(subtitle).font(.system(size: 10.5)).lineLimit(2).frame(minHeight: 26, alignment: .topLeading)
            }
            .foregroundColor(vm.current == t ? ClaudeTheme.terracottaDeep : ClaudeTheme.ink)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(vm.current == t ? ClaudeTheme.terracottaTint : ClaudeTheme.iconWell)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(vm.current == t ? ClaudeTheme.terracotta.opacity(0.4) : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy || vm.phase == .failed || vm.phase == .checking || vm.coreMissing)
        .opacity(vm.isBusy || vm.phase == .failed || vm.phase == .checking || vm.coreMissing ? 0.5 : 1)
        .accessibilityLabel("账号 \(t)，\(subtitle)")
        .help(vm.current == t ? "启动当前账号" : "切换到账号 \(t)")
    }

    var setupCard: some View {
        ClaudeSurface(title: "需要安装核心脚本", subtitle: "安装完成后重新检查") {
            Text(vm.banner).font(.caption).foregroundColor(ClaudeTheme.muted)
            Button("打开安装说明") { openURL("https://github.com/anyun-hy/claude-switcher#安装") }
        }
    }

    private func openURL(_ text: String) {
        if let url = URL(string: text) { NSWorkspace.shared.open(url) }
    }

    var retryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if vm.phase == .fixing { ProgressView().controlSize(.small) }
                Text(vm.phase == .fixing ? "正在修复" : "检查未通过")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button("一键修复") { vm.fixAll() }.buttonStyle(ClaudeActionStyle(primary: true))
                Button("重查") { vm.refresh() }
            }
            .controlSize(.small)
            .disabled(vm.isBusy)
            if !vm.banner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(vm.banner).font(.caption).foregroundColor(ClaudeTheme.error)
                    .lineLimit(2).truncationMode(.tail).help(vm.banner)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.cardBorder))
    }

    var footer: some View {
        HStack(spacing: 16) {
            Label("硬性安全项必须通过；跳过不表示通过", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundColor(ClaudeTheme.muted)
            Spacer()
            Menu("关于") {
                Button("官方版本免费与举报") { vm.presentNotice(.officialRelease) }
                Button("安全防护体系公告") { vm.presentNotice(.security) }
            }
            .fixedSize()
            .disabled(vm.hasPresentedSheet)
            .help("官方版本免费与举报 · 安全防护体系公告")
            Button("AI 交接") { vm.showAIPrompt = true }
                .disabled(vm.hasPresentedSheet)
            Button("检查更新") { vm.checkUpdate(); vm.showUpdateSheet = true }
                .disabled(vm.isBusy || vm.checkingUpdate || vm.hasPresentedSheet)
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundColor(ClaudeTheme.muted)
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
    @State private var networkAcknowledged = false

    static let destinations: [(id: String, title: String, icon: String, subtitle: String)] = [
        ("cli", "Claude Code", "terminal", "检查命令行环境，选择项目并启动会话。"),
        ("snapshot", "加密账号快照", "externaldrive", "在不同设备之间迁移已归档的桌面账号。"),
        ("region", "地区设置", "globe.asia.australia", "更换国家节点后，重新锁定地区目标。"),
        ("proxy", "代理诊断", "network", "通过指定代理检查 Claude 网页与 API 的传输。"),
        ("rebuild", "Mac 网络重建", "arrow.triangle.2.circlepath", "分级刷新、复位或重建整台 Mac 的系统网络。"),
        ("browser", "隔离浏览器", "safari", "用独立的临时浏览器会话打开链接。"),
        ("keep", "跨账号保留", "doc.on.doc", "管理切换账号时共享的通用文件。"),
        ("policy", "WebRTC 策略", "waveform.path", "为支持的客户端选择 UDP 修复策略。")
    ]

    private enum Confirmation: String, Identifiable {
        case region, policy, keep, networkApply, networkRollback
        var id: String { rawValue }
    }

    init(vm: VM, initialSection: String = "cli") {
        self.vm = vm
        _section = State(initialValue: initialSection == "network" ? "region" : initialSection)
    }

    private var destination: (id: String, title: String, icon: String, subtitle: String) {
        Self.destinations.first { $0.id == section } ?? Self.destinations[0]
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(ClaudeTheme.cardBorder).frame(width: 1)
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(destination.title).font(.system(size: 24, weight: .bold, design: .serif))
                        Text(destination.subtitle).font(.system(size: 12)).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    ClaudeIconButton(systemName: "xmark", help: "关闭工具箱", disabled: vm.toolRunning) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            switch section {
                            case "cli": cliSection
                            case "snapshot": snapshotSection
                            case "region": regionSection
                            case "proxy": proxySection
                            case "rebuild": networkSection
                            case "browser": browserSection
                            case "policy": policySection
                            default: keepSection
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(1)
                        .disabled(vm.isBusy || vm.checkingUpdate || vm.coreMissing)
                    }
                    .onChange(of: vm.networkPlan?.token) { token in
                        if section == "rebuild", token != nil, !vm.networkPending {
                            scroll.scrollTo("network-plan", anchor: .top)
                        }
                    }
                    .onAppear {
                        if section == "rebuild", vm.networkPlan != nil, !vm.networkPending {
                            DispatchQueue.main.async { scroll.scrollTo("network-plan", anchor: .top) }
                        }
                    }
                }
                resultPanel
            }
            .padding(24)
            .background(ClaudeTheme.bgTop)
        }
        .frame(width: 900, height: 700)
        .font(.system(size: 13))
        .foregroundColor(ClaudeTheme.ink)
        .buttonStyle(ClaudeActionStyle())
        .tint(ClaudeTheme.terracottaDeep)
        .controlSize(.large)
        .interactiveDismissDisabled(vm.toolRunning)
        .onAppear { if section == "rebuild" { vm.loadNetworkState() } else { vm.loadTools() } }
        .onChange(of: section) { if $0 == "rebuild" { vm.loadNetworkState() } }
        .onChange(of: vm.networkLevel) { _ in networkAcknowledged = false }
        .onDisappear { password = ""; repeatedPassword = ""; proxyAddress = "" }
        .alert(item: $pending) { action in
            switch action {
            case .networkApply:
                return Alert(title: Text("执行第 \(vm.networkLevel) 层网络重置？"),
                             message: Text("将修改预检清单中的全机网络服务，可能断网。Wi-Fi 已保存网络、密码和自动加入偏好保留。第 3 层将建立新位置并使用 DHCP／自动 IPv6；原位置保留供回退。恢复代理并验收前，切换器不会启动 Claude。"),
                             primaryButton: .destructive(Text("确认并请求授权")) { vm.applyNetworkRebuild(confirmed: networkAcknowledged); networkAcknowledged = false },
                             secondaryButton: .cancel())
            case .networkRollback:
                return Alert(title: Text("切回旧网络位置？"),
                             message: Text("请先退出代理／VPN 软件。切回后仍需重新检查保护环境，不会自动启动 Claude。"),
                             primaryButton: .default(Text("切回旧位置")) { vm.rollbackNetworkRebuild() },
                             secondaryButton: .cancel())
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill").font(.title3).foregroundColor(ClaudeTheme.terracottaDeep)
                Text("工具箱").font(.system(size: 18, weight: .semibold, design: .serif))
            }.padding(.horizontal, 12)
            VStack(spacing: 5) {
                ForEach(Self.destinations, id: \.id) { item in
                    Button { section = item.id } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).frame(width: 18)
                            Text(item.title).font(.system(size: 13, weight: section == item.id ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).frame(height: 42)
                        .foregroundColor(section == item.id ? ClaudeTheme.terracottaDeep : ClaudeTheme.ink)
                        .background(section == item.id ? ClaudeTheme.terracottaTint : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item.id ? .isSelected : [])
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("当前工作环境").font(.system(size: 10, weight: .semibold)).foregroundColor(ClaudeTheme.muted)
                Label(VM.accountLetters.contains(vm.current) ? "桌面账号 \(vm.current)" : "账号待确认", systemImage: "person.crop.circle")
                Label(VM.clientChoices.first { $0.key == vm.currentClient }?.label ?? "客户端待确认", systemImage: "network")
            }
            .font(.caption).padding(12)
            Divider()
            Button("刷新工具配置") { vm.loadTools() }
                .disabled(vm.isBusy || vm.checkingUpdate)
                .font(.caption).padding(.horizontal, 12)
        }
        .padding(.horizontal, 12).padding(.vertical, 24)
        .frame(width: 188)
        .background(ClaudeTheme.sidebar)
    }

    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if vm.toolRunning { ProgressView().controlSize(.small) }
                else { Image(systemName: vm.toolFailed ? "exclamationmark.circle" : "text.alignleft") }
                Text(vm.toolRunning ? "正在执行，请稍候" : (vm.toolFailed ? "操作未完成" : "最近一次操作"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if vm.toolRunning { Text("完成后在这里显示结果").font(.caption) }
            }
            .foregroundColor(vm.toolFailed ? ClaudeTheme.error : ClaudeTheme.muted)
            ScrollView {
                Text(vm.coreMissing ? "请先在主窗口安装核心脚本，再使用这些工具。" : (vm.toolOutput.isEmpty ? "选择功能并执行后，这里会显示结果。" : vm.toolOutput))
                    .font(.system(size: 12, design: .monospaced)).lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 86)
        }
        .padding(16)
        .background(ClaudeTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(vm.toolFailed ? ClaudeTheme.warningBorder : ClaudeTheme.cardBorder))
    }

    private func description(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).lineSpacing(3).foregroundColor(ClaudeTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cliSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClaudeSurface(title: "安装与账号", subtitle: "CLI 槽位表示目录映射，不代表已登录") {
                HStack {
                    Button("检查安装与版本") { vm.inspectCLI() }
                    Button("查看当前 CLI 槽位") { vm.inspectCLISlot() }
                }
                description("B–D 的 CLI 需要分别登录；桌面账号快照不包含独立 CLI 数据。")
            }
            ClaudeSurface(title: "打开项目") {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.title3).foregroundColor(ClaudeTheme.muted)
                    Text(project?.path ?? "尚未选择项目文件夹")
                        .font(.system(size: 12)).lineLimit(2).textSelection(.enabled).help(project?.path ?? "")
                    Spacer()
                    Button("选择文件夹…") { project = selectFile(directory: true) ?? project }
                }
                HStack {
                    Button("启动 Claude Code") { if let project = project { vm.launchCLI(project: project, resume: false) } }
                        .buttonStyle(ClaudeActionStyle(primary: true))
                    Button("选择历史会话") { if let project = project { vm.launchCLI(project: project, resume: true) } }
                }.disabled(project == nil)
                description("对话和登录在终端完成。首次可能需要允许控制终端，启动前仍执行环境检查。")
            }
        }
    }

    private var snapshotSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClaudeSurface(title: importing ? "导入加密快照" : "导出加密快照") {
                Picker("操作", selection: $importing) {
                    Text("导出快照").tag(false)
                    Text("导入快照").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                Picker("账号槽位", selection: $account) {
                    ForEach(VM.accountLetters, id: \.self) { slot in
                        Text("账号 \(slot) · \(slot == vm.current ? "当前" : (vm.archived.contains(slot) ? "已归档" : "未归档"))").tag(slot)
                    }
                }
                description(importing
                    ? "目标须为当前未使用的空槽位，且与镜像的账号标记一致。不会覆盖已有快照。"
                    : "只能导出当前未使用的已归档槽位。当前账号需先在主窗口切换到其他账号。")
                VStack(alignment: .leading, spacing: 8) {
                    Text(importing ? "镜像密码" : "设置镜像密码").font(.system(size: 12, weight: .medium))
                    SecureField(importing ? "输入镜像密码" : "至少 8 位", text: $password)
                    if !importing { SecureField("再次输入密码", text: $repeatedPassword) }
                }
                Button(importing ? "选择镜像并导入…" : "选择位置并导出…") { transferSnapshot() }
                    .buttonStyle(ClaudeActionStyle(primary: true))
                    .disabled(account == vm.current || (importing ? vm.archived.contains(account) : !vm.archived.contains(account)) || password.isEmpty || (!importing && (password.count < 8 || password != repeatedPassword)))
            }
            description("macOS 加密 DMG · 密码无法找回 · 不包含独立 CLI 数据。导入或导出期间请等待完成。")
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: importing) { _ in password = ""; repeatedPassword = "" }
    }

    private var regionSection: some View {
        ClaudeSurface(title: "当前地区目标") {
            Label(vm.regionTarget, systemImage: "globe.asia.australia")
                .font(.system(size: 15, weight: .medium)).textSelection(.enabled)
            description("更换其他国家的代理节点后，按当前出口重新锁定国家、时区与地区格式。")
            Divider()
            description("将修改系统地区设置，并可能请求管理员授权。操作完成后自动重新检查环境。")
            Button("按当前出口重设地区…") { pending = .region }
                .buttonStyle(ClaudeActionStyle(primary: true))
        }
    }

    private var browserSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClaudeSurface(title: "打开链接", subtitle: "支持 http 和 https") {
                TextField("https://…", text: $address).accessibilityLabel("要隔离打开的网址")
                Button("隔离打开链接") { vm.openIsolated(address); address = "" }
                    .buttonStyle(ClaudeActionStyle(primary: true)).disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                description("使用独立的临时浏览器配置。退出隔离浏览器后清理本次会话，不保留本次登录。")
            }
            ClaudeSurface(title: "Web 指纹检测", subtitle: "补充 Canvas 与 WebGL 的浏览器检测") {
                Button("打开 Web 指纹检测页") { vm.openIsolated("https://yoursjeyo.github.io/claude-switcher/") }
            }
        }.textFieldStyle(.roundedBorder)
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClaudeSurface(title: "保留 Wi-Fi 连接信息", subtitle: "覆盖整台 Mac 的系统网络服务") {
                Label("已保存网络、密码和自动加入偏好始终保留", systemImage: "lock.shield")
                    .font(.system(size: 13, weight: .medium))
                description("不忽略 Wi-Fi，不清空钥匙串，不删除代理订阅、节点或 Claude 账号。执行前请正常退出 Claude 和 Claude Code。")
            }
            if vm.networkPending {
                ClaudeSurface(title: "网络操作待验收", subtitle: "普通联网与代理保护分别检查") {
                    description("先恢复网络，再重新开启代理、TUN 和原有安全设置。完成检查前，启动和账号切换保持锁定；关闭窗口或重启切换器不会解除锁定。")
                    HStack {
                        Button("检查保护环境") { vm.validateNetworkProtection() }
                            .buttonStyle(ClaudeActionStyle(primary: true))
                        if vm.networkCanRollback {
                            Button("切回旧位置…") { pending = .networkRollback }
                        }
                    }
                    Button("重新读取重建状态") { vm.loadNetworkState() }
                }
            }
            ClaudeSurface(title: "选择重置深度", subtitle: "层级不会自动升级，预检不会修改网络") {
                Picker("重置层级", selection: $vm.networkLevel) {
                    Text("1 · 连接刷新 — 按原有配置重新连接").tag(1)
                    Text("2 · 参数复位 — 清除全机手动 DNS 与代理设置").tag(2)
                    Text("3 · 深度重建 — 新网络位置与默认网络服务").tag(3)
                }
                .pickerStyle(.radioGroup)
                .disabled(vm.networkPending)
                if vm.networkLevel == 3 {
                    description("第 3 层将 IPv4 改为 DHCP、IPv6 改为自动配置，并保留旧位置供回退。静态地址和特殊虚拟服务可能需要手动重新配置。恢复 Claude 保护前仍须按原有要求处理 IPv6。")
                }
                HStack {
                    Button("只读预检") { networkAcknowledged = false; vm.previewNetworkRebuild() }
                        .buttonStyle(ClaudeActionStyle(primary: true))
                        .disabled(vm.networkPending)
                    Button("打开系统网络设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.network") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            if let plan = vm.networkPlan {
                ClaudeSurface(title: "本次执行清单", subtitle: "当前位置：\(plan.location) · \(plan.services.count) 个服务") {
                    ForEach(plan.services) { service in
                        HStack {
                            Label(service.name, systemImage: service.device == "en0" ? "network" : "cable.connector")
                            Spacer()
                            Text("\(service.device) · \(service.enabled ? "启用" : "停用")")
                                .font(.system(size: 11, design: .monospaced)).foregroundColor(ClaudeTheme.muted)
                        }
                    }
                    Divider()
                    Text("自动处理").font(.system(size: 12, weight: .semibold))
                    networkLines(plan.automatic, symbol: "arrow.triangle.2.circlepath", color: ClaudeTheme.ink)
                    Text("需要手动处理／确认").font(.system(size: 12, weight: .semibold))
                    networkLines(plan.manual, symbol: "hand.raised", color: ClaudeTheme.muted)
                    if !plan.blocked.isEmpty {
                        Divider()
                        networkLines(plan.blocked, symbol: "exclamationmark.triangle", color: ClaudeTheme.error)
                    }
                    Toggle("我已核对清单，了解断网和参数变化，并确认保留 Wi-Fi 信息",
                           isOn: $networkAcknowledged)
                        .toggleStyle(.checkbox)
                        .disabled(!plan.canApply)
                    Button("执行第 \(plan.level) 层重置…") { pending = .networkApply }
                        .buttonStyle(ClaudeActionStyle(primary: true))
                        .disabled(!plan.canApply || !networkAcknowledged || vm.networkPending)
                }
                .id("network-plan")
            }
        }
    }

    private func networkLines(_ lines: [String], symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: symbol)
                    .font(.system(size: 12)).foregroundColor(color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var proxySection: some View {
        ClaudeSurface(title: "指定诊断入口", subtitle: "填写代理地址，或选择包含代理地址的私有 JSON 文件") {
            VStack(alignment: .leading, spacing: 8) {
                Text("代理地址").font(.system(size: 12, weight: .medium))
                SecureField("协议://地址:端口", text: $proxyAddress)
                    .disabled(proxyConfig != nil).accessibilityLabel("用于诊断的代理地址")
            }
            HStack {
                Button("选择私有 JSON…") { proxyConfig = selectFile(directory: false, types: [.json]) ?? proxyConfig }
                if let config = proxyConfig {
                    Label(config.lastPathComponent, systemImage: "doc").font(.caption).lineLimit(1)
                    Button("清除文件") { proxyConfig = nil }
                }
            }
            Divider()
            description("只测试 Claude 网页和 API 的网络传输。401 表示尚未认证，403 表示访问受限，均不代表账号已可用。")
            Button("开始诊断") { vm.diagnoseProxy(address: proxyAddress, config: proxyConfig); proxyAddress = "" }
                .buttonStyle(ClaudeActionStyle(primary: true))
                .disabled(proxyConfig == nil && proxyAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.textFieldStyle(.roundedBorder)
    }

    private var policySection: some View {
        ClaudeSurface(title: "UDP 修复策略") {
            if !vm.supportsWebRTCPolicy {
                Label("当前客户端需自行管理规则", systemImage: "info.circle")
                    .font(.system(size: 13, weight: .medium)).foregroundColor(ClaudeTheme.warning)
                description("此入口仅适用于 Clash Verge 和 FlClash。切换器不会通过这里改写 TAG 等客户端的规则。")
            }
            VStack(alignment: .leading, spacing: 16) {
                Picker("UDP 策略", selection: $vm.webrtcPolicy) {
                    Text("走代理 · 保留通话能力").tag("proxy")
                    Text("拒绝相关端口 · 可能影响通话").tag("reject")
                }.pickerStyle(.radioGroup)
                Button("应用策略并修复…") { pending = .policy }
                    .buttonStyle(ClaudeActionStyle(primary: true))
            }.disabled(!vm.supportsWebRTCPolicy)
            description("应用会执行一键修复，可能修改规则、重启代理并请求管理员授权，结束后重新检查环境。")
        }
    }

    private var keepSection: some View {
        ClaudeSurface(title: "保留路径", subtitle: "每行一个相对于 Claude 数据目录的路径；留空关闭") {
            TextEditor(text: $vm.keepPaths)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8).frame(height: 150)
                .background(ClaudeTheme.bgTop)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ClaudeTheme.cardBorder))
                .accessibilityLabel("跨账号保留路径列表")
            description("例如 settings.json、skills/。仅共享通用配置，不要加入登录凭据、Cookie、设备标识或缓存。绝对路径、.. 和符号链接会被拒绝。")
            HStack {
                Button("保存保留列表…") { pending = .keep }.buttonStyle(ClaudeActionStyle(primary: true))
                Text("从下次切换开始生效").font(.caption).foregroundColor(ClaudeTheme.muted)
            }
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
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("检查设置").font(.system(size: 24, weight: .bold, design: .serif))
                        Text("硬性检查始终执行；跳过不表示通过").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    ClaudeIconButton(systemName: "xmark", help: "关闭检查设置") { dismiss() }
                }
                ScrollView {
                    VStack(spacing: 16) {
                        ClaudeSurface(title: "可选检查", subtitle: "关闭后停止对应探测，并显示为“已跳过”") {
                            ForEach(VM.optionalChecks, id: \.key) { item in
                                HStack {
                                    Text(item.label)
                                    Spacer()
                                    Text(vm.disabledChecks.contains(item.key) ? "关闭" : "开启")
                                        .font(.caption).foregroundColor(ClaudeTheme.muted)
                                    Toggle(item.label, isOn: Binding(
                                        get: { !vm.disabledChecks.contains(item.key) },
                                        set: { enabled in
                                            if enabled { vm.disabledChecks.remove(item.key) }
                                            else { vm.disabledChecks.insert(item.key) }
                                        }
                                    ))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                }
                            }
                        }
                        ClaudeSurface(title: "失败处理与日志") {
                            HStack {
                                Text("将非关键项失败降为警告")
                                Spacer()
                                Toggle("将非关键项失败降为警告", isOn: $vm.allowOptionalFailures)
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            Text("仅影响上面的六项；代理、TUN、出口国家、保镖等硬性检查始终强制执行。")
                                .font(.caption).foregroundColor(ClaudeTheme.muted)
                            Divider()
                            HStack {
                                Text("记录脱敏客户端日志")
                                Spacer()
                                Toggle("记录脱敏客户端日志", isOn: $vm.loggingEnabled)
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            Text("仅记录操作、耗时和状态，不包含 IP、凭据、账号内容或代理配置。")
                                .font(.caption).foregroundColor(ClaudeTheme.muted)
                            Button("导出脱敏诊断日志…") { vm.exportDiagnostics() }.disabled(vm.settingsBusy)
                        }
                    }.padding(1)
                }
                if !vm.settingsMessage.isEmpty {
                    Text(vm.settingsMessage).font(.caption).foregroundColor(ClaudeTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("恢复默认选项") { vm.restoreCheckDefaults() }.disabled(vm.settingsBusy)
                    Spacer()
                    if vm.settingsBusy { ProgressView().controlSize(.small) }
                    Button("保存并重新检查") { vm.saveCheckConfig() }
                        .buttonStyle(ClaudeActionStyle(primary: true))
                        .disabled(vm.settingsBusy || vm.isBusy)
                }
            }.padding(24)
        }
        .font(.system(size: 13)).foregroundColor(ClaudeTheme.ink)
        .buttonStyle(ClaudeActionStyle()).tint(ClaudeTheme.terracottaDeep)
        .frame(width: 640, height: 680)
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
                Text("设备指纹体检").font(.system(size: 24, weight: .bold, design: .serif)).foregroundColor(ClaudeTheme.ink)
                Spacer()
                ClaudeIconButton(systemName: "xmark", help: "关闭设备指纹体检") { dismiss() }
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
        .padding(24)
        .frame(width: 640, height: 460)
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
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("版本更新").font(.system(size: 24, weight: .bold, design: .serif))
                        Text("更新核心、界面与系统守护").font(.caption).foregroundColor(ClaudeTheme.muted)
                    }
                    Spacer()
                    ClaudeIconButton(systemName: "xmark", help: "关闭版本更新", disabled: vm.updating) { dismiss() }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        if vm.checkingUpdate || vm.updating { ProgressView().controlSize(.small) }
                        Text(vm.updating ? "正在更新，请等待完成" : (vm.checkingUpdate ? "正在检查版本" : "更新结果"))
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(ClaudeTheme.muted)
                    }
                    ScrollView {
                        Text(vm.updateText.isEmpty ? "点击“重新检查”获取版本状态。" : vm.updateText)
                            .font(.system(size: 12, design: .monospaced)).lineSpacing(4)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 138)
                }
                .padding(16).background(ClaudeTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ClaudeTheme.cardBorder))
                HStack {
                    Button { vm.performUpdate() } label: {
                        Label(vm.updating ? "正在更新…" : "立即更新", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(ClaudeActionStyle(primary: true))
                    .disabled(vm.checkingUpdate || vm.updating || vm.isBusy)
                    Button("重新检查") { vm.checkUpdate() }.disabled(vm.checkingUpdate || vm.updating || vm.isBusy)
                    Spacer()
                    Button(copied ? "命令已复制" : "复制更新命令") { copyUpdateCommand() }
                }
                Text("会先校验文件并自检；自检失败自动回滚。需要同步系统守护时请求管理员授权，仅界面 App 更新后自动重启。")
                    .font(.caption).foregroundColor(ClaudeTheme.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(24)
        }
        .font(.system(size: 13)).foregroundColor(ClaudeTheme.ink)
        .buttonStyle(ClaudeActionStyle()).tint(ClaudeTheme.terracottaDeep)
        .frame(width: 640, height: 400)
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
                        Text("AI 交接提示词").font(.system(size: 24, weight: .bold, design: .serif)).foregroundColor(ClaudeTheme.ink)
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
                    }
                    .buttonStyle(ClaudeActionStyle(primary: true))
                    Spacer()
                }
            }
            .padding(20)
        }
        .frame(width: 640, height: 520)
    }

    private func copyPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        copied = true
    }
}

// MARK: - 公告页

struct OfficialReleaseNoticeView: View {
    @Environment(\.dismiss) private var dismiss
    let onAcknowledge: () -> Void

    var body: some View {
        ZStack {
            ClaudeBackground()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("官方版本免费与举报")
                        .font(.title3.bold())
                        .foregroundColor(ClaudeTheme.ink)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(ClaudeTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭提醒")
                    .help("关闭不会标记已读")
                    .keyboardShortcut(.cancelAction)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("官方版本免费提供")
                            .font(.headline)
                            .foregroundColor(ClaudeTheme.terracottaDeep)
                        Text("维护者不会出售官方安装包或账号服务。请勿冒充官方、维护者或授权渠道收费销售。")
                        Text("发现冒充官方销售、删除版权或许可证声明、隐瞒修改，或未按许可证要求提供对应源码等疑似违规行为，欢迎举报。")
                        Text("本项目采用 AGPL-3.0-only。履行许可证义务后可以再分发和收费，单纯收费不自动等于违规。")
                        Text("举报时请附商品链接、页面截图和版本信息。请勿公开买家个人信息、订单信息或账号凭据。")
                            .foregroundColor(ClaudeTheme.muted)
                    }
                    .font(.callout)
                    .foregroundColor(ClaudeTheme.ink)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("点击「知道了」后不再自动提醒，可从「关于」菜单或菜单栏再次查看。")
                    .font(.caption)
                    .foregroundColor(ClaudeTheme.muted)
                HStack {
                    Button("前往 Issues 举报") {
                        if let url = URL(string: "https://github.com/YOURSJEYO/claude-switcher/issues") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                    Button("知道了", action: onAcknowledge)
                        .buttonStyle(.borderedProminent)
                        .tint(ClaudeTheme.terracottaDeep)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 420, height: 460)
    }
}

struct NoticeView: View {
    @Environment(\.dismiss) private var dismiss

    let sections: [(String, String)] = [
        ("Full-Tunnel 全流量接管", "基于 TUN 虚拟网卡的内核级流量劫持，配合 Fake-IP DNS 解析机制，包括 UDP 在内的全部出站流量在网络栈底层被强制路由至加密隧道，应用层无法旁路。"),
        ("Environment Audit 环境一致性审计", "每次启动前执行 14 项环境指纹审计：Egress IP 归属地与 ASN 属性、时区与 Geo-location 一致性、Locale、IPv6 双栈旁路、DNS Leak、WebRTC/STUN 多节点交叉探测等。硬性安全项失败即 Block-on-Fail；仅显式配置的非关键项可跳过或降级，skip 不表示通过。"),
        ("Kill-Switch 断网急停", "macOS 保镖按 1 秒间隔调度巡检隧道健康度，发现异常后终止受保护进程。实际响应受系统调度与执行耗时影响；进程级急停，非防火墙级保证，边界详见 SECURITY.md。已有安装需同步系统守护调度配置后生效。"),
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
                        Text("安全防护体系公告").font(.system(size: 24, weight: .bold, design: .serif)).foregroundColor(ClaudeTheme.ink)
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
        // 等窗口与 SwiftUI 宿主就绪后展示；重开隐藏窗口不走此启动路径。
        DispatchQueue.main.async { [weak self] in
            self?.vm.prepareOfficialReleaseNotice()
        }
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
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            let titleHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: style).height
            let height = min(CGFloat(760), (NSScreen.main?.visibleFrame.height ?? 840) - titleHeight - 24)
            let width = min(CGFloat(1060), (NSScreen.main?.visibleFrame.width ?? 1100) - 32)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: style,
                backing: .buffered, defer: false
            )
            window.title = "Claude切换器"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 860, height: 620)
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
        Button("官方版本免费与举报") {
            showWindow()
            vm.presentNotice(.officialRelease)
        }
        .disabled(vm.hasPresentedSheet)
        Button("检查更新") {
            showWindow()
            vm.checkUpdate()
            vm.showUpdateSheet = true
        }
        .disabled(vm.hasPresentedSheet)
        Button("检查设置") {
            showWindow()
            vm.showSettingsSheet = true
        }
        .disabled(vm.hasPresentedSheet)
        Button("工具…") {
            showWindow()
            vm.showToolsSheet = true
        }
        .disabled(vm.isBusy || vm.checkingUpdate || vm.hasPresentedSheet)
        Button("导出诊断日志") { vm.exportDiagnostics() }
            .disabled(vm.settingsBusy || vm.hasPresentedSheet)
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
