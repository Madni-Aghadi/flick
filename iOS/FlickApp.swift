import SwiftUI
import FlickKit

@main
struct FlickApp: App {
    @UIApplicationDelegateAdaptor(FlickAppDelegate.self) private var delegate
    @StateObject private var link = Link.shared
    @StateObject private var router = Router.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(link)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .active: link.start()
            case .background: link.suspend()
            default: break
            }
        }
    }
}

enum Mode: String, CaseIterable, Identifiable, Hashable {
    case trackpad, air, keys, screen, more
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .trackpad: "hand.point.up.left"
        case .air: "wand.and.rays"
        case .keys: "keyboard"
        case .screen: "macbook"
        case .more: "square.grid.2x2"
        }
    }
    var title: String {
        switch self {
        case .trackpad: "Trackpad"
        case .air: "Air"
        case .keys: "Keys"
        case .screen: "Screen"
        case .more: "More"
        }
    }
}

/// App-wide navigation state (also driven by App Intents and UI-test launch arguments).
final class Router: ObservableObject {
    static let shared = Router()
    @Published var mode: Mode
    @Published var showAsk = false
    @Published var showDrive = false
    @Published var showPresent = false
    @Published var showSettings = false
    @Published var listenOnOpen = false
    @Published var showMacPairing = false

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-FlickMode"), i + 1 < args.count, let m = Mode(rawValue: args[i + 1]) { mode = m }
        else { mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .trackpad }
        // Debug/test entry points.
        if let i = args.firstIndex(of: "-FlickOpen"), i + 1 < args.count {
            switch args[i + 1] {
            case "drive": showDrive = true
            case "present": showPresent = true
            case "ask": showAsk = true
            case "settings": showSettings = true
            default: break
            }
        }
    }

    func set(_ m: Mode) {
        mode = m
        UserDefaults.standard.set(m.rawValue, forKey: "mode")
    }
}

enum Settings {
    static var airSensitivity: Double {
        get { UserDefaults.standard.object(forKey: "airSensitivity") as? Double ?? 900 }
        set { UserDefaults.standard.set(newValue, forKey: "airSensitivity") }
    }
    static var trackpadSpeed: Double {
        get { UserDefaults.standard.object(forKey: "trackpadSpeed") as? Double ?? 1.6 }
        set { UserDefaults.standard.set(newValue, forKey: "trackpadSpeed") }
    }
    static var speakAnswers: Bool {
        get { UserDefaults.standard.object(forKey: "speakAnswers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speakAnswers") }
    }
    static var haptics: Bool {
        get { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "haptics") }
    }
    static var airOnTrackpad: Bool {
        get { UserDefaults.standard.object(forKey: "airOnTrackpad") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "airOnTrackpad") }
    }
    static var wasd: Bool {
        get { UserDefaults.standard.bool(forKey: "wasd") }
        set { UserDefaults.standard.set(newValue, forKey: "wasd") }
    }
}

enum Haptics {
    static let light = UIImpactFeedbackGenerator(style: .light)
    static let soft = UIImpactFeedbackGenerator(style: .soft)
    static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    static let select = UISelectionFeedbackGenerator()

    static func tap() { if Settings.haptics { light.impactOccurred() } }
    static func press() { if Settings.haptics { soft.impactOccurred(intensity: 0.9) } }
    static func click() { if Settings.haptics { rigid.impactOccurred(intensity: 0.7) } }
    static func tick() { if Settings.haptics { select.selectionChanged() } }
}
