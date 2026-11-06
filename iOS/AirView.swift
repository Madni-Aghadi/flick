import SwiftUI
import Combine
import FlickKit

/// Open it and point: the cursor follows the phone. The orb is the mouse button
/// (tap = click, hold = drag). The small button pauses pointing.
struct AirView: View {
    @State private var on = true
    @State private var pressing = false
    @State private var downAt = Date()
    @State private var dragging = false
    @State private var samples = 0
    private let sampler = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button {
                    on.toggle()
                    Haptics.tick()
                    if on { MotionEngine.shared.startPointing(laser: true); MotionEngine.shared.recenterAim() } else { MotionEngine.shared.stopPointing() }
                } label: {
                    Image(systemName: on ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? Theme.text : Theme.accent)
                        .frame(width: 40, height: 40)
                        .glass(Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(on ? "Pause pointing" : "Resume pointing")
                .accessibilityIdentifier("air.toggle")
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
            orb
                .overlay(alignment: .trailing) { ScrollStrip().offset(x: 62) }
            Spacer(minLength: 0)
            HoldPad(shape: AnyShape(Capsule()), id: "air.right", onChange: { down in
                MotionEngine.shared.freeze(for: down ? 1 : 0.2)
                if down { Link.shared.send(.click(button: .right)) }
            }) { down in
                Image(systemName: "contextualmenu.and.cursorarrow").font(.system(size: 20, weight: .medium))
                    .foregroundStyle(down ? Theme.accent : Theme.text)
            }
            .frame(width: 150, height: 60)
        }
        .onAppear { if on { MotionEngine.shared.startPointing(laser: true) } }
        .onDisappear {
            MotionEngine.shared.stopPointing()
            if dragging { Link.shared.send(.button(button: .left, down: false)) }
        }
        .onReceive(sampler) { _ in samples = MotionEngine.shared.samples }
    }

    private var orb: some View {
        let live = on || pressing
        return ZStack {
            Rings(intensity: pressing ? 1.4 : (on ? 1.0 : 0.3), speed: on ? 2.0 : 0.6)
                .clipShape(Circle())
                .animation(.easeOut(duration: 0.25), value: live)
            Circle().stroke(on ? Theme.accent.opacity(0.7) : Color.white.opacity(0.1), lineWidth: on ? 2 : 1)
            Image(systemName: pressing ? "cursorarrow.click.2" : "cursorarrow.click")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.text)
                .opacity(on ? 0.55 : 0.85)
        }
        .frame(width: 250, height: 250)
        .shadow(color: Theme.accent.opacity(on ? 0.4 : 0.1), radius: on ? 36 : 16)
        .scaleEffect(pressing ? 0.96 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressing)
        .animation(.easeInOut(duration: 0.3), value: on)
        .contentShape(Circle())
        .accessibilityElement()
        .accessibilityIdentifier("air.clutch")
        .accessibilityLabel("Click")
        .accessibilityValue("\(on ? "on" : "off") \(samples)")
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    downAt = Date()
                    Haptics.press()
                    // Pressing jiggles the phone: hold the cursor where you aimed.
                    MotionEngine.shared.freeze(for: 1)
                    // Held past a beat = drag (button down, pointer moves again).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if pressing, !dragging {
                            dragging = true
                            Link.shared.send(.button(button: .left, down: true))
                            MotionEngine.shared.unfreeze()
                            Haptics.click()
                        }
                    }
                }
                .onEnded { _ in
                    pressing = false
                    if dragging {
                        dragging = false
                        Link.shared.send(.button(button: .left, down: false))
                    } else {
                        Haptics.tap()
                        Link.shared.send(.click(button: .left))
                    }
                    // Let the hand settle after lifting the thumb, then follow again.
                    MotionEngine.shared.freeze(for: 0.2)
                }
        )
    }
}

/// Vertical glass strip: drag to scroll.
struct ScrollStrip: View {
    @State private var last: CGFloat?
    @State private var active = false

    var body: some View {
        VStack {
            Image(systemName: "chevron.up")
            Spacer()
            Image(systemName: "chevron.down")
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(active ? Theme.accent : Theme.faint)
        .padding(.vertical, 16)
        .frame(width: 38, height: 200)
        .glass(Capsule(), tint: active ? Theme.accent.opacity(0.2) : nil)
        .accessibilityElement()
        .accessibilityIdentifier("air.scroll")
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !active { active = true; Link.shared.send(.scroll(dx: 0, dy: 0, phase: .began)) }
                    let y = v.translation.height
                    let d = y - (last ?? 0)
                    last = y
                    Link.shared.send(.scroll(dx: 0, dy: Double(d) * 2.2, phase: .changed))
                }
                .onEnded { _ in
                    last = nil
                    active = false
                    Link.shared.send(.scroll(dx: 0, dy: 0, phase: .ended))
                }
        )
    }
}
