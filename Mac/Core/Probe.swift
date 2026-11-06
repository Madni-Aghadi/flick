import AppKit

/// Test-only window (FLICK_PROBE=<file>): records what actually arrives — typed text, key codes,
/// clicks, scrolls — to a JSON file the test client reads back.
public final class Probe {
    public static let shared = Probe()
    private var window: NSWindow?
    private var view: ProbeView?

    public func open(logTo path: String) {
        DispatchQueue.main.async {
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 260),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Flick probe"
            let v = ProbeView(frame: w.contentView!.bounds, path: path)
            w.contentView = v
            w.level = .floating
            self.window = w
            self.view = v
            self.focus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { v.flush() }

        }
    }

    public func focus() {
        DispatchQueue.main.async {
            guard let w = self.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(self.view)
        }
    }

    public var frame: CGRect {
        DispatchQueue.main.sync {
            guard let w = window, let primary = NSScreen.screens.first else { return .zero }
            let f = w.frame
            return CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        }
    }
}

final class ProbeView: NSView {
    let path: String
    var text = ""
    var keys: [Int] = []
    var ups: [Int] = []
    var clicks: [String] = []
    var scrollY = 0.0

    init(frame: NSRect, path: String) {
        self.path = path
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        flush()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with e: NSEvent) {
        keys.append(Int(e.keyCode))
        if ProcessInfo.processInfo.environment["FLICK_LOG"] != nil {
            print("key", e.keyCode, (e.characters ?? "").unicodeScalars.map { String($0.value, radix: 16) }, e.modifierFlags.rawValue & 0xFFFF0000)
        }
        if e.keyCode == 51 { if !text.isEmpty { text.removeLast() } }
        else if e.modifierFlags.intersection([.command, .control]).isEmpty, let c = e.characters, e.keyCode != 36,
                c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) }) { text += c }
        if e.keyCode == 36 { text += "\n" }
        flush()
    }
    override func keyUp(with e: NSEvent) { ups.append(Int(e.keyCode)); flush() }
    override func mouseDown(with e: NSEvent) { clicks.append("left:\(e.clickCount)"); flush() }
    override func rightMouseDown(with e: NSEvent) { clicks.append("right"); flush() }
    override func scrollWheel(with e: NSEvent) { scrollY += e.scrollingDeltaY; flush() }

    func flush() {
        var frame: [Double] = []
        if let w = window, let primary = NSScreen.screens.first {
            let f = w.frame
            frame = [f.minX, primary.frame.maxY - f.maxY, f.width, f.height]
        }
        let obj: [String: Any] = ["text": text, "keys": keys, "ups": ups, "clicks": clicks, "scrollY": scrollY, "frame": frame]
        if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: URL(fileURLWithPath: path)) }
    }
}
