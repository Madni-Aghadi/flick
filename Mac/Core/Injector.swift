import AppKit
import CoreGraphics
import ApplicationServices
import FlickKit

/// Turns Flick messages into real mouse/keyboard events on this Mac.
public final class Injector {
    public static let shared = Injector()

    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<MouseButton> = []
    private var keysDown: Set<Key> = []
    private var lastClick: (button: MouseButton, time: TimeInterval, count: Int, at: CGPoint)?
    private var zoomCarry = 0

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: pointer

    public var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func displayRects() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Clamp to the nearest point that's on some display (handles gaps between screens).
    static func clamp(_ p: CGPoint, to rects: [CGRect]) -> CGPoint {
        if rects.contains(where: { $0.contains(p) }) { return p }
        var best = p, bestDist = CGFloat.infinity
        for r in rects {
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestDist { bestDist = d; best = q }
        }
        return best
    }

    /// Where we last put the cursor. Reading the real position mid-stream returns a stale value
    /// (posted events land a few ms later), which silently drops motion — so chain from our own target.
    private var lastTarget: CGPoint?
    private var lastTargetTime: TimeInterval = 0

    public func move(dx: Double, dy: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let base: CGPoint
        if let t = lastTarget, now - lastTargetTime < 0.25 { base = t } else { base = cursor }
        let target = Self.clamp(CGPoint(x: base.x + dx, y: base.y + dy), to: Self.displayRects())
        lastTarget = target
        lastTargetTime = now
        postMove(to: target, dx: dx, dy: dy)
    }

    /// Absolute position as a fraction of the main display.
    public func point(x: Double, y: Double) {
        let b = CGDisplayBounds(CGMainDisplayID())
        let target = CGPoint(x: b.minX + min(max(x, 0), 1) * (b.width - 1), y: b.minY + min(max(y, 0), 1) * (b.height - 1))
        lastTarget = target
        lastTargetTime = ProcessInfo.processInfo.systemUptime
        postMove(to: target, dx: target.x - cursor.x, dy: target.y - cursor.y)
    }

