import Foundation

// MARK: - Amounts, without the exchange rates

/// Symbols, names and the written form of an amount already in its own
/// currency. Converting between currencies needs the rates, which are
/// fetched and cached on the Mac (`CurrencyRates`); this part needs neither.
public enum CurrencyFormat {
    public static func symbol(for code: String) -> String {
        switch code {
        case "USD": "$"
        case "CNY": "¥"
        case "JPY": "JP¥"
        case "HKD": "HK$"
        case "TWD": "NT$"
        case "KRW": "₩"
        case "SGD": "S$"
        case "EUR": "€"
        case "GBP": "£"
        case "CAD": "CA$"
        case "AUD": "A$"
        default: code + " "
        }
    }

    public static func displayName(for code: String) -> String {
        switch code {
        case "USD": L10n.t("US dollar", "美元")
        case "CNY": L10n.t("Chinese yuan", "人民币")
        case "HKD": L10n.t("Hong Kong dollar", "港币")
        case "TWD": L10n.t("New Taiwan dollar", "新台币")
        case "JPY": L10n.t("Japanese yen", "日元")
        case "KRW": L10n.t("Korean won", "韩元")
        case "SGD": L10n.t("Singapore dollar", "新加坡元")
        case "EUR": L10n.t("Euro", "欧元")
        case "GBP": L10n.t("Pound sterling", "英镑")
        case "CAD": L10n.t("Canadian dollar", "加元")
        case "AUD": L10n.t("Australian dollar", "澳元")
        default: code
        }
    }

    /// Currencies whose minor unit is not shown.
    public static func wholeUnits(_ code: String) -> Bool { code == "JPY" || code == "KRW" || code == "TWD" }
}

extension QuotaFormat {
    /// An amount already in `code`: "¥1,000.00", "$250.00".
    public static func amount(_ value: Double, code: String) -> String {
        converted(value, code: code)
    }

    public static func converted(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        let digits = CurrencyFormat.wholeUnits(code) ? 0 : 2
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        let magnitude = formatter.string(from: NSNumber(value: abs(value))) ?? String(format: "%.2f", abs(value))
        return (value < 0 ? "-" : "") + CurrencyFormat.symbol(for: code) + magnitude
    }
}
