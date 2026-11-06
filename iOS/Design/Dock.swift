import SwiftUI

/// Floating glass dock. Tap an icon, or slide a finger along it: icons swell under the
/// finger like the macOS dock, and lifting picks the one underneath.
struct Dock: View {
    let modes: [Mode]
    @Binding var selection: Mode
    @Namespace private var ns
    @State private var fingerX: CGFloat?
    @State private var hovered: Mode?

    private let item: CGFloat = 52

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(modes.enumerated()), id: \.element) { i, m in
                let scale = magnification(index: i)
                ZStack {
                    if selection == m {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: 18, height: 3)
                            .offset(y: 19)
                            .matchedGeometryEffect(id: "dot", in: ns)
                    }
                    Image(systemName: m.symbol)
                        .font(.system(size: 19, weight: selection == m ? .semibold : .regular))
                        .foregroundStyle(selection == m ? Theme.text : Theme.dim)
                        .scaleEffect(scale)
                        .offset(y: -(scale - 1) * 14)
                }
                .frame(width: item, height: item)
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityIdentifier("mode.\(m.rawValue)")
                .accessibilityLabel(m.title)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { pick(m) }
                .onTapGesture { pick(m) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glass(Capsule())
        .coordinateSpace(name: "dock")
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("dock"))
                .onChanged { v in
                    withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.8)) { fingerX = v.location.x }
                    let m = mode(at: v.location.x)
                    if m != hovered { hovered = m; Haptics.tick() }
                }
                .onEnded { v in
                    if let m = mode(at: v.location.x) { pick(m) }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { fingerX = nil }
                    hovered = nil
                }
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: selection)
    }

    private func center(_ i: Int) -> CGFloat { 10 + item / 2 + CGFloat(i) * (item + 4) }

    private func mode(at x: CGFloat) -> Mode? {
        guard !modes.isEmpty else { return nil }
        let i = Int(((x - 10) / (item + 4)).rounded(.down))
        return modes[max(0, min(modes.count - 1, i))]
    }

    private func magnification(index i: Int) -> CGFloat {
        guard let x = fingerX else { return 1 }
        let d = abs(x - center(i))
        return 1 + 0.55 * exp(-(d * d) / (2 * 38 * 38))
    }

    private func pick(_ m: Mode) {
        guard m != selection else { return }
        Haptics.tick()
        selection = m
    }
}
