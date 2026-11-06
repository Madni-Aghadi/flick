import Foundation
import Network
import CoreGraphics
import FlickKit

public final class Session {
    let conn: FlickConnection
    public internal(set) var name = "iPhone"
    var wantsVideo = false
    var asking = false
    /// What this phone is holding down, so its disconnect can't leave anything stuck.
    var heldKeys: Set<Key> = []
    var heldButtons: Set<MouseButton> = []

    init(conn: FlickConnection) { self.conn = conn }
}

/// Bonjour-advertised TLS-PSK listener for paired phones, plus a short-lived pairing listener.
public final class Server {
    public static let shared = Server()

    /// Fires on the main queue whenever sessions or pairing state change.
    public var onChange: (() -> Void)?
    public private(set) var sessions: [Session] = []
    public private(set) var pairingCode: String?
    public private(set) var lastPairedName: String?
    public private(set) var port: UInt16 = 0

    let queue = DispatchQueue(label: "flick.server")
    private var main: NWListener?
    private var pair: NWListener?
    private var pairTimeout: DispatchWorkItem?
    private let injector = Injector.shared
    private let streamer = ScreenStreamer.shared
    private let claude = ClaudeRunner.shared

    public var connectedNames: [String] { queue.sync { sessions.map(\.name) } }

    public func start() {
        queue.async { self.startMain() }
        streamer.onPacket = { [weak self] packet in
            guard let self else { return }
            self.queue.async {
                for s in self.sessions where s.wantsVideo { s.conn.sendVideo(packet) }
            }
        }
        streamer.shouldDrop = { [weak self] in
            guard let self else { return true }
            return self.queue.sync { self.sessions.filter(\.wantsVideo).contains { $0.conn.pendingVideo > 2 } }
        }
        claude.onEvent = { [weak self] msg in
            guard let self else { return }
            self.queue.async { for s in self.sessions where s.asking { s.conn.send(msg) } }
        }
        FrontApp.shared.onChange = { [weak self] msg in
            guard let self else { return }
            self.queue.async { for s in self.sessions { s.conn.send(msg) } }
        }
        FrontApp.shared.start()
    }

    private func changed() { DispatchQueue.main.async { self.onChange?() } }

    private func service(type: String) -> NWListener.Service {
        NWListener.Service(name: Store.shared.macName, type: type, domain: nil,
                           txtRecord: NWTXTRecord(["id": Store.shared.macID, "v": "\(flickProtocolVersion)"]))
    }

