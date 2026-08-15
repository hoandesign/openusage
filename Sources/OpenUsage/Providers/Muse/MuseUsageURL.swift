import Foundation

/// Builds the Meta Model API usage console URL for Muse's Usage quick-link.
///
/// The console SPA requires `project_id` + `team_id` in the query. Opening with only
/// `start_date` / `end_date` lets Meta inject those ids itself and rewrite the URL — which
/// drops the date window. So we only attach the last-30-days range when both ids are known;
/// otherwise we fall back to the bare usage page.
///
/// Query order matches the console's own links:
/// `end_date`, `project_id`, `start_date`, `team_id`.
enum MuseUsageURL {
    static let base = "https://dev.meta.ai/usage"

    static func make(
        now: Date,
        calendar: Calendar = .current,
        projectID: String? = nil,
        teamID: String? = nil
    ) -> String {
        guard let projectID = Self.trimmed(projectID), let teamID = Self.trimmed(teamID) else {
            return base
        }

        let endDay = calendar.startOfDay(for: now)
        let startDay = calendar.date(byAdding: .day, value: -29, to: endDay) ?? endDay
        let end = DailyUsageAccumulator.dayKey(from: endDay, calendar: calendar)
        let start = DailyUsageAccumulator.dayKey(from: startDay, calendar: calendar)

        // Build the query by hand so param order stays identical to Meta's console links.
        // URLComponents does not guarantee order, and a reshuffled query still trips the SPA rewrite.
        return "\(base)/?end_date=\(end)&project_id=\(projectID)&start_date=\(start)&team_id=\(teamID)"
    }

    fileprivate static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Resolves Meta console project/team ids for Muse Usage links.
///
/// Priority: `META_PROJECT_ID` / `META_TEAM_ID` env → OpenUsage-saved context file →
/// optional `project_id` / `team_id` keys in `~/.config/muse/settings.json`.
struct MuseConsoleContext: Sendable, Equatable {
    var projectID: String?
    var teamID: String?

    static func resolve(
        environment: EnvironmentReading,
        files: TextFileAccessing,
        homeDirectory: @escaping @Sendable () -> URL,
        applicationSupportDirectory: @escaping @Sendable () -> URL = {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenUsage", isDirectory: true)
        }
    ) -> MuseConsoleContext {
        let envProject = MuseUsageURL.trimmed(environment.value(for: "META_PROJECT_ID"))
        let envTeam = MuseUsageURL.trimmed(environment.value(for: "META_TEAM_ID"))
        if envProject != nil || envTeam != nil {
            return MuseConsoleContext(projectID: envProject, teamID: envTeam)
        }

        if let saved = readJSON(at: savedContextPath(applicationSupportDirectory), files: files) {
            return saved
        }

        let settingsPath: String = {
            if let xdg = environment.value(for: "XDG_CONFIG_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !xdg.isEmpty {
                return (xdg as NSString).appendingPathComponent("muse/settings.json")
            }
            return homeDirectory().appendingPathComponent(".config/muse/settings.json").path
        }()
        if let fromSettings = readJSON(at: settingsPath, files: files) {
            return fromSettings
        }

        return MuseConsoleContext(projectID: nil, teamID: nil)
    }

    /// Persists ids so the menu-bar app (which often inherits no shell env) can keep a dated Usage link.
    static func save(
        projectID: String,
        teamID: String,
        files: TextFileAccessing,
        applicationSupportDirectory: @escaping @Sendable () -> URL = {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenUsage", isDirectory: true)
        }
    ) throws {
        guard let projectID = MuseUsageURL.trimmed(projectID),
              let teamID = MuseUsageURL.trimmed(teamID) else { return }
        let payload: [String: String] = ["project_id": projectID, "team_id": teamID]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { return }
        try files.writeText(savedContextPath(applicationSupportDirectory), text)
    }

    private static func savedContextPath(_ applicationSupportDirectory: () -> URL) -> String {
        applicationSupportDirectory().appendingPathComponent("muse-usage-context.json").path
    }

    private static func readJSON(at path: String, files: TextFileAccessing) -> MuseConsoleContext? {
        guard let text = try? files.readTextIfPresent(path),
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let project = (obj["project_id"] as? String) ?? (obj["projectID"] as? String)
        let team = (obj["team_id"] as? String) ?? (obj["teamID"] as? String)
        guard MuseUsageURL.trimmed(project) != nil || MuseUsageURL.trimmed(team) != nil else { return nil }
        return MuseConsoleContext(projectID: project, teamID: team)
    }
}
