import Foundation

/// One Bluetooth HID report, before it's split for the wire.
public enum HIDEvent: Equatable, Sendable {
    case mouse(buttons: UInt8, dx: Int, dy: Int, wheel: Int)
    case keyboard(mods: UInt8, keys: [UInt8])
    case consumer(UInt16)
    case system(UInt8)
    /// Absolute pointer position, 0…32767 each way, with the current buttons (report 7).
    case absolute(buttons: UInt8, x: UInt16, y: UInt16)
}

public enum HIDReportID {
    public static let mouse: UInt8 = 1
    public static let keyboard: UInt8 = 2
    public static let system: UInt8 = 5
    public static let consumer: UInt8 = 6
    public static let absolute: UInt8 = 7
}

public extension Key {
    /// USB HID keyboard usage (page 0x07).
    var hidUsage: UInt8 {
        switch self {
        case .a: 0x04; case .b: 0x05; case .c: 0x06; case .d: 0x07; case .e: 0x08; case .f: 0x09; case .g: 0x0A
        case .h: 0x0B; case .i: 0x0C; case .j: 0x0D; case .k: 0x0E; case .l: 0x0F; case .m: 0x10; case .n: 0x11
        case .o: 0x12; case .p: 0x13; case .q: 0x14; case .r: 0x15; case .s: 0x16; case .t: 0x17; case .u: 0x18
        case .v: 0x19; case .w: 0x1A; case .x: 0x1B; case .y: 0x1C; case .z: 0x1D
        case .n1: 0x1E; case .n2: 0x1F; case .n3: 0x20; case .n4: 0x21; case .n5: 0x22; case .n6: 0x23
        case .n7: 0x24; case .n8: 0x25; case .n9: 0x26; case .n0: 0x27
        case .returnKey: 0x28; case .escape: 0x29; case .delete: 0x2A; case .tab: 0x2B; case .space: 0x2C
        case .minus: 0x2D; case .equal: 0x2E; case .leftBracket: 0x2F; case .rightBracket: 0x30; case .backslash: 0x31
        case .semicolon: 0x33; case .quote: 0x34; case .grave: 0x35; case .comma: 0x36; case .period: 0x37; case .slash: 0x38
        case .f1: 0x3A; case .f2: 0x3B; case .f3: 0x3C; case .f4: 0x3D; case .f5: 0x3E; case .f6: 0x3F
        case .f7: 0x40; case .f8: 0x41; case .f9: 0x42; case .f10: 0x43; case .f11: 0x44; case .f12: 0x45
        case .home: 0x4A; case .pageUp: 0x4B; case .forwardDelete: 0x4C; case .end: 0x4D; case .pageDown: 0x4E
        case .right: 0x4F; case .left: 0x50; case .down: 0x51; case .up: 0x52
        }
    }
}

extension Mod {
    var hidBit: UInt8 {
        switch self {
        case .ctrl: 0x01
        case .shift: 0x02
        case .opt: 0x04
        case .cmd: 0x08
        case .fn: 0 // no standard HID usage
        }
    }
}

/// Turns Flick actions into HID reports for Bluetooth mode, keeping held keys/buttons in sync.
public struct HIDTranslator: Sendable {
    /// Wheel notches per point of finger travel.
    public var scrollScale: Double = 0.12
    /// Mouse counts per point of cursor travel (macOS applies its own acceleration on top).
    public var pointerScale: Double = 0.6

    private var held: [UInt8] = []
    private var buttons: UInt8 = 0
    private var carryX = 0.0, carryY = 0.0, carryWheel = 0.0

    public init() {}

    public static func bits(_ mods: [Mod]) -> UInt8 { mods.reduce(0) { $0 | $1.hidBit } }

    /// Nothing held down on purpose (no drive keys, no drag).
    public var isIdle: Bool { held.isEmpty && buttons == 0 }

    /// "All released" reports. Re-sent a beat after typing so a lost key-up can never leave a key stuck.
    public func settle() -> [HIDEvent] {
        isIdle ? [.keyboard(mods: 0, keys: []), .mouse(buttons: 0, dx: 0, dy: 0, wheel: 0)] : []
    }

    private func board(extra: [UInt8] = [], mods: UInt8 = 0) -> HIDEvent {
        .keyboard(mods: mods, keys: Array((held + extra.filter { !held.contains($0) }).prefix(6)))
    }

    private func tap(_ usage: UInt8, mods: UInt8) -> [HIDEvent] {
        [board(extra: [usage], mods: mods), board()]
    }

    /// `true` for actions that only the Mac helper can do (screen, Claude, absolute pointing, laser).
    public static func needsHelper(_ m: ClientMessage) -> Bool {
        switch m {
        case .laser, .stream, .keyframe, .ask, .askCancel: true
        default: false
        }
    }

