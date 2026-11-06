import BTHIDKit
import Combine
import CoreBluetooth
import Foundation
import FlickKit

/// The phone as a Bluetooth keyboard + mouse. Works with any Mac (or TV, iPad, PC) with nothing installed there.
///
/// Two ways in: a Mac on the same Apple Account never lists the iPhone in its Bluetooth settings,
/// so Flick connects *to* it from the phone (scan, tap); the Mac then finds the HID service on that
/// link and uses it. Anything else pairs the usual way from its own Bluetooth settings.
@MainActor
final class Bluetooth: ObservableObject {
    static let shared = Bluetooth()

    enum State: Equatable { case off, unauthorized, waiting, connecting, connected }

    struct Nearby: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        var symbol: String {
            let n = name.lowercased()
            if n.contains("ipad") { return "ipad" }
            if n.contains("tv") { return "tv" }
            if n.contains("imac") { return "desktopcomputer" }
            if n.contains("mac") || n.contains("laptop") || n.contains("book") { return "laptopcomputer" }
            return "dot.radiowaves.left.and.right"
        }
        var looksLikeComputer: Bool { symbol == "laptopcomputer" || symbol == "desktopcomputer" }
    }

    @Published private(set) var state: State = .waiting
    @Published private(set) var nearby: [Nearby] = []
    @Published private(set) var target: UUID?

    let peripheral = HIDPeripheral(profile: FlickHIDProfile())
    let central = HIDCentral()
    private var translator = HIDTranslator()
    private var queue = HIDQueue()
    private var bag: Set<AnyCancellable> = []
    private var started = false
    private var peripheralStarted = false
    private var wantsScan = false
    private static let lastHostKey = "lastBluetoothHost"

    var isConnected: Bool { state == .connected }

    private init() {
        peripheral.onReadyToSend = { [weak self] in self?.pump() }
        peripheral.$state.combineLatest(peripheral.$subscribedCentrals, central.$connecting, central.$connected)
            .receive(on: RunLoop.main)
            .sink { [weak self] cb, subscribed, connecting, linked in
                self?.update(cb: cb, subscribed: !subscribed.isEmpty, linking: !connecting.isEmpty || !linked.isEmpty)
            }
            .store(in: &bag)
        central.$discovered
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                let named = list.filter { $0.isNamed && $0.isConnectable != false && ($0.rssi == 0 || $0.rssi > -85) }
                    .map { Nearby(id: $0.id, name: $0.name, rssi: $0.rssi) }
                // Computers first, then by signal.
                self?.nearby = named.sorted {
                    if $0.looksLikeComputer != $1.looksLikeComputer { return $0.looksLikeComputer }
                    return $0.rssi > $1.rssi
                }
            }
            .store(in: &bag)
        // Advertise only after the central side is up (it registers for connection events first).
        central.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] s in
                guard let self, s == .poweredOn else { return }
                self.startPeripheral()
                self.reconnectLast()
                if self.wantsScan { self.beginScan() }
            }
            .store(in: &bag)
    }

    private func update(cb: CBManagerState, subscribed: Bool, linking: Bool) {
        let next: State
        switch cb {
        case .poweredOff: next = .off
        case .unauthorized: next = .unauthorized
        default: next = subscribed ? .connected : (linking ? .connecting : .waiting)
        }
        guard next != state else { return }
        if next != .connected { queue.removeAll() }
        if next == .connected {
            central.stopScan()
            if let t = target { UserDefaults.standard.set(t.uuidString, forKey: Self.lastHostKey) }
        }
        state = next
    }

    func start() {
        guard !started else { return }
        started = true
        UserDefaults.standard.register(defaults: [HIDSettings.forceServiceChangedKey: true])
        central.start()
        // Fallback if the central never reports (e.g. no Bluetooth permission yet).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startPeripheral() }
    }

    private func startPeripheral() {
        guard !peripheralStarted else { return }
        peripheralStarted = true
        peripheral.start()
    }

    // MARK: finding a host

    /// Scan now, or as soon as Bluetooth is up.
    func scan() {
        wantsScan = true
        if central.state == .poweredOn { beginScan() } else { start() }
    }

    private func beginScan() {
        guard state != .connected else { return }
        // Macs on the same Apple Account are often already linked to the phone and don't show up in a scan.
        central.refreshKnownPeripherals(servicesFilter: [CBUUID(string: "180A"), CBUUID(string: "D0611E78-BBB4-4591-A5F8-487910AE4366")])
        central.startScan()
    }

    func stopScan() {
        wantsScan = false
        central.stopScan()
    }

    func connect(_ id: UUID) {
        target = id
        central.connect(id)
    }

    private func reconnectLast() {
        guard state != .connected, let s = UserDefaults.standard.string(forKey: Self.lastHostKey), let id = UUID(uuidString: s) else { return }
        target = id
        central.connect(id)
    }

    func forgetHost() {
        UserDefaults.standard.removeObject(forKey: Self.lastHostKey)
        if let t = target { central.disconnect(t) }
        target = nil
    }

    // MARK: sending

    func setPointerScale(_ s: Double) { translator.pointerScale = s }

    private var settleWork: DispatchWorkItem?
    /// Laser aim → relative motion on the one mouse (≈ one screen per full aim with macOS acceleration).
    private var aim = AimRelay()

    func send(_ m: ClientMessage) {
        guard isConnected else { return }
        // A click that's down and up in the same instant is ignored by parts of macOS (the menu bar);
        // hold it like a real mouse button.
        if case .click(let b) = m {
            send(.button(button: b, down: true))
            releaseWhenSent(b, tries: 0)
            return
        }
        // Laser aim over Bluetooth: turn aim changes into relative motion on the one mouse.
        if case .point(let x, let y) = m {
            if let d = aim.step(x: x, y: y, at: ProcessInfo.processInfo.systemUptime) { send(.move(dx: d.dx, dy: d.dy)) }
            return
        }
        for e in translator.translate(m) { queue.push(e) }
        pump()
        switch m {
        case .key, .text, .system, .zoom, .click, .button, .media, .keyState:
            settleWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                for e in self.translator.settle() { self.queue.push(e) }
                self.pump()
            }
            settleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        default:
            break
        }
    }

    /// Start the 60 ms hold only once the press has actually left the radio; when it's busy
    /// with motion, a fixed timer let press and release arrive together (a 1 ms click).
    private func releaseWhenSent(_ b: MouseButton, tries: Int) {
        if (queue.isEmpty && peripheral.canSend) || tries > 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.send(.button(button: b, down: false)) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.releaseWhenSent(b, tries: tries + 1) }
        }
    }

    /// Motion goes out at most every `motionInterval`; meanwhile new motion merges into the waiting
    /// report, so nothing is lost but the radio never backs up. Clicks and keys go straight out —
    /// with a backed-up radio a press and its release landed on the Mac together (a 1 ms click).
    private static let motionInterval: TimeInterval = 0.016
    private var lastMotionSent: TimeInterval = 0
    private var pumpScheduled = false

    private func pump() {
        while peripheral.canSend, !queue.isEmpty {
            if queue.frontIsMotion {
                let wait = lastMotionSent + Self.motionInterval - ProcessInfo.processInfo.systemUptime
                if wait > 0 {
                    if !pumpScheduled {
                        pumpScheduled = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                            self?.pumpScheduled = false
                            self?.pump()
                        }
                    }
                    return
                }
                lastMotionSent = ProcessInfo.processInfo.systemUptime
            }
            guard let (id, data) = queue.pop() else { return }
            peripheral.send(id, data)
        }
    }
}
