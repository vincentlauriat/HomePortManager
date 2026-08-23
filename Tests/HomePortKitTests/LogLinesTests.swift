import XCTest
@testable import HomePortKit

/// The pure half of the log capability — everything the app's log viewer decides is decided
/// here, where it is executable.
final class LogLinesTests: XCTestCase {

    // MARK: - Error classification

    func testClassifiesErrorTokens() {
        XCTAssertTrue(logLineIsError("ERROR: could not bind"))
        XCTAssertTrue(logLineIsError("Failed to start homeport.service"))
        XCTAssertTrue(logLineIsError("panic: runtime error"))
        XCTAssertTrue(logLineIsError("segfault at 0x0"))
        XCTAssertTrue(logLineIsError("Traceback (most recent call last):"))
        XCTAssertTrue(logLineIsError("unhandled Exception in worker"))
        XCTAssertTrue(logLineIsError("CRITICAL disk pressure"))
        XCTAssertTrue(logLineIsError("health check failing"))
        XCTAssertTrue(logLineIsError("fatal: repository not found"))
        XCTAssertTrue(logLineIsError("backup failure recorded"))
    }

    func testClassificationIsCaseInsensitive() {
        XCTAssertTrue(logLineIsError("eRrOr while reloading"))
        XCTAssertTrue(logLineIsError("FaTaL condition"))
    }

    func testNegatedOccurrencesAreNotErrors() {
        XCTAssertFalse(logLineIsError("no errors"))
        XCTAssertFalse(logLineIsError("0 errors found"))
        XCTAssertFalse(logLineIsError("doctor: no error detected"))
    }

    func testNegationOnlyCoversTheImmediatelyFollowingToken() {
        // "no" guards "warnings", not the "error" three words later.
        XCTAssertTrue(logLineIsError("no warnings but one error"))
    }

    func testWordBoundariesExcludeSubstringMatches() {
        XCTAssertFalse(logLineIsError("errno 111 connection refused"))
        XCTAssertFalse(logLineIsError("writing to /var/log/error_log"))
        XCTAssertFalse(logLineIsError("terrorist"))
    }

    func testOrdinaryLineIsNotAnError() {
        XCTAssertFalse(logLineIsError("Aug 24 09:12:01 raspcorse homeport[812]: mqtt connected"))
        XCTAssertFalse(logLineIsError(""))
    }

    func testPunctuationDelimitsTokens() {
        XCTAssertTrue(logLineIsError("homeport[812]: (error)"))
        XCTAssertTrue(logLineIsError("state=failed"))
    }

    // MARK: - LineSplitter

    func testSplitterHoldsBackAnIncompleteLine() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.push("alpha\nbra"), ["alpha"])
        XCTAssertEqual(splitter.push("vo\ncharlie\n"), ["bravo", "charlie"])
        XCTAssertNil(splitter.flush())
    }

    func testSplitterEmitsNothingForAChunkWithoutNewline() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.push("no newline here"), [])
        XCTAssertEqual(splitter.flush(), "no newline here")
        XCTAssertNil(splitter.flush())
    }

    func testSplitterTrimsCarriageReturns() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.push("alpha\r\nbravo\r\n"), ["alpha", "bravo"])
        XCTAssertEqual(splitter.push("tail\r"), [])
        XCTAssertEqual(splitter.flush(), "tail")
    }

    func testSplitterKeepsBlankLines() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.push("alpha\n\nbravo\n"), ["alpha", "", "bravo"])
    }

    // MARK: - splitLogLines

    func testSplitLogLinesOnEmptyInput() {
        XCTAssertEqual(splitLogLines(""), [])
    }

    func testSplitLogLinesDoesNotInventATrailingEmptyLine() {
        XCTAssertEqual(splitLogLines("alpha\nbravo\n"), ["alpha", "bravo"])
        XCTAssertEqual(splitLogLines("alpha\nbravo"), ["alpha", "bravo"])
    }

    // MARK: - LogBuffer

    func testBufferIdsAreMonotoneAndNeverReused() {
        var buffer = LogBuffer(cap: 10)
        buffer.append(["a", "b"])
        XCTAssertEqual(buffer.lines.map(\.id), [0, 1])
        buffer.reset()
        buffer.append(["c"])
        XCTAssertEqual(buffer.lines.map(\.id), [2])
        XCTAssertEqual(buffer.lines.map(\.text), ["c"])
    }

    func testBufferDropsTheOldestLinesPastItsCap() {
        var buffer = LogBuffer(cap: 3)
        buffer.append(["1", "2", "3", "4", "5"])
        XCTAssertEqual(buffer.lines.count, 3)
        XCTAssertEqual(buffer.lines.map(\.text), ["3", "4", "5"])
        buffer.append(["6"])
        XCTAssertEqual(buffer.lines.map(\.text), ["4", "5", "6"])
        XCTAssertEqual(buffer.lines.count, 3)
    }

    func testBufferTagsErrorLinesOnce() {
        var buffer = LogBuffer()
        buffer.append(["all good", "ERROR: nope"])
        XCTAssertEqual(buffer.lines.map(\.isError), [false, true])
    }

    func testDefaultBufferCapIsTheDocumentedOne() {
        XCTAssertEqual(LogDefaults.bufferCap, 1000)
        XCTAssertEqual(LogDefaults.tail, 200)
        XCTAssertEqual(LogBuffer().cap, LogDefaults.bufferCap)
    }

    // MARK: - Filter

    private var sample: [LogLine] {
        var buffer = LogBuffer()
        buffer.append(["mqtt connected", "MQTT retry", "zigbee paired"])
        return buffer.lines
    }

    func testFilterIsCaseInsensitive() {
        XCTAssertEqual(filterLogLines(sample, matching: "mqtt").map(\.text),
                       ["mqtt connected", "MQTT retry"])
    }

    func testEmptyFilterKeepsEverything() {
        XCTAssertEqual(filterLogLines(sample, matching: "").count, 3)
    }

    func testWhitespaceOnlyFilterKeepsEverything() {
        XCTAssertEqual(filterLogLines(sample, matching: "   ").count, 3)
    }

    func testFilterWithNoMatchKeepsNothing() {
        XCTAssertTrue(filterLogLines(sample, matching: "zzz").isEmpty)
    }
}
