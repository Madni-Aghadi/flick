import SwiftUI
import FlickKit

#if DEBUG
/// UI tests: exercises the Siri / Action Button path (a separate one-shot connection).
struct OneShotProbe: View {
    @State private var result: Bool?
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier(result == nil ? "oneshot.pending" : (result! ? "oneshot.ok" : "oneshot.fail"))
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-FlickOneShotTest") else { return }
                try? await Task.sleep(for: .seconds(1))
                result = await Link.oneShot([.releaseAll])
            }
    }
}
#endif

/// Optional: pair with Flick for Mac (screen view, Claude, use from anywhere).
struct MacPairSheet: View {
    @EnvironmentObject var link: Link
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PairCandidate?
    @State private var code = ""
    @State private var busy = false
    @State private var wrong = false
    @FocusState private var focused: Bool

    private var testCode: String? {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "-FlickTestPairCode").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }

    var body: some View {
        ZStack {
            Rings(intensity: 0.35, speed: 0.6).ignoresSafeArea()
            VStack(spacing: 26) {
                Capsule().fill(Theme.faint).frame(width: 36, height: 5).padding(.top, 10)
                Spacer()
                Image(systemName: "macbook")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.text)
                    .frame(width: 88, height: 88)
                    .glass(Circle())
                if let selected {
                    VStack(spacing: 18) {
                        Text(selected.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.dim)
                        CodeBoxes(code: code, wrong: wrong)
                            .onTapGesture { focused = true }
                            .accessibilityIdentifier("pair.code")
                        TextField("", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($focused)
                            .frame(width: 1, height: 1)
                            .opacity(0.01)
                            .accessibilityIdentifier("pair.field")
                            .onChange(of: code) { _, v in
                                let digits = String(v.filter(\.isNumber).prefix(6))
                                if digits != v { code = digits }
                                wrong = false
                                if digits.count == 6 { submit(digits) }
                            }
                        if busy { ProgressView().tint(Theme.dim) }
                    }
                } else if link.candidates.isEmpty {
                    VStack(spacing: 8) {
                        Text("Flick for Mac").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                        Text("Menu bar → Pair iPhone").font(.system(size: 15)).foregroundStyle(Theme.dim)
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(link.candidates) { c in
                            Button { choose(c) } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer")
                                    Text(c.name)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.faint)
                                }
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 18).frame(height: 56)
                                .glass(RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pair.mac")
                        }
                    }
                    .padding(.horizontal, 28)
                }
                Spacer()
                Spacer()
            }
        }
        .presentationBackground(.black)
        .onAppear {
            link.browsePairing()
            if selected == nil, link.candidates.count == 1 { choose(link.candidates[0]) }
        }
        .onChange(of: link.candidates) { _, list in
            if selected == nil, list.count == 1 { choose(list[0]) }
        }
    }

    private func choose(_ c: PairCandidate) {
        selected = c
        if let testCode {
            code = testCode
            // The field is created in this same update, so its onChange won't fire for this value.
            DispatchQueue.main.async { submit(testCode) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true }
        }
    }

    private func submit(_ digits: String) {
        guard let selected, !busy else { return }
        busy = true
        focused = false
        link.pair(with: selected, code: digits) { ok in
            busy = false
            if ok {
                Haptics.click()
                dismiss()
            } else {
                wrong = true
                code = ""
                focused = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

struct CodeBoxes: View {
    let code: String
    let wrong: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { i in
                let ch = i < code.count ? String(code[code.index(code.startIndex, offsetBy: i)]) : ""
                Text(ch)
                    .font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .frame(width: 42, height: 54)
                    .glass(RoundedRectangle(cornerRadius: 14, style: .continuous),
                           tint: wrong ? Theme.accent.opacity(0.3) : (i == code.count ? Color.white.opacity(0.08) : nil))
                if i == 2 { Spacer().frame(width: 6) }
            }
        }
        .modifier(Shake(amount: wrong ? 1 : 0))
        .animation(.default, value: wrong)
    }
}

struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(amount * .pi * 4), y: 0))
    }
}
