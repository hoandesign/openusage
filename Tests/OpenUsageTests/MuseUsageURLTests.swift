import XCTest
@testable import OpenUsage

final class MuseUsageURLTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    func testLast30DaysInclusiveWindowMatchesMetaConsole() {
        // 2026-08-15 end → 2026-07-17 start (29 days earlier = 30 inclusive days).
        let now = OpenUsageISO8601.date(from: "2026-08-15T12:00:00.000Z")!

        let url = MuseUsageURL.make(now: now, calendar: calendar)

        XCTAssertEqual(
            url,
            "https://dev.meta.ai/usage/?start_date=2026-07-17&end_date=2026-08-15"
        )
    }

    func testAppendsProjectAndTeamWhenProvided() {
        let now = OpenUsageISO8601.date(from: "2026-08-15T12:00:00.000Z")!

        let url = MuseUsageURL.make(
            now: now,
            calendar: calendar,
            projectID: "2165947557682142",
            teamID: "1430796172289191"
        )

        XCTAssertEqual(
            url,
            "https://dev.meta.ai/usage/?start_date=2026-07-17&end_date=2026-08-15&project_id=2165947557682142&team_id=1430796172289191"
        )
    }

    func testBlankProjectAndTeamAreOmitted() {
        let now = OpenUsageISO8601.date(from: "2026-08-15T12:00:00.000Z")!

        let url = MuseUsageURL.make(now: now, calendar: calendar, projectID: "  ", teamID: "")

        XCTAssertEqual(
            url,
            "https://dev.meta.ai/usage/?start_date=2026-07-17&end_date=2026-08-15"
        )
    }
}
