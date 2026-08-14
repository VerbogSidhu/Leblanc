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

    private let cache = RACache()
    private let settings: SettingsStore

    private let profileTTL: TimeInterval = 15 * 60
    private let unlocksTTL: TimeInterval = 15 * 60
    private let completionTTL: TimeInterval = 60 * 60

    init(settings: SettingsStore) {
        self.settings = settings
        loadCache()
    }

    var isConfigured: Bool { settings.raConfigured }

    private var client: RAClient? {
        guard let u = settings.raUsername, let y = settings.raAPIToken,
              !u.isEmpty, !y.isEmpty else { return nil }
        return RAClient(username: u, apiKey: y)
    }

    // MARK: - Loading

    private func loadCache() {
        if let e = cache.load("profile", as: RAProfile.self) {
            profile = e.value
            lastUpdated = e.fetchedAt
        }
        if let e = cache.load("unlocks", as: [RARecentAchievement].self) {
            unlocks = e.value
            lastUpdated = lastUpdated ?? e.fetchedAt
        }
        if let e = cache.load("completions", as: [RACompletionProgressEntry].self) {
            completions = e.value
            lastUpdated = lastUpdated ?? e.fetchedAt
        }
    }

    func loadIfNeeded(force: Bool = false) async {
        guard isConfigured else {
            await MainActor.run {
                profile = nil; unlocks = []; completions = []
                lastUpdated = nil
                error = nil
            }
            return
        }
        await refresh(force: force)
    }

    func refresh(force: Bool = false) async {
        guard let client else { return }
        let alreadyRefreshing = await MainActor.run { () -> Bool in
            if isRefreshing { return true }
            isRefreshing = true
            return false
        }
        guard !alreadyRefreshing else { return }
        defer {
            Task { @MainActor in isRefreshing = false }
        }

        let cacheTime = await MainActor.run { lastUpdated ?? .distantPast }
        let now = Date()

        let doProfile = force || cacheTime.addingTimeInterval(profileTTL) < now
        let doUnlocks = force || cacheTime.addingTimeInterval(unlocksTTL) < now
        let doCompletions = force || cacheTime.addingTimeInterval(completionTTL) < now

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
                cache.save(finalProfile, key: "profile")
            }
            if let finalUnlocks {
                unlocks = finalUnlocks
                cache.save(finalUnlocks, key: "unlocks")
            }
            if let finalCompletions {
                completions = finalCompletions
                cache.save(finalCompletions, key: "completions")
            }
            if anySuccess {
                lastUpdated = now
            }
            if !anySuccess, profile == nil, unlocks.isEmpty {
                error = "Couldn't reach RetroAchievements. Check your connection and try again."
            } else {
                error = nil
            }
        }
    }
}
