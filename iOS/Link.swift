import Foundation
import Network
import UIKit
import Combine
import FlickKit

struct PairedMac: Codable, Equatable {
    var macID: String
    var name: String
    var addresses: [String]
    var port: UInt16
    var extraHosts: [String] = []
}

struct PairCandidate: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var endpoint: NWEndpoint
}

struct FrontAppInfo: Equatable {
    var bundleID = ""
    var name = ""
    var icon: UIImage?
}

struct AskLine: Identifiable, Equatable {
    let id = UUID()
    var kind: AskKind
    var text: String
}

/// The phone's connection to its Mac: discovery, pairing, reconnects, messages.
final class Link: ObservableObject {
    static let shared = Link()

    enum State: Equatable { case unpaired, searching, connecting, connected }

    @Published private(set) var state: State = .unpaired
    @Published private(set) var paired: PairedMac?
    @Published private(set) var candidates: [PairCandidate] = []
    @Published private(set) var frontApp = FrontAppInfo()
    @Published private(set) var canControl = true
    @Published private(set) var canSeeScreen = true
    @Published private(set) var display = DisplayInfo(width: 1512, height: 982)
    @Published var askLines: [AskLine] = []
    @Published var askAnswer: String?
    @Published var asking = false
    /// Bluetooth HID link (no Mac app needed). Mirrors Bluetooth.shared.state.
    @Published private(set) var bluetoothConnected = false

    var onVideo: ((VideoPacket) -> Void)?
    var onAnswer: ((String) -> Void)?

    private let lock = NSLock()
    private var conn: FlickConnection?
    private var browser: NWBrowser?
    private var pairBrowser: NWBrowser?
    private var fallback: DispatchWorkItem?
    private var pingTimer: Timer?
    private var lastPong = Date()
    private var attempt = 0
    private var active = false
    /// The helper connection is up (guarded by `lock`, read from any thread).
    private var helperReady = false
    private var btWatch: AnyCancellable?

    private init() {
        if ProcessInfo.processInfo.arguments.contains("-FlickResetPairing") { forget() }
        paired = Self.loadPaired()
        // Link is created on the main thread (app start), where Bluetooth lives too.
        btWatch = MainActor.assumeIsolated {
            Bluetooth.shared.$state.receive(on: RunLoop.main).sink { [weak self] s in
                self?.bluetoothConnected = s == .connected
            }
        }
    }

    /// Something can receive input: the Mac helper over the network, or a Bluetooth host.
    var isConnected: Bool { state == .connected || bluetoothConnected }
    /// The Mac helper is connected (screen view, Claude, absolute pointing).
    var helperConnected: Bool { state == .connected }

    // MARK: sending (any thread)

    /// Helper first (it can do more); otherwise straight to Bluetooth.
    func send(_ m: ClientMessage) {
        lock.lock(); let c = conn; let ready = helperReady; lock.unlock()
        if ready, let c { c.send(m); return }
        if HIDTranslator.needsHelper(m) { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { Bluetooth.shared.send(m) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { Bluetooth.shared.send(m) } }
        }
    }

    // MARK: lifecycle

    func start() {
        MainActor.assumeIsolated { Bluetooth.shared.start() }
        if active, state == .connected || state == .connecting || browser != nil { return }
        active = true
        let bluetoothOnly = ProcessInfo.processInfo.arguments.contains("-FlickBluetoothOnly")
        if !bluetoothOnly, paired != nil, Keychain.secret != nil { connect() } else { state = .unpaired }
    }

    func suspend() {
        active = false
        send(.releaseAll)
        stopAll()
    }

    private func stopAll() {
        browser?.cancel(); browser = nil
        fallback?.cancel()
        pingTimer?.invalidate(); pingTimer = nil
        lock.lock(); let c = conn; conn = nil; helperReady = false; lock.unlock()
        c?.cancel()
    }

    // MARK: connecting

