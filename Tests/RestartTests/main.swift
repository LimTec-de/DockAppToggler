import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let output = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "TestOutput") as! String)
let skipUpdateCheck = Bundle.main.object(forInfoDictionaryKey: "SkipUpdateCheck") as! Bool
let launches = (try! FileManager.default.contentsOfDirectory(atPath: output.path))
    .filter { $0.hasPrefix("launch-") }.count
let pid = ProcessInfo.processInfo.processIdentifier
let data = try! JSONSerialization.data(withJSONObject: ["pid": pid, "arguments": CommandLine.arguments])
try! data.write(to: output.appendingPathComponent("launch-\(launches).json"))

let terminationObserver = NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification, object: application, queue: .main
) { _ in
    try! Data(String(pid).utf8).write(to: output.appendingPathComponent("terminated-\(launches)"))
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    if launches < 2 {
        NSApplication.restart(skipUpdateCheck: skipUpdateCheck)
        // A second click while launch is pending must not create another instance.
        NSApplication.restart(skipUpdateCheck: skipUpdateCheck)
    } else {
        application.terminate(nil)
    }
}

application.run()
