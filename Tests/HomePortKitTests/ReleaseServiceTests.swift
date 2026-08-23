import XCTest
@testable import HomePortKit

final class ReleaseServiceTests: XCTestCase {
    private var mock: MockProcessRunner!
    private var cacheDir: String!
    private var service: ReleaseService!

    override func setUp() {
        super.setUp()
        mock = MockProcessRunner()
        cacheDir = NSTemporaryDirectory() + "hpm-cache-\(UUID().uuidString)"
        service = ReleaseService(runner: mock, repo: "vincentlauriat/homeport", cacheDir: cacheDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: cacheDir)
        super.tearDown()
    }

    func testListParsesReleases() throws {
        mock.stub(matching: "api.github.com/repos/vincentlauriat/homeport/releases",
                  stdout: #"[{"tag_name":"v0.4.0","published_at":"2026-08-18T10:00:00Z"},{"tag_name":"v0.3.0","published_at":"2026-08-01T10:00:00Z"}]"#)
        let releases = try service.list()
        XCTAssertEqual(releases.map(\.tag), ["v0.4.0", "v0.3.0"])
        XCTAssertEqual(releases[0].publishedAt, "2026-08-18T10:00:00Z")
    }

    func testListFallsBackToTags() throws {
        mock.stub(matching: "/releases", stdout: "[]")
        mock.stub(matching: "/tags", stdout: #"[{"name":"v0.4.0"},{"name":"v0.3.0"}]"#)
        XCTAssertEqual(try service.list().map(\.tag), ["v0.4.0", "v0.3.0"])
    }

    func testLatest() throws {
        mock.stub(matching: "/releases", stdout: #"[{"tag_name":"v0.4.0","published_at":null}]"#)
        XCTAssertEqual(try service.latest().tag, "v0.4.0")
    }

    func testLatestThrowsWhenEmpty() {
        mock.stub(matching: "/releases", stdout: "[]")
        mock.stub(matching: "/tags", stdout: "[]")
        XCTAssertThrowsError(try service.latest())
    }

    func testDownloadTarballBuildsURL() throws {
        let path = try service.downloadTarball(tag: "v0.4.0")
        XCTAssertEqual(path, cacheDir + "/homeport-v0.4.0.tar.gz")
        let line = mock.calls[0].line
        XCTAssertTrue(line.contains("https://github.com/vincentlauriat/homeport/archive/refs/tags/v0.4.0.tar.gz"))
        XCTAssertTrue(line.contains("-o \(cacheDir!)/homeport-v0.4.0.tar.gz"))
    }

    func testDownloadTarballUsesCache() throws {
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cacheDir + "/homeport-v0.4.0.tar.gz", contents: Data("x".utf8))
        _ = try service.downloadTarball(tag: "v0.4.0")
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testDownloadFailureThrows() {
        mock.stub(matching: "curl", exitCode: 22, stderr: "404")
        XCTAssertThrowsError(try service.downloadTarball(tag: "v9.9.9"))
    }
}
