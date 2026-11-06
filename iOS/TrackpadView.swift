import SwiftUI
import UIKit
import FlickKit

struct TrackpadView: View {
    @State private var air = Settings.airOnTrackpad

    var body: some View {
        TrackpadSurfaceView()
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(air ? Theme.accent.opacity(0.25) : Theme.hairline, lineWidth: 1))
            .accessibilityIdentifier("trackpad")
            .overlay(alignment: .topTrailing) {
                // Moving the phone moves the cursor too; this turns that off.
                Button {
                    air.toggle()
                    Settings.airOnTrackpad = air
                    Haptics.tick()
                    if air { MotionEngine.shared.startPointing(allowFake: false) } else { MotionEngine.shared.stopPointing() }
                } label: {
                    Image(systemName: "wand.and.rays")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(air ? Theme.accent : Theme.dim)
                        .frame(width: 40, height: 40)
                        .glass(Circle(), tint: air ? Theme.accent.opacity(0.25) : nil, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(air ? "Air pointer on" : "Air pointer off")
                .accessibilityIdentifier("trackpad.air")
                .padding(12)
            }
            .padding(.horizontal, 12)
            .onAppear { if air { MotionEngine.shared.startPointing(allowFake: false) } }
            .onDisappear { MotionEngine.shared.stopPointing(); MotionEngine.shared.paused = false }
            .animation(.easeOut(duration: 0.2), value: air)
    }
}

struct TrackpadSurfaceView: UIViewRepresentable {
    func makeUIView(context: Context) -> TrackpadSurface { TrackpadSurface() }
    func updateUIView(_ uiView: TrackpadSurface, context: Context) {}
}

/// Mac-style trackpad: move, tap/click, two-finger tap = right click, two-finger scroll with
/// momentum, press-and-hold to drag, pinch to zoom, three-finger swipes for Mission Control / Spaces.
final class TrackpadSurface: UIView, UIGestureRecognizerDelegate {
    private let link = Link.shared
    private var last: CGPoint = .zero
    private var dragging = false
    private var scrollLast: CGPoint = .zero
    private var momentum: CADisplayLink?
    private var velocity: CGPoint = .zero
    private var pinchBase: CGFloat = 1
    /// One soft orange light per finger.
    private var glows: [UITouch: CAGradientLayer] = [:]
    /// Fingers on the pad; the air pointer waits while any are down.
    private var fingers = 0
    private let dots = CAReplicatorLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.035, alpha: 1)
        isMultipleTouchEnabled = true
        setUpDots()
        isAccessibilityElement = true
        accessibilityIdentifier = "trackpad"
        accessibilityTraits = .allowsDirectInteraction

