import UIKit
import VideoToolbox

/// User preferences (UserDefaults, same keys as the main Lumen app).
enum LumenSettings {
    static let audioKey = "audioOn"
    static let extendKey = "extendMode"
    static let touchModeKey = "touchMode"
    static let fpsKey = "fps"
    static let cableMbpsKey = "mbpsCable"
    static let wifiMbpsKey = "mbpsWifi"
    static let controllersKey = "controllersOn"
    static let keyboardAutoKey = "keyboardAuto"
    static let manualHostKey = "manualHost"

    static let cableMaxMbps: Float = 150
    static let wifiMaxMbps: Float = 80
    static let minMbps: Float = 8

    /// Sound on by default.
    static var audioOn: Bool {
        get { UserDefaults.standard.object(forKey: audioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: audioKey) }
    }

    /// false = Mirror, true = Extend.
    static var extend: Bool {
        get { UserDefaults.standard.bool(forKey: extendKey) }
        set { UserDefaults.standard.set(newValue, forKey: extendKey) }
    }

    static var touchMode: TouchEngine.Mode {
        get { TouchEngine.Mode(rawValue: UserDefaults.standard.string(forKey: touchModeKey) ?? "") ?? .touchscreen }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: touchModeKey) }
    }

    static var fps: Int {
        get { let v = UserDefaults.standard.integer(forKey: fpsKey); return v == 0 ? 60 : v }
        set { UserDefaults.standard.set(newValue, forKey: fpsKey) }
    }

    static var cableMbps: Float {
        get { clamp(UserDefaults.standard.object(forKey: cableMbpsKey) as? Float ?? 100, cableMaxMbps) }
        set { UserDefaults.standard.set(clamp(newValue, cableMaxMbps), forKey: cableMbpsKey) }
    }

    static var wifiMbps: Float {
        get { clamp(UserDefaults.standard.object(forKey: wifiMbpsKey) as? Float ?? 40, wifiMaxMbps) }
        set { UserDefaults.standard.set(clamp(newValue, wifiMaxMbps), forKey: wifiMbpsKey) }
    }

    private static func clamp(_ v: Float, _ maxValue: Float) -> Float { min(maxValue, max(minMbps, v)) }

    static var controllersOn: Bool {
        get { UserDefaults.standard.object(forKey: controllersKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: controllersKey) }
    }

    static var keyboardAuto: Bool {
        get { UserDefaults.standard.bool(forKey: keyboardAutoKey) }
        set { UserDefaults.standard.set(newValue, forKey: keyboardAutoKey) }
    }

    /// Hello flags for the current preferences.
    static func helloFlags() -> UInt8 {
        var f: UInt8 = 0
        if audioOn { f |= HelloInfo.flagAudio }
        if extend { f |= HelloInfo.flagExtend }
        // Automatic: H.264 only when this chip cannot decode HEVC in hardware.
        if !VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { f |= HelloInfo.flagH264 }
        return f
    }

    /// The hello to send: requested size / fps / flags (the bitrate is chosen per transport inside StreamClient). Main thread.
    static func makeHello() -> HelloInfo {
        let (w, h) = ResolutionSetting.requested()
        return HelloInfo(width: UInt16(w), height: UInt16(h), fps: UInt8(fps), bitrateMbps: 40, flags: helloFlags())
    }
}

/// Resolution choices: full screen (device original), 16:9 (1080p) or custom.
enum ResolutionSetting {
    static let modeKey = "resMode", widthKey = "resW", heightKey = "resH"

    static var mode: Int {
        get { UserDefaults.standard.integer(forKey: modeKey) }
        set { UserDefaults.standard.set(newValue, forKey: modeKey) }
    }
    static var customWidth: Int {
        get { UserDefaults.standard.object(forKey: widthKey) as? Int ?? 1920 }
        set { UserDefaults.standard.set(newValue, forKey: widthKey) }
    }
    static var customHeight: Int {
        get { UserDefaults.standard.object(forKey: heightKey) as? Int ?? 1080 }
        set { UserDefaults.standard.set(newValue, forKey: heightKey) }
    }

    static func requested() -> (Int, Int) {
        switch mode {
        case 1: return (1920, 1080)
        case 2:
            return (min(3840, max(640, customWidth)) & ~1, min(2160, max(360, customHeight)) & ~1)
        default:
            // With a monitor / AirPlay display attached (and switched on): its real resolution, so a 1080p monitor gets 1080p.
            if ExternalDisplay.isActive, let m = ExternalDisplay.pixelSize {
                return (Int(min(3840, m.width)) & ~1, Int(min(2160, m.height)) & ~1)
            }
            let b = UIScreen.main.nativeBounds
            return (Int(min(3840, max(b.width, b.height))), Int(min(2160, min(b.width, b.height))))
        }
    }

    static var footnote: String {
        switch mode {
        case 0: return "The device's own resolution, or the attached monitor's own resolution (for example 1080p) when one is connected."
        case 1: return "1920×1080: lighter on the computer and the network."
        default: return "Between 640×360 and 3840×2160. The picture keeps the computer screen's shape inside this size."
        }
    }
}