    public mutating func translate(_ m: ClientMessage) -> [HIDEvent] {
        switch m {
        case .move(let dx, let dy):
            carryX += dx * pointerScale
            carryY += dy * pointerScale
            let ix = Int(carryX.rounded(.towardZero)), iy = Int(carryY.rounded(.towardZero))
            carryX -= Double(ix); carryY -= Double(iy)
            return ix == 0 && iy == 0 ? [] : [.mouse(buttons: buttons, dx: ix, dy: iy, wheel: 0)]
        case .button(let b, let down):
            let bit = Self.bit(b)
            buttons = down ? buttons | bit : buttons & ~bit
            return [.mouse(buttons: buttons, dx: 0, dy: 0, wheel: 0)]
        case .click(let b):
            let bit = Self.bit(b)
            return [.mouse(buttons: buttons | bit, dx: 0, dy: 0, wheel: 0), .mouse(buttons: buttons, dx: 0, dy: 0, wheel: 0)]
        case .scroll(_, let dy, let phase):
            if phase == .began || phase == .ended { return [] }
            carryWheel += dy * scrollScale
            let w = Int(carryWheel.rounded(.towardZero))
            carryWheel -= Double(w)
            return w == 0 ? [] : [.mouse(buttons: buttons, dx: 0, dy: 0, wheel: w)]
        case .zoom(let steps):
            let usage = steps > 0 ? Key.equal.hidUsage : Key.minus.hidUsage
            return (0..<min(abs(steps), 6)).flatMap { _ in tap(usage, mods: Mod.cmd.hidBit) }
        case .key(let key, let mods):
            return tap(key.hidUsage, mods: Self.bits(mods))
        case .keyState(let key, let down):
            let u = key.hidUsage
            if down { if !held.contains(u) { held.append(u) } } else { held.removeAll { $0 == u } }
            return [board()]
        case .text(let value):
            return value.flatMap { ch -> [HIDEvent] in
                guard let (u, shift) = Self.ascii(ch) else { return [] }
                return tap(u, mods: shift ? Mod.shift.hidBit : 0)
            }
        case .media(let a):
            let usage: UInt16 = switch a {
            case .playPause: 0xCD; case .next: 0xB5; case .previous: 0xB6; case .mute: 0xE2
            case .volumeUp: 0xE9; case .volumeDown: 0xEA; case .brightnessUp: 0x6F; case .brightnessDown: 0x70
            }
            return [.consumer(usage), .consumer(0)]
        case .system(let a):
            let ctrl = Mod.ctrl.hidBit, cmd = Mod.cmd.hidBit
            switch a {
            case .missionControl: return tap(Key.up.hidUsage, mods: ctrl)
            case .appWindows: return tap(Key.down.hidUsage, mods: ctrl)
            case .spaceLeft: return tap(Key.left.hidUsage, mods: ctrl)
            case .spaceRight: return tap(Key.right.hidUsage, mods: ctrl)
            case .desktop: return tap(Key.f11.hidUsage, mods: 0)
            case .spotlight: return tap(Key.space.hidUsage, mods: cmd)
            case .lock: return tap(Key.q.hidUsage, mods: ctrl | cmd)
            case .displaySleep: return [.system(0x02), .system(0)]
            case .appSwitcher:
                // ⌘ down, tab, ⌘ up: picks the previous app.
                return [.keyboard(mods: cmd, keys: held), .keyboard(mods: cmd, keys: held + [Key.tab.hidUsage]),
                        .keyboard(mods: cmd, keys: held), board()]
            }
        case .releaseAll:
            held.removeAll()
            buttons = 0
            return [board(), .mouse(buttons: 0, dx: 0, dy: 0, wheel: 0)]
        case .point(let x, let y):
            let s = { (v: Double) in UInt16(min(max(v, 0), 1) * 32767) }
            return [.absolute(buttons: buttons, x: s(x), y: s(y))]
        case .hello, .laser, .stream, .keyframe, .ask, .askCancel, .ping:
            return []
        }
    }

    static func bit(_ b: MouseButton) -> UInt8 {
        switch b { case .left: 1; case .right: 2; case .middle: 4 }
    }

