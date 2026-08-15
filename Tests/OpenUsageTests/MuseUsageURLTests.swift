import XCTest
@testable import OpenUsage

final class MuseUsageURLTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private let now = OpenUsageISO8601.date(from: "2026-08-15T12:00:00.000Z")!

    func testWithoutIdsFallsBackToBareUsagePage() {
        // Dates alone let Meta inject project/team and rewrite away the window.
        XCTAssertEqual(MuseUsageURL.make(now: now, calendar: calendar), "https://dev.meta.ai/usage")
        XCTAssertEqual(
            MuseUsageURL.make(now: now, calendar: calendar, projectID: "2165947557682142"),
            "https://dev.meta.ai/usage"
        )
    }

    func testWithBothIdsUsesMetaConsoleParamOrderAndLast30Days() {
        let url = MuseUsageURL.make(
            now: now,
            calendar: calendar,
            projectID: "2165947557682142",
            teamID: "1430796172289191"
        )

        XCTAssertEqual(
            url,
            "https://dev.meta.ai/usage/?end_date=2026-08-15&project_id=2165947557682142&start_date=2026-07-17&team_id=1430796172289191"
        )
    }

    func testBlankIdsAreTreatedAsMissing() {
        XCTAssertEqual(
            MuseUsageURL.make(now: now, calendar: calendar, projectID: "  ", teamID: "1430796172289191"),
            "https://dev.meta.ai/usage"
        )
    }

    func testResolvePrefersEnvThenSavedContextThenMuseSettings() throws {
        let support = URL(fileURLWithPath: "/tmp/ou-muse-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }

        let files = FakeFiles([
            support.appendingPathComponent("muse-usage-context.json").path:
                #"{"project_id":"from-file","team_id":"from-file-team"}"#,
            "/home/.config/muse/settings.json":
                #"{"project_id":"from-settings","team_id":"from-settings-team"}"#
        ])

        let fromEnv = MuseConsoleContext.resolve(
            environment: FakeEnvironment([
                "META_PROJECT_ID": "env-project",
                "META_TEAM_ID": "env-team"
            ]),
            files: files,
            homeDirectory: { URL(fileURLWithPath: "/home") },
            applicationSupportDirectory: { support }
        )
        XCTAssertEqual(fromEnv, MuseConsoleContext(projectID: "env-project", teamID: "env-team"))

        let fromFile = MuseConsoleContext.resolve(
            environment: FakeEnvironment(),
            files: files,
            homeDirectory: { URL(fileURLWithPath: "/home") },
            applicationSupportDirectory: { support }
        )
        XCTAssertEqual(fromFile, MuseConsoleContext(projectID: "from-file", teamID: "from-file-team"))

        let filesSettingsOnly = FakeFiles([
            "/home/.config/muse/settings.json":
                #"{"project_id":"from-settings","team_id":"from-settings-team"}"#
        ])
        let fromSettings = MuseConsoleContext.resolve(
            environment: FakeEnvironment(),
            files: filesSettingsOnly,
            homeDirectory: { URL(fileURLWithPath: "/home") },
            applicationSupportDirectory: { support }
        )
        XCTAssertEqual(fromSettings, MuseConsoleContext(projectID: "from-settings", teamID: "from-settings-team"))
    }
}