        let move = UIPanGestureRecognizer(target: self, action: #selector(onMove(_:)))
        move.maximumNumberOfTouches = 1
        move.delegate = self

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2

        let swipe = UIPanGestureRecognizer(target: self, action: #selector(onSwipe3(_:)))
        swipe.minimumNumberOfTouches = 3

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        let tap2 = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap))
        tap2.numberOfTouchesRequired = 2

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onHold(_:)))
        hold.minimumPressDuration = 0.32
        hold.allowableMovement = 8
        hold.delegate = self

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))

        tap.require(toFail: tap2)
        for g in [move, scroll, swipe, tap, tap2, hold, pinch] as [UIGestureRecognizer] {
            g.cancelsTouchesInView = false
            addGestureRecognizer(g)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: look

    /// Faint dot grid, like a precision pad.
    private func setUpDots() {
        let dot = CALayer()
        dot.backgroundColor = UIColor(white: 1, alpha: 0.07).cgColor
        dot.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        dot.cornerRadius = 1
        let row = CAReplicatorLayer()
        row.instanceCount = 40
        row.instanceTransform = CATransform3DMakeTranslation(22, 0, 0)
        row.addSublayer(dot)
        dots.instanceCount = 60
        dots.instanceTransform = CATransform3DMakeTranslation(0, 22, 0)
        dots.addSublayer(row)
        layer.addSublayer(dots)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dots.frame = bounds.offsetBy(dx: 11, dy: 11)
    }

    private func makeGlow() -> CAGradientLayer {
        let g = CAGradientLayer()
        g.type = .radial
        g.colors = [UIColor(red: 1, green: 0.42, blue: 0, alpha: 0.55).cgColor,
                    UIColor(red: 1, green: 0.42, blue: 0, alpha: 0.12).cgColor,
                    UIColor(red: 1, green: 0.42, blue: 0, alpha: 0).cgColor]
        g.locations = [0, 0.35, 1]
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.bounds = CGRect(x: 0, y: 0, width: 220, height: 220)
        g.opacity = 0
        return g
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        fingers += touches.count
        MotionEngine.shared.paused = true
        for t in touches {
            let g = makeGlow()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            g.position = t.location(in: self)
            layer.addSublayer(g)
            CATransaction.commit()
            g.opacity = 1
            glows[t] = g
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for t in touches { glows[t]?.position = t.location(in: self) }
        CATransaction.commit()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        fade(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        fade(touches)
    }

    private func fade(_ touches: Set<UITouch>) {
        fingers = max(0, fingers - touches.count)
        if fingers == 0 {
            // Let a tap's click land where the cursor is before the phone's motion moves it again.
            MotionEngine.shared.freeze(for: 0.35)
            MotionEngine.shared.paused = false
        }
        for t in touches {
            guard let g = glows.removeValue(forKey: t) else { continue }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setCompletionBlock { g.removeFromSuperlayer() }
            g.opacity = 0
            g.transform = CATransform3DMakeScale(1.25, 1.25, 1)
            CATransaction.commit()
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UILongPressGestureRecognizer && other is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && other is UILongPressGestureRecognizer)
    }

    private func gain(_ speed: CGFloat) -> CGFloat {
        // Gentle near zero for precision, ramps up for fast flicks.
        CGFloat(Settings.trackpadSpeed) * (0.75 + min(speed / 900, 2.2))
    }

    @objc private func onMove(_ g: UIPanGestureRecognizer) {
        let p = g.translation(in: self)
        switch g.state {
        case .began:
            last = p
            stopMomentum()
        case .changed:
            let d = CGPoint(x: p.x - last.x, y: p.y - last.y)
            last = p
            // A second finger landing means scroll/pinch, not pointing.
            guard g.numberOfTouches == 1 else { return }
            let v = g.velocity(in: self)
            let k = gain(hypot(v.x, v.y))
            link.send(.move(dx: Double(d.x * k), dy: Double(d.y * k)))
        default:
            break
        }
    }

    @objc private func onTap() {
        Haptics.tap()
        link.send(.click(button: .left))
    }

    @objc private func onTwoFingerTap() {
        Haptics.tap()
        link.send(.click(button: .right))
    }

    @objc private func onHold(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            dragging = true
            Haptics.press()
            link.send(.button(button: .left, down: true))
        case .ended, .cancelled, .failed:
            if dragging {
                dragging = false
                link.send(.button(button: .left, down: false))
            }
        default: break
        }
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        let p = g.translation(in: self)
        switch g.state {
        case .began:
            stopMomentum()
            scrollLast = p
            link.send(.scroll(dx: 0, dy: 0, phase: .began))
        case .changed:
            let d = CGPoint(x: p.x - scrollLast.x, y: p.y - scrollLast.y)
            scrollLast = p
            link.send(.scroll(dx: Double(d.x * 1.4), dy: Double(d.y * 1.4), phase: .changed))
        case .ended, .cancelled:
            link.send(.scroll(dx: 0, dy: 0, phase: .ended))
            startMomentum(g.velocity(in: self))
        default: break
        }
    }

    private func startMomentum(_ v: CGPoint) {
        guard hypot(v.x, v.y) > 250 else { return }
        velocity = CGPoint(x: v.x * 1.4, y: v.y * 1.4)
        let dl = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        dl.add(to: .main, forMode: .common)
        momentum = dl
    }

    @objc private func stepMomentum(_ dl: CADisplayLink) {
        let dt = CGFloat(dl.targetTimestamp - dl.timestamp)
        velocity.x *= 0.94; velocity.y *= 0.94
        if hypot(velocity.x, velocity.y) < 40 { stopMomentum(); return }
        link.send(.scroll(dx: Double(velocity.x * dt), dy: Double(velocity.y * dt), phase: .momentum))
    }

    private func stopMomentum() {
        momentum?.invalidate()
        momentum = nil
    }

    @objc private func onSwipe3(_ g: UIPanGestureRecognizer) {
        guard g.state == .ended else { return }
        let t = g.translation(in: self)
        guard max(abs(t.x), abs(t.y)) > 40 else { return }
        Haptics.press()
        if abs(t.y) > abs(t.x) {
            link.send(.system(action: t.y < 0 ? .missionControl : .appWindows))
        } else {
            link.send(.system(action: t.x < 0 ? .spaceRight : .spaceLeft))
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchBase = 1
        case .changed:
            let ratio = g.scale / pinchBase
            if ratio > 1.25 { link.send(.zoom(steps: 1)); pinchBase = g.scale; Haptics.tick() }
            else if ratio < 0.8 { link.send(.zoom(steps: -1)); pinchBase = g.scale; Haptics.tick() }
        default: break
        }
    }
}
