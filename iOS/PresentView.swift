import SwiftUI
import FlickKit

/// Presenter remote: hold the top to show an orange laser dot on the Mac and point with the phone.
struct PresentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var laser = false
    @State private var started = Date()
    private let link = Link.shared

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 36, height: 36)
                        .glass(Circle(), interactive: true)
                }
                .accessibilityIdentifier("present.close")
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsed(ctx.date))
                        .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
                .onTapGesture { started = Date() }
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, 18)

            ZStack {
                Rings(intensity: laser ? 1.1 : 0.3, speed: laser ? 2 : 0.6)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                Image(systemName: "dot.radiowaves.forward")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.text)
                    .opacity(laser ? 0 : 0.8)
            }
                .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(laser ? Theme.accent.opacity(0.8) : Theme.hairline, lineWidth: laser ? 2 : 1))
                .animation(.easeOut(duration: 0.2), value: laser)
                .contentShape(Rectangle())
                .accessibilityIdentifier("present.laser")
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !laser else { return }
                            laser = true
                            Haptics.press()
                            link.send(.laser(on: true))
                            MotionEngine.shared.startPointing()
                        }
                        .onEnded { _ in
                            laser = false
                            MotionEngine.shared.stopPointing()
                            link.send(.laser(on: false))
                        }
                )
                .padding(.horizontal, 14)

            HStack(spacing: 12) {
                slideButton("chevron.left", id: "present.prev") { link.send(.key(key: .left, mods: [])) }
                    .frame(width: 110)
                slideButton("chevron.right", id: "present.next") { link.send(.key(key: .right, mods: [])) }
            }
            .frame(height: 150)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            MotionEngine.shared.stopPointing()
            link.send(.laser(on: false))
        }
    }

    private func slideButton(_ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.click(); action() } label: {
            Image(systemName: symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glass(RoundedRectangle(cornerRadius: 30, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func elapsed(_ now: Date) -> String {
        let s = Int(now.timeIntervalSince(started))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
