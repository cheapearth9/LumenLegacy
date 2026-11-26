import Foundation
import AVFoundation
import AudioToolbox
import os

/// Small lock-protected jitter buffer of interleaved stereo s16le frames (48 kHz).
/// The render thread pops, the network queue pushes.
final class AudioRing {
    static let sampleRate = 48000.0
    private let capacity = 24000                 // frames (500 ms)
    private let targetFrames = 2880              // ~60 ms jitter buffer
    private let maxFrames = 7200                 // ~150 ms: beyond this the oldest data is dropped

    private let buf: UnsafeMutablePointer<Int16>
    private let lockPtr: UnsafeMutablePointer<os_unfair_lock>
    private var readPos = 0
    private var count = 0
    private var primed = false
    private var mutedFlag = false

    init() {
        buf = UnsafeMutablePointer<Int16>.allocate(capacity: capacity * 2)
        buf.initialize(repeating: 0, count: capacity * 2)
        lockPtr = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lockPtr.initialize(to: os_unfair_lock())
    }

    deinit {
        buf.deallocate()
        lockPtr.deinitialize(count: 1)
        lockPtr.deallocate()
    }

    var muted: Bool {
        get { os_unfair_lock_lock(lockPtr); defer { os_unfair_lock_unlock(lockPtr) }; return mutedFlag }
        set {
            os_unfair_lock_lock(lockPtr)
            mutedFlag = newValue
            if newValue { count = 0; readPos = 0; primed = false }
            os_unfair_lock_unlock(lockPtr)
        }
    }

    func reset() {
        os_unfair_lock_lock(lockPtr)
        count = 0; readPos = 0; primed = false
        os_unfair_lock_unlock(lockPtr)
    }

    /// Appends PCM (4 bytes per frame: L16 R16 little endian).
    func push(_ data: Data) {
        let frames = min(data.count / 4, capacity / 2)
        guard frames > 0 else { return }
        let bytes = [UInt8](data)
        os_unfair_lock_lock(lockPtr)
        defer { os_unfair_lock_unlock(lockPtr) }
        if mutedFlag { return }
        if count + frames > maxFrames {
            let drop = min(count, count + frames - targetFrames)
            if drop > 0 { readPos = (readPos + drop) % capacity; count -= drop }
        }
        var w = (readPos + count) % capacity
        for f in 0..<frames {
            let o = f * 4
            buf[w * 2] = Int16(bitPattern: UInt16(bytes[o]) | (UInt16(bytes[o + 1]) << 8))
            buf[w * 2 + 1] = Int16(bitPattern: UInt16(bytes[o + 2]) | (UInt16(bytes[o + 3]) << 8))
            w += 1
            if w == capacity { w = 0 }
        }
        count += frames
    }

    /// Fills an interleaved stereo Int16 buffer. Outputs silence while (re)buffering or on underrun.
    func pop(into out: UnsafeMutablePointer<Int16>, frames: Int) {
        os_unfair_lock_lock(lockPtr)
        defer { os_unfair_lock_unlock(lockPtr) }
        if !primed {
            if count >= targetFrames { primed = true }
            else {
                for i in 0..<(frames * 2) { out[i] = 0 }
                return
            }
        }
        let n = min(frames, count)
        var r = readPos
        for i in 0..<n {
            out[i * 2] = buf[r * 2]
            out[i * 2 + 1] = buf[r * 2 + 1]
            r += 1
            if r == capacity { r = 0 }
        }
        readPos = r
        count -= n
        if n < frames {
            for i in (n * 2)..<(frames * 2) { out[i] = 0 }
            primed = false   // underrun: refill the jitter buffer before resuming
        }
    }
}

/// RemoteIO render callback (AVAudioSourceNode is iOS 13+, so the legacy app drives the output unit directly).
private let audioRenderCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    let ring = Unmanaged<AudioRing>.fromOpaque(refCon).takeUnretainedValue()
    guard let list = ioData else { return noErr }
    let abl = UnsafeMutableAudioBufferListPointer(list)
    guard abl.count >= 1, let raw = abl[0].mData else { return noErr }
    ring.pop(into: raw.assumingMemoryBound(to: Int16.self), frames: Int(frameCount))
    return noErr
}

/// Plays the host's audio stream through a RemoteIO audio unit (works on iOS 12 and later).
final class AudioPlayer {
    private let ring = AudioRing()
    private let queue = DispatchQueue(label: "lumen.audio")
    private var unit: AudioUnit?
    private var observer: NSObjectProtocol?

    var muted: Bool {
        get { return ring.muted }
        set { ring.muted = newValue }
    }

    func push(_ pcm: Data) { ring.push(pcm) }

    func start() {
        queue.async { self.startNow() }
    }

    func stop() {
        queue.async { self.stopNow() }
    }

    private func startNow() {
        guard unit == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch {
            return
        }

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_RemoteIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return }
        var created: AudioUnit?
        guard AudioComponentInstanceNew(comp, &created) == noErr, let au = created else { return }

        var format = AudioStreamBasicDescription(mSampleRate: AudioRing.sampleRate,
                                                 mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var cb = AURenderCallbackStruct(inputProc: audioRenderCallback,
                                        inputProcRefCon: Unmanaged.passUnretained(ring).toOpaque())
        let ok1 = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        let ok2 = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        ring.reset()
        guard ok1 == noErr, ok2 == noErr, AudioUnitInitialize(au) == noErr, AudioOutputUnitStart(au) == noErr else {
            AudioComponentInstanceDispose(au)
            return
        }
        unit = au
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                          object: nil, queue: nil) { [weak self] n in
            guard let self = self,
                  let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.queue.async {
                guard let u = self.unit else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                AudioOutputUnitStart(u)
            }
        }
    }

    private func stopNow() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        guard let u = unit else { return }
        AudioOutputUnitStop(u)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
        unit = nil
        ring.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
