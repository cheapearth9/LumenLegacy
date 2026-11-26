import Foundation

/// USB HID keyboard usage codes (page 0x07) -> macOS virtual key codes (ANSI layout), which is what the wire protocol uses.
/// GCKeyCode.rawValue (iOS 14+) and UIKey.keyCode.rawValue (iOS 13.4+) are both these HID usages.
enum KeyMap {
    static let hidToMac: [Int: UInt16] = [
        // letters a...z = 4...29
        4: 0, 5: 11, 6: 8, 7: 2, 8: 14, 9: 3, 10: 5, 11: 4, 12: 34, 13: 38, 14: 40, 15: 37, 16: 46, 17: 45, 18: 31,
        19: 35, 20: 12, 21: 15, 22: 1, 23: 17, 24: 32, 25: 9, 26: 13, 27: 7, 28: 16, 29: 6,
        // digits 1...9, 0 = 30...39
        30: 18, 31: 19, 32: 20, 33: 21, 34: 23, 35: 22, 36: 26, 37: 28, 38: 25, 39: 29,
        40: 36,  // return
        41: 53,  // escape
        42: 51,  // backspace
        43: 48,  // tab
        44: 49,  // space
        45: 27,  // -
        46: 24,  // =
        47: 33,  // [
        48: 30,  // ]
        49: 42,  // backslash
        51: 41,  // ;
        52: 39,  // '
        53: 50,  // `
        54: 43,  // ,
        55: 47,  // .
        56: 44,  // /
        57: 57,  // caps lock
        // F1...F12 = 58...69
        58: 122, 59: 120, 60: 99, 61: 118, 62: 96, 63: 97, 64: 98, 65: 100, 66: 101, 67: 109, 68: 103, 69: 111,
        73: 114, // insert
        74: 115, // home
        75: 116, // page up
        76: 117, // forward delete
        77: 119, // end
        78: 121, // page down
        79: 124, 80: 123, 81: 125, 82: 126,   // right, left, down, up
        // keypad
        84: 75, 85: 67, 86: 78, 87: 69, 88: 76,
        89: 83, 90: 84, 91: 85, 92: 86, 93: 87, 94: 88, 95: 89, 96: 91, 97: 92, 98: 82, 99: 65, 103: 81,
        // modifiers: left ctrl, shift, alt, gui, right ctrl, shift, alt, gui
        224: 59, 225: 56, 226: 58, 227: 55, 228: 62, 229: 60, 230: 61, 231: 54
    ]

    static let leftControl = 224, leftShift = 225, leftAlt = 226, leftGUI = 227
    static let rightControl = 228, rightShift = 229, rightAlt = 230, rightGUI = 231
    static let keyL = 15
}