    private func connect() {
        guard active, let paired, let secret = Keychain.secret else { return }
        stopAll()
        state = .searching
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: flickServiceType, domain: nil), using: Self.browseParams())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results {
                if case .bonjour(let txt) = r.metadata, txt["id"] == paired.macID {
                    DispatchQueue.main.async { self?.open(r.endpoint, secret: secret) }
                    return
                }
            }
        }
        b.start(queue: .main)
        browser = b

        // Not on the same network (or Bonjour is slow): try saved addresses — Tailscale works from anywhere.
        let work = DispatchWorkItem { [weak self] in self?.tryAddresses(secret: secret, paired: paired, index: 0) }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func tryAddresses(secret: Data, paired: PairedMac, index: Int) {
        let hosts = paired.extraHosts + paired.addresses
        guard active, state == .searching, index < hosts.count else {
            if active, state == .searching { scheduleRetry() }
            return
        }
        let port = NWEndpoint.Port(rawValue: paired.port == 0 ? flickDefaultPort : paired.port)!
        open(.hostPort(host: NWEndpoint.Host(hosts[index]), port: port), secret: secret) { [weak self] ok in
            if !ok { self?.tryAddresses(secret: secret, paired: paired, index: index + 1) }
        }
    }

    private func open(_ endpoint: NWEndpoint, secret: Data, result: ((Bool) -> Void)? = nil) {
        lock.lock(); let busy = conn != nil; lock.unlock()
        // One attempt at a time; a failed attempt schedules the next round itself.
        if busy || state == .connected { return }
        state = .connecting
        let c = FlickConnection(endpoint: endpoint, parameters: FlickSecurity.parameters(psk: FlickSecurity.sessionKey(secret: secret)))
        lock.lock(); conn = c; lock.unlock()
        var reported = false
        c.start { [weak self] ev in
            DispatchQueue.main.async {
                guard let self else { return }
                switch ev {
                case .ready:
                    reported = true
                    result?(true)
                    self.didConnect(c)
                case .frame(let f):
                    self.handle(f)
                case .closed:
                    self.lock.lock(); if self.conn === c { self.conn = nil }; self.lock.unlock()
                    if !reported { reported = true; if let result { self.state = .searching; result(false); return } }
                    self.didDisconnect()
                }
            }
        }
    }

    static let connectedNote = Notification.Name("FlickConnected")

    private func didConnect(_ c: FlickConnection) {
        browser?.cancel(); browser = nil
        fallback?.cancel()
        attempt = 0
        state = .connected
        lock.lock(); helperReady = true; lock.unlock()
        c.send(ClientMessage.hello(name: UIDevice.current.name, version: flickProtocolVersion))
        NotificationCenter.default.post(name: Self.connectedNote, object: nil)
        lastPong = Date()
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastPong) > 7 { self.dropAndRetry(); return }
            self.send(.ping(t: Date().timeIntervalSince1970))
        }
    }

    private func didDisconnect() {
        lock.lock(); helperReady = false; lock.unlock()
        pingTimer?.invalidate(); pingTimer = nil
        guard paired != nil else { return }
        if state != .unpaired { state = .searching }
        scheduleRetry()
    }

    private func dropAndRetry() {
        lock.lock(); let c = conn; conn = nil; helperReady = false; lock.unlock()
        c?.cancel()
        didDisconnect()
    }

    private func scheduleRetry() {
        guard active else { return }
        attempt += 1
        let delay = min(5.0, 0.6 * Double(attempt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.active, self.state != .connected else { return }
            self.lock.lock(); let busy = self.conn != nil; self.lock.unlock()
            if !busy { self.connect() }
        }
    }

    private func handle(_ f: Frame) {
        if f.type == .video {
            if let p = VideoPacket.decode(f.payload) { onVideo?(p) }
            return
        }
        guard let m = f.decode(ServerMessage.self) else { return }
        switch m {
        case .welcome(let name, let macID, _, let addresses, let port, let display):
            self.display = display
            if var p = paired, p.macID == macID {
                p.name = name; p.addresses = addresses; p.port = port
                paired = p
                Self.savePaired(p)
            }
        case .frontApp(let id, let name, let icon):
            frontApp = FrontAppInfo(bundleID: id, name: name, icon: icon.flatMap { UIImage(data: $0) })
        case .status(let ax, let screen):
            canControl = ax; canSeeScreen = screen
        case .askEvent(let kind, let text):
            if kind == .status { return }
            askLines.append(AskLine(kind: kind, text: text))
        case .askDone(let text, _):
            asking = false
            askAnswer = text
            onAnswer?(text)
        case .pong:
            lastPong = Date()
        case .paired:
            break
        }
    }

    // MARK: asking Claude

    func ask(_ prompt: String) {
        askLines = []
        askAnswer = nil
        guard helperConnected else { asking = false; return }   // Bluetooth alone can't reach Claude
        asking = true
        send(.ask(prompt: prompt))
    }

    func cancelAsk() {
        send(.askCancel)
        asking = false
    }

    // MARK: pairing

    func browsePairing() {
        pairBrowser?.cancel()
        let b = NWBrowser(for: .bonjour(type: flickPairServiceType, domain: nil), using: Self.browseParams())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list: [PairCandidate] = results.compactMap {
                guard case .service(let name, _, _, _) = $0.endpoint else { return nil }
                return PairCandidate(name: name, endpoint: $0.endpoint)
            }
            DispatchQueue.main.async { self?.candidates = list.sorted { $0.name < $1.name } }
        }
        b.start(queue: .main)
        pairBrowser = b
    }

    /// The phone never hears a PSK rejection (Network.framework silently re-attempts), so a wrong code and a
    /// stalled handshake look the same: no answer. A right code answers in ~10 ms on the LAN, so each attempt
    /// gets 3 s and one fresh retry (a first pairing was seen to stall); a wrong code fails in about 6 s.
    func pair(with candidate: PairCandidate, code: String, retries: Int = 1, done: @escaping (Bool) -> Void) {
        let params = FlickSecurity.parameters(psk: FlickSecurity.pairingKey(code: code))
        // Pairing is always on the local network: one IPv4 attempt, so a wrong code fails at once instead of
        // after racing every IPv6 address the Mac advertises.
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = FlickConnection(endpoint: candidate.endpoint, parameters: params)
        var finished = false
        func finish(_ ok: Bool, stalled: Bool = false) {
            guard !finished else { return }
            finished = true
            if !ok, stalled, retries > 0 {
                c.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.pair(with: candidate, code: code, retries: retries - 1, done: done)
                }
                return
            }
            done(ok)
        }
        c.start { [weak self] ev in
            DispatchQueue.main.async {
                guard let self else { return }
                switch ev {
                case .frame(let f):
                    if case .paired(let secret, let macID, let name, let addrs, let port)? = f.decode(ServerMessage.self),
                       let data = Data(base64Encoded: secret) {
                        c.send(ClientMessage.hello(name: UIDevice.current.name, version: flickProtocolVersion))
                        Keychain.secret = data
                        let p = PairedMac(macID: macID, name: name, addresses: addrs, port: port)
                        Self.savePaired(p)
                        self.paired = p
                        self.pairBrowser?.cancel(); self.pairBrowser = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            c.cancel()
                            self.connect()
                        }
                        finish(true)
                    }
                case .closed:
                    finish(false)
                case .ready:
                    break
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if !finished { c.cancel(); finish(false, stalled: true) } }
    }

    func forget() {
        stopAll()
        Keychain.secret = nil
        UserDefaults.standard.removeObject(forKey: "pairedMac")
        paired = nil
        state = .unpaired
        browsePairing()
    }

    func setExtraHost(_ host: String) {
        guard var p = paired else { return }
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        p.extraHosts = h.isEmpty ? [] : [h]
        paired = p
        Self.savePaired(p)
    }

    // MARK: storage

    private static func browseParams() -> NWParameters {
        let p = NWParameters()
        p.includePeerToPeer = true
        return p
    }

    private static func loadPaired() -> PairedMac? {
        guard let d = UserDefaults.standard.data(forKey: "pairedMac") else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: d)
    }

    private static func savePaired(_ p: PairedMac) {
        UserDefaults.standard.set(try? JSONEncoder().encode(p), forKey: "pairedMac")
    }

    /// For App Intents: connect, send, hang up — without the UI.
    static func oneShot(_ messages: [ClientMessage]) async -> Bool {
        guard let p = loadPaired(), let secret = Keychain.secret else { return false }
        let psk = FlickSecurity.sessionKey(secret: secret)
        let port = NWEndpoint.Port(rawValue: p.port == 0 ? flickDefaultPort : p.port)!
        var endpoints: [NWEndpoint] = (p.extraHosts + p.addresses).map { .hostPort(host: NWEndpoint.Host($0), port: port) }
        if let bonjour = await findBonjour(macID: p.macID) { endpoints.insert(bonjour, at: 0) }
        for ep in endpoints {
            if await sendOnce(to: ep, psk: psk, messages) { return true }
        }
        return false
    }

    private static func findBonjour(macID: String) async -> NWEndpoint? {
        await withCheckedContinuation { cont in
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: flickServiceType, domain: nil), using: browseParams())
            var done = false
            let q = DispatchQueue(label: "flick.oneshot")
            func finish(_ ep: NWEndpoint?) { if !done { done = true; b.cancel(); cont.resume(returning: ep) } }
            b.browseResultsChangedHandler = { results, _ in
                if let r = results.first(where: { if case .bonjour(let t) = $0.metadata { return t["id"] == macID }; return false }) {
                    q.async { finish(r.endpoint) }
                }
            }
            b.start(queue: q)
            q.asyncAfter(deadline: .now() + 2) { finish(nil) }
        }
    }

    private static func sendOnce(to ep: NWEndpoint, psk: Data, _ messages: [ClientMessage]) async -> Bool {
        let name = await MainActor.run { UIDevice.current.name }
        return await withCheckedContinuation { cont in
            let c = FlickConnection(endpoint: ep, parameters: FlickSecurity.parameters(psk: psk))
            var done = false
            let q = c.queue
            func finish(_ ok: Bool) { if !done { done = true; cont.resume(returning: ok) } }
            c.start { ev in
                switch ev {
                case .ready:
                    c.send(ClientMessage.hello(name: name, version: flickProtocolVersion))
                    for m in messages { c.send(m) }
                    q.asyncAfter(deadline: .now() + 0.4) { c.cancel(); finish(true) }
                case .closed: finish(false)
                case .frame: break
                }
            }
            q.asyncAfter(deadline: .now() + 4) { c.cancel(); finish(false) }
        }
    }
}

enum Keychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "flick") + ".secret"

    static var secret: Data? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            guard let newValue else { return }
            var add = base
            add[kSecValueData as String] = newValue
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
