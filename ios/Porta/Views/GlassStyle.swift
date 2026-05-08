import SwiftUI

/// Background that uses iOS 26 Liquid Glass when available, falling back to
/// `.ultraThinMaterial` on older systems. Keeps view code declarative.
struct GlassCard<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(tint?.opacity(0.12) ?? .clear, in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(tint?.opacity(0.12) ?? .clear, in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 20, tint: Color? = nil) -> some View {
        modifier(GlassCard(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint
        ))
    }
}

/// Ambient gradient used behind the home screen. Looks better with glass on top.
struct AmbientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.07, green: 0.09, blue: 0.18),
                Color(red: 0.12, green: 0.06, blue: 0.20),
                Color(red: 0.05, green: 0.12, blue: 0.18),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(
                colors: [Color.purple.opacity(0.35), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
        )
        .overlay(
            RadialGradient(
                colors: [Color.cyan.opacity(0.28), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 420
            )
        )
        .ignoresSafeArea()
    }
}
