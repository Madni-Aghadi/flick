import Foundation

/// One Euro filter (Casiez et al. 2012): low lag when moving fast, smooth when slow.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double
    private var x: Double?
    private var dx: Double = 0

    public init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1.0 / (2 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    public mutating func filter(_ value: Double, dt: Double) -> Double {
        guard let prev = x, dt > 0 else { x = value; return value }
        let rawD = (value - prev) / dt
        let aD = Self.alpha(dCutoff, dt)
        dx = dx + aD * (rawD - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let a = Self.alpha(cutoff, dt)
        let out = prev + a * (value - prev)
        x = out
        return out
    }

    public mutating func reset() { x = nil; dx = 0 }
}

public struct Vec3: Sendable, Equatable {
    public var x, y, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public var length: Double { dot(self).squareRoot() }
    public var normalized: Vec3 { let l = length; return l > 1e-9 ? self * (1 / l) : self }
}

/// Turns gyro rotation rate (rad/s, device frame) + gravity (device frame) into cursor deltas.
/// Horizontal = rotation about world vertical (yaw), vertical = rotation about the device's
/// horizontal x axis (pitch) — works whether the phone is held flat or upright.
public struct AirMouse: Sendable {
    /// Points per radian at low speed.
    public var sensitivity: Double
    /// Extra gain at high angular speed (pointer acceleration).
    public var acceleration: Double
    public var deadZone: Double = 0.012

    private var fx = OneEuroFilter(minCutoff: 1.4, beta: 0.04, dCutoff: 1.0)
    private var fy = OneEuroFilter(minCutoff: 1.4, beta: 0.04, dCutoff: 1.0)
    private var carryX = 0.0, carryY = 0.0

    public init(sensitivity: Double = 900, acceleration: Double = 1.2) {
        self.sensitivity = sensitivity; self.acceleration = acceleration
    }

    public mutating func reset() {
        fx.reset(); fy.reset(); carryX = 0; carryY = 0
    }

    /// Returns whole-point deltas; fractional remainder carries over so slow motion isn't lost.
    public mutating func step(rotationRate w: Vec3, gravity g: Vec3, dt: Double) -> (dx: Double, dy: Double) {
        let up = (g * -1).normalized
        var yawRate = w.dot(up)
        let xAxis = Vec3(1, 0, 0)
        let right = (xAxis - up * xAxis.dot(up)).normalized
        var pitchRate = w.dot(right)

        if abs(yawRate) < deadZone { yawRate = 0 }
        if abs(pitchRate) < deadZone { pitchRate = 0 }

        yawRate = fx.filter(yawRate, dt: dt)
        pitchRate = fy.filter(pitchRate, dt: dt)

        let speed = (yawRate * yawRate + pitchRate * pitchRate).squareRoot()
        let gain = sensitivity * (1 + acceleration * min(speed / 3.0, 1.5))

        carryX += -yawRate * dt * gain
        carryY += -pitchRate * dt * gain
        let dx = carryX.rounded(.towardZero)
        let dy = carryY.rounded(.towardZero)
        carryX -= dx; carryY -= dy
        return (dx, dy)
    }
}

/// Steering for drive mode: tilt → left/right key held with a duty cycle (poor man's analog).
public struct Steering: Sendable {
    public var deadZone: Double = 0.08    // radians
    public var fullLock: Double = 0.6     // radians
    public var period: Double = 0.12      // seconds

    private var phase: Double = 0
    public init() {}

    /// Returns which direction should be held right now (-1 left, 0 none, 1 right).
    public mutating func step(angle: Double, dt: Double) -> Int {
        let mag = abs(angle)
        guard mag > deadZone else { phase = 0; return 0 }
        let duty = min(1, (mag - deadZone) / (fullLock - deadZone))
        phase = (phase + dt / period).truncatingRemainder(dividingBy: 1)
        let on = duty >= 0.98 || phase < duty
        return on ? (angle > 0 ? 1 : -1) : 0
    }
}

/// Absolute "laser" pointing: the direction the phone points *is* the cursor position.
/// Turning left/right (yaw) spans the screen width, tilting up/down (pitch) its height.
/// Works flat or upright (same gravity projection as AirMouse). Pushing past an edge
/// clamps, so swinging back re-aims immediately — that doubles as recentring.
public struct AirLaser: Sendable {
    /// Radians from the left edge to the right edge.
    public var width: Double
    /// Radians from top to bottom.
    public var height: Double
    private var yaw = 0.0, pitch = 0.0
    private var fx = OneEuroFilter(minCutoff: 0.9, beta: 4.0, dCutoff: 1.0)
    private var fy = OneEuroFilter(minCutoff: 0.9, beta: 4.0, dCutoff: 1.0)

    public init(width: Double = 0.75, height: Double = 0.48) {
        self.width = width; self.height = height
    }

    /// Aim straight ahead = middle of the screen.
    public mutating func recenter() {
        yaw = 0; pitch = 0
        fx.reset(); fy.reset()
    }

    /// Returns the cursor position, 0…1 each way (0,0 = top-left).
    public mutating func step(rotationRate w: Vec3, gravity g: Vec3, dt: Double) -> (x: Double, y: Double) {
        let up = (g * -1).normalized
        let xAxis = Vec3(1, 0, 0)
        let right = (xAxis - up * xAxis.dot(up)).normalized
        yaw = min(max(yaw + w.dot(up) * dt, -width / 2), width / 2)
        pitch = min(max(pitch + w.dot(right) * dt, -height / 2), height / 2)
        let rawX = 0.5 - yaw / width
        let rawY = 0.5 - pitch / height
        let x = fx.filter(rawX, dt: dt), y = fy.filter(rawY, dt: dt)
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }
}