    /// US layout: character → (usage, needs shift).
    public static func ascii(_ ch: Character) -> (UInt8, Bool)? {
        if let a = ch.asciiValue {
            if (0x61...0x7A).contains(a) { return (0x04 + a - 0x61, false) }
            if (0x41...0x5A).contains(a) { return (0x04 + a - 0x41, true) }
        }
        if ch == "\n" || ch == "\r" { return (Key.returnKey.hidUsage, false) }
        if ch == "\t" { return (Key.tab.hidUsage, false) }
        let plain = "1234567890 -=[]\\;'`,./"
        let shifted = "!@#$%^&*() _+{}|:\"~<>?"
        if let i = plain.firstIndex(of: ch), let k = Key.from(character: ch) { _ = i; return (k.hidUsage, false) }
        if let i = shifted.firstIndex(of: ch), ch != " " {
            let base = plain[plain.index(plain.startIndex, offsetBy: shifted.distance(from: shifted.startIndex, to: i))]
            if let k = Key.from(character: base) { return (k.hidUsage, true) }
        }
        return nil
    }
}

/// FIFO of HID reports that never drops keys or clicks, merges back-to-back pointer motion
/// (so a busy radio slows the cursor down instead of losing distance), and splits big moves
/// into the ±127 steps a HID mouse report can carry.
public struct HIDQueue: Sendable {
    private struct Item: Sendable {
        var event: HIDEvent
        var motion: Bool
    }
    private var items: [Item] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    /// The next report is plain pointer motion (safe to hold back and keep merging into).
    public var frontIsMotion: Bool { items.first?.motion ?? false }

    public mutating func push(_ e: HIDEvent) {
        // Only the newest aim matters: replace a waiting absolute position instead of queueing it.
        if case .absolute(let b, _, _) = e, let last = items.last, case .absolute(let b2, _, _) = last.event, b == b2 {
            items[items.count - 1].event = e
            return
        }
        // Only pure motion merges, and only into pure motion: a click followed by a move must stay a click.
        if case .mouse(let b, let dx, let dy, let w) = e, dx != 0 || dy != 0 || w != 0,
           let last = items.last, last.motion, case .mouse(let b2, let dx2, let dy2, let w2) = last.event, b == b2 {
            items[items.count - 1].event = .mouse(buttons: b, dx: dx + dx2, dy: dy + dy2, wheel: w + w2)
            return
        }
        var motion = false
        if case .mouse(_, let dx, let dy, let w) = e { motion = dx != 0 || dy != 0 || w != 0 }
        items.append(Item(event: e, motion: motion))
    }

    /// Next wire report: (report ID, payload).
    public mutating func pop() -> (id: UInt8, data: Data)? {
        guard !items.isEmpty else { return nil }
        let e = items[0].event
        switch e {
        case .mouse(let b, let dx, let dy, let w):
            let cx = max(-127, min(127, dx)), cy = max(-127, min(127, dy)), cw = max(-127, min(127, w))
            let rest = HIDEvent.mouse(buttons: b, dx: dx - cx, dy: dy - cy, wheel: w - cw)
            if case .mouse(_, 0, 0, 0) = rest { items.removeFirst() } else { items[0].event = rest }
            let bytes: [UInt8] = [b, UInt8(bitPattern: Int8(cx)), UInt8(bitPattern: Int8(cy)), UInt8(bitPattern: Int8(cw))]
            return (HIDReportID.mouse, Data(bytes))
        case .keyboard(let mods, let keys):
            items.removeFirst()
            var bytes = [UInt8](repeating: 0, count: 8)
            bytes[0] = mods
            for (i, k) in keys.prefix(6).enumerated() { bytes[2 + i] = k }
            return (HIDReportID.keyboard, Data(bytes))
        case .consumer(let u):
            items.removeFirst()
            return (HIDReportID.consumer, Data([UInt8(u & 0xFF), UInt8(u >> 8), 0, 0, 0]))
        case .system(let bits):
            items.removeFirst()
            return (HIDReportID.system, Data([bits]))
        case .absolute(let b, let x, let y):
            items.removeFirst()
            return (HIDReportID.absolute, Data([b, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8)]))
        }
    }

    public mutating func removeAll() { items.removeAll() }
}

/// Bluetooth has one relative mouse, so a laser aim (absolute, 0…1) becomes the motion between
/// successive aims. A gap longer than `gap` starts fresh (no jump when pointing resumes).
public struct AimRelay: Sendable {
    public var span: (width: Double, height: Double)
    public var gap: Double
    private var last: (x: Double, y: Double, t: Double)?

    public init(span: (width: Double, height: Double) = (2600, 1650), gap: Double = 0.5) {
        self.span = span; self.gap = gap
    }

    /// Motion (in points) to move from the previous aim to this one, or nil for the first aim.
    public mutating func step(x: Double, y: Double, at t: Double) -> (dx: Double, dy: Double)? {
        defer { last = (x, y, t) }
        guard let l = last, t - l.t < gap else { return nil }
        return ((x - l.x) * span.width, (y - l.y) * span.height)
    }
}
