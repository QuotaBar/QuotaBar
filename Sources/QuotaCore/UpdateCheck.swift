import Foundation

/// A newer release than the one running.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: String
    public let url: URL
}

/// Checks GitHub Releases for a newer version.
///
/// Deliberately not Sparkle: that would add the project's first third-party
/// dependency, an appcast to host, and an EdDSA private key to keep. This
/// tells the user a release exists and sends them to it — `brew upgrade` or
/// the download page does the rest. Full in-place updating is a separate
/// decision, not a prerequisite for people knowing they are behind.
public enum UpdateCheck {
    public static let releasesURL = URL(string: "https://github.com/gentpan/quotabar/releases/latest")!
    private static let api = URL(
        string: "https://api.github.com/repos/gentpan/quotabar/releases/latest")!

    /// Returns the newer release, or nil when current, offline, or rate-limited.
    public static func latest(currentVersion: String) async -> AvailableUpdate? {
        guard let response = try? await HTTP.get(api, headers: [
            "Accept": "application/vnd.github+json",
            "User-Agent": "QuotaBar",
        ]), response.status == 200,
            let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let tag = root["tag_name"] as? String
        else { return nil }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard compare(latest, isNewerThan: currentVersion) else { return nil }
        let page = (root["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesURL
        return AvailableUpdate(version: latest, url: page)
    }

    /// Numeric component-wise comparison, so 0.2.10 sorts above 0.2.9 —
    /// a string compare would get that backwards.
    static func compare(_ lhs: String, isNewerThan rhs: String) -> Bool {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }
}
