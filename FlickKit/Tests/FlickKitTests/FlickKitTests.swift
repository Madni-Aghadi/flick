import Testing
import Foundation
import Network
@testable import FlickKit

@Suite struct FramingTests {
    @Test func roundTripAcrossArbitraryChunks() {
        let msgs: [ClientMessage] = [
            .move(dx: 3.5, dy: -2), .key(key: .c, mods: [.cmd]), .text(value: "héllo 👋"),
            .scroll(dx: 0, dy: -12, phase: .changed), .ask(prompt: "open redline"), .releaseAll,
        ]
        var stream = Data()
        for m in msgs { stream.append(Frame(type: .json, payload: FlickJSON.encode(m)).encoded()) }
        let video = VideoPacket(keyframe: true, isConfig: false, pts: 123_456, body: Data(repeating: 7, count: 5000))
        stream.append(Frame(type: .video, payload: video.encoded()).encoded())

        for chunk in [1, 3, 7, 64, 4096] {
            var reader = FrameReader()
            var frames: [Frame] = []
            var i = 0
            while i < stream.count {
                frames += reader.append(stream.subdata(in: i..<min(i + chunk, stream.count)))
                i += chunk
            }
            #expect(frames.count == msgs.count + 1, "chunk \(chunk)")
            #expect(frames.prefix(msgs.count).compactMap { $0.decode(ClientMessage.self) } == msgs)
            #expect(VideoPacket.decode(frames.last!.payload) == video)
        }
    }

    @Test func garbageMarksCorrupted() {
        var reader = FrameReader()
        _ = reader.append(Data([0xFF, 0, 0, 0, 1, 0]))
        #expect(reader.corrupted)
    }

    @Test func videoConfigRoundTrip() {
        let sets = [Data([0x67, 1, 2, 3]), Data([0x68, 9])]
        let cfg = VideoPacket.config(width: 1600, height: 1000, parameterSets: sets)
        let parsed = VideoPacket.decode(cfg.encoded())!.parseConfig()!
        #expect(parsed.width == 1600)
        #expect(parsed.height == 1000)
        #expect(parsed.parameterSets == sets)
    }

    @Test func serverMessagesRoundTrip() {
        let msgs: [ServerMessage] = [
            .welcome(name: "Mac", macID: "id", version: 1, addresses: ["100.1.2.3"], port: 47321, display: DisplayInfo(width: 1512, height: 982)),
            .frontApp(bundleID: "com.google.Chrome", name: "Chrome", icon: Data([1, 2, 3])),
            .askDone(text: "done", ok: true),
        ]
        for m in msgs { #expect(FlickJSON.decode(ServerMessage.self, from: FlickJSON.encode(m)) == m) }
    }
}

@Suite struct MotionTests {
    let flat = Vec3(0, 0, -1)       // phone lying screen-up
    let upright = Vec3(0, -1, 0)    // phone standing in portrait

    @Test func stillPhoneDoesNotDrift() {
        var m = AirMouse()
        var x = 0.0, y = 0.0
        for i in 0..<600 {
            let noise = Vec3(sin(Double(i)) * 0.004, cos(Double(i) * 1.3) * 0.004, sin(Double(i) * 0.7) * 0.004)
            let d = m.step(rotationRate: noise, gravity: flat, dt: 1 / 120)
            x += d.dx; y += d.dy
        }
        #expect(x == 0 && y == 0)
    }

    @Test func yawMovesHorizontallyFlatAndUpright() {
        for g in [flat, upright] {
            var m = AirMouse()
            var x = 0.0, y = 0.0
            let up = g * -1
            for _ in 0..<60 {
                let d = m.step(rotationRate: up * 1.0, gravity: g, dt: 1 / 120)
                x += d.dx; y += d.dy
            }
            #expect(x < -200, "turning left moves cursor left (g=\(g))")
            #expect(abs(y) <= 1)
        }
    }

    @Test func pitchUpMovesCursorUp() {
        var m = AirMouse()
        var y = 0.0
        for _ in 0..<60 { y += m.step(rotationRate: Vec3(1, 0, 0), gravity: flat, dt: 1 / 120).dy }
        #expect(y < -200)
    }

