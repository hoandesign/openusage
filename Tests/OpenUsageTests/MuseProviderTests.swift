import XCTest
@testable import OpenUsage

@MainActor
final class MuseProviderTests: XCTestCase {
    func testHasLocalCredentialsMirrorsAuthFootprint() async {
        let home = URL(fileURLWithPath: "/Users/test")
        let authPath = home.appendingPathComponent(".config/muse/auth.json").path

        let absent = MuseProvider(
            authStore: MuseAuthStore(files: FakeFiles(), environment: FakeEnvironment(), homeDirectory: { home }),
            logUsageScanner: MuseLogUsageScanner(files: FakeFiles(), environment: FakeEnvironment(), homeDirectory: { home }),
            pricing: { TestPricing.bundled }
        )
        let absentCreds = await absent.hasLocalCredentials()
        XCTAssertFalse(absentCreds)

        let present = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles([authPath: "{}"]),
                environment: FakeEnvironment(),
                homeDirectory: { home }
            ),
            logUsageScanner: MuseLogUsageScanner(files: FakeFiles(), environment: FakeEnvironment(), homeDirectory: { home }),
            pricing: { TestPricing.bundled }
        )
        let presentCreds = await present.hasLocalCredentials()
        XCTAssertTrue(presentCreds)
    }

    func testRefreshWithoutCredentialsErrorsAsNotLoggedIn() async {
        let home = URL(fileURLWithPath: "/Users/none")
        let provider = MuseProvider(
            authStore: MuseAuthStore(files: FakeFiles(), environment: FakeEnvironment(), homeDirectory: { home }),
            logUsageScanner: MuseLogUsageScanner(files: FakeFiles(), environment: FakeEnvironment(), homeDirectory: { home }),
            now: { OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")! },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        guard case .badge(_, let text, _, _) = snapshot.lines.first(where: { $0.label == MetricLine.errorBadgeLabel }) else {
            return XCTFail("expected an error badge")
        }
        XCTAssertEqual(text, MuseAuthError.notLoggedIn.localizedDescription)
    }

    func testRefreshWithCredentialsButNoLogsShowsNoDataNotAuthError() async {
        let home = URL(fileURLWithPath: "/Users/test")
        let provider = MuseProvider(
            authStore: MuseAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["META_API_KEY": "tok"]),
                homeDirectory: { home }
            ),
            logUsageScanner: MuseLogUsageScanner(
                files: FakeFiles(),
                environment: FakeEnvironment(),
                homeDirectory: { home }
            ),
            now: { OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")! },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(values(snapshot.lines, "Today"))
        XCTAssertNil(values(snapshot.lines, "Yesterday"))
        XCTAssertNil(values(snapshot.lines, "Last 30 Days"))
    }

    func testRefreshAppendsSpendTilesAndTrendFromSessionLogs() async throws {
        let now = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
        let xdg = try MuseLogFixture.makeHome(files: [
            "2026/06/18/sess/session.jsonl": MuseLogFixture.sessionFile(
                MuseLogFixture.modelCompleted(
                    recordedAt: "2026-06-18T10:00:00.000Z",
                    model: "muse-spark-1.2-contributor",
                    input: 1_000_000
                )
            ),
            "2026/06/17/sess/session.jsonl": MuseLogFixture.sessionFile(
                MuseLogFixture.modelCompleted(
                    recordedAt: "2026-06-17T10:00:00.000Z",
                    model: "muse-spark",
                    input: 0,
                    output: 1_000_000
                )
            )
        ])
        defer { try? FileManager.default.removeItem(at: xdg) }

        let env = FakeEnvironment(["XDG_DATA_HOME": xdg.path, "META_API_KEY": "tok"])
        let provider = MuseProvider(
            authStore: MuseAuthStore(files: LocalTextFileAccessor(), environment: env, homeDirectory: { URL(fileURLWithPath: "/home/ignored") }),
            logUsageScanner: MuseLogUsageScanner(files: LocalTextFileAccessor(), environment: env, homeDirectory: { URL(fileURLWithPath: "/home/ignored") }),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        // Today (contributor): 1M input @ $0.10. Yesterday (standard): 1M output @ $4.25.
        XCTAssertEqual(
            values(snapshot.lines, "Today"),
            [MetricValue(number: 0.10, kind: .dollars, estimated: true), MetricValue(number: 1_000_000, kind: .count, label: "tokens")]
        )
        XCTAssertEqual(
            values(snapshot.lines, "Yesterday"),
            [MetricValue(number: 4.25, kind: .dollars, estimated: true), MetricValue(number: 1_000_000, kind: .count, label: "tokens")]
        )
        XCTAssertEqual(
            values(snapshot.lines, "Last 30 Days"),
            [MetricValue(number: 4.35, kind: .dollars, estimated: true), MetricValue(number: 2_000_000, kind: .count, label: "tokens")]
        )

        guard case .chart(_, let points, let note) = snapshot.lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("expected a Usage Trend chart line")
        }
        XCTAssertEqual(note, "From Muse CLI session logs on this Mac (estimated)")
        XCTAssertEqual(points.last?.value, 1_000_000)
        XCTAssertEqual(points[points.count - 2].value, 1_000_000)
        XCTAssertNotNil(snapshot.usageHistory)
    }

    func testWidgetDescriptorsExposeTrendAndSpendTiles() {
        let provider = MuseProvider(pricing: { TestPricing.bundled })
        let ids = provider.widgetDescriptors.map(\.id)
        XCTAssertEqual(ids, ["muse.trend", "muse.today", "muse.yesterday", "muse.last30"])
    }

    func testUsageLinkUsesLast30DaysAndOptionalProjectTeamFromEnv() {
        let now = OpenUsageISO8601.date(from: "2026-08-15T12:00:00.000Z")!
        let env = FakeEnvironment([
            "META_PROJECT_ID": "2165947557682142",
            "META_TEAM_ID": "1430796172289191"
        ])
        let provider = MuseProvider(
            authStore: MuseAuthStore(files: FakeFiles(), environment: env, homeDirectory: { URL(fileURLWithPath: "/home") }),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        XCTAssertEqual(
            provider.provider.links.first { $0.label == "Usage" }?.url,
            "https://dev.meta.ai/usage/?end_date=2026-08-15&project_id=2165947557682142&start_date=2026-07-17&team_id=1430796172289191"
        )
        XCTAssertEqual(provider.provider.links.first { $0.label == "Dashboard" }?.url, "https://dev.meta.ai/")
    }

    func testUsageLinkFallsBackToBarePageWithoutProjectTeamIds() {
        let now = OpenUsageISO8601.date(from: "2026-08-15T12:00:00.000Z")!
        let provider = MuseProvider(
            authStore: MuseAuthStore(files: FakeFiles(), environment: FakeEnvironment(), homeDirectory: { URL(fileURLWithPath: "/home") }),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        XCTAssertEqual(provider.provider.links.first { $0.label == "Usage" }?.url, "https://dev.meta.ai/usage")
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}
