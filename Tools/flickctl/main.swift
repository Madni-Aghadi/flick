import Foundation
import Network
import CoreGraphics
import CoreMedia
import VideoToolbox
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import FlickKit

// A fake iPhone for end-to-end tests: pairs with the Mac app, drives it, checks what really happened.

setvbuf(stdout, nil, _IOLBF, 0)
let stateFile = ProcessInfo.processInfo.environment["FLICKCTL_FILE"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flickctl.json").path

struct Saved: Codable { var secret: String; var macID: String; var name: String; var addresses: [String]; var port: UInt16 }

final class Client: @unchecked Sendable {
    let conn: FlickConnection
    private let lock = NSLock()
    private var inbox: [ServerMessage] = []
    private(set) var video: [VideoPacket] = []
    private var ready = false
    private var closed = false

    init(endpoint: NWEndpoint, psk: Data) {
        conn = FlickConnection(endpoint: endpoint, parameters: FlickSecurity.parameters(psk: psk))
    }

    func connect(timeout: Double = 8) -> Bool {
        conn.start { [weak self] ev in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            switch ev {
            case .ready: self.ready = true
            case .frame(let f):
                if f.type == .video, let p = VideoPacket.decode(f.payload) { self.video.append(p) }
                else if let m = f.decode(ServerMessage.self) { self.inbox.append(m) }
            case .closed: self.closed = true
            }
        }
        return poll(timeout) { self.ready || self.closed } && ready
    }

    func send(_ m: ClientMessage) { conn.send(m) }

    func take(_ timeout: Double, where match: (ServerMessage) -> Bool) -> ServerMessage? {
        var found: ServerMessage?
        _ = poll(timeout) {
            if let i = self.inbox.firstIndex(where: match) { found = self.inbox.remove(at: i); return true }
            return false
        }
        return found
    }

    func videoCount() -> Int { lock.lock(); defer { lock.unlock() }; return video.count }
    func clearVideo() { lock.lock(); video.removeAll(); lock.unlock() }

    func poll(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            lock.lock(); let ok = cond(); lock.unlock()
            if ok { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return false
    }
}

func browse(_ type: String, macID: String? = nil, timeout: Double = 6) -> NWEndpoint? {
    let b = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: NWParameters())
    let lock = NSLock()
    var found: NWEndpoint?
    b.browseResultsChangedHandler = { results, _ in
        for r in results {
            if let macID, case .bonjour(let txt) = r.metadata, txt["id"] != macID { continue }
            lock.lock(); if found == nil { found = r.endpoint }; lock.unlock()
        }
    }
    b.start(queue: DispatchQueue(label: "browse"))
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        lock.lock(); let f = found; lock.unlock()
        if let f { b.cancel(); return f }
        Thread.sleep(forTimeInterval: 0.05)
    }
    b.cancel()
    return nil
}

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func hidIdleSeconds() -> Double {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    p.arguments = ["-c", "IOHIDSystem", "-d", "4"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let line = out.split(separator: "\n").first(where: { $0.contains("HIDIdleTime") }),
          let n = line.split(separator: "=").last.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) else { return 0 }
    return n / 1e9
}

func volume() -> Int? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "output volume of (get volume settings)"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    return Int(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
}

func readProbe(_ path: String) -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: path),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