    /// The usual port first (so saved addresses keep working); any free port if it's taken.
    private func startMain(fixedPort: Bool = true) {
        main?.cancel()
        let params = FlickSecurity.parameters(psk: FlickSecurity.sessionKey(secret: Store.shared.secret))
        let fixed = NWEndpoint.Port(rawValue: flickDefaultPort)!
        let listener = fixedPort ? (try? NWListener(using: params, on: fixed)) ?? (try? NWListener(using: params)) : (try? NWListener(using: params))
        guard let listener else { return }
        listener.service = service(type: flickServiceType)
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener.port?.rawValue ?? 0
                self.changed()
            case .failed:
                // Port taken (another copy running) or network change: retry on any port.
                self.queue.asyncAfter(deadline: .now() + 1) { self.startMain(fixedPort: false) }
            default: break
            }
        }
        listener.start(queue: queue)
        main = listener
    }

    private func accept(_ nw: NWConnection) {
        let s = Session(conn: FlickConnection(connection: nw, queue: queue))
        sessions.append(s)
        s.conn.start { [weak self, weak s] ev in
            guard let self, let s else { return }
            switch ev {
            case .ready:
                self.changed()
            case .frame(let f):
                if let m = f.decode(ClientMessage.self) { self.handle(m, from: s) }
            case .closed:
                self.drop(s)
            }
        }
    }

    private func drop(_ s: Session) {
        sessions.removeAll { $0 === s }
        if Self.dryRun == nil {
            for k in s.heldKeys { injector.keyState(k, down: false) }
            for b in s.heldButtons { injector.button(b, down: false) }
            if sessions.isEmpty { injector.releaseAll() }
        }
        if !sessions.contains(where: \.wantsVideo) { streamer.stop() }
        changed()
    }

    func welcome() -> ServerMessage {
        let b = CGDisplayBounds(CGMainDisplayID())
        return .welcome(name: Store.shared.macName, macID: Store.shared.macID, version: flickProtocolVersion,
                        addresses: Addresses.current(), port: port, display: DisplayInfo(width: b.width, height: b.height))
    }

    func status() -> ServerMessage {
        .status(accessibility: Self.dryRun != nil || injector.isTrusted, screen: ScreenStreamer.hasPermission)
    }

    static let logging = ProcessInfo.processInfo.environment["FLICK_LOG"] != nil

    /// FLICK_DRY_RUN=<file>: records every command to the file and never touches this Mac (no input, laser
    /// overlay, screen capture or Claude), so the phone app can run end to end against it at any time.
    static let dryRun: FileHandle? = ProcessInfo.processInfo.environment["FLICK_DRY_RUN"].flatMap {
        FileManager.default.createFile(atPath: $0, contents: nil)
        return FileHandle(forWritingAtPath: $0)
    }

    /// Dry run: record the command, answer the ones the phone waits on. True when handled.
    private func dryRun(_ m: ClientMessage, from s: Session) -> Bool {
        guard let log = Self.dryRun else { return false }
        switch m {
        case .hello, .ping: return false
        case .ask(let prompt): s.conn.send(ServerMessage.askDone(text: "dry run: \(prompt)", ok: true))
        case .stream(let on, _, _): if on { s.conn.send(ServerMessage.status(accessibility: true, screen: false)) }
        default: break
        }
        log.write(Data("\(m)\n".utf8))
        return true
    }

    private func handle(_ m: ClientMessage, from s: Session) {
        if Self.logging, !{ if case .ping = m { return true }; if case .move = m { return true }; return false }() { print("rx", m) }
        if dryRun(m, from: s) { return }
        switch m {
        case .hello(let name, _):
            s.name = name
            s.conn.send(welcome())
            s.conn.send(status())
            if let app = FrontApp.shared.current() { s.conn.send(app) }
            changed()
        case .move(let dx, let dy): injector.move(dx: dx, dy: dy)
        case .point(let x, let y): injector.point(x: x, y: y)
        case .button(let b, let down):
            if down { s.heldButtons.insert(b) } else { s.heldButtons.remove(b) }
            injector.button(b, down: down)
        case .click(let b): injector.click(b)
        case .scroll(let dx, let dy, let phase): injector.scroll(dx: dx, dy: dy, phase: phase)
        case .zoom(let steps): injector.zoom(steps: steps)
        case .key(let key, let mods): injector.tap(key, mods: mods)
        case .keyState(let key, let down):
            if down { s.heldKeys.insert(key) } else { s.heldKeys.remove(key) }
            injector.keyState(key, down: down)
        case .text(let value): injector.type(value)
        case .media(let a): injector.media(a)
        case .system(let a): injector.system(a)
        case .laser(let on): Laser.shared.set(on: on)
        case .stream(let on, let maxWidth, let fps):
            s.wantsVideo = on
            if on {
                if !ScreenStreamer.hasPermission { ScreenStreamer.requestPermission() }
                streamer.start(maxWidth: maxWidth, fps: fps) { [weak self] ok in
                    self?.queue.async { s.conn.send(self?.status() ?? .status(accessibility: false, screen: ok)) }
                }
            } else if !sessions.contains(where: \.wantsVideo) {
                streamer.stop()
            }
        case .keyframe: streamer.requestKeyframe()
        case .ask(let prompt):
            for other in sessions { other.asking = false }
            s.asking = true
            claude.ask(prompt)
        case .askCancel: claude.cancel()
        case .ping(let t): s.conn.send(ServerMessage.pong(t: t))
        case .releaseAll:
            for k in s.heldKeys { injector.keyState(k, down: false) }
            for b in s.heldButtons { injector.button(b, down: false) }
            s.heldKeys = []; s.heldButtons = []
        }
    }

    // MARK: pairing

    public func beginPairing(code: String? = nil, timeout: TimeInterval = 180) {
        queue.async {
            self.pair?.cancel()
            let code = code ?? FlickSecurity.randomCode()
            let params = FlickSecurity.parameters(psk: FlickSecurity.pairingKey(code: code))
            guard let listener = try? NWListener(using: params) else { return }
            listener.service = self.service(type: flickPairServiceType)
            listener.newConnectionHandler = { [weak self] nw in self?.acceptPairing(nw) }
            listener.start(queue: self.queue)
            self.pair = listener
            self.pairingCode = code
            self.pairTimeout?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.endPairingNow() }
            self.pairTimeout = work
            self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
            self.changed()
        }
    }

    public func endPairing() { queue.async { self.endPairingNow() } }

    private func endPairingNow() {
        pair?.cancel()
        pair = nil
        pairingCode = nil
        pairTimeout?.cancel()
        changed()
    }

    private var pairingConns: [FlickConnection] = []

    private func acceptPairing(_ nw: NWConnection) {
        let c = FlickConnection(connection: nw, queue: queue)
        if Self.logging { print("pair: incoming", nw.endpoint, Date().timeIntervalSince1970) }
        pairingConns.append(c)
        c.start { [weak self, weak c] ev in
            guard let self, let c else { return }
            switch ev {
            case .ready:
                if Self.logging { print("pair: ready", Date().timeIntervalSince1970) }
                c.send(ServerMessage.paired(secret: Store.shared.secret.base64EncodedString(), macID: Store.shared.macID,
                                            name: Store.shared.macName, addresses: Addresses.current(), port: self.port))
            case .frame(let f):
                if case .hello(let name, _)? = f.decode(ClientMessage.self) {
                    self.lastPairedName = name
                    self.endPairingNow()
                }
            case .closed:
                if Self.logging { print("pair: closed", Date().timeIntervalSince1970) }
                self.pairingConns.removeAll { $0 === c }
            }
        }
    }

    /// Forget every phone: new secret, drop sessions, restart the listener.
    public func unpairAll() {
        queue.async {
            Store.shared.rotateSecret()
            for s in self.sessions { s.conn.cancel() }
            self.startMain()
            self.changed()
        }
    }
}
