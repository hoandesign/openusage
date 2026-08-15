import Foundation

/// Builds the Meta Model API usage console URL for Muse's Usage quick-link.
///
/// Matches the console's query shape (`start_date` / `end_date`, optional `project_id` /
/// `team_id`). The date window is the same inclusive last-30-days local calendar range the
/// spend tiles use. Project/team ids are optional — set `META_PROJECT_ID` / `META_TEAM_ID` when
/// you want the console to open on a specific Meta project.
enum MuseUsageURL {
    static let base = "https://dev.meta.ai/usage/"

    static func make(
        now: Date,
        calendar: Calendar = .current,
        projectID: String? = nil,
        teamID: String? = nil
    ) -> String {
        let endDay = calendar.startOfDay(for: now)
        let startDay = calendar.date(byAdding: .day, value: -29, to: endDay) ?? endDay

        var items: [URLQueryItem] = [
            URLQueryItem(name: "start_date", value: DailyUsageAccumulator.dayKey(from: startDay, calendar: calendar)),
            URLQueryItem(name: "end_date", value: DailyUsageAccumulator.dayKey(from: endDay, calendar: calendar))
        ]
        if let projectID = trimmed(projectID) {
            items.append(URLQueryItem(name: "project_id", value: projectID))
        }
        if let teamID = trimmed(teamID) {
            items.append(URLQueryItem(name: "team_id", value: teamID))
        }

        var components = URLComponents(string: base)!
        components.queryItems = items
        return components.url?.absoluteString ?? base
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
