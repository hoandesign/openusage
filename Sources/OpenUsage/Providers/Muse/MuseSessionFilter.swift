import Foundation

/// Decides whether a Muse session log belongs to the Muse CLI coding agent (not other Meta API clients).
enum MuseSessionFilter {
    static let museSparkModelPrefix = "muse-spark"

    static func isMuseSparkModel(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == museSparkModelPrefix || trimmed.hasPrefix("\(museSparkModelPrefix)-")
    }

    /// Whether a `session.jsonl` path should contribute to Muse spend tiles.
    static func qualifiesSessionFile(at path: String, files: TextFileAccessing) -> Bool {
        if path.contains("/subagent/") {
            guard let parent = parentSessionPath(for: path) else { return false }
            return qualifiesSessionFile(at: parent, files: files)
        }
        return hasMuseCodingMetadata(in: path, files: files)
    }

    static func parentSessionPath(for path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard url.pathComponents.contains("subagent") else { return nil }
        let sessionDir = url
            .deletingLastPathComponent() // agent id
            .deletingLastPathComponent() // subagent
            .deletingLastPathComponent() // session id
        return sessionDir.appendingPathComponent("session.jsonl").path
    }

    private static func hasMuseCodingMetadata(in path: String, files: TextFileAccessing) -> Bool {
        guard let text = try? files.readTextIfPresent(path) else { return false }
        for rawLine in text.split(separator: "\n", maxSplits: 256, omittingEmptySubsequences: true) {
            guard let data = String(rawLine).data(using: .utf8),
                  let object = ProviderParse.jsonObject(data),
                  object["payload_type"] as? String == "runtime.session.metadata",
                  let payload = object["payload"] as? [String: Any],
                  let record = payload["record"] as? [String: Any],
                  record["provider_id"] as? String == "meta",
                  record["build"] is [String: Any] else { continue }
            return true
        }
        return false
    }
}
