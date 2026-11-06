import SwiftUI
import UIKit
import FlickKit

struct KeysView: View {
    @EnvironmentObject var link: Link
    @StateObject private var mods = ModState()
    @State private var typing = true

    var shortcuts: [Shortcut] { ShortcutCatalog.shortcuts(for: link.frontApp.bundleID) }

    var body: some View {
        VStack(spacing: 14) {
            GlassGroup(spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 16) {
                    ForEach(shortcuts) { s in
                        GlassIcon(symbol: s.symbol, size: 54, label: s.label) {
                            link.send(.key(key: s.key, mods: s.mods))
                        }
                        .accessibilityIdentifier("shortcut.\(s.label)")
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: link.frontApp.bundleID)

            Spacer(minLength: 0)

            SpecialKeys(mods: mods, typing: $typing)
                .padding(.horizontal, 10)

            KeyCatcherView(mods: mods, active: typing)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("keys.catcher")
        }
        .padding(.bottom, 8)
    }
}

final class ModState: ObservableObject {
    @Published var on: Set<Mod> = []
    func toggle(_ m: Mod) { if on.contains(m) { on.remove(m) } else { on.insert(m) } }
    /// Sticky modifiers apply to the next key only, then clear (right away, so a fast second key gets none).
    func consume() -> [Mod] {
        let m = Array(on)
        if !m.isEmpty { on.removeAll() }
        return m
    }
}

struct SpecialKeys: View {
    @ObservedObject var mods: ModState
    @Binding var typing: Bool
    private let link = Link.shared

    var body: some View {
        GlassGroup(spacing: 8) {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                key("esc") { send(.escape) }
                key("tab") { send(.tab) }
                mod("⌃", .ctrl)
                mod("⌥", .opt)
                mod("⌘", .cmd)
                mod("⇧", .shift)
                Button {
                    Haptics.tap()
                    typing.toggle()
                } label: {
                    Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .glass(RoundedRectangle(cornerRadius: 13, style: .continuous), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("keys.toggle")
            }
            HStack(spacing: 6) {
                arrow("arrow.left", .left)
                arrow("arrow.up", .up)
                arrow("arrow.down", .down)
                arrow("arrow.right", .right)
                key("del") { send(.delete) }
                key("return") { send(.returnKey) }
            }
        }
        }
    }

    private func send(_ k: Key) { link.send(.key(key: k, mods: mods.consume())) }

    private func key(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, minHeight: 42)
                .glass(RoundedRectangle(cornerRadius: 13, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("key.\(title)")
    }

    private func arrow(_ symbol: String, _ k: Key) -> some View {
        Button { Haptics.tap(); send(k) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, minHeight: 42)
                .glass(RoundedRectangle(cornerRadius: 13, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("key.\(k.rawValue)")
    }

    private func mod(_ title: String, _ m: Mod) -> some View {
        let on = mods.on.contains(m)
        return Button { Haptics.tick(); mods.toggle(m) } label: {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(on ? Theme.accent : Theme.text)
                .frame(maxWidth: .infinity, minHeight: 42)
                .glass(RoundedRectangle(cornerRadius: 13, style: .continuous), tint: on ? Theme.accent.opacity(0.3) : nil, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mod.\(m.rawValue)")
    }
}

/// Invisible first responder that turns the iOS keyboard into Mac keystrokes.
struct KeyCatcherView: UIViewRepresentable {
    @ObservedObject var mods: ModState
    var active: Bool

    func makeUIView(context: Context) -> KeyCatcher {
        let v = KeyCatcher()
        v.mods = mods
        return v
    }

    func updateUIView(_ v: KeyCatcher, context: Context) {
        v.mods = mods
        DispatchQueue.main.async {
            if active, v.window != nil, !v.isFirstResponder { v.becomeFirstResponder() }
            if !active, v.isFirstResponder { v.resignFirstResponder() }
        }
    }
}

final class KeyCatcher: UIView, UIKeyInput, UITextInputTraits {
    var mods: ModState?
    private let link = Link.shared

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DispatchQueue.main.async { self.becomeFirstResponder() } }
    }

    func insertText(_ text: String) {
        let held = mods?.consume() ?? []
        if text == "\n" {
            link.send(.key(key: .returnKey, mods: held))
        } else if !held.isEmpty, text.count == 1, let k = Key.from(character: text.first!) {
            link.send(.key(key: k, mods: held))
        } else {
            link.send(.text(value: text))
        }
    }

    func deleteBackward() {
        link.send(.key(key: .delete, mods: mods?.consume() ?? []))
    }
}
