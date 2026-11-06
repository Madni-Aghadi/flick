import SwiftUI
import UIKit
import AVFoundation
import CoreMedia
import FlickKit

/// Live view of the Mac screen. Tap to click where you tap, drag to point, two fingers to scroll.
struct ScreenView: View {
    @EnvironmentObject var link: Link

    var body: some View {
        ZStack {
                if link.canSeeScreen {
                    VideoSurfaceView()
                        .accessibilityIdentifier("screen.video")
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "macbook").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.dim)
                        Text("Allow Screen Recording on your Mac")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.dim)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.03))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .padding(.horizontal, 8)
    }
}

struct VideoSurfaceView: UIViewRepresentable {
    func makeUIView(context: Context) -> VideoSurface { VideoSurface() }
    func updateUIView(_ uiView: VideoSurface, context: Context) {}
    static func dismantleUIView(_ uiView: VideoSurface, coordinator: ()) { uiView.stop() }
}

final class VideoSurface: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private let link = Link.shared
    private var format: CMVideoFormatDescription?
    private var videoSize = CGSize(width: 16, height: 10)
    private var waitingForKey = true
    private var scrollLast: CGPoint = .zero
    private(set) var framesShown = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        display.videoGravity = .resizeAspect
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityIdentifier = "screen.video"
        accessibilityValue = "waiting"

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold(_:)))
        hold.minimumPressDuration = 0.45
        [tap, double, pan, scroll, hold].forEach(addGestureRecognizer)

        link.onVideo = { [weak self] p in DispatchQueue.main.async { self?.receive(p) } }
        subscribe()
        // After a reconnect the Mac has forgotten us: ask again.
        observer = NotificationCenter.default.addObserver(forName: Link.connectedNote, object: nil, queue: .main) { [weak self] _ in
            self?.waitingForKey = true
            self?.subscribe()
        }
    }

    private var observer: NSObjectProtocol?

    private func subscribe() {
        let width = Int(max(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height))
        link.send(.stream(on: true, maxWidth: min(1920, width), fps: 30))
        link.send(.keyframe)
    }

    required init?(coder: NSCoder) { fatalError() }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        link.onVideo = nil
        link.send(.stream(on: false, maxWidth: 0, fps: 0))
    }

    private func receive(_ p: VideoPacket) {
        if p.isConfig {
            guard let cfg = p.parseConfig(), cfg.parameterSets.count >= 2 else { return }
            videoSize = CGSize(width: cfg.width, height: cfg.height)
            let sets = cfg.parameterSets
            var fmt: CMFormatDescription?
            sets[0].withUnsafeBytes { a in
                sets[1].withUnsafeBytes { b in
                    let ptrs = [a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!]
                    _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                                                                            parameterSetSizes: [sets[0].count, sets[1].count],
                                                                            nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
                }
            }
            format = fmt
            return
        }
        guard let format else { return }
        if waitingForKey && !p.keyframe { return }
        waitingForKey = false
        if display.sampleBufferRenderer.status == .failed {
            display.sampleBufferRenderer.flush()
            waitingForKey = true
            link.send(.keyframe)
            return
        }
        guard let sample = Self.sample(p.body, format: format) else { return }
        display.sampleBufferRenderer.enqueue(sample)
        framesShown += 1
        if framesShown == 1 { accessibilityValue = "live" }
    }

    static func sample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var sample: CMSampleBuffer?
        var size = data.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        if let sample, let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// Where the video actually sits inside this view (aspect fit).
    private var videoRect: CGRect {
        AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    private func normalized(_ p: CGPoint) -> (Double, Double)? {
        let r = videoRect
        guard r.width > 0, r.height > 0 else { return nil }
        let x = (p.x - r.minX) / r.width, y = (p.y - r.minY) / r.height
        guard (-0.02...1.02).contains(x), (-0.02...1.02).contains(y) else { return nil }
        return (Double(x), Double(y))
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        Haptics.tap()
        link.send(.point(x: x, y: y))
        link.send(.click(button: .left))
    }

    @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        Haptics.tap()
        link.send(.point(x: x, y: y))
        link.send(.click(button: .left))
        link.send(.click(button: .left))
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        guard let (x, y) = normalized(g.location(in: self)) else { return }
        link.send(.point(x: x, y: y))
    }

    @objc private func onHold(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let (x, y) = normalized(g.location(in: self)) else { return }
        Haptics.press()
        link.send(.point(x: x, y: y))
        link.send(.click(button: .right))
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        let p = g.translation(in: self)
        switch g.state {
        case .began:
            scrollLast = p
            if let (x, y) = normalized(g.location(in: self)) { link.send(.point(x: x, y: y)) }
            link.send(.scroll(dx: 0, dy: 0, phase: .began))
        case .changed:
            link.send(.scroll(dx: Double(p.x - scrollLast.x) * 2, dy: Double(p.y - scrollLast.y) * 2, phase: .changed))
            scrollLast = p
        default:
            link.send(.scroll(dx: 0, dy: 0, phase: .ended))
        }
    }
}
