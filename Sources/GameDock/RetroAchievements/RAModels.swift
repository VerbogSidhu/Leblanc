import Foundation

/// RetroAchievements Web API response models. The API uses PascalCase keys;
/// CodingKeys map them explicitly (not every field follows consistent casing).
/// Uncertain fields are Optional so a missing field never fails the whole decode.

struct RAProfile: Codable, Equatable {
    let user: String
    let userPic: String
    let memberSince: String?
    let richPresenceMsg: String?
    let totalPoints: Int
    let totalSoftcorePoints: Int
    let totalTruePoints: Int
    let motto: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case userPic = "UserPic"
        case memberSince = "MemberSince"
        case richPresenceMsg = "RichPresenceMsg"
        case totalPoints = "TotalPoints"
        case totalSoftcorePoints = "TotalSoftcorePoints"
        case totalTruePoints = "TotalTruePoints"
        case motto = "Motto"
    }
}

struct RARecentAchievement: Codable, Equatable, Identifiable {
    let date: String
    let hardcoreMode: Int
    let achievementID: Int
    let title: String
    let description: String
    let points: Int
    let trueRatio: Int?
    let gameTitle: String
    let gameIcon: String?
    let gameID: Int
    let consoleName: String?
    let badgeURL: String?

    var id: Int { achievementID }

    enum CodingKeys: String, CodingKey {
        case date = "Date"
        case hardcoreMode = "HardcoreMode"
        case achievementID = "AchievementID"
        case title = "Title"
        case description = "Description"
        case points = "Points"
        case trueRatio = "TrueRatio"
        case gameTitle = "GameTitle"
        case gameIcon = "GameIcon"
        case gameID = "GameID"
        case consoleName = "ConsoleName"
        case badgeURL = "BadgeURL"
    }
}

struct RACompletionProgressEntry: Codable, Equatable, Identifiable {
    let gameID: Int
    let title: String
    let imageIcon: String?
    let consoleID: Int?
    let consoleName: String?
    let maxPossible: Int
    let numAwarded: Int
    let numAwardedHardcore: Int?

    var id: Int { gameID }

    var percent: Double {
        maxPossible > 0 ? Double(numAwarded) / Double(maxPossible) : 0
    }

    enum CodingKeys: String, CodingKey {
        case gameID = "GameID"
        case title = "Title"
        case imageIcon = "ImageIcon"
        case consoleID = "ConsoleID"
        case consoleName = "ConsoleName"
        case maxPossible = "MaxPossible"
        case numAwarded = "NumAwarded"
        case numAwardedHardcore = "NumAwardedHardcore"
    }
}

/// Wrapper matching the API's `{ Count, Total, Results }` envelope for
/// completion progress.
struct RACompletionProgress: Codable {
    let results: [RACompletionProgressEntry]
    enum CodingKeys: String, CodingKey { case results = "Results" }
}
