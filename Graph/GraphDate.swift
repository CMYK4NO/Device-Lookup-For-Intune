import Foundation

enum GraphDate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    /// Parses Graph timestamps, with or without fractional seconds (Graph can send 7 digits).
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        // Reports send times in UTC without a zone, such as "2026-09-02T13:07:39".
        let zoned = trimmed.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) == nil ? trimmed + "Z" : trimmed
        return fractional.date(from: zoned) ?? plain.date(from: zoned)
    }
}