    private func postMove(to target: CGPoint, dx: Double, dy: Double) {
        let type: CGEventType
        let button: CGMouseButton
        if buttonsDown.contains(.left) { type = .leftMouseDragged; button = .left }
        else if buttonsDown.contains(.right) { type = .rightMouseDragged; button = .right }
        else if buttonsDown.contains(.middle) { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.post(tap: .cghidEventTap)
        Laser.shared.follow(target)
    }

    /// Where the pointer is from our point of view: the live position lags just-posted moves.
    private var effectiveCursor: CGPoint {
        if let t = lastTarget, ProcessInfo.processInfo.systemUptime - lastTargetTime < 0.25 { return t }
        return cursor
    }

    public func button(_ b: MouseButton, down: Bool) {
        let p = effectiveCursor
        var count = 1
        if down {
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastClick, last.button == b, now - last.time < NSEvent.doubleClickInterval,
               hypot(last.at.x - p.x, last.at.y - p.y) < 6 {
                count = last.count + 1
            }
            lastClick = (b, now, count, p)
            buttonsDown.insert(b)
        } else {
            count = lastClick?.button == b ? lastClick!.count : 1
            buttonsDown.remove(b)
        }
        let (type, cgButton): (CGEventType, CGMouseButton) = switch (b, down) {
        case (.left, true): (.leftMouseDown, .left)
        case (.left, false): (.leftMouseUp, .left)
        case (.right, true): (.rightMouseDown, .right)
        case (.right, false): (.rightMouseUp, .right)
        case (.middle, true): (.otherMouseDown, .center)
        case (.middle, false): (.otherMouseUp, .center)
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        e.post(tap: .cghidEventTap)
    }

    public func click(_ b: MouseButton) {
        button(b, down: true)
        // A real button is down for tens of ms; a 0 ms click is ignored by some controls (the menu bar).
        usleep(40_000)
        button(b, down: false)
    }

    public func scroll(dx: Double, dy: Double, phase: ScrollPhase) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // kCGScrollWheelEventScrollPhase = 99, kCGScrollWheelEventMomentumPhase = 123
        let phaseValue: Int64 = switch phase { case .began: 1; case .changed: 2; case .ended: 4; case .momentum: 0 }
        if let f = CGEventField(rawValue: 99) { e.setIntegerValueField(f, value: phaseValue) }
        if phase == .momentum, let f = CGEventField(rawValue: 123) { e.setIntegerValueField(f, value: 2) }
        e.post(tap: .cghidEventTap)
    }

    public func zoom(steps: Int) {
        let key: Key = steps > 0 ? .equal : .minus
        for _ in 0..<min(abs(steps), 6) { tap(key, mods: [.cmd]) }
    }

    // MARK: keyboard

    static func flags(_ mods: [Mod]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in mods {
            switch m {
            case .cmd: f.insert(.maskCommand)
            case .opt: f.insert(.maskAlternate)
            case .ctrl: f.insert(.maskControl)
            case .shift: f.insert(.maskShift)
            case .fn: f.insert(.maskSecondaryFn)
            }
        }
        return f
    }

    public func tap(_ key: Key, mods: [Mod]) {
        let f = Self.flags(mods)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key.macKeyCode, keyDown: down) else { continue }
            var flags = f
            if [.left, .right, .up, .down, .home, .end, .pageUp, .pageDown, .forwardDelete].contains(key) {
                flags.insert(.maskNumericPad); flags.insert(.maskSecondaryFn)
            }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    public func keyState(_ key: Key, down: Bool) {
        if down { guard keysDown.insert(key).inserted else { return } }
        else { guard keysDown.remove(key) != nil else { return } }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: key.macKeyCode, keyDown: down) else { return }
        e.flags = [.left, .right, .up, .down].contains(key) ? [.maskNumericPad, .maskSecondaryFn] : []
        e.post(tap: .cghidEventTap)
    }

    public func type(_ text: String) {
        for ch in text {
            if ch == "\n" { tap(.returnKey, mods: []); continue }
            if ch == "\t" { tap(.tab, mods: []); continue }
            let utf16 = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// Never leave a key or button stuck when a phone disconnects.
    public func releaseAll() {
        for k in keysDown { keyState(k, down: false) }
        for b in buttonsDown { button(b, down: false) }
        Laser.shared.set(on: false)
    }

    // MARK: media + system

    public func media(_ action: MediaAction) {
        // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
        let code: Int = switch action {
        case .volumeUp: 0; case .volumeDown: 1; case .brightnessUp: 2; case .brightnessDown: 3
        case .mute: 7; case .playPause: 16; case .next: 17; case .previous: 18
        }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (code << 16) | ((down ? 0xA : 0xB) << 8)
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    public func system(_ action: SystemAction) {
        switch action {
        case .missionControl: openMissionControl(nil)
        case .appWindows: openMissionControl("2")
        case .desktop: openMissionControl("1")
        case .spaceLeft: tap(.left, mods: [.ctrl])
        case .spaceRight: tap(.right, mods: [.ctrl])
        case .spotlight: tap(.space, mods: [.cmd])
        case .lock: tap(.q, mods: [.ctrl, .cmd])
        case .displaySleep: run("/usr/bin/pmset", ["displaysleepnow"])
        case .appSwitcher:
            // Hold ⌘, tap tab once; release so the switcher picks the previous app.
            keyDownRaw(0x37, true); tapRaw(0x30, flags: .maskCommand); keyDownRaw(0x37, false)
        }
    }

    private func keyDownRaw(_ code: CGKeyCode, _ down: Bool) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = down ? .maskCommand : []
        e?.post(tap: .cghidEventTap)
    }

    private func tapRaw(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    private func openMissionControl(_ arg: String?) {
        let bin = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
        run(bin, arg.map { [$0] } ?? [])
    }

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }
}
