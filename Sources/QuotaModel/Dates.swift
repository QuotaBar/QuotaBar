import Foundation

public enum Dates {
    public static func parseISO(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// Accepts epoch seconds or milliseconds. Nothing for "inf" or a figure
    /// millions of years out: a countdown to such a date would not fit an
    /// `Int`, and `QuotaFormat` would stop the app converting it.
    public static func parseEpoch(_ value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0, value < 1e18 else { return nil }
        return value > 100_000_000_000 ? Date(timeIntervalSince1970: value / 1000) : Date(timeIntervalSince1970: value)
    }

    /// Tries ISO first, then epoch (s/ms) encoded as string/number.
    public static func parseAny(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let iso = parseISO(string) { return iso }
        return parseEpoch(Double(string))
    }
}
