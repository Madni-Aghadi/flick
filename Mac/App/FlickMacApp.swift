import SwiftUI
import AppKit
import ServiceManagement
import FlickKit
import FlickMacCore

@main
struct FlickMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = MacModel.shared

    /// Tests run the helper with FLICK_HEADLESS=1: no menu bar item, nothing on screen.
    @State private var showInMenuBar = ProcessInfo.processInfo.environment["FLICK_HEADLESS"] == nil

    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuPanel()
                .environmentObject(model)
        } label: {
            Image(systemName: model.connected ? "cursorarrow.rays" : "cursorarrow")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let env = ProcessInfo.processInfo.environment
        if env["FLICK_LOG"] != nil { setvbuf(stdout, nil, _IOLBF, 0) }
        if let dir = env["FLICK_RENDER"] { renderPanels(to: dir); exit(0) }
        Power.shared.restore()
        Server.shared.start()
        if !Injector.shared.isTrusted, env["FLICK_NO_PROMPT"] == nil { Injector.shared.requestTrust() }
        if let code = env["FLICK_PAIR_CODE"] { Server.shared.beginPairing(code: code, timeout: 3600) }
        if let probe = env["FLICK_PROBE"] { Probe.shared.open(logTo: probe) }
        MacModel.shared.refresh()
    }
}

final class MacModel: ObservableObject {
    static let shared = MacModel()

    @Published var phones: [String] = []
    @Published var code: String?
    @Published var trusted = true
    @Published var screen = true
    @Published var keepAwake = Power.shared.keepAwake
    @Published var claudeFull = ClaudeRunner.shared.fullAccess
    @Published var atLogin = SMAppService.mainApp.status == .enabled
    @Published var justPaired: String?

    var connected: Bool { !phones.isEmpty }
    private var timer: Timer?

    init() {
        Server.shared.onChange = { [weak self] in self?.refresh() }
        // Permissions can flip in System Settings at any time.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPermissions() }
    }

    func refresh() {
        let wasPairing = code != nil
        phones = Server.shared.connectedNames
        code = Server.shared.pairingCode
        if wasPairing, code == nil, let name = Server.shared.lastPairedName { justPaired = name }
        refreshPermissions()
    }

    func refreshPermissions() {
        let t = Injector.shared.isTrusted, s = ScreenStreamer.hasPermission
        if t != trusted { trusted = t }
        if s != screen { screen = s }
    }

    func setKeepAwake(_ on: Bool) { Power.shared.keepAwake = on; keepAwake = on }
    func setClaudeFull(_ on: Bool) { ClaudeRunner.shared.fullAccess = on; claudeFull = on }
    func setAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
        atLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Design check: renders the menu panel states to PNGs (FLICK_RENDER=<dir>).
@MainActor
func renderPanels(to dir: String) {
    let m = MacModel.shared
    let states: [(String, () -> Void)] = [
        ("idle", { m.phones = []; m.code = nil; m.trusted = true; m.screen = true }),
        ("connected", { m.phones = ["iPhone 15 Pro Max"]; m.code = nil }),
        ("pairing", { m.phones = []; m.code = "482913" }),
        ("permissions", { m.phones = []; m.code = nil; m.trusted = false; m.screen = false }),
    ]
    for (name, apply) in states {
        apply()
        for scheme in [ColorScheme.dark, .light] {
            let view = MenuPanel().environmentObject(m)
                .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("panel-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
