import Foundation

/// Scans Muse CLI local session logs for token usage.
///
/// Sessions live under `~/.local/share/muse/sessions/<yyyy>/<mm>/<dd>/<session-id>/session.jsonl`
/// and also historically under `~/.local/share/muse/sessions/<session-id>/session.jsonl`.
/// Usage is recorded on `runtime.session` `model_completed` events carrying `usage` token counts
/// and a `model` slug. Only Muse Spark models (`muse-spark*`) from Muse CLI session logs are
/// counted — other Meta API clients on dev.meta.ai do not write here.
/// We aggregate per local calendar day.
struct MuseLogUsageScanner: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var sessionsRoot: String {
        if let xdg = environment.value(for: "XDG_DATA_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("muse/sessions")
        }
        return homeDirectory().appendingPathComponent(".local/share/muse/sessions").path
    }

    /// Scan last `daysBack` days (default 31 to cover Last 30 + today). Returns nil when no sessions dir.
    func scan(daysBack: Int = 31, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let root = sessionsRoot
        guard files.exists(root) else { return nil }
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let filesToRead = collectSessionFiles(root: root)
        guard !filesToRead.isEmpty else { return nil }

        var accumulator = DailyUsageAccumulator()
        var foundAnyFile = false

        for path in filesToRead {
            guard let text = try? files.readText(path) else { continue }
            foundAnyFile = true
            Self.parse(text, since: since, pricing: pricing, into: &accumulator)
        }

        if !foundAnyFile { return nil }
        return accumulator.build()
    }

    // MARK: - File discovery

    func collectSessionFiles(root: String) -> [String] {
        let url = URL(fileURLWithPath: root)
        return JSONLScanning.jsonlFiles(under: url)
            .filter { $0.path.hasSuffix("session.jsonl") }
            .map(\.path)
            .filter { MuseSessionFilter.qualifiesSessionFile(at: $0, files: files) }
            .sorted()
    }

    // MARK: - Parsing

    /// Parse one session file's text into a scan result (used by tests and single-file callers).
    static func parse(_ text: String, since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        parse(text, since: since, pricing: pricing, into: &accumulator)
        return accumulator.build()
    }

    /// Parses one session file into `accumulator`. `inout` is mutated only from this call stack —
    /// line iteration uses `split` (not escaping `enumerateLines`) so the capture is legal.
    static func parse(
        _ text: String,
        since: Date,
        pricing: ModelPricing,
        into accumulator: inout DailyUsageAccumulator
    ) {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // Cheap pre-filter: model_completed lines carry both usage and the model slug.
            guard line.contains("model_completed") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = ProviderParse.jsonObject(data) else { continue }

            guard let recordedAt = obj["recorded_at"] as? NSNumber else { continue }
            // recorded_at is microseconds since epoch
            let date = Date(timeIntervalSince1970: recordedAt.doubleValue / 1_000_000)
            guard date >= since else { continue }

            guard let payload = obj["payload"] as? [String: Any],
                  let event = payload["event"] as? [String: Any],
                  (event["kind"] as? String) == "model_completed",
                  let usage = event["usage"] as? [String: Any] else { continue }

            let input = ProviderParse.number(usage["input_tokens"]) ?? 0
            let output = ProviderParse.number(usage["output_tokens"]) ?? 0
            let cached = min(ProviderParse.number(usage["cached_tokens"]) ?? 0, input)
            let reasoning = ProviderParse.number(usage["reasoning_tokens"]) ?? 0

            // cached_tokens is a subset of input_tokens — count input once (Grok/Claude pattern).
            let inputNoCache = Int(max(0, input - cached))
            let cacheRead = Int(cached)
            let outputTokens = Int(output + reasoning)
            let total = Int(input) + outputTokens
            guard total > 0 else { continue }

            let dayKey = DailyUsageAccumulator.dayKey(from: date)
            let model: String = {
                if let m = (event["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !m.isEmpty {
                    return m
                }
                return "muse-spark"
            }()
            guard MuseSessionFilter.isMuseSparkModel(model) else { continue }

            let breakdown = TokenBreakdown(
                input: inputNoCache,
                cacheRead: cacheRead,
                output: outputTokens
            )
            guard let price = pricing.estimatedCostDollars(model: model, tokens: breakdown) else {
                // Unpriced models are excluded from tile totals; warn via unknownModelsByDay only.
                accumulator.addUnknownModel(day: dayKey, model: model)
                continue
            }
            accumulator.add(day: dayKey, tokens: total, cost: price, model: model)
        }
    }
}