    @Test func slowMotionAccumulates() {
        var m = AirMouse()
        var x = 0.0
        for _ in 0..<240 { x += m.step(rotationRate: Vec3(0, 0, 0.05), gravity: flat, dt: 1 / 120).dx }
        #expect(x < -10, "slow, deliberate motion still moves the cursor")
    }

    @Test func fastMotionGetsAcceleration() {
        func travel(_ rate: Double, seconds: Double) -> Double {
            var m = AirMouse()
            var x = 0.0
            for _ in 0..<Int(seconds * 120) { x += m.step(rotationRate: Vec3(0, 0, rate), gravity: flat, dt: 1 / 120).dx }
            return abs(x)
        }
        #expect(travel(4, seconds: 0.25) > travel(0.5, seconds: 2) * 1.3)
    }

    @Test func laserMapsAimToScreenAndClampsAtEdges() {
        for g in [Vec3(0, 0, -1), Vec3(0, -1, 0)] {
            var l = AirLaser(width: 0.8, height: 0.5)
            let up = g * -1
            var p = (x: 0.5, y: 0.5)
            for _ in 0..<240 { p = l.step(rotationRate: Vec3(0, 0, 0), gravity: g, dt: 1 / 120) }
            #expect(abs(p.x - 0.5) < 0.001 && abs(p.y - 0.5) < 0.001, "still = centre")
            // Turn right by 0.2 rad (a quarter of the width) at 1 rad/s.
            for _ in 0..<24 { p = l.step(rotationRate: up * -1.0, gravity: g, dt: 1 / 120) }
            for _ in 0..<120 { p = l.step(rotationRate: Vec3(0, 0, 0), gravity: g, dt: 1 / 120) }
            #expect(abs(p.x - 0.75) < 0.02, "aim 0.2 rad right → x 0.75 (got \(p.x))")
            // Way past the edge, then come back the same amount: clamped, so it lands left of where it started.
            for _ in 0..<240 { p = l.step(rotationRate: up * -1.0, gravity: g, dt: 1 / 120) }
            for _ in 0..<120 { p = l.step(rotationRate: Vec3(0, 0, 0), gravity: g, dt: 1 / 120) }
            #expect(p.x > 0.99)
            for _ in 0..<24 { p = l.step(rotationRate: up * 1.0, gravity: g, dt: 1 / 120) }
            for _ in 0..<120 { p = l.step(rotationRate: Vec3(0, 0, 0), gravity: g, dt: 1 / 120) }
            #expect(abs(p.x - 0.75) < 0.02, "swinging back re-aims from the edge (got \(p.x))")
        }
    }

    @Test func laserIsSteadyUnderHandTremor() {
        var l = AirLaser()
        var xs: [Double] = []
        for i in 0..<600 {
            // ~8 Hz tremor, 0.15 rad/s amplitude.
            let w = sin(Double(i) / 120 * 2 * .pi * 8) * 0.15
            xs.append(l.step(rotationRate: Vec3(0, 0, w), gravity: Vec3(0, 0, -1), dt: 1 / 120).x)
        }
        let tail = xs.suffix(300)
        let spread = (tail.max()! - tail.min()!) * 1710
        #expect(spread < 12, "tremor spread on a 1710 px screen: \(Int(spread)) px")
    }

    @Test func steeringDutyCycle() {
        var s = Steering()
        func duty(_ angle: Double) -> Double {
            var on = 0
            for _ in 0..<1200 { if s.step(angle: angle, dt: 1 / 120) != 0 { on += 1 } }
            return Double(on) / 1200
        }
        #expect(duty(0.02) == 0)
        #expect(duty(0.7) == 1)
        let half = duty(0.34)
        #expect(half > 0.3 && half < 0.7)
        #expect(s.step(angle: -0.7, dt: 1 / 120) == -1)
    }
}

@Suite struct KeyTests {
    @Test func keyCodesAreUnique() {
        let codes = Key.allCases.map(\.macKeyCode)
        #expect(Set(codes).count == codes.count)
    }

    @Test func characterLookup() {
        #expect(Key.from(character: "T") == .t)
        #expect(Key.from(character: "7") == .n7)
        #expect(Key.from(character: "/") == .slash)
        #expect(Key.from(character: "é") == nil)
    }

