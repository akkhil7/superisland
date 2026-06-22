import SwiftUI
import AppKit
import CoreText

/// Visual system for the onboarding window, lifted from the landing page
/// (`website/index.html`): near-black starfield, purple gradient CTAs with
/// glow, lavender accents, glass cards, monospace chips, serif-italic accent
/// words.
enum OnboardingTheme {
    // MARK: Palette (website/index.html)
    static let bg = Color(red: 0x05 / 255, green: 0x04 / 255, blue: 0x09 / 255)
    static let purple = Color(red: 0x7B / 255, green: 0x39 / 255, blue: 0xFC / 255)
    static let purpleLight = Color(red: 0x8D / 255, green: 0x53 / 255, blue: 0xFF / 255)
    static let lavender = Color(red: 0xAE / 255, green: 0x9A / 255, blue: 0xE6 / 255)
    static let heading = Color(red: 0xFD / 255, green: 0xF9 / 255, blue: 0xFF / 255)
    static let body = Color.white.opacity(0.55)
    static let glow = purple.opacity(0.4)

    // MARK: Fonts
    private static var fontsRegistered = false

    /// Register the bundled Instrument Serif faces (no-op when absent).
    static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        for name in ["InstrumentSerif-Regular.ttf", "InstrumentSerif-Italic.ttf"] {
            guard let url = resourceURL(name) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Serif italic accent ("a *window* again") — Instrument Serif when
    /// bundled, New York italic otherwise.
    static func serifAccent(_ size: CGFloat) -> Font {
        registerFonts()
        if NSFont(name: "Instrument Serif", size: size) != nil {
            return .custom("Instrument Serif", size: size).italic()
        }
        return .system(size: size, design: .serif).italic()
    }

    // MARK: Resources
    static func resourceURL(_ name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("Onboarding/\(name)"),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    static func art(_ name: String) -> NSImage? {
        resourceURL(name).flatMap { NSImage(contentsOf: $0) }
    }
}

// MARK: - Background (starfield + aurora)

struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            OnboardingTheme.bg
            // Aurora: the website asset when bundled, else radial gradients.
            if let aurora = OnboardingTheme.art("hero-aurora.webp") {
                Image(nsImage: aurora)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.55)
                    .blur(radius: 18)
            } else {
                RadialGradient(
                    colors: [OnboardingTheme.purple.opacity(0.38), .clear],
                    center: .init(x: 0.5, y: 0.1), startRadius: 10, endRadius: 420
                )
                RadialGradient(
                    colors: [OnboardingTheme.lavender.opacity(0.12), .clear],
                    center: .init(x: 0.85, y: 0.9), startRadius: 10, endRadius: 380
                )
            }
            Starfield()
        }
        .clipped()   // scaledToFill overflow stays inside the window bounds
        .ignoresSafeArea()
    }
}

/// Deterministic starfield (seeded LCG — no randomness at render time).
private struct Starfield: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x5EED
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 33) / CGFloat(UInt32.max)
            }
            for _ in 0..<110 {
                let x = next() * size.width
                let y = next() * size.height
                let r = 0.4 + next() * 1.0
                let alpha = 0.10 + next() * 0.35
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                    with: .color(.white.opacity(alpha))
                )
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Buttons

/// Primary CTA: purple gradient pill with outer glow.
struct GlowPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [OnboardingTheme.purple, OnboardingTheme.purpleLight],
                    startPoint: .leading, endPoint: .trailing
                ))
            )
            .shadow(color: OnboardingTheme.glow, radius: 14, y: 2)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Secondary: ghost pill.
struct GhostPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(.white.opacity(0.06)))
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Cards, chips, keycaps

struct OnboardingGlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

/// Monospace status chip with a glowing colored dot (landing-page style).
struct OnboardingChip: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.8), radius: 3)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.05)))
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Logo

/// The brand mark from `website/assets/favicon.svg`, redrawn natively:
/// purple rounded square + white clip stroke. Vector-sharp at any size.
struct SuperIslandLogo: View {
    var size: CGFloat = 110

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 8 / 32, style: .continuous)
                .fill(LinearGradient(
                    colors: [OnboardingTheme.purple, OnboardingTheme.purpleLight],
                    startPoint: .top, endPoint: .bottom
                ))
            ClipStroke()
                .stroke(.white, style: StrokeStyle(
                    lineWidth: size * 2.6 / 32, lineCap: .round
                ))
        }
        .frame(width: size, height: size)
        .shadow(color: OnboardingTheme.glow, radius: 26, y: 4)
    }

    /// The paperclip path from the SVG (viewBox 0 0 32 32):
    /// M10 8 v11 a6 6 0 0 0 12 0 V9.5 a3.5 3.5 0 0 0 -7 0 V19
    private struct ClipStroke: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 32
            var p = Path()
            p.move(to: CGPoint(x: 10 * s, y: 8 * s))
            p.addLine(to: CGPoint(x: 10 * s, y: 19 * s))
            p.addArc(center: CGPoint(x: 16 * s, y: 19 * s), radius: 6 * s,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: CGPoint(x: 22 * s, y: 9.5 * s))
            p.addArc(center: CGPoint(x: 18.5 * s, y: 9.5 * s), radius: 3.5 * s,
                     startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
            p.addLine(to: CGPoint(x: 15 * s, y: 19 * s))
            return p
        }
    }
}

/// Custom switch: brand purple when on, regardless of window key state.
/// (NSSwitch ignores SwiftUI .tint and desaturates in inactive windows.)
struct PurpleSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn
                      ? AnyShapeStyle(LinearGradient(
                          colors: [OnboardingTheme.purple, OnboardingTheme.purpleLight],
                          startPoint: .leading, endPoint: .trailing))
                      : AnyShapeStyle(Color.white.opacity(0.14)))
                .frame(width: 40, height: 23)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 19, height: 19)
                        .padding(2)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                }
                .shadow(color: configuration.isOn ? OnboardingTheme.glow : .clear, radius: 7)
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

struct Keycap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 26, weight: .semibold, design: .monospaced))
            .foregroundStyle(OnboardingTheme.heading)
            .frame(minWidth: 54, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(OnboardingTheme.lavender.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: OnboardingTheme.glow, radius: 10, y: 2)
    }
}
