import UIKit

/// Hardware keyboard fallback for iOS 12 / 13.0-13.3, where neither GCKeyboard (iOS 14) nor UIPress.key (iOS 13.4) exists.
/// UIKeyCommand only reports complete key strokes (no key-up), so each match is sent as modifiers down, key down, key up,
/// modifiers up. Holding a key relies on the keyboard's auto-repeat. Shifted symbols (such as "!") are best effort.
enum LegacyKeyCommands {
    private static let inputToHID: [String: Int] = {
        var m = [String: Int]()
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for (i, ch) in letters.enumerated() { m[String(ch)] = 4 + i }
        let digits = Array("1234567890")
        for (i, ch) in digits.enumerated() { m[String(ch)] = 30 + i }
        m["\r"] = 40; m["\t"] = 43; m[" "] = 44; m["\u{8}"] = 42
        m["-"] = 45; m["="] = 46; m["["] = 47; m["]"] = 48; m["\\"] = 49
        m[";"] = 51; m["'"] = 52; m["`"] = 53; m[","] = 54; m["."] = 55; m["/"] = 56
        m[UIKeyCommand.inputEscape] = 41
        m[UIKeyCommand.inputRightArrow] = 79
        m[UIKeyCommand.inputLeftArrow] = 80
        m[UIKeyCommand.inputDownArrow] = 81
        m[UIKeyCommand.inputUpArrow] = 82
        m[UIKeyCommand.inputPageUp] = 75
        m[UIKeyCommand.inputPageDown] = 78
        return m
    }()

    private static let modifierSets: [UIKeyModifierFlags] = [
        [], .shift, .control, .alternate, .command,
        [.control, .shift], [.alternate, .shift], [.command, .shift], [.control, .alternate]
    ]

    static func hid(forInput input: String) -> Int? { return inputToHID[input] }

    static func make(action: Selector) -> [UIKeyCommand] {
        var out = [UIKeyCommand]()
        for key in inputToHID.keys {
            for mods in modifierSets {
                out.append(UIKeyCommand(input: key, modifierFlags: mods, action: action))
            }
        }
        return out
    }
}
