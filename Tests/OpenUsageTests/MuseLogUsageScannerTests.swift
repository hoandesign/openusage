import XCTest
@testable import OpenUsage

final class MuseLogUsageScannerTests: XCTestCase {
    private let since = OpenUsageISO8601.date(from: "2026-06-01T00:00:00.000Z")!

    func testPricesContributorSlugAtContributorTier() {
        // muse-spark-1.3-contributor: 1M input @ $0.10 + 1M output @ $0.20 = $0.30
        let log = MuseLogFixture.modelCompleted(
            recordedAt: "2026-06-10T10:00:00.000Z",
            model: "muse-spark-1.3-contributor",
            input: 1_000_000,
            output: 1_000_000
        )

        let usage = MuseLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        let day = usage.series.daily.first { $0.date == localDay("2026-06-10T10:00:00.000Z") }
        XCTAssertEqual(day?.totalTokens, 2_000_000)
        XCTAssertEqual(day?.costUSD ?? 0, 0.30, accuracy: 0.0001)
        XCTAssertEqual(
            usage.modelUsage?.daily.first { $0.date == day?.date }?.models.map(\.model),
            ["muse-spark-1.3-contributor"]
        )
    }

    func testPricesStandardSlugAtStandardTiers() {
        // muse-spark-1.3 (no contributor): 1M input @ $1.25 + 1M output @ $4.25 = $5.50
        let log = MuseLogFixture.modelCompleted(
            recordedAt: "2026-06-10T10:00:00.000Z",
            model: "muse-spark-1.3",
            input: 1_000_000,
            output: 1_000_000
        )

        let usage = MuseLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        XCTAssertEqual(usage.series.daily.first?.costUSD ?? 0, 5.50, accuracy: 0.0001)
    }

    func testCachedTokensAreSubsetOfInputNotDoubleCounted() {
        // Contributor: 800k of 1M input are cache reads → 200k @ $0.10/M + 800k @ $0.002/M = $0.0216
        let log = MuseLogFixture.modelCompleted(
            recordedAt: "2026-06-12T09:00:00.000Z",
            model: "muse-spark-1.2-contributor",
            input: 1_000_000,
            output: 0,
            cached: 800_000
        )

        let usage = MuseLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        let day = usage.series.daily.first
        XCTAssertEqual(day?.totalTokens, 1_000_000, "cached tokens must not inflate the total")
        XCTAssertEqual(day?.costUSD ?? 0, 0.0216, accuracy: 0.0001)
    }

    func testReasoningTokensCountTowardOutputCostAndTotal() {
        // Standard: 1M reasoning billed at output rate → $4.25
        let log = MuseLogFixture.modelCompleted(
            recordedAt: "2026-06-12T09:00:00.000Z",
            model: "muse-spark",
            input: 0,
            output: 0,
            reasoning: 1_000_000
        )

        let usage = MuseLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        XCTAssertEqual(usage.series.daily.first?.totalTokens, 1_000_000)
        XCTAssertEqual(usage.series.daily.first?.costUSD ?? 0, 4.25, accuracy: 0.0001)
    }

