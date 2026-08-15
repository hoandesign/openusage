import Foundation

@MainActor
final class MuseProvider: ProviderRuntime {
    /// Rebuilt on each access so the Usage link's last-30-days window stays current.
    var provider: Provider {
        Provider(
            id: "muse",
            displayName: "Muse",
            icon: .providerMark("muse"),
            links: [
                .init(
                    label: "Usage",
                    url: MuseUsageURL.make(
                        now: now(),
                        projectID: authStore.environment.value(for: "META_PROJECT_ID"),
                        teamID: authStore.environment.value(for: "META_TEAM_ID")
                    )
                ),
                .init(label: "Dashboard", url: "https://dev.meta.ai/")
            ]
        )
    }

    let authStore: MuseAuthStore
    let logUsageScanner: MuseLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        authStore: MuseAuthStore = MuseAuthStore(),
        logUsageScanner: MuseLogUsageScanner = MuseLogUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.logUsageScanner = logUsageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your Muse logs (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.hasCredentialFootprint() }
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()
        let pricing = await pricing()
        let hasCredentials = await hasLocalCredentials()

        // Scan local session logs. Missing logs with a credential footprint still means "installed"
        // — show empty spend tiles, not "not detected".
        guard let scan = await logUsageScanner.scan(now: refreshedAt, pricing: pricing) else {
            if hasCredentials {
                var lines: [MetricLine] = []
                MetricLine.appendNoDataIfNeeded(&lines)
                return ProviderSnapshot.make(
                    provider: provider,
                    plan: nil,
                    lines: lines,
                    refreshedAt: refreshedAt
                )
            }
            return ProviderSnapshot.error(provider: provider, error: MuseAuthError.notLoggedIn)
        }

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.series, to: &lines, now: refreshedAt,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage,
            modelSourceNote: "From your Muse logs (estimated)"
        )
        SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: refreshedAt, note: "From your Muse logs (estimated)")

        let usageHistory = ProviderUsageHistory(
            series: scan.series,
            modelUsage: scan.modelUsage,
            unknownModelsByDay: scan.unknownModelsByDay
        )

        MetricLine.appendNoDataIfNeeded(&lines)

        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: usageHistory
        )
    }
}
