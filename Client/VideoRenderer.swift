import UIKit
import AVFoundation
import CoreMedia

/// Fans decoded-on-display sample buffers out to every video layer (iPad screen + external monitor).
/// AVSampleBufferDisplayLayer decodes HEVC in hardware and, with DisplayImmediately set,
/// shows each frame as soon as it arrives (no jitter buffer = lowest latency).
final class VideoRenderer {
    static let shared = VideoRenderer()
    private let lock = NSLock()
    private let layers = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()

    func attach(_ layer: AVSampleBufferDisplayLayer) { lock.lock(); layers.add(layer); lock.unlock() }

    func enqueue(_ sb: CMSampleBuffer) {
        lock.lock(); let all = layers.allObjects; lock.unlock()
        for l in all {
            if l.status == .failed { l.flush() }
            l.enqueue(sb)
        }
    }

    func clear() {
        lock.lock(); let all = layers.allObjects; lock.unlock()
        for l in all { l.flushAndRemoveImage() }
    }
}

final class VideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        VideoRenderer.shared.attach(displayLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Builds CMSampleBuffers out of raw HEVC (AVCC) access units.
enum SampleFactory {
    static func formatDescription(parameterSets sets: [Data]) -> CMVideoFormatDescription? {
        guard !sets.isEmpty else { return nil }
        let ptrs = sets.map { s -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(s.count, 1))
            s.copyBytes(to: p, count: s.count)
            return UnsafePointer(p)
        }
        defer { ptrs.forEach { $0.deallocate() } }
        let sizes = sets.map { $0.count }
        var fd: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil,
                                                                    parameterSetCount: sets.count,
                                                                    parameterSetPointers: ptrs,
                                                                    parameterSetSizes: sizes,
                                                                    nalUnitHeaderLength: 4,
                                                                    extensions: nil,
                                                                    formatDescriptionOut: &fd)
        return st == noErr ? fd : nil
    }

    static func sampleBuffer(avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let len = avcc.count
        guard len > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len,
                                                 blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: len,
                                                 flags: CMBlockBufferFlags(kCMBlockBufferAssureMemoryNowFlag),
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let bb = block else { return nil }
        let copied = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: len)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sizes = [len]
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                                        sampleBufferOut: &sb) == noErr, let made = sb else { return nil }

        if let arr = CMSampleBufferGetSampleAttachmentsArray(made, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return made
    }
}
