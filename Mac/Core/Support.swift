import AppKit
import IOKit.pwr_mgt
import FlickKit

/// Persistent identity: Mac ID + the secret paired phones use. Lives in a 0600 file so
/// rebuilds with a different signature never trigger Keychain prompts.
public final class Store {
    public static let shared = Store()

    public let dir: URL
    public private(set) var macID: String
    public private(set) var secret: Data

    init() {
        let base = ProcessInfo.processInfo.environment["FLICK_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Flick")
        dir = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = base.appendingPathComponent("identity.json")
        if let data = try? Data(contentsOf: file),
           let obj = try? JSONDecoder().decode([String: String].self, from: data),
           let id = obj["macID"], let s = obj["secret"].flatMap({ Data(base64Encoded: $0) }) {
            macID = id; secret = s
        } else {
            macID = UUID().uuidString
            secret = FlickSecurity.randomSecret()
            save()
        }
    }

    private func save() {
        let file = dir.appendingPathComponent("identity.json")
        let obj = ["macID": macID, "secret": secret.base64EncodedString()]
        try? JSONEncoder().encode(obj).write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }

    /// Forget every paired phone.
    public func rotateSecret() {
        secret = FlickSecurity.randomSecret()
        save()
    }

    /// FLICK_NAME overrides the advertised name (demos, screenshots).
    public var macName: String { ProcessInfo.processInfo.environment["FLICK_NAME"] ?? Host.current().localizedName ?? "Mac" }
}

public enum Addresses {
    /// IPv4 addresses phones can try when Bonjour can't see us (other networks, Tailscale).
    public static func current() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            out.append(ip)
        }
        // Tailscale (100.64.0.0/10) first: it works from anywhere.
        return out.sorted { isTailscale($0) && !isTailscale($1) }
    }

    public static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}

/// Keeps the Mac from idling to sleep while you're away.
public final class Power {
    public static let shared = Power()
    private var assertion: IOPMAssertionID = 0

    public var keepAwake: Bool {
        get { assertion != 0 }
        set {
            if newValue, assertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Flick remote access" as CFString, &assertion)
            } else if !newValue, assertion != 0 {
                IOPMAssertionRelease(assertion)
                assertion = 0
            }
            UserDefaults.standard.set(newValue, forKey: "keepAwake")
        }
    }

    public func restore() {
        if UserDefaults.standard.bool(forKey: "keepAwake") { keepAwake = true }
    }
}

/// Reports the frontmost app so the phone can show matching shortcuts.
public final class FrontApp {
    public static let shared = FrontApp()
    public var onChange: ((ServerMessage) -> Void)?
    private var token: NSObjectProtocol?

    public func start() {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
            if let m = self.current() { self.onChange?(m) }
        }
        _ = current()
    }

    private var lastOther: NSRunningApplication?

    /// The app you're working in. Flick's own panel/windows don't count.
    public func current() -> ServerMessage? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me { lastOther = front }
        guard let app = lastOther else { return nil }
        let id = app.bundleIdentifier ?? ""
        return .frontApp(bundleID: id, name: app.localizedName ?? id, icon: Self.iconPNG(app.icon))
    }

    static func iconPNG(_ image: NSImage?) -> Data? {
        guard let image else { return nil }
        let size = NSSize(width: 64, height: 64)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Orange presenter dot that follows the cursor. Click-through, above everything.
public final class Laser {
    public static let shared = Laser()
    private var window: NSWindow?
    private var on = false

    public func set(on: Bool) {
        DispatchQueue.main.async {
            self.on = on
            if on { self.show() } else { self.window?.orderOut(nil) }
        }
    }

    public func follow(_ p: CGPoint) {
        guard on else { return }
        DispatchQueue.main.async { self.place(at: p) }
    }

    private func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 44, height: 44), styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .screenSaver
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = NSView(frame: w.contentView!.bounds)
            v.wantsLayer = true
            let glow = CALayer()
            glow.frame = v.bounds
            glow.cornerRadius = 22
            glow.backgroundColor = NSColor(red: 1, green: 0.42, blue: 0, alpha: 0.28).cgColor
            let dot = CALayer()
            dot.frame = v.bounds.insetBy(dx: 13, dy: 13)
            dot.cornerRadius = dot.frame.width / 2
            dot.backgroundColor = NSColor(red: 1, green: 0.42, blue: 0, alpha: 1).cgColor
            v.layer?.addSublayer(glow)
            v.layer?.addSublayer(dot)
            w.contentView = v
            window = w
        }
        place(at: CGEvent(source: nil)?.location ?? .zero)
        window?.orderFrontRegardless()
    }

    private func place(at p: CGPoint) {
        guard let w = window, let primary = NSScreen.screens.first else { return }
        // CG coordinates are top-left based; AppKit's are bottom-left of the primary screen.
        let y = primary.frame.maxY - p.y
        w.setFrameOrigin(NSPoint(x: p.x - 22, y: y - 22))
    }
}
