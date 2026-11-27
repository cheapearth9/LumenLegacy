import UIKit

/// Remembers the last steps the app took and, if the app crashes, saves them together with the crash reason.
/// The next launch offers the report so it can be copied and sent for a fix. Nothing leaves the device by itself.
enum Crumb {
    private static let lock = NSLock()
    private static var items = [String]()

    static func add(_ text: String) {
        lock.lock()
        items.append(String(format: "%.2f ", Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000)) + text)
        if items.count > 40 { items.removeFirst() }
        lock.unlock()
    }

    static var text: String {
        lock.lock(); defer { lock.unlock() }
        return items.joined(separator: "\n")
    }
}

enum CrashReporter {
    private static var path: String {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("lumen-last-crash.txt")
    }

    /// An uncaught exception ends in abort(); the SIGABRT handler must not overwrite the report that already names the exception.
    private static var haveExceptionReport = false

    static func install() {
        NSSetUncaughtExceptionHandler { e in
            CrashReporter.haveExceptionReport = true
            CrashReporter.write("Uncaught exception \(e.name.rawValue): \(e.reason ?? "")\n" + e.callStackSymbols.joined(separator: "\n"))
        }
        for sig in [SIGABRT, SIGILL, SIGTRAP, SIGSEGV, SIGBUS, SIGFPE] {
            signal(sig) { s in
                if !CrashReporter.haveExceptionReport { CrashReporter.write("Crashed with signal \(s)\n" + Thread.callStackSymbols.prefix(14).joined(separator: "\n")) }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    private static func write(_ reason: String) {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let lines = reason.components(separatedBy: "\n")
        let head = lines.first ?? ""
        let report = "Lumen Legacy \(v), iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)\n\(head)\n\nLast steps:\n\(Crumb.text)\n\nStack:\n\(lines.dropFirst().joined(separator: "\n"))\n"
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Call once the UI is up: shows the report of the previous crash (if any) with a Copy button.
    static func offerPreviousReport(from vc: UIViewController?) {
        guard let report = try? String(contentsOfFile: path, encoding: .utf8), !report.isEmpty, let vc = vc else { return }
        try? FileManager.default.removeItem(atPath: path)
        let preview = report.count > 1100 ? String(report.prefix(1100)) + "…" : report
        let alert = UIAlertController(title: "Lumen crashed last time", message: preview, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Copy report", style: .default) { _ in UIPasteboard.general.string = report })
        alert.addAction(UIAlertAction(title: "Dismiss", style: .cancel, handler: nil))
        vc.present(alert, animated: true, completion: nil)
    }
}
