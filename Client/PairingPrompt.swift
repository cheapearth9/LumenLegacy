import UIKit

/// Shows the 5-digit pairing code on the device. The user types it on the computer; nothing is entered here.
enum PairingPrompt {
    private static var current: UIAlertController?
    private static var wanted = false

    /// Shows the code with a Cancel button. Must be called on the main thread.
    static func show(host: String, code: String, onCancel: @escaping () -> Void) {
        dismiss()
        wanted = true
        present(host: host, code: code, onCancel: onCancel, attempts: 6)
    }

    /// Removes the prompt (if any). Must be called on the main thread.
    static func dismiss() {
        wanted = false
        if let a = current { a.dismiss(animated: true, completion: nil) }
        current = nil
    }

    /// A simple "OK" alert for a failure such as "Wrong code. Try pairing again."
    static func showFailure(_ text: String) {
        guard let top = topViewController(), !(top is UIAlertController) else { return }
        let alert = UIAlertController(title: "Pairing", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        top.present(alert, animated: true, completion: nil)
    }

    private static func present(host: String, code: String, onCancel: @escaping () -> Void, attempts: Int) {
        guard wanted else { return }
        guard let top = topViewController(), !(top is UIAlertController) else {
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    present(host: host, code: code, onCancel: onCancel, attempts: attempts - 1)
                }
            }
            return
        }
        // Plain title/message only: no private KVC keys (setValue forKey: "attributedMessage" can raise an exception).
        let spaced = code.map { String($0) }.joined(separator: " ")
        let alert = UIAlertController(title: "Pair with \(host)",
                                      message: "On \(host), type this code when asked:\n\n\(spaced)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            current = nil
            wanted = false
            onCancel()
        })
        current = alert
        top.present(alert, animated: true) {
            if !wanted && current === alert { alert.dismiss(animated: false, completion: nil); current = nil }
        }
    }

    private static func topViewController() -> UIViewController? {
        var vc: UIViewController? = AppWindows.main?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }
}
