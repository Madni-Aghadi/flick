import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import FlickKit

/// Main display → ScreenCaptureKit → H.264 (low-latency, no B-frames) → VideoPackets.
public final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    public static let shared = ScreenStreamer()

    public var onPacket: ((VideoPacket) -> Void)?
    /// Return true to skip encoding this frame (network is behind).
    public var shouldDrop: (() -> Bool)?
    public private(set) var running = false

    private let queue = DispatchQueue(label: "flick.capture")
    private var stream: SCStream?
    private var session: VTCompressionSession?
    private var forceKeyframe = true
    private var lastBuffer: CVPixelBuffer?
    private var lastPTS = CMTime.zero
    private var size = (w: 0, h: 0)

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    public static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    public func start(maxWidth: Int, fps: Int, completion: @escaping (Bool) -> Void) {
        queue.async {
            if self.running { self.forceKeyframe = true; self.reencodeLast(); completion(true); return }
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                guard let content, let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    completion(false); return
                }
                self.queue.async { completion(self.begin(display: display, maxWidth: maxWidth, fps: fps)) }
            }
        }
    }

    private func begin(display: SCDisplay, maxWidth: Int, fps: Int) -> Bool {
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let pixelW = mode?.pixelWidth ?? display.width * 2
        let pixelH = mode?.pixelHeight ?? display.height * 2
        let scale = min(1.0, Double(maxWidth) / Double(pixelW))
        let w = Int(Double(pixelW) * scale) & ~1
        let h = Int(Double(pixelH) * scale) & ~1
        size = (w, h)

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(fps, 60))))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 4
        cfg.colorSpaceName = CGColorSpace.sRGB

        guard makeEncoder(width: w, height: h, fps: fps) else { return false }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch { return false }
        let started = DispatchSemaphore(value: 0)
        var ok = false
        s.startCapture { err in ok = err == nil; started.signal() }
        _ = started.wait(timeout: .now() + 5)
        guard ok else { return false }
        stream = s
        running = true
        forceKeyframe = true
        return true
    }

    public func stop() {
        queue.async {
            guard self.running else { return }
            self.running = false
            self.stream?.stopCapture { _ in }
            self.stream = nil
            if let s = self.session {
                VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(s)
            }
            self.session = nil
            self.lastBuffer = nil
        }
    }

    public func requestKeyframe() {
        queue.async {
            self.forceKeyframe = true
            self.reencodeLast()
        }
    }

    private func makeEncoder(width: Int, height: Int, fps: Int) -> Bool {
        var s: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { return false }
        let bitrate = max(1_500_000, min(12_000_000, width * height * max(fps, 1) / 9))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 4 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        return true
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastBuffer = pb
        lastPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !forceKeyframe, shouldDrop?() == true { return }
        encode(pb, pts: lastPTS)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.running = false; self.stream = nil }
    }

    private func reencodeLast() {
        guard running, let pb = lastBuffer else { return }
        lastPTS = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 600))
        encode(pb, pts: lastPTS)
    }

    private func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKeyframe = false
        }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.emit(sample)
        }
    }

    private func emit(_ sample: CMSampleBuffer) {
        var keyframe = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = arr.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            var sets: [Data] = []
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var len = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                      parameterSetSizeOut: &len, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    sets.append(Data(bytes: ptr, count: len))
                }
            }
            onPacket?(.config(width: size.w, height: size.h, parameterSets: sets))
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let micros = UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000)
        onPacket?(VideoPacket(keyframe: keyframe, isConfig: false, pts: micros, body: data))
    }
}
