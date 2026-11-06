import SwiftUI
import FlickKit

struct RootView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var router: Router
    @AppStorage("everConnected") private var everConnected = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if everConnected || link.isConnected {
                MainView().transition(.opacity)
            } else {
                ConnectView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: everConnected || link.isConnected)
        .onAppear {
            link.start()
            if ProcessInfo.processInfo.arguments.contains("-FlickTestPairCode"), link.paired == nil { router.showMacPairing = true }
        }
        .onChange(of: link.isConnected) { _, on in
            if on, !everConnected { everConnected = true; UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
        .sheet(isPresented: $router.showMacPairing) { MacPairSheet().environmentObject(link) }
        #if DEBUG
        .overlay(alignment: .topLeading) { OneShotProbe() }
        #endif
    }
}

/// First run: pick your Mac, done.
struct ConnectView: View {
    @EnvironmentObject var router: Router
    @ObservedObject private var bt = Bluetooth.shared
    @State private var showOther = false

    var body: some View {
        ZStack {
            Rings(intensity: 0.55, speed: 0.7)
                .ignoresSafeArea()
            RadialGradient(colors: [.black.opacity(0.85), .black.opacity(0.55), .clear], center: .center, startRadius: 30, endRadius: 260)
                .frame(height: 520)
                .allowsHitTesting(false)
            VStack(spacing: 26) {
                Spacer()
                CursorMark(size: 46)
                    .frame(width: 92, height: 92)
                    .glass(Circle())
                Text("Connect")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                devices
                Spacer()
                Button { showOther.toggle() } label: {
                    Text(showOther ? "Mac → Settings → Bluetooth → Flick" : "Not listed?")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glass(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showOther)
                Button { router.showMacPairing = true } label: {
                    Text("Have Flick for Mac?").font(.system(size: 13)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connect.mac")
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
        }
        .onAppear { bt.scan() }
        .onDisappear { bt.stopScan() }
    }

    @ViewBuilder private var devices: some View {
        switch bt.state {
        case .off:
            Label("Turn on Bluetooth", systemImage: "exclamationmark.circle")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.accent)
        case .unauthorized:
            Button("Allow Bluetooth") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
        default:
            GlassGroup(spacing: 10) {
                VStack(spacing: 10) {
                    ForEach(bt.nearby.prefix(4)) { d in
                        Button { Haptics.press(); bt.connect(d.id) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: d.symbol).font(.system(size: 18, weight: .medium)).frame(width: 26)
                                Text(d.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                Spacer()
                                if bt.target == d.id, bt.state == .connecting {
                                    ProgressView().controlSize(.small).tint(Theme.accent)
                                } else {
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint)
                                }
                            }
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 18).frame(height: 58)
                            .glass(RoundedRectangle(cornerRadius: 20, style: .continuous),
                                   tint: bt.target == d.id ? Theme.accent.opacity(0.22) : nil, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bt.device")
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    if bt.nearby.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(Theme.dim)
                            Text("Looking for your Mac").font(.system(size: 14)).foregroundStyle(Theme.dim)
                        }
                        .frame(height: 58)
                    }
                }
            }
            .frame(maxWidth: 360)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: bt.nearby)
        }
    }
}

struct MainView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var router: Router

    private var modes: [Mode] { link.helperConnected ? Mode.allCases : [.trackpad, .air, .keys, .more] }
    private var shown: Mode { modes.contains(router.mode) ? router.mode : .trackpad }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                switch shown {
                case .trackpad: TrackpadView()
                case .air: AirView()
                case .keys: KeysView()
                case .screen: ScreenView()
                case .more: MoreView()
                }
            }
            .padding(.top, 62)
            .padding(.bottom, 84)
            .opacity(link.isConnected ? 1 : 0.3)
            .allowsHitTesting(link.isConnected)
            .animation(.easeOut(duration: 0.25), value: link.isConnected)
            .transition(.opacity)
            .id(shown)

            VStack {
                StatusBar()
                Spacer()
                Dock(modes: modes, selection: Binding(get: { shown }, set: { router.set($0) }))
                    .padding(.bottom, 4)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: shown)
        .sheet(isPresented: $router.showAsk) { AskView().environmentObject(link).environmentObject(router) }
        .sheet(isPresented: $router.showSettings) { SettingsView().environmentObject(link).environmentObject(router) }
        .fullScreenCover(isPresented: $router.showDrive) { DriveView() }
        .fullScreenCover(isPresented: $router.showPresent) { PresentView() }
    }
}

struct StatusBar: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var router: Router

    private var title: String {
        if link.helperConnected { return link.paired?.name ?? "Mac" }
        if link.bluetoothConnected { return "Bluetooth" }
        return "Reconnecting"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { router.showSettings = true } label: {
                HStack(spacing: 8) {
                    LiveDot(on: link.isConnected)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if link.helperConnected, let icon = link.frontApp.icon {
                        Image(uiImage: icon).resizable().frame(width: 20, height: 20)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.leading, 12).padding(.trailing, 14).frame(height: 40)
                .glass(Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(link.isConnected ? "connected" : "not connected")")
            .accessibilityIdentifier(link.isConnected ? "status.connected" : "status.offline")
            Spacer()
            if link.helperConnected {
                Button { Haptics.tap(); router.showAsk = true } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 40, height: 40)
                        .glass(Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ask.open")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: link.helperConnected)
        .animation(.easeOut(duration: 0.2), value: link.frontApp.bundleID)
    }
}
