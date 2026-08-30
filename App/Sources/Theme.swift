import SwiftUI
import AppKit
import HomePortKit

/// The single source of style for every view in the app: palette, type scale, shape and
/// spacing tokens, transcribed from `docs/specs/ux-designs/.../DESIGN.md`.
///
/// This is deliberately the only file in `App/Sources` that contains a colour, a font size
/// or a corner radius literal. A view that needs a value it cannot find here needs a token
/// added here, not a literal inline.
enum Theme {

    // MARK: - Palette

    static let ink = Color(hex: "#000000")
    static let onPrimary = Color(hex: "#ffffff")
    static let canvas = Color(hex: "#ffffff")
    static let inverseCanvas = Color(hex: "#000000")
    static let inverseInk = Color(hex: "#ffffff")
    static let hairline = Color(hex: "#e6e6e6")
    static let hairlineSoft = Color(hex: "#f1f1f1")
    static let surfaceSoft = Color(hex: "#f7f7f5")

    /// Darker than the pastel green of the palette on purpose: this one is *text*, at 11 px
    /// mono on white canvas, so it has to clear 4.5:1 (it reads 5.09:1) while the warning
    /// and critical inks it sits next to read 5.02:1 and 4.85:1. Same hue as the palette's
    /// green, one step down in lightness.
    static let semanticSuccess = Color(hex: "#157f39")
    static let semanticWarning = Color(hex: "#b45309")
    static let semanticCritical = Color(hex: "#d2372f")

    /// The only place a `MachineBlock` becomes a colour — the kit stays SwiftUI-free. The
    /// seven hex values live on the enum cases and nowhere else: a second copy here would be
    /// a palette that can drift from the one the assignment logic is tested against.
    static func color(of block: MachineBlock) -> Color {
        Color(hex: block.hex)
    }

    static func color(of severity: FleetRow.Severity) -> Color {
        switch severity {
        case .ok: return semanticSuccess
        case .warning: return semanticWarning
        case .critical: return semanticCritical
        }
    }

    // MARK: - Shape

    enum Rounded {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 16
        static let pill: CGFloat = 50
    }

    // MARK: - Spacing

    enum Spacing {
        static let hair: CGFloat = 1
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    /// Fixed sizes the layout section of DESIGN.md pins down.
    enum Metrics {
        static let sidebarWidth: CGFloat = 220
        static let sidebarRowHeight: CGFloat = 28
        static let tableRowHeight: CGFloat = 26
        static let blockDot: CGFloat = 8
        static let focusRing: CGFloat = 2
        /// macOS paints a unified-toolbar strip over the top of a `NavigationSplitView`'s
        /// detail column, and SwiftUI does not account for it: measured from inside the
        /// detail, `safeAreaInsets.top` reads 0 while the strip covers the first 28 points.
        /// Without this the machine banner's title is drawn under it and reads as clipped.
        static let splitViewTopStrip: CGFloat = 28
        /// A `Chart` has no intrinsic height: inside the machine sheet's `ScrollView` an
        /// unconstrained one collapses to nothing, so a metric card states its own.
        static let metricChartHeight: CGFloat = 120
        /// The narrowest a metric card may get before its curve stops being readable. Two
        /// columns at the nominal 1040pt, still two at the 900pt minimum.
        static let metricCardMinWidth: CGFloat = 280
        static let windowMinWidth: CGFloat = 900
        static let windowMinHeight: CGFloat = 600
    }

    // MARK: - Typography

    /// DESIGN.md expresses weights as variable-font values; SwiftUI only takes named
    /// weights. This table is the whole conversion, and it lives only here.
    ///
    ///     340 → .light      400 → .regular    480 → .medium
    ///     540 → .semibold   600 → .bold
    struct TextStyle {
        let font: Font
        let tracking: CGFloat
        let lineSpacing: CGFloat
    }

    static let windowTitle = TextStyle(font: sans(22, .light), tracking: -0.33, lineSpacing: 3.3)
    static let sectionTitle = TextStyle(font: sans(16, .semibold), tracking: -0.16, lineSpacing: 4.8)
    static let body = TextStyle(font: sans(13, .regular), tracking: 0, lineSpacing: 5.85)
    static let bodyStrong = TextStyle(font: sans(13, .bold), tracking: 0, lineSpacing: 5.85)
    static let button = TextStyle(font: sans(13, .medium), tracking: -0.06, lineSpacing: 5.2)
    static let eyebrow = TextStyle(font: mono(11, .regular), tracking: 0.55, lineSpacing: 3.3)
    static let data = TextStyle(font: mono(12, .regular), tracking: 0, lineSpacing: 6)
    static let caption = TextStyle(font: mono(10, .regular), tracking: 0.50, lineSpacing: 2)

    // MARK: - Font resolution

    /// The documented stacks (`Inter, PingFang SC, SF Pro Display, system-ui`) are walked
    /// once at launch and the *first family the system can actually render* is the one the
    /// app draws with — that is the contract the frozen matrix states, not merely a
    /// compromise: no font binary ships in the repository, so the head of a stack is
    /// normally absent and a fallback position is the expected outcome, not a failure.
    /// `.system` is kept for the one case the stack cannot cover — nothing in it installed,
    /// which on macOS means the last entry (`system-ui`, a CSS keyword and not a family)
    /// was the only candidate left. The stacks themselves stay in `HomePortKit.FontStack`
    /// where `resolveFontFamily` is covered by `swift test`.
    private static let sansFamily = resolveFontFamily(preferred: FontStack.sans,
                                                      isAvailable: isInstalled)
    private static let monoFamily = resolveFontFamily(preferred: FontStack.mono,
                                                      isAvailable: isInstalled)

    private static func isInstalled(_ family: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }

    private static func sans(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        guard let sansFamily else {
            return .system(size: size, weight: weight, design: .default)
        }
        return .custom(sansFamily, fixedSize: size).weight(weight)
    }

    /// Data is always tabular: columns of versions, percentages and durations must align.
    private static func mono(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        guard let monoFamily else {
            return .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
        }
        return .custom(monoFamily, fixedSize: size).weight(weight).monospacedDigit()
    }
}

extension Color {
    /// `#rrggbb` → colour. The only hex parser in the app; every call site is above.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt64(digits, radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255,
                  opacity: 1)
    }
}

extension Text {
    /// Applies a full type token — face, size, weight and tracking.
    func styled(_ style: Theme.TextStyle) -> Text {
        font(style.font).tracking(style.tracking)
    }
}

extension View {
    /// Face, size and the documented line height. `Text.styled` adds the tracking a bare
    /// `Text` can carry; this is what non-`Text` labels and wrapping blocks use — line
    /// height is a `View` modifier, so a `Text` that wraps needs both.
    func themeFont(_ style: Theme.TextStyle) -> some View {
        font(style.font).lineSpacing(style.lineSpacing)
    }
}
