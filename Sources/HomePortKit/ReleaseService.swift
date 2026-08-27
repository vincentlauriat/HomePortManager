import Foundation

public struct Release: Equatable {
    public let tag: String
    public let publishedAt: String?
    /// GitHub's release body (its Markdown notes) — nil for a tags-fallback entry (the
    /// `/tags` endpoint carries no notes) and for a tagged release published without any.
    public let notes: String?
    public init(tag: String, publishedAt: String? = nil, notes: String? = nil) {
        self.tag = tag
        self.publishedAt = publishedAt
        self.notes = notes
    }
}

/// Resolves and downloads Homeport versions from GitHub. Network access goes through
/// curl (via ProcessRunner) so the whole service is mockable; tarballs are the source
/// archives of tags, which exist for any tag even without a published release.
public final class ReleaseService {
    private let runner: ProcessRunner
    private let repo: String
    private let cacheDir: String

    public init(runner: ProcessRunner, repo: String = "vincentlauriat/homeport", cacheDir: String = "~/.cache/hpm") {
        self.runner = runner
        self.repo = repo
        self.cacheDir = expandPath(cacheDir)
    }

    private struct APIRelease: Decodable {
        let tag_name: String
        let published_at: String?
        let body: String?
    }

    private struct APITag: Decodable {
        let name: String
    }

    public func list() throws -> [Release] {
        let releasesJSON = try fetch("https://api.github.com/repos/\(repo)/releases")
        let releases = try decode([APIRelease].self, from: releasesJSON)
        if !releases.isEmpty {
            return releases.map { Release(tag: $0.tag_name, publishedAt: $0.published_at, notes: $0.body) }
        }
        let tagsJSON = try fetch("https://api.github.com/repos/\(repo)/tags")
        return try decode([APITag].self, from: tagsJSON).map { Release(tag: $0.name) }
    }

    public func latest() throws -> Release {
        guard let first = try list().first else {
            throw HPMError("no releases or tags found for \(repo)")
        }
        return first
    }

    /// Returns the local path of the tarball for `tag`, downloading it only when
    /// it is not already in the cache.
    public func downloadTarball(tag: String) throws -> String {
        let path = "\(cacheDir)/homeport-\(tag).tar.gz"
        if FileManager.default.fileExists(atPath: path) { return path }
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let url = "https://github.com/\(repo)/archive/refs/tags/\(tag).tar.gz"
        let result = try runner.run("/usr/bin/curl", ["-fsSL", "-o", path, url])
        guard result.succeeded else {
            throw HPMError("download of \(url) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return path
    }

    private func fetch(_ url: String) throws -> String {
        let result = try runner.run("/usr/bin/curl", ["-fsS", url])
        guard result.succeeded else {
            throw HPMError("GitHub API request failed (\(url)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            throw HPMError("unexpected GitHub API response: \(error)")
        }
    }
}
