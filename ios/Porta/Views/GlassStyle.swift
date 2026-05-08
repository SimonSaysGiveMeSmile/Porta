import SwiftUI

/// Background that uses iOS 26 Liquid Glass when available, falling back to
/// `.ultraThinMaterial` on older systems. Pure monochrome — no tints.
struct GlassCard<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(Color.white.opacity(0.04), in: shape)
                .glassEffect(.regular, in: shape)
                .overlay(
                    shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        } else {
            content
                .background(Color.white.opacity(0.04), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassCard(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ))
    }
}

/// Pure-black backdrop with a very subtle radial highlight. Replaces the
/// previous cyan/purple ambient gradient for the monochrome theme.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [
                    Color.white.opacity(0.06),
                    Color.white.opacity(0.0),
                ],
                center: .top,
                startRadius: 20,
                endRadius: 520
            )
            .ignoresSafeArea()
        }
    }
}