    @Test func catalogPicksAppSets() {
        #expect(ShortcutCatalog.shortcuts(for: "com.google.Chrome").first?.label == "New tab")
        #expect(ShortcutCatalog.shortcuts(for: "com.microsoft.VSCode").first?.label == "Commands")
        #expect(ShortcutCatalog.shortcuts(for: "com.unknown.app").first?.label == "Copy")
    }
}

/// Collects one value from callback-land with a timeout.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); if value == nil { value = v }; lock.unlock() }
    func wait(_ seconds: Double) -> T? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            lock.lock(); let v = value; lock.unlock()
            if let v { return v }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }
}

@Suite(.serialized) struct SecurityTests {
    @Test func keysDifferByCodeAndPurpose() {
        #expect(FlickSecurity.pairingKey(code: "123456") == FlickSecurity.pairingKey(code: "123456"))
        #expect(FlickSecurity.pairingKey(code: "123456") != FlickSecurity.pairingKey(code: "123457"))
        let s = FlickSecurity.randomSecret()
        #expect(s.count == 32)
        #expect(FlickSecurity.sessionKey(secret: s) != FlickSecurity.pairingKey(code: "123456"))
    }

    /// Real TLS-PSK handshake over loopback: right key exchanges frames, wrong key is refused.
    @Test func pskHandshake() throws {
        let good = FlickSecurity.pairingKey(code: "111111")
        let listener = try NWListener(using: FlickSecurity.parameters(psk: good), on: .any)
        let q = DispatchQueue(label: "test.listener")
        var serverConns: [FlickConnection] = []
        let got = Box<Bool>()
        listener.newConnectionHandler = { nw in
            let c = FlickConnection(connection: nw, queue: q)
            serverConns.append(c)
            c.start { ev in
                if case .frame(let f) = ev, f.decode(ClientMessage.self) == .ping(t: 42) {
                    c.send(ServerMessage.pong(t: 42))
                    got.set(true)
                }
            }
        }
        let ready = Box<Bool>()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.set(true) } }
        listener.start(queue: q)
        #expect(ready.wait(5) == true)
        let port = try #require(listener.port)

        let pong = Box<Bool>()
        let client = FlickConnection(endpoint: .hostPort(host: "127.0.0.1", port: port), parameters: FlickSecurity.parameters(psk: good))
        client.start { ev in
            switch ev {
            case .ready: client.send(ClientMessage.ping(t: 42))
            case .frame(let f): if f.decode(ServerMessage.self) == .pong(t: 42) { pong.set(true) }
            case .closed: break
            }
        }
        #expect(got.wait(8) == true)
        #expect(pong.wait(8) == true)

        let outcome = Box<String>()
        let bad = FlickConnection(endpoint: .hostPort(host: "127.0.0.1", port: port), parameters: FlickSecurity.parameters(psk: FlickSecurity.pairingKey(code: "999999")))
        bad.start { ev in
            switch ev {
            case .ready: outcome.set("ready")
            case .closed: outcome.set("closed")
            default: break
            }
        }
        #expect(outcome.wait(10) == "closed")
        client.cancel(); listener.cancel()
        _ = serverConns
    }
}

