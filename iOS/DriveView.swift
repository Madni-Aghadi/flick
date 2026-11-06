import SwiftUI
import FlickKit

/// Hold the phone like a wheel. Tilt to steer, right thumb = gas, left thumb = brake.
struct DriveView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var drive = DriveController()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                HStack(spacing: 12) {
                    Pedal(symbol: "chevron.down", down: drive.braking, id: "drive.brake") { drive.brake($0) }
                    VStack(spacing: 18) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.dim)
                                .frame(width: 36, height: 36)
                                .glass(Circle(), interactive: true)
                        }
                        .accessibilityIdentifier("drive.close")
                        Spacer(minLength: 0)
                        Wheel(angle: drive.angle)
                            .frame(width: min(geo.size.width * 0.28, 170), height: min(geo.size.width * 0.28, 170))
                            .onTapGesture { Haptics.tick(); drive.recenter() }
                        HStack(spacing: 10) {
                            SmallKey(title: "esc") { drive.tap(.escape) }
                            HoldKey(title: "space", id: "drive.space") { drive.hold(.space, $0) }
                            SmallKey(title: drive.wasd ? "WASD" : "↑↓←→") { drive.wasd.toggle() }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: max(200, geo.size.width * 0.3))
                    Pedal(symbol: "chevron.up", down: drive.accelerating, id: "drive.gas") { drive.gas($0) }
                }
                .padding(16)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            Orientation.lock(.landscape, prefer: .landscapeRight)
            drive.start()
        }
        .onDisappear {
            drive.stop()
            Orientation.lock(.allButUpsideDown, prefer: .portrait)
        }
    }
}

final class DriveController: ObservableObject {
    @Published var angle = 0.0
    @Published var accelerating = false
    @Published var braking = false
    @Published var wasd = Settings.wasd { didSet { releaseAll(); Settings.wasd = wasd } }

    private var steering = Steering()
    private var held: Int = 0
    private var lastTick = Date()
    private let link = Link.shared

    private var leftKey: Key { wasd ? .a : .left }
    private var rightKey: Key { wasd ? .d : .right }
    private var gasKey: Key { wasd ? .w : .up }
    private var brakeKey: Key { wasd ? .s : .down }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        MotionEngine.shared.startSteering { [weak self] a in self?.update(a) }
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        MotionEngine.shared.stopSteering()
        releaseAll()
        link.send(.releaseAll)
    }

    func recenter() { MotionEngine.shared.recenterSteering() }

    private func update(_ a: Double) {
        angle = a
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        let dir = steering.step(angle: a, dt: min(dt, 0.05))
        guard dir != held else { return }
        if held == -1 { link.send(.keyState(key: leftKey, down: false)) }
        if held == 1 { link.send(.keyState(key: rightKey, down: false)) }
        if dir == -1 { link.send(.keyState(key: leftKey, down: true)) }
        if dir == 1 { link.send(.keyState(key: rightKey, down: true)) }
        held = dir
    }

    func gas(_ down: Bool) { accelerating = down; link.send(.keyState(key: gasKey, down: down)) }
    func brake(_ down: Bool) { braking = down; link.send(.keyState(key: brakeKey, down: down)) }
    func hold(_ k: Key, _ down: Bool) { link.send(.keyState(key: k, down: down)) }
    func tap(_ k: Key) { link.send(.key(key: k, mods: [])) }

    private func releaseAll() {
        for k in [Key.left, .right, .up, .down, .a, .d, .w, .s, .space] { link.send(.keyState(key: k, down: false)) }
        held = 0
        accelerating = false
        braking = false
    }
}

struct Pedal: View {
    let symbol: String
    let down: Bool
    let id: String
    let onChange: (Bool) -> Void
    @State private var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(Color.clear)
            .glass(RoundedRectangle(cornerRadius: 34, style: .continuous), tint: pressed ? Theme.accent.opacity(0.3) : nil)
            .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(pressed ? Theme.accent.opacity(0.8) : .clear, lineWidth: 2))
            .overlay(Image(systemName: symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(pressed ? Theme.accent : Theme.dim))
            .shadow(color: Theme.accent.opacity(pressed ? 0.5 : 0), radius: 30)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
            .contentShape(Rectangle())
            .accessibilityIdentifier(id)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; Haptics.press(); onChange(true) } }
                    .onEnded { _ in pressed = false; onChange(false) }
            )
    }
}

struct Wheel: View {
    let angle: Double

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 10)
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 10)
                Circle().fill(Color.clear).frame(width: 40, height: 40).glass(Circle())
                Capsule().fill(Theme.accent).frame(width: 4, height: 16).offset(y: -(r - 5)).opacity(abs(angle) > 0.08 ? 1 : 0.5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .rotationEffect(.radians(angle))
        .animation(.interactiveSpring(response: 0.12), value: angle)
        .accessibilityIdentifier("drive.wheel")
    }
}

struct SmallKey: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button { Haptics.tap(); action() } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(minWidth: 52, minHeight: 36)
                .padding(.horizontal, 6)
                .glass(Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

struct HoldKey: View {
    let title: String
    let id: String
    let onChange: (Bool) -> Void
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(down ? Theme.accent : Theme.text)
            .frame(minWidth: 64, minHeight: 36)
            .glass(Capsule(), tint: down ? Theme.accent.opacity(0.4) : nil)
            .accessibilityIdentifier(id)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !down { down = true; Haptics.tap(); onChange(true) } }
                    .onEnded { _ in down = false; onChange(false) }
            )
    }
}
