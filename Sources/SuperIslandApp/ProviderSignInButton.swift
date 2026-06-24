import SuperIslandCore
import SwiftUI

/// A branded OAuth sign-in button: white pill, provider logo, "Continue with X".
/// Shared by the onboarding sign-in step and the Account settings pane.
struct ProviderSignInButton: View {
    let provider: OAuthProvider
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ProviderLogo(provider: provider)
                    .frame(width: 17, height: 17)
                Text("Continue with \(provider.displayName)")
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: 300)
            .frame(height: 44)
            .background(Color.white)
            .foregroundStyle(Color(white: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06))
            )
            .shadow(color: .black.opacity(hovering ? 0.30 : 0.18), radius: hovering ? 11 : 6, y: 3)
            .scaleEffect(hovering ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// Renders the brand mark for a provider, drawn in code (no asset files).
struct ProviderLogo: View {
    let provider: OAuthProvider

    var body: some View {
        switch provider {
        case .google: GoogleGLogo()
        case .azure: MicrosoftLogo()
        case .apple:
            Image(systemName: "apple.logo")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(white: 0.1))
        }
    }
}

/// The four-color Google "G", built from circle-trim arcs (unambiguous,
/// clockwise from the 3 o'clock position) plus the blue crossbar.
struct GoogleGLogo: View {
    private let blue = Color(red: 0.259, green: 0.522, blue: 0.957)
    private let green = Color(red: 0.204, green: 0.659, blue: 0.325)
    private let yellow = Color(red: 0.984, green: 0.737, blue: 0.020)
    private let red = Color(red: 0.918, green: 0.263, blue: 0.208)

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let lw = s * 0.22
            ZStack {
                seg(0.02, 0.16, blue, s, lw)
                seg(0.16, 0.40, green, s, lw)
                seg(0.40, 0.62, yellow, s, lw)
                seg(0.62, 0.95, red, s, lw)
                Rectangle()
                    .fill(blue)
                    .frame(width: s * 0.30, height: lw)
                    .position(x: s * 0.62, y: s / 2)
            }
            .frame(width: s, height: s)
        }
    }

    private func seg(
        _ from: CGFloat, _ to: CGFloat, _ color: Color, _ s: CGFloat, _ lw: CGFloat
    ) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .butt))
            .frame(width: s - lw, height: s - lw)
            .position(x: s / 2, y: s / 2)
    }
}

/// The Microsoft four-square mark.
struct MicrosoftLogo: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let gap = s * 0.08
            let sq = (s - gap) / 2
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(red: 0.95, green: 0.32, blue: 0.13))
                    .frame(width: sq, height: sq)
                Rectangle().fill(Color(red: 0.50, green: 0.73, blue: 0.0))
                    .frame(width: sq, height: sq).offset(x: sq + gap)
                Rectangle().fill(Color(red: 0.0, green: 0.64, blue: 0.94))
                    .frame(width: sq, height: sq).offset(y: sq + gap)
                Rectangle().fill(Color(red: 1.0, green: 0.73, blue: 0.0))
                    .frame(width: sq, height: sq).offset(x: sq + gap, y: sq + gap)
            }
            .frame(width: s, height: s)
        }
    }
}
