import Foundation

/// The defaults of the app's Logs tab, named here so the tab and its tests read the same
/// numbers. Deliberately *not* imposed on the older call sites: `logs(on:lines:)` keeps its
/// 50-line default and `hpm logs` its `-n 50`, because the story that added this tab requires
/// the CLI's existing behaviour to be preserved exactly.
public enum LogDefaults {
    /// Lines the remote `journalctl` serves before it starts following.
    public static let tail = 200
    /// Lines a buffer keeps. The whole buffer is laid out as one attributed string, so this
    /// is a rendering budget, not a memory one — the oldest lines fall off.
    public static let bufferCap = 1000
}

/// One journal line, tagged once at ingestion. `id` is monotone within a buffer so a view
/// can tell "new lines arrived" apart from "the same lines re-rendered", and never reuses a
/// value even across a buffer reset.
public struct LogLine: Identifiable, Equatable {
    public let id: Int
    public let text: String
    public let isError: Bool

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
        self.isError = logLineIsError(text)
    }
}

/// The tokens that make a line an error line. Frozen: the app tints on text, not on the
/// journald `PRIORITY` field, because reading that field would mean a different remote
/// command (`journalctl -o json`) than the one the CLI runs for the same capability.
private let errorTokens: Set<String> = [
    "error", "errors", "failed", "failure", "failing", "fatal",
    "critical", "panic", "segfault", "traceback", "exception",
]

/// Words that neutralise the token immediately after them: `no errors` and `0 errors found`
/// are the two ways a healthy journal announces itself, and tinting them red would make the
/// colour meaningless on exactly the lines an operator scans for.
private let negations: Set<String> = ["no", "0"]

/// Is this line an error line? Pure and total, case-insensitive, on word boundaries — a
/// word being a maximal run of `[A-Za-z0-9_]`, so `errno` and `error_log` are single tokens
/// and match nothing.
public func logLineIsError(_ line: String) -> Bool {
    var previous: String?
    var current = ""
    var verdict = false

    func consider(_ token: String) {
        guard !token.isEmpty else { return }
        if errorTokens.contains(token), !(previous.map(negations.contains) ?? false) {
            verdict = true
        }
        previous = token
    }

    for scalar in line.lowercased().unicodeScalars {
        if isWordScalar(scalar) {
            current.unicodeScalars.append(scalar)
        } else {
            consider(current)
            current = ""
        }
    }
    consider(current)
    return verdict
}

private func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    (scalar >= "a" && scalar <= "z")
        || (scalar >= "A" && scalar <= "Z")
        || (scalar >= "0" && scalar <= "9")
        || scalar == "_"
}

/// Cuts a byte-per-byte stream into whole lines. A chunk arriving from a pipe stops wherever
/// the kernel decided, which is regularly mid-line: what is not terminated is held back
/// until the rest arrives, so a line is never published in two halves.
public struct LineSplitter {
    private var pending = ""

    public init() {}

    /// The lines completed by this chunk, in order. A chunk with no newline yields nothing.
    ///
    /// Scalar by scalar, not `firstIndex(of: "\n")`: Swift reads `\r\n` as a *single*
    /// `Character`, so a `Character`-level search finds no newline at all in CRLF output and
    /// the splitter would hold the whole stream back forever.
    public mutating func push(_ chunk: String) -> [String] {
        guard !chunk.isEmpty else { return [] }
        var lines: [String] = []
        var current = pending
        for scalar in chunk.unicodeScalars {
            if scalar == "\n" {
                lines.append(Self.trimCarriageReturn(current))
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        pending = current
        return lines
    }

    /// The unterminated remainder, once no more input is coming. `nil` when the stream ended
    /// on a newline — the common case, and not an empty last line.
    public mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let tail = pending
        pending = ""
        return Self.trimCarriageReturn(tail)
    }

    /// CRLF is not journald's doing, but a line can travel through anything.
    private static func trimCarriageReturn(_ line: String) -> String {
        guard line.unicodeScalars.last == "\r" else { return line }
        var scalars = line.unicodeScalars
        scalars.removeLast()
        return String(scalars)
    }
}

/// A whole blob of output cut into lines — the one-shot counterpart of `LineSplitter`.
public func splitLogLines(_ text: String) -> [String] {
    var splitter = LineSplitter()
    var lines = splitter.push(text)
    if let tail = splitter.flush() { lines.append(tail) }
    return lines
}

/// The lines a filter keeps, case-insensitively. A blank filter — empty or whitespace only —
/// keeps everything: it is a filter not yet written, not a filter that matches nothing.
public func filterLogLines(_ lines: [LogLine], matching filter: String) -> [LogLine] {
    let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return lines }
    return lines.filter { $0.text.range(of: needle, options: .caseInsensitive) != nil }
}

/// The capped, monotonically identified line buffer behind a log view. Holding it here
/// rather than in the view keeps the two rules that matter — ids never repeat, the oldest
/// lines fall off past the cap — under `swift test`.
public struct LogBuffer {
    public private(set) var lines: [LogLine] = []
    public let cap: Int
    private var nextID = 0

    public init(cap: Int = LogDefaults.bufferCap) {
        self.cap = max(1, cap)
    }

    public mutating func append(_ texts: [String]) {
        guard !texts.isEmpty else { return }
        for text in texts {
            lines.append(LogLine(id: nextID, text: text))
            nextID += 1
        }
        if lines.count > cap {
            lines.removeFirst(lines.count - cap)
        }
    }

    /// Empties the buffer without rewinding the ids: a reset means a new remote command owns
    /// the buffer, and a recycled id would read to a view as "the same line came back".
    public mutating func reset() {
        lines.removeAll()
    }
}