/// Decodes one keyframe and writes it as PNG — proves the stream is real video, not just bytes.
func decodeKeyframe(config: VideoPacket, frame: VideoPacket, to path: String) -> (Int, Int)? {
    guard let cfg = config.parseConfig(), cfg.parameterSets.count >= 2 else { return nil }
    var fmt: CMFormatDescription?
    let sets = cfg.parameterSets
    let status: OSStatus = sets[0].withUnsafeBytes { a in
        sets[1].withUnsafeBytes { b in
            let ptrs = [a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = [sets[0].count, sets[1].count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                                                                       parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
    }
    guard status == noErr, let fmt else { return nil }
    var session: VTDecompressionSession?
    let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                       imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &session) == noErr,
          let session else { return nil }
    var block: CMBlockBuffer?
    let data = frame.body
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
    guard let block else { return nil }
    data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
    var sample: CMSampleBuffer?
    var size = data.count
    CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 0,
                              sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    guard let sample else { return nil }
    var result: (Int, Int)?
    VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in
        guard st == noErr, let image else { return }
        let ci = CIImage(cvPixelBuffer: image)
        if let cg = CIContext().createCGImage(ci, from: ci.extent),
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
            result = (cg.width, cg.height)
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    return result
}

// MARK: commands

func pair(code: String) {
    guard let ep = browse(flickPairServiceType) else { print("No Mac is in pairing mode."); exit(1) }
    let c = Client(endpoint: ep, psk: FlickSecurity.pairingKey(code: code))
    guard c.connect() else { print("Wrong code or Mac unreachable."); exit(1) }
    guard case .paired(let secret, let macID, let name, let addrs, let port)? = c.take(5, where: { if case .paired = $0 { return true }; return false }) else {
        print("No pairing reply."); exit(1)
    }
    c.send(.hello(name: "flickctl", version: flickProtocolVersion))
    Thread.sleep(forTimeInterval: 0.3)
    let saved = Saved(secret: secret, macID: macID, name: name, addresses: addrs, port: port)
    try? FileManager.default.createDirectory(atPath: (stateFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? JSONEncoder().encode(saved).write(to: URL(fileURLWithPath: stateFile))
    print("Paired with \(name) (\(addrs.joined(separator: ", ")) port \(port))")
}

func loadSaved() -> Saved {
    guard let d = FileManager.default.contents(atPath: stateFile), let s = try? JSONDecoder().decode(Saved.self, from: d) else {
        print("Not paired. Run: flickctl pair <code>"); exit(1)
    }
    return s
}

func connectSaved(host: String?) -> (Client, Saved) {
    let s = loadSaved()
    let psk = FlickSecurity.sessionKey(secret: Data(base64Encoded: s.secret)!)
    let ep: NWEndpoint
    if let host { ep = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: s.port)!) }
    else if let b = browse(flickServiceType, macID: s.macID) { ep = b }
    else { print("Mac not found on the network."); exit(1) }
    let c = Client(endpoint: ep, psk: psk)
    guard c.connect() else { print("Could not connect (\(ep))."); exit(1) }
    return (c, s)
}

func selftest(args: [String]) {
    let probe = args.firstIndex(of: "--probe").map { args[$0 + 1] }
    let host = args.firstIndex(of: "--host").map { args[$0 + 1] }
    let doAsk = args.contains("--ask")
    let (c, saved) = connectSaved(host: host)
    check("connect (\(host ?? "bonjour"))", true)

    c.send(.hello(name: "flickctl", version: flickProtocolVersion))
    let welcome = c.take(3) { if case .welcome = $0 { return true }; return false }
    if case .welcome(let name, let macID, _, let addrs, let port, let display)? = welcome {
        check("welcome", macID == saved.macID, "\(name), \(Int(display.width))×\(Int(display.height)), port \(port), \(addrs.joined(separator: " "))")
    } else { check("welcome", false) }
    if case .status(let ax, let screen)? = c.take(3, where: { if case .status = $0 { return true }; return false }) {
        check("permissions", ax, "accessibility \(ax), screen \(screen)")
    }
    if case .frontApp(let id, let name, let icon)? = c.take(3, where: { if case .frontApp = $0 { return true }; return false }) {
        check("front app", !id.isEmpty, "\(name) (\(id)), icon \(icon?.count ?? 0) B")
    } else { check("front app", false) }

    // Latency
    var rtts: [Double] = []
    for i in 0..<60 {
        let t0 = Date().timeIntervalSince1970
        c.send(.ping(t: Double(i)))
        if c.take(2, where: { $0 == .pong(t: Double(i)) }) != nil { rtts.append((Date().timeIntervalSince1970 - t0) * 1000) }
    }
    rtts.sort()
    let med = rtts.isEmpty ? 0 : rtts[rtts.count / 2], p95 = rtts.isEmpty ? 0 : rtts[min(rtts.count - 1, Int(Double(rtts.count) * 0.95))]
    check("round trip", rtts.count == 60 && p95 < 50, String(format: "median %.1f ms, p95 %.1f ms", med, p95))

    // Everything below touches the real cursor/keyboard: only when nobody is using the Mac.
    let idle = hidIdleSeconds()
    guard idle > 15 || args.contains("--force") else {
        print("SKIP  input tests — Mac in use (idle \(Int(idle)) s)")
        finishStream(c, args: args, doAsk: doAsk)
        return
    }

    let start = cursor()
    for _ in 0..<20 { c.send(.move(dx: 5, dy: 3)); Thread.sleep(forTimeInterval: 0.008) }
    Thread.sleep(forTimeInterval: 0.25)
    let moved = cursor()
    let dx = moved.x - start.x, dy = moved.y - start.y
    check("relative move", abs(dx - 100) < 3 && abs(dy - 60) < 3, String(format: "Δ %.0f, %.0f (expected 100, 60)", dx, dy))
    for _ in 0..<20 { c.send(.move(dx: -5, dy: -3)) }
    Thread.sleep(forTimeInterval: 0.2)

    // Clamped at screen edge, never off-screen.
    c.send(.move(dx: -100_000, dy: -100_000))
    Thread.sleep(forTimeInterval: 0.2)
    let corner = cursor()
    check("edge clamp", corner.x >= -1 && corner.y >= -1 && corner.x < 50 && corner.y < 50, "at \(Int(corner.x)), \(Int(corner.y))")

    c.send(.point(x: 0.5, y: 0.5))
    Thread.sleep(forTimeInterval: 0.2)
    let mid = cursor()
    let b = CGDisplayBounds(CGMainDisplayID())
    check("absolute point", abs(mid.x - b.midX) < 3 && abs(mid.y - b.midY) < 3, "at \(Int(mid.x)), \(Int(mid.y))")

    if let probe {
        let f = readProbe(probe)["frame"] as? [Double] ?? []
        if f.count == 4 {
            let target = CGPoint(x: f[0] + f[2] / 2, y: f[1] + f[3] / 2)
            let here = cursor()
            c.send(.move(dx: target.x - here.x, dy: target.y - here.y))
            Thread.sleep(forTimeInterval: 0.3)
            c.send(.click(button: .left))
            Thread.sleep(forTimeInterval: 0.6)
            c.send(.click(button: .left)); Thread.sleep(forTimeInterval: 0.05); c.send(.click(button: .left))
            Thread.sleep(forTimeInterval: 0.6)
            // Jump away, then point + click with no pause (what a tap on the screen view sends).
            c.send(.point(x: 0.9, y: 0.1))
            Thread.sleep(forTimeInterval: 0.3)
            let before = (readProbe(probe)["clicks"] as? [String] ?? []).count
            c.send(.point(x: Double(target.x - b.minX) / Double(b.width), y: Double(target.y - b.minY) / Double(b.height)))
            c.send(.click(button: .left))
            Thread.sleep(forTimeInterval: 0.6)
            let after = (readProbe(probe)["clicks"] as? [String] ?? []).count
            check("point then click", after == before + 1, "clicks \(before) → \(after)")
            c.send(.click(button: .right))
            Thread.sleep(forTimeInterval: 0.3)
            // Escape closes any context menu the right click opened.
            c.send(.key(key: .escape, mods: []))
            Thread.sleep(forTimeInterval: 0.2)
            c.send(.text(value: "Flick ✓ héllo 42"))
            c.send(.key(key: .returnKey, mods: []))
            c.send(.text(value: "ab"))
            c.send(.key(key: .delete, mods: []))
            for _ in 0..<5 { c.send(.scroll(dx: 0, dy: -20, phase: .changed)) }
            Thread.sleep(forTimeInterval: 0.6)
            let typed = readProbe(probe)["text"] as? String ?? ""
            c.send(.keyState(key: .left, down: true))
            Thread.sleep(forTimeInterval: 0.15)
            c.send(.keyState(key: .left, down: false))
            c.send(.keyState(key: .w, down: true))
            Thread.sleep(forTimeInterval: 0.8)
            let r = readProbe(probe)
            check("typing", typed == "Flick ✓ héllo 42\na", "got \(typed.debugDescription)")
            let clicks = r["clicks"] as? [String] ?? []
            check("clicks", clicks.contains("left:1") && clicks.contains("left:2") && clicks.contains("right"), clicks.joined(separator: " "))
            let sy = r["scrollY"] as? Double ?? 0
            check("scroll", abs(sy) >= 50, "Δy \(sy)")
            let keys = r["keys"] as? [Int] ?? [], ups = r["ups"] as? [Int] ?? []
            check("hold keys (drive)", keys.contains(123) && ups.contains(123) && keys.contains(13), "down \(keys.suffix(4)), up \(ups.suffix(3))")
        } else { check("probe window", false, "no frame in \(probe)") }
    }

    if let v0 = volume() {
        c.send(.media(action: v0 >= 90 ? .volumeDown : .volumeUp))
        Thread.sleep(forTimeInterval: 0.6)
        let v1 = volume() ?? v0
        c.send(.media(action: v0 >= 90 ? .volumeUp : .volumeDown))
        Thread.sleep(forTimeInterval: 0.6)
        let v2 = volume() ?? v1
        check("media keys (volume)", v1 != v0 && abs(v2 - v0) <= 1, "\(v0) → \(v1) → \(v2)")
    }

    c.send(.point(x: Double((start.x - b.minX) / b.width), y: Double((start.y - b.minY) / b.height)))
    finishStream(c, args: args, doAsk: doAsk)
    if let probe {
        // Disconnect while W is held: the Mac must release it.
        c.conn.cancel()
        Thread.sleep(forTimeInterval: 1.0)
        let ups = readProbe(probe)["ups"] as? [Int] ?? []
        check("release on disconnect", ups.contains(13), "ups \(ups.suffix(3))")
    }
}

func finishStream(_ c: Client, args: [String], doAsk: Bool) {
    c.clearVideo()
    c.send(.stream(on: true, maxWidth: 1280, fps: 30))
    let t0 = Date()
    _ = c.poll(6) { c.video.filter { !$0.isConfig }.count >= 30 }
    let elapsed = Date().timeIntervalSince(t0)
    let frames = c.video.filter { !$0.isConfig }
    let bytes = frames.reduce(0) { $0 + $1.body.count }
    if let cfg = c.video.first(where: \.isConfig), let key = frames.first(where: \.keyframe) {
        let size = decodeKeyframe(config: cfg, frame: key, to: "/tmp/flick-stream.png")
        check("screen stream", size != nil, "\(frames.count) frames in \(String(format: "%.1f", elapsed)) s, \(bytes / 1024) KB, decoded \(size.map { "\($0.0)×\($0.1)" } ?? "nothing") → /tmp/flick-stream.png")
    } else {
        check("screen stream", false, "\(c.video.count) packets")
    }
    c.send(.stream(on: false, maxWidth: 0, fps: 0))

    if doAsk {
        c.send(.ask(prompt: "Reply with exactly the word: pong"))
        let done = c.take(120) { if case .askDone = $0 { return true }; return false }
        if case .askDone(let text, let ok)? = done { check("ask Claude", ok && text.lowercased().contains("pong"), text) }
        else { check("ask Claude", false, "timed out") }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "pair" where args.count >= 2: pair(code: args[1])
case "selftest":
    selftest(args: args)
    print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
default:
    print("usage: flickctl pair <code> | selftest [--probe file] [--host ip] [--ask] [--force]")
}