@Suite struct HIDTests {
    /// Replays a queue into a fake HID host and returns what it would see.
    struct Host {
        var x = 0, y = 0, wheel = 0
        var buttons: UInt8 = 0
        var pressed: [String] = []
        var typed = ""
        var media: [UInt16] = []
        var keysDown: Set<UInt8> = []
        mutating func feed(_ q: inout HIDQueue) {
            while let (id, d) = q.pop() {
                let b = [UInt8](d)
                switch id {
                case HIDReportID.mouse:
                    if b[0] & 1 != 0 && buttons & 1 == 0 { pressed.append("left@\(x),\(y)") }
                    if b[0] & 2 != 0 && buttons & 2 == 0 { pressed.append("right@\(x),\(y)") }
                    buttons = b[0]
                    x += Int(Int8(bitPattern: b[1])); y += Int(Int8(bitPattern: b[2])); wheel += Int(Int8(bitPattern: b[3]))
                case HIDReportID.keyboard:
                    let now = Set(b[2...].filter { $0 != 0 })
                    for k in now.subtracting(keysDown) {
                        let shift = b[0] & 0x02 != 0
                        if let ch = Host.char(k, shift: shift) { typed.append(ch) } else { typed.append("[\(k)]") }
                    }
                    keysDown = now
                case HIDReportID.consumer:
                    let u = UInt16(b[0]) | UInt16(b[1]) << 8
                    if u != 0 { media.append(u) }
                default: break
                }
            }
        }
        static func char(_ u: UInt8, shift: Bool) -> Character? {
            for c in "abcdefghijklmnopqrstuvwxyz0123456789 -=[]\\;'`,./" {
                if let k = Key.from(character: c), k.hidUsage == u {
                    if !shift { return c }
                    let plain = Array("abcdefghijklmnopqrstuvwxyz1234567890-=[]\\;'`,./")
                    let up = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()_+{}|:\"~<>?")
                    if let i = plain.firstIndex(of: c) { return up[i] }
                }
            }
            return u == 0x28 ? "\n" : nil
        }
    }

    @Test func typingRoundTripsThroughHID() {
        var t = HIDTranslator(), q = HIDQueue(), host = Host()
        let text = "Hello, Flick! 42 (a+b)=c? ~/path_x\n"
        for e in t.translate(.text(value: text)) { q.push(e) }
        host.feed(&q)
        #expect(host.typed == text)
        #expect(host.keysDown.isEmpty, "every key released")
    }

    @Test func repeatedLettersEachRegister() {
        var t = HIDTranslator(), q = HIDQueue(), host = Host()
        for e in t.translate(.text(value: "aaa")) { q.push(e) }
        host.feed(&q)
        #expect(host.typed == "aaa")
    }

    @Test func motionMergesButNeverLosesDistance() {
        var t = HIDTranslator(), q = HIDQueue(), host = Host()
        t.pointerScale = 1
        for _ in 0..<500 { for e in t.translate(.move(dx: 3.3, dy: -1.7)) { q.push(e) } }
        #expect(q.count == 1, "500 moves while the radio is busy collapse into one pending move")
        host.feed(&q)
        #expect(abs(host.x - 1650) <= 1 && abs(host.y + 850) <= 1, "\(host.x),\(host.y)")
    }

    @Test func clickThenMoveStaysAClickNotADrag() {
        var t = HIDTranslator(), q = HIDQueue(), host = Host()
        t.pointerScale = 1
        for e in t.translate(.move(dx: 10, dy: 0)) { q.push(e) }
        for e in t.translate(.click(button: .left)) { q.push(e) }
        for e in t.translate(.move(dx: 50, dy: 0)) { q.push(e) }
        host.feed(&q)
        #expect(host.pressed == ["left@10,0"])
        #expect(host.buttons == 0 && host.x == 60)
    }

    @Test func dragHoldsButtonWhileMoving() {
        var t = HIDTranslator(), q = HIDQueue()
        t.pointerScale = 1
        for e in t.translate(.button(button: .left, down: true)) { q.push(e) }
        for e in t.translate(.move(dx: 300, dy: 0)) { q.push(e) }
        var sawDragMove = false
        while let (id, d) = q.pop() {
            if id == HIDReportID.mouse, d[0] == 1, Int8(bitPattern: d[1]) != 0 { sawDragMove = true }
        }
        #expect(sawDragMove)
        let release = t.translate(.button(button: .left, down: false))
        #expect(release == [.mouse(buttons: 0, dx: 0, dy: 0, wheel: 0)])
    }

    @Test func heldKeysForDriving() {
        var t = HIDTranslator()
        #expect(t.translate(.keyState(key: .up, down: true)) == [.keyboard(mods: 0, keys: [0x52])])
        #expect(t.translate(.keyState(key: .left, down: true)) == [.keyboard(mods: 0, keys: [0x52, 0x50])])
        // A tap while holding keeps the held ones down.
        #expect(t.translate(.key(key: .space, mods: [])) == [.keyboard(mods: 0, keys: [0x52, 0x50, 0x2C]), .keyboard(mods: 0, keys: [0x52, 0x50])])
        #expect(t.translate(.keyState(key: .up, down: false)) == [.keyboard(mods: 0, keys: [0x50])])
        #expect(t.translate(.releaseAll).first == .keyboard(mods: 0, keys: []))
    }

    @Test func shortcutsAndMedia() {
        var t = HIDTranslator()
        #expect(t.translate(.key(key: .c, mods: [.cmd])).first == .keyboard(mods: 0x08, keys: [0x06]))
        #expect(t.translate(.system(action: .lock)).first == .keyboard(mods: 0x09, keys: [0x14]))
        #expect(t.translate(.media(action: .playPause)) == [.consumer(0xCD), .consumer(0)])
        #expect(t.translate(.point(x: 0.5, y: 1)) == [.absolute(buttons: 0, x: 16383, y: 32767)])
        #expect(HIDTranslator.needsHelper(.ask(prompt: "x")))
    }

    @Test func scrollAccumulatesIntoNotches() {
        var t = HIDTranslator(), q = HIDQueue(), host = Host()
        for _ in 0..<50 { for e in t.translate(.scroll(dx: 0, dy: 4, phase: .changed)) { q.push(e) } }
        host.feed(&q)
        #expect((23...24).contains(host.wheel), "200 pt of finger travel ≈ 24 notches (got \(host.wheel))")
    }

    @Test func settleReleasesOnlyWhenNothingIsHeld() {
        var t = HIDTranslator()
        _ = t.translate(.key(key: .f11, mods: []))
        #expect(t.settle() == [.keyboard(mods: 0, keys: []), .mouse(buttons: 0, dx: 0, dy: 0, wheel: 0)])
        _ = t.translate(.keyState(key: .up, down: true))
        #expect(t.settle().isEmpty, "never release a key the user is holding (drive)")
        _ = t.translate(.keyState(key: .up, down: false))
        _ = t.translate(.button(button: .left, down: true))
        #expect(t.settle().isEmpty, "never break a drag")
    }

    @Test func absoluteKeepsOnlyNewestAimButStaysInOrder() {
        var t = HIDTranslator(), q = HIDQueue()
        for i in 0..<50 { for e in t.translate(.point(x: Double(i) / 100, y: 0.5)) { q.push(e) } }
        for e in t.translate(.click(button: .left)) { q.push(e) }
        for e in t.translate(.point(x: 0.9, y: 0.1)) { q.push(e) }
        #expect(q.count == 4, "one aim, click down, click up, next aim")
        let (id, d) = q.pop()!
        #expect(id == HIDReportID.absolute)
        #expect(d[0] == 0)
        #expect(UInt16(d[1]) | UInt16(d[2]) << 8 == UInt16(0.49 * 32767))
        #expect(q.pop()!.id == HIDReportID.mouse)
        // While dragging, aims carry the held button so the drag isn't dropped.
        var t2 = HIDTranslator()
        _ = t2.translate(.button(button: .left, down: true))
        #expect(t2.translate(.point(x: 0, y: 0)) == [.absolute(buttons: 1, x: 0, y: 0)])
    }

    @Test func aimRelayTurnsAimIntoMotionWithoutJumps() {
        var r = AimRelay(span: (2000, 1000), gap: 0.5)
        #expect(r.step(x: 0.5, y: 0.5, at: 0) == nil, "first aim only sets the anchor")
        let d = r.step(x: 0.6, y: 0.4, at: 0.01)!
        #expect(abs(d.dx - 200) < 1e-6 && abs(d.dy + 100) < 1e-6)
        // A sweep from left edge to right edge adds up to one full span, however it's sliced.
        var r2 = AimRelay(span: (2000, 1000), gap: 0.5)
        var total = 0.0
        _ = r2.step(x: 0, y: 0.5, at: 0)
        for i in 1...120 { total += r2.step(x: Double(i) / 120, y: 0.5, at: Double(i) / 120)!.dx }
        #expect(abs(total - 2000) < 1e-6)
        // After a pause, resuming somewhere else must not yank the cursor.
        #expect(r2.step(x: 0.1, y: 0.1, at: 5) == nil)
        // And a laser aim never reaches the HID layer as an absolute report any more.
        var t = HIDTranslator()
        #expect(t.translate(.click(button: .left)).allSatisfy { if case .absolute = $0 { return false }; return true })
    }

    @Test func everyKeyHasADistinctUsage() {
        let u = Key.allCases.map(\.hidUsage)
        #expect(Set(u).count == u.count)
        #expect(!u.contains(0))
    }
}
