import CoreMotion
import Foundation
import FlickKit

/// Gyro → cursor (air mouse) and gravity → steering angle (drive).
final class MotionEngine {
    static let shared = MotionEngine()

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private var air = AirMouse()
    private var laser = AirLaser()
    /// Laser: phone direction = cursor position (absolute). Otherwise relative nudges.
    private var laserMode = false
    private var lastAim: (x: Double, y: Double)?
    /// Pointer held still until this uptime (so a tap clicks where you aimed).
    private var frozenUntil: TimeInterval = 0
    private var lastStamp: TimeInterval?
    private var fakeTimer: Timer?
    private var steerHandler: ((Double) -> Void)?
    private var neutral: Double?
    private let fake = ProcessInfo.processInfo.arguments.contains("-FlickFakeMotion")

    var pointing = false
    /// A finger is on the trackpad: hold the air pointer still so the two don't fight.
    var paused = false
    /// Motion samples received since launch (diagnostics, shown to UI tests).
    private(set) var samples = 0

    // MARK: air mouse

    /// `allowFake: false` = real gyro only (the trackpad's air pointer stays off in UI tests).
    func startPointing(allowFake: Bool = true, laser useLaser: Bool = false) {
        if pointing, laserMode == useLaser, !fake || !allowFake { return }
        stopPointing()
        if fake && !allowFake { return }
        pointing = true
        laserMode = useLaser
        air = AirMouse(sensitivity: Settings.airSensitivity)
        // Higher sensitivity = less turning to cross the screen.
        let span = 0.75 * 900 / max(Settings.airSensitivity, 200)
        laser = AirLaser(width: span, height: span / 1.6)
        lastAim = nil
        lastStamp = nil
        if fake {
            // UI tests: a steady turn to the right so the pipeline can be verified on a still phone.
            let t = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.handle(rotation: Vec3(0, 0, -0.9), gravity: Vec3(0, 0, -1), dt: 1 / 120)
            }
            RunLoop.main.add(t, forMode: .common)
            fakeTimer = t
            return
        }
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1 / 120
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] m, _ in
            guard let self, let m, self.pointing else { return }
            self.samples += 1
            let dt = self.lastStamp.map { m.timestamp - $0 } ?? (1 / 120)
            self.lastStamp = m.timestamp
            let r = m.rotationRate, g = m.gravity
            self.handle(rotation: Vec3(r.x, r.y, r.z), gravity: Vec3(g.x, g.y, g.z), dt: min(max(dt, 0.001), 0.05))
        }
    }

    private func handle(rotation: Vec3, gravity: Vec3, dt: Double) {
        let still = paused || ProcessInfo.processInfo.systemUptime < frozenUntil
        if laserMode {
            // Keep integrating while frozen so the aim stays true; just don't move the cursor.
            let p = laser.step(rotationRate: rotation, gravity: gravity, dt: dt)
            if still { return }
            if let l = lastAim, abs(l.x - p.x) < 0.0003, abs(l.y - p.y) < 0.0003 { return }
            lastAim = p
            Link.shared.send(.point(x: p.x, y: p.y))
        } else {
            let d = air.step(rotationRate: rotation, gravity: gravity, dt: dt)
            if still { return }
            if d.dx != 0 || d.dy != 0 { Link.shared.send(.move(dx: d.dx, dy: d.dy)) }
        }
    }

    /// Hold the cursor still for a moment (around a tap) so the click lands where you aimed.
    func freeze(for seconds: Double) {
        frozenUntil = ProcessInfo.processInfo.systemUptime + seconds
    }

    func unfreeze() { frozenUntil = 0 }

    /// Laser: wherever the phone points now becomes the middle of the screen.
    func recenterAim() {
        laser.recenter()
        lastAim = nil
    }

    func stopPointing() {
        pointing = false
        fakeTimer?.invalidate(); fakeTimer = nil
        if steerHandler == nil { manager.stopDeviceMotionUpdates() }
    }

    // MARK: steering

    /// Calls back on the main queue with the wheel angle in radians (+ = right).
    func startSteering(_ handler: @escaping (Double) -> Void) {
        steerHandler = handler
        neutral = nil
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1 / 60
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] m, _ in
            guard let self, let m, let h = self.steerHandler else { return }
            // Phone held like a wheel (landscape, screen facing you): steering = rotation about the screen normal.
            let g = m.gravity
            let raw = atan2(g.y, -g.x)
            let base = self.neutral ?? raw
            if self.neutral == nil { self.neutral = raw }
            // Turning clockwise (right) lowers `raw` however the phone is held, so flip it.
            var a = base - raw
            if a > .pi { a -= 2 * .pi }
            if a < -.pi { a += 2 * .pi }
            DispatchQueue.main.async { h(a) }
        }
    }

    /// Drive: the current tilt becomes "straight".
    func recenterSteering() { neutral = nil }

    func stopSteering() {
        steerHandler = nil
        if !pointing { manager.stopDeviceMotionUpdates() }
    }
}