    func testSkipsOutsideWindowZeroUsageAndNonCompletedEvents() {
        let log = [
            MuseLogFixture.modelCompleted(
                recordedAt: "2026-05-30T09:00:00.000Z",
                model: "muse-spark",
                input: 1_000_000
            ),
            MuseLogFixture.modelCompleted(
                recordedAt: "2026-06-10T10:00:00.000Z",
                model: "muse-spark",
                input: 0,
                output: 0
            ),
            // Attribution lines are ignored (no model; duplicates model_completed totals).
            #"{"recorded_at":\#(MuseLogFixture.micros("2026-06-10T11:00:00.000Z")),"payload":{"event":{"kind":"goal_usage_attribution","record":{"quantity":{"input_tokens":999,"output_tokens":0,"cached_tokens":0,"reasoning_tokens":0}}}}}"#,
            MuseLogFixture.modelCompleted(
                recordedAt: "2026-06-10T12:00:00.000Z",
                model: "muse-spark",
                input: 500_000
            )
        ].joined(separator: "\n")

        let usage = MuseLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        XCTAssertEqual(usage.series.daily.count, 1)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 500_000)
    }

    func testUnpricedModelIsExcludedFromTotalsButWarns() {
        let log = [
            MuseLogFixture.modelCompleted(
                recordedAt: "2026-06-10T10:00:00.000Z",
                model: "muse-spark-future",
                input: 1_000_000
            ),
            MuseLogFixture.modelCompleted(
                recordedAt: "2026-06-10T11:00:00.000Z",
                model: "muse-spark",
                input: 500_000
            )
        ].joined(separator: "\n")

        let usage = MuseLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        let day = localDay("2026-06-10T10:00:00.000Z")

        XCTAssertEqual(usage.series.daily.first?.totalTokens, 500_000)
        XCTAssertEqual(usage.unknownModelsByDay[day], ["muse-spark-future"])
        XCTAssertEqual(usage.modelUsage?.daily.first?.models.map(\.model), ["muse-spark"])
    }

    func testUnpricedOnlyDayLeavesSeriesEmptyWithWarning() {
        let log = MuseLogFixture.modelCompleted(
            recordedAt: "2026-06-10T10:00:00.000Z",
            model: "muse-spark-future",
            input: 1_000_000
        )

        let usage = MuseLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)
        let day = localDay("2026-06-10T10:00:00.000Z")

        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertEqual(usage.unknownModelsByDay[day], ["muse-spark-future"])
    }

    func testNonMuseSparkModelsAreIgnoredWithoutWarning() {
        let log = MuseLogFixture.modelCompleted(
            recordedAt: "2026-06-10T10:00:00.000Z",
            model: "muse-totally-unknown",
            input: 1_000_000
        )

        let usage = MuseLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertTrue(usage.unknownModelsByDay.isEmpty)
    }

    func testMissingModelFallsBackToMuseSpark() {
        let log = MuseLogFixture.modelCompleted(
            recordedAt: "2026-06-10T10:00:00.000Z",
            model: nil,
            input: 1_000_000
        )

        let usage = MuseLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        XCTAssertEqual(usage.modelUsage?.daily.first?.models.map(\.model), ["muse-spark"])
        XCTAssertEqual(usage.series.daily.first?.costUSD ?? 0, 1.25, accuracy: 0.0001)
    }

    func testScanReadsXDGDataHomeSessionsTree() async throws {
        let home = try MuseLogFixture.makeHome(files: [
            "2026/06/10/sess/session.jsonl": MuseLogFixture.sessionFile(
                MuseLogFixture.modelCompleted(
                    recordedAt: "2026-06-10T10:00:00.000Z",
                    model: "muse-spark",
                    input: 1_000_000
                )
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scanner = MuseLogUsageScanner(
            files: LocalTextFileAccessor(),
            environment: FakeEnvironment(["XDG_DATA_HOME": home.path]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") }
        )

        let usage = await scanner.scan(
            daysBack: 30,
            now: OpenUsageISO8601.date(from: "2026-06-18T00:00:00.000Z")!,
            pricing: TestPricing.bundled
        )

        XCTAssertEqual(usage?.series.daily.first?.totalTokens, 1_000_000)
    }

    func testScanIgnoresSessionsWithoutMuseCLIMetadata() async throws {
        let home = try MuseLogFixture.makeHome(files: [
            "2026/06/10/external/session.jsonl": MuseLogFixture.modelCompleted(
                recordedAt: "2026-06-10T10:00:00.000Z",
                model: "muse-spark",
                input: 1_000_000
            ),
            "2026/06/10/muse/session.jsonl": MuseLogFixture.sessionFile(
                MuseLogFixture.modelCompleted(
                    recordedAt: "2026-06-10T11:00:00.000Z",
                    model: "muse-spark-1.2-contributor",
                    input: 250_000
                )
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scanner = MuseLogUsageScanner(
            files: LocalTextFileAccessor(),
            environment: FakeEnvironment(["XDG_DATA_HOME": home.path]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") }
        )

        let usage = await scanner.scan(
            daysBack: 30,
            now: OpenUsageISO8601.date(from: "2026-06-18T00:00:00.000Z")!,
            pricing: TestPricing.bundled
        )

        XCTAssertEqual(usage?.series.daily.first?.totalTokens, 250_000)
    }

    func testScanIncludesSubagentLogsWhenParentSessionQualifies() async throws {
        let home = try MuseLogFixture.makeHome(files: [
            "2026/06/10/parent/session.jsonl": MuseLogFixture.sessionFile(""),
            "2026/06/10/parent/subagent/worker/session.jsonl": MuseLogFixture.modelCompleted(
                recordedAt: "2026-06-10T12:00:00.000Z",
                model: "muse-spark-1.2",
                input: 100_000
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scanner = MuseLogUsageScanner(
            files: LocalTextFileAccessor(),
            environment: FakeEnvironment(["XDG_DATA_HOME": home.path]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") }
        )

        let usage = await scanner.scan(
            daysBack: 30,
            now: OpenUsageISO8601.date(from: "2026-06-18T00:00:00.000Z")!,
            pricing: TestPricing.bundled
        )

        XCTAssertEqual(usage?.series.daily.first?.totalTokens, 100_000)
    }

    func testParseSkipsNonMuseSparkModels() {
        let log = MuseLogFixture.modelCompleted(
            recordedAt: "2026-06-10T10:00:00.000Z",
            model: "gpt-5.4",
            input: 1_000_000
        )

        let usage = MuseLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertTrue(usage.unknownModelsByDay.isEmpty)
    }

    func testScanReturnsNilWhenSessionsMissingOrEmpty() async {
        let missing = MuseLogUsageScanner(
            files: FakeFiles(),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/none") }
        )
        let missingScan = await missing.scan(pricing: TestPricing.bundled)
        XCTAssertNil(missingScan)

        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-muse-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        let empty = MuseLogUsageScanner(
            files: LocalTextFileAccessor(),
            environment: FakeEnvironment(["XDG_DATA_HOME": emptyRoot.path]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") }
        )
        // Root exists as XDG_DATA_HOME/muse/sessions — create the sessions dir empty.
        let sessions = emptyRoot.appendingPathComponent("muse/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let emptyScan = await empty.scan(pricing: TestPricing.bundled)
        XCTAssertNil(emptyScan)
    }

    private func localDay(_ iso: String) -> String {
        DailyUsageAccumulator.dayKey(from: OpenUsageISO8601.date(from: iso)!)
    }
}

enum MuseLogFixture {
    static func micros(_ iso: String) -> Int64 {
        Int64((OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1_000_000).rounded())
    }

    static func sessionMetadata(
        providerID: String = "meta",
        modelID: String = "muse-spark-1.2-contributor"
    ) -> String {
        let object: [String: Any] = [
            "payload_type": "runtime.session.metadata",
            "payload": [
                "kind": "metadata",
                "record": [
                    "workspace_root": "/tmp/project",
                    "provider_id": providerID,
                    "model_id": modelID,
                    "build": ["sha": "test", "semver": "0.1.0"],
                    "tool_surface_version": "2"
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    static func sessionFile(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return sessionMetadata()
        }
        return sessionMetadata() + "\n" + trimmed
    }

    static func modelCompleted(
        recordedAt: String,
        model: String?,
        input: Int = 0,
        output: Int = 0,
        cached: Int = 0,
        reasoning: Int = 0
    ) -> String {
        var event: [String: Any] = [
            "kind": "model_completed",
            "usage": [
                "input_tokens": input,
                "output_tokens": output,
                "cached_tokens": cached,
                "reasoning_tokens": reasoning
            ]
        ]
        if let model {
            event["model"] = model
        }
        let object: [String: Any] = [
            "recorded_at": micros(recordedAt),
            "payload": [
                "kind": "run",
                "event": event
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    /// Temp `$XDG_DATA_HOME` whose `muse/sessions/` contains `files` (relative path → JSONL).
    static func makeHome(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-muse-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("muse/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for (relativePath, content) in files {
            let url = sessions.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
}
