import UIKit

/// Invisible view that brings up the iOS on-screen keyboard and turns what you type into key presses on the computer.
final class SoftKeyboardView: UIView, UIKeyInput {
    var send: ((InputEvent) -> Void)?
    var onHidden: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var returnKeyType: UIReturnKeyType { get { .default } set {} }

    // US layout, macOS virtual key codes (what the wire protocol uses).
    private static let plain: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49, "\n": 36, "\t": 48
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
        "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
    ]

    func insertText(_ text: String) {
        for ch in text { type(ch) }
    }

    func deleteBackward() { tap(51, shift: false) }

    private func type(_ ch: Character) {
        if let c = SoftKeyboardView.plain[ch] { tap(c, shift: false); return }
        if let base = SoftKeyboardView.shifted[ch], let c = SoftKeyboardView.plain[base] { tap(c, shift: true); return }
        let lower = Character(ch.lowercased())
        if ch.isUppercase, let c = SoftKeyboardView.plain[lower] { tap(c, shift: true) }
    }

    private func tap(_ code: UInt16, shift: Bool) {
        if shift { send?(.key(56, down: true)) }
        send?(.key(code, down: true))
        send?(.key(code, down: false))
        if shift { send?(.key(56, down: false)) }
    }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r { onHidden?() }
        return r
    }
}
