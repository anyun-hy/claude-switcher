import AppKit
import Foundation

// Run in a separate process with a fake core and a fake `open` executable.
final class RelaunchTestDelegate: AppDelegate {
    let scenario: String
    private var testSheet: NSWindow?

    init(vm: VM, scenario: String) {
        self.scenario = scenario
        super.init(vm: vm)
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        super.applicationDidFinishLaunching(notification)
        beginWhenReady()
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            if self.scenario == "veto", self.vm.showUpdateSheet,
               self.vm.updateText.contains("自动重启未完成") {
                print("PASS veto reported"); fflush(stdout); exit(0)
            }
            print("FAIL restart did not finish: \(self.vm.updateText)"); fflush(stdout); exit(42)
        }
    }

    private func beginWhenReady() {
        guard !vm.isBusy, let window = mainWindow else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.beginWhenReady() }
            return
        }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        testSheet = sheet
        window.beginSheet(sheet)
        vm.performUpdate()
    }

    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if scenario == "veto" { return .terminateCancel }
        let reply = super.applicationShouldTerminate(sender)
        if reply == .terminateNow { print("PASS termination requested"); fflush(stdout) }
        return reply
    }
}

@main
struct RelaunchLifecycleTests {
    static func main() {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        setenv("RELAUNCH_TEST_OLD_PID", String(ProcessInfo.processInfo.processIdentifier), 1)
        let app = NSApplication.shared
        let delegate = RelaunchTestDelegate(vm: VM(core: CommandLine.arguments[1]),
                                           scenario: CommandLine.arguments[2])
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
