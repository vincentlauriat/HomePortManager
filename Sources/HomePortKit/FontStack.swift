import Foundation

/// The documented font fallback stacks. They are written CSS-style, and that matters: in a
/// browser the cascade is resolved *per glyph*, so `PingFang SC` sits in both stacks only to
/// cover Chinese characters that the head font has no glyphs for.
///
/// SwiftUI has no per-glyph cascade — `Font.custom` takes one family for the whole run of
/// text — so the stacks cannot be transposed literally: resolving to `PingFang SC` would draw
/// a French interface in a Chinese face, and would resolve the *mono* stack to a font that is
/// not even fixed-width, breaking the tabular alignment the data table depends on.
///
/// macOS already covers CJK on its own for any family, so the coverage entries are skipped
/// when picking the interface family, and only there.
public enum FontStack {
    /// Prose, titles, buttons.
    public static let sans = ["Inter", "PingFang SC", "SF Pro Display", "system-ui"]
    /// Data, eyebrows, captions — never a paragraph.
    public static let mono = ["JetBrains Mono", "PingFang SC", "SF Mono", "Menlo"]

    /// Families present in the stacks for CJK coverage only, never as the interface face.
    /// Skipping them is what keeps the mono stack fixed-width.
    public static let coverageOnly: Set<String> = ["PingFang SC"]
}

/// First family of `preferred` that the system can actually render and that is not there for
/// glyph coverage alone, or `nil` when none of the stack qualifies — in which case the caller
/// falls back on the system face, which is the right answer on macOS.
///
/// Injecting `isAvailable` keeps the resolution testable without depending on what happens to
/// be installed on the running machine.
public func resolveFontFamily(preferred: [String],
                              isAvailable: (String) -> Bool) -> String? {
    preferred.first { !FontStack.coverageOnly.contains($0) && isAvailable($0) }
}
