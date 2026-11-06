import SwiftUI

enum Theme {
    static let accent = Color(red: 1, green: 0.42, blue: 0)
    static let text = Color.white.opacity(0.94)
    static let dim = Color.white.opacity(0.5)
    static let faint = Color.white.opacity(0.22)
    static let hairline = Color.white.opacity(0.08)
    static let surface = Color.white.opacity(0.05)
    static let surfaceHi = Color.white.opacity(0.1)
}

/// Rippling orange light rings (Shaders.metal). `intensity` 0…1.4 (idle glow → full burst).
struct Rings: View {
    var intensity: Double = 1
    var speed: Double = 1

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) * 3 * speed
            GeometryReader { geo in
                Rectangle()
                    .fill(.black)
                    .colorEffect(ShaderLibrary.flickRings(.float2(geo.size), .float(t), .float(intensity)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Black with a breath of grain so big surfaces don't look flat.
struct Grain: View {
    var amount: Double = 0.035
    var body: some View {
        Rectangle()
            .fill(Color(white: 0.02))
            .colorEffect(ShaderLibrary.flickGrain(.float(0), .float(amount)))
            .allowsHitTesting(false)
    }
}

extension View {
    /// Liquid Glass on iOS 26+, frosted material before that.
    @ViewBuilder
    func glass(_ shape: some Shape = Capsule(), tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(Self.makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(tint ?? Color.white.opacity(0.03))
                    shape.stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                }
            }
        }
    }

    @available(iOS 26.0, *)
    private static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Groups glass shapes so they blend on iOS 26+; a plain container before that.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Round glass icon button with haptic.
struct GlassIcon: View {
    let symbol: String
    var size: CGFloat = 52
    var label: String? = nil
    var name: String? = nil
    var on = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(on ? Theme.accent : Theme.text)
                    .frame(width: size, height: size)
                    .glass(Circle(), tint: on ? Theme.accent.opacity(0.25) : nil, interactive: true)
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? name ?? symbol)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A big press-and-hold glass pad. Down/up go straight to `onChange` (so holding = dragging / gas pedal).
struct HoldPad<Content: View>: View {
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    let id: String
    let onChange: (Bool) -> Void
    @ViewBuilder var content: (Bool) -> Content
    @State private var down = false

    var body: some View {
        ZStack { content(down) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glass(shape, tint: down ? Theme.accent.opacity(0.22) : nil)
            .overlay(shape.stroke(down ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
            .scaleEffect(down ? 0.98 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: down)
            .contentShape(shape)
            .accessibilityElement()
            .accessibilityIdentifier(id)
            .accessibilityAddTraits(.isButton)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !down { down = true; Haptics.press(); onChange(true) }
                    }
                    .onEnded { _ in
                        down = false
                        onChange(false)
                    }
            )
    }
}

/// The Flick mark: a white pointer with a dark outline and an orange tip (same as the app icon).
struct CursorMark: View {
    var size: CGFloat = 64

    private struct Pointer: Shape {
        func path(in r: CGRect) -> Path {
            // 100-unit art, bbox 38…70 × 26…76, centred in `r`.
            let u = min(r.width, r.height) / 56
            let ox = r.midX - 54 * u, oy = r.midY - 51 * u
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * u, y: oy + y * u) }
            var p = Path()
            p.move(to: pt(38, 26))
            for (x, y) in [(38, 70), (48.5, 60), (56, 76), (63.5, 72.5), (56, 57), (70, 57)] as [(CGFloat, CGFloat)] { p.addLine(to: pt(x, y)) }
            p.closeSubpath()
            return p
        }
    }

    var body: some View {
        let u = size / 56
        ZStack(alignment: .topLeading) {
            Pointer().fill(.white)
            Pointer().stroke(Color(white: 0.08), style: StrokeStyle(lineWidth: 4.2 * u, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .overlay {
            Circle().fill(Theme.accent)
                .frame(width: 13 * u, height: 13 * u)
                .position(x: size / 2 + (38 - 54) * u, y: size / 2 + (26 - 51) * u)
        }
        .accessibilityHidden(true)
    }
}

/// Pulsing status dot.
struct LiveDot: View {
    let on: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if on {
                Circle().fill(Theme.accent.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.4 : 0.6)
                    .opacity(pulse ? 0 : 1)
            }
            Circle().fill(on ? Theme.accent : Theme.faint).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}
