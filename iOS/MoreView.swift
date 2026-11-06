import SwiftUI
import FlickKit

struct MoreView: View {
    @EnvironmentObject var router: Router
    private let link = Link.shared
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ScrollView {
            GlassGroup(spacing: 16) {
                VStack(spacing: 22) {
                    QuickLaunch()
                    HStack(spacing: 12) {
                        Tile(symbol: "steeringwheel", title: "Drive", id: "more.drive") { router.showDrive = true }
                        Tile(symbol: "dot.radiowaves.forward", title: "Present", id: "more.present") { router.showPresent = true }
                    }
                    media
                    LazyVGrid(columns: cols, spacing: 18) {
                        GlassIcon(symbol: "rectangle.3.group", label: "Spaces") { link.send(.system(action: .missionControl)) }
                        GlassIcon(symbol: "menubar.dock.rectangle", label: "Desktop") { link.send(.system(action: .desktop)) }
                        GlassIcon(symbol: "arrow.left.to.line", label: "Left") { link.send(.system(action: .spaceLeft)) }
                        GlassIcon(symbol: "arrow.right.to.line", label: "Right") { link.send(.system(action: .spaceRight)) }
                        GlassIcon(symbol: "magnifyingglass", label: "Spotlight") { link.send(.system(action: .spotlight)) }
                        GlassIcon(symbol: "square.on.square", label: "Switch") { link.send(.system(action: .appSwitcher)) }
                        GlassIcon(symbol: "moon", label: "Sleep") { link.send(.system(action: .displaySleep)) }
                        GlassIcon(symbol: "lock", label: "Lock") { link.send(.system(action: .lock)) }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var media: some View {
        VStack(spacing: 18) {
            HStack(spacing: 26) {
                GlassIcon(symbol: "backward.fill", size: 52, name: "Previous track") { link.send(.media(action: .previous)) }
                GlassIcon(symbol: "playpause.fill", size: 74, name: "Play or pause", on: true) { link.send(.media(action: .playPause)) }
                    .accessibilityIdentifier("media.playPause")
                GlassIcon(symbol: "forward.fill", size: 52, name: "Next track") { link.send(.media(action: .next)) }
            }
            HStack(spacing: 10) {
                Stepper(minus: "speaker.wave.1.fill", plus: "speaker.wave.3.fill", name: "Volume",
                        down: { link.send(.media(action: .volumeDown)) }, up: { link.send(.media(action: .volumeUp)) })
                GlassIcon(symbol: "speaker.slash.fill", size: 44, name: "Mute") { link.send(.media(action: .mute)) }
                Stepper(minus: "sun.min.fill", plus: "sun.max.fill", name: "Brightness",
                        down: { link.send(.media(action: .brightnessDown)) }, up: { link.send(.media(action: .brightnessUp)) })
            }
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .glass(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

/// Fast lanes: open any app by name (through Spotlight), Finder, screenshot. Often quicker than pointing.
struct QuickLaunch: View {
    @State private var name = ""
    @FocusState private var focused: Bool
    private let link = Link.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                TextField("Open app", text: $name)
                    .focused($focused)
                    .submitLabel(.go)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { open(name); name = "" }
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("quick.open")
            }
            .font(.system(size: 16))
            .padding(.horizontal, 18)
            .frame(height: 50)
            .glass(Capsule(), interactive: true)
            HStack(spacing: 10) {
                chip("Finder", "folder") { open("Finder") }
                chip("Screenshot", "camera.viewfinder") { link.send(.key(key: .n5, mods: [.cmd, .shift])) }
                chip("Spotlight", "sparkle.magnifyingglass") { link.send(.system(action: .spotlight)) }
            }
        }
    }

    private func chip(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, minHeight: 40)
                .glass(Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("quick.\(title.lowercased())")
    }

    /// ⌘Space, type the name, Return. Spotlight needs a moment to open before it takes text.
    private func open(_ app: String) {
        let app = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { return }
        focused = false
        link.send(.system(action: .spotlight))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { link.send(.text(value: app)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { link.send(.key(key: .returnKey, mods: [])) }
    }
}

/// Two-button glass pill: − and +.
struct Stepper: View {
    let minus: String
    let plus: String
    let name: String
    let down: () -> Void
    let up: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button(minus, "\(name) down", down)
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 20)
            button(plus, "\(name) up", up)
        }
        .frame(height: 44)
        .glass(Capsule())
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                .frame(width: 52, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(label == "Volume up" ? "media.volumeUp" : label == "Volume down" ? "media.volumeDown" : label)
    }
}

struct Tile: View {
    let symbol: String
    let title: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .glass(RoundedRectangle(cornerRadius: 26, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct SettingsView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var router: Router
    @ObservedObject private var bt = Bluetooth.shared
    @Environment(\.dismiss) private var dismiss
    @State private var air = Settings.airSensitivity
    @State private var pad = Settings.trackpadSpeed
    @State private var speak = Settings.speakAnswers
    @State private var haptics = Settings.haptics
    @State private var host = Link.shared.paired?.extraHosts.first ?? ""
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    slider("Air pointer", value: $air, range: 400...1800) { Settings.airSensitivity = $0 }
                    slider("Trackpad", value: $pad, range: 0.6...3.2) { Settings.trackpadSpeed = $0 }
                }
                Section {
                    Toggle("Speak Claude's answers", isOn: $speak).onChange(of: speak) { _, v in Settings.speakAnswers = v }
                    Toggle("Haptics", isOn: $haptics).onChange(of: haptics) { _, v in Settings.haptics = v }
                }
                Section("Bluetooth") {
                    HStack {
                        Text(bt.state == .connected ? "Connected" : bt.state == .off ? "Off" : "Waiting")
                        Spacer()
                        LiveDot(on: bt.state == .connected)
                    }
                }
                Section {
                    if let p = link.paired {
                        HStack {
                            Text(p.name)
                            Spacer()
                            LiveDot(on: link.helperConnected)
                        }
                        TextField("Tailscale name or IP", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { link.setExtraHost(host) }
                        Button("Forget \(p.name)", role: .destructive) { confirmForget = true }
                    } else {
                        Button("Pair Flick for Mac") {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { router.showMacPairing = true }
                        }
                        .accessibilityIdentifier("settings.pairMac")
                    }
                } header: {
                    Text("Flick for Mac")
                } footer: {
                    Text("Adds live screen, Claude, and use from anywhere.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { link.setExtraHost(host); dismiss() }
                }
            }
            .confirmationDialog("Forget this Mac?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) { dismiss(); link.forget() }
            }
        }
        .presentationDetents([.large])
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, save: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14)).foregroundStyle(Theme.dim)
            Slider(value: value, in: range).onChange(of: value.wrappedValue) { _, v in save(v) }
        }
        .padding(.vertical, 4)
    }
}
