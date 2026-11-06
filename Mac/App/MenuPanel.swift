import SwiftUI
import FlickMacCore

let flickOrange = Color(red: 1, green: 0.42, blue: 0)

struct MenuPanel: View {
    @EnvironmentObject var model: MacModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let code = model.code {
                CodeView(code: code) { Server.shared.endPairing() }
            } else {
                Button { model.justPaired = nil; Server.shared.beginPairing() } label: {
                    Text(model.connected ? "Pair another iPhone" : "Pair iPhone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButton())
            }

            if !model.trusted || !model.screen {
                VStack(spacing: 6) {
                    if !model.trusted {
                        PermissionRow(title: "Control", detail: "Accessibility") {
                            Injector.shared.requestTrust()
                            openSettings("Privacy_Accessibility")
                        }
                    }
                    if !model.screen {
                        PermissionRow(title: "Screen view", detail: "Screen Recording") {
                            ScreenStreamer.requestPermission()
                            openSettings("Privacy_ScreenCapture")
                        }
                    }
                }
            }

            VStack(spacing: 2) {
                ToggleRow(title: "Keep Mac awake", isOn: Binding(get: { model.keepAwake }, set: model.setKeepAwake))
                ToggleRow(title: "Claude can run commands", isOn: Binding(get: { model.claudeFull }, set: model.setClaudeFull))
                ToggleRow(title: "Open at login", isOn: Binding(get: { model.atLogin }, set: model.setAtLogin))
            }

            Divider().opacity(0.5)
            HStack {
                Button("Forget phones") { Server.shared.unpairAll() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Flick").font(.system(size: 14, weight: .semibold))
                Text(statusLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Circle()
                .fill(model.connected ? flickOrange : Color.primary.opacity(0.2))
                .frame(width: 7, height: 7)
        }
    }

    var statusLine: String {
        if let name = model.phones.first { return model.phones.count > 1 ? "\(model.phones.count) phones connected" : name }
        if let p = model.justPaired { return "Paired with \(p)" }
        return "No phone connected"
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

struct CodeView: View {
    let code: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(code.enumerated()), id: \.offset) { i, ch in
                    Text(String(ch))
                        .font(.system(size: 24, weight: .medium, design: .rounded).monospacedDigit())
                        .frame(width: 32, height: 42)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.07)))
                    if i == 2 { Spacer().frame(width: 4) }
                }
            }
            HStack {
                Text("Enter on your iPhone").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Allow", action: action)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(flickOrange)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05)))
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() } } label: {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? flickOrange : Color.primary.opacity(0.15))
                    Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                }
                .frame(width: 30, height: 18)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(flickOrange.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Rectangle())
    }
}
