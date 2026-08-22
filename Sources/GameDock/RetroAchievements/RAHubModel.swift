import Combine
import Foundation

/// Read-only RetroAchievements Hub state: profile, recent unlocks, and
/// completion progress. Cache-first with a TTL-based background refresh.
/// Empty/error states are surfaced explicitly (no-key vs network failure).
///
/// Non-isolated: `loadIfNeeded`/`refresh` are async and hop to the main actor
/// only to apply `@Published` mutations.
final class RAHubModel: ObservableObject {
    @Published private(set) var profile: RAProfile?
    @Published private(set) var unlocks: [RARecentAchievement] = []
    @Published private(set) var completions: [RACompletionProgressEntry] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    /// Non-nil only when there's no cache at all and the network failed.
    @Published private(set) var error: String?

    /// Per-endpoint fetch timestamps (persisted inside each cache envelope).
    private var profileFetchedAt: Date?
    private var unlocksFetchedAt: Date?
    private var completionsFetchedAt: Date?

    private let settings: SettingsStore

    private let profileTTL: TimeInterval = 15 * 60
    private let unlocksTTL: TimeInterval = 15 * 60
    private let completionTTL: TimeInterval = 60 * 60

    init(settings: SettingsStore) {
        self.settings = settings
        loadCache()
    }

    var isConfigured: Bool { settings.raConfigured }

    /// Username-scoped so an account switch never reads another account's files.
    private var cache: RACache {
        RACache(username: settings.raUsername)
    }

    private var client: RAClient? {
        guard let u = settings.raUsername, let y = settings.raAPIToken,
              !u.isEmpty, !y.isEmpty else { return nil }
        return RAClient(username: u, apiKey: y)
    }

    // MARK: - Loading

    private func loadCache() {
        if let e = cache.load("profile", as: RAProfile.self) {
            profile = e.value
            profileFetchedAt = e.fetchedAt
            lastUpdated = e.fetchedAt
        }
        if let e = cache.load("unlocks", as: [RARecentAchievement].self) {
            unlocks = e.value
            unlocksFetchedAt = e.fetchedAt
            lastUpdated = max(lastUpdated ?? e.fetchedAt, e.fetchedAt)
        }
        if let e = cache.load("completions", as: [RACompletionProgressEntry].self) {
            completions = e.value
            completionsFetchedAt = e.fetchedAt
            lastUpdated = max(lastUpdated ?? e.fetchedAt, e.fetchedAt)
        }
    }

    func loadIfNeeded(force: Bool = false) async {
        guard isConfigured else {
            await MainActor.run {
                profile = nil; unlocks = []; completions = []
                profileFetchedAt = nil; unlocksFetchedAt = nil; completionsFetchedAt = nil
                lastUpdated = nil
                error = nil
            }
            return
        }
        await refresh(force: force)
    }

    func refresh(force: Bool = false) async {
        guard let client else { return }
        let cache = self.cache
        let alreadyRefreshing = await MainActor.run { () -> Bool in
            if isRefreshing { return true }
            isRefreshing = true
            return false
        }
        guard !alreadyRefreshing else { return }
        defer {
            Task { @MainActor in isRefreshing = false }
        }

        let times = await MainActor.run { () -> (Date, Date, Date) in
            (profileFetchedAt ?? .distantPast,
             unlocksFetchedAt ?? .distantPast,
             completionsFetchedAt ?? .distantPast)
        }
        let now = Date()

        let doProfile = force || times.0.addingTimeInterval(profileTTL) < now
        let doUnlocks = force || times.1.addingTimeInterval(unlocksTTL) < now
        let doCompletions = force || times.2.addingTimeInterval(completionTTL) < now

        async let p: RAProfile? = doProfile ? try? await client.profile() : nil
        async let u: [RARecentAchievement]? = doUnlocks ? try? await client.recentAchievements() : nil
        async let c: [RACompletionProgressEntry]? = doCompletions ? try? await client.completionProgress() : nil
        let (profileResult, unlocksResult, completionsResult) = await (p, u, c)

        let anySuccess = profileResult != nil || unlocksResult != nil || completionsResult != nil
        let finalProfile = profileResult
        let finalUnlocks = unlocksResult
        let finalCompletions = completionsResult

        await MainActor.run {
            if let finalProfile {
                profile = finalProfile
                profileFetchedAt = now
                cache.save(finalProfile, key: "profile")
            }
            if let finalUnlocks {
                unlocks = finalUnlocks
                unlocksFetchedAt = now
                cache.save(finalUnlocks, key: "unlocks")
            }
            if let finalCompletions {
                completions = finalCompletions
                completionsFetchedAt = now
                cache.save(finalCompletions, key: "completions")
            }
            if anySuccess {
                lastUpdated = [profileFetchedAt, unlocksFetchedAt, completionsFetchedAt]
                    .compactMap { $0 }.max()
            }
            if !anySuccess, profile == nil, unlocks.isEmpty {
                error = "Couldn't reach RetroAchievements. Check your connection and try again."
            } else {
                error = nil
            }
        }
    }
}
