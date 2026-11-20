import Foundation

/// Builds CSV files: UTF-8 with BOM, RFC 4180 quoting, CRLF line ends, ISO 8601 dates.
enum CSVExporter {
    struct Table: Equatable {
        let header: [String]
        let rows: [[String]]
    }

    static func data(for table: Table) -> Data {
        let lines = ([table.header] + table.rows).map { $0.map(escape).joined(separator: ",") }
        return Data([0xEF, 0xBB, 0xBF]) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Quotes a field when it holds a comma, quote, or line break; quotes inside are doubled. Script output and device names
    /// come from the devices themselves, so a field that Excel or Numbers would run as a formula (it starts with =, +, -, @,
    /// a tab or a carriage return) gets a leading apostrophe and is shown as text.
    static func escape(_ field: String) -> String {
        var field = field
        if let first = field.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { field = "'" + field }
        guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func isoDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(.iso8601)
    }

    /// `<os>-<name>-<yyyyMMdd-HHmm>.csv`, with characters that are unsafe in file names replaced by "-".
    static func fileName(os: String, name: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "\(safe(os))-\(safe(name))-\(formatter.string(from: date)).csv"
    }

    private static func safe(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@"))
        let cleaned = String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "export" : cleaned
    }

    // MARK: Tables

    static func table(for rows: [AttributeRow], includesValue: Bool = true) -> Table {
        Table(
            header: ["Device", "User (UPN)", "Serial", "OS version"] + (includesValue ? ["Value"] : []) + ["Run state", "Last updated"],
            rows: rows.map {
                [$0.device, $0.user, $0.serial, $0.osVersion] + (includesValue ? [$0.value] : []) + [$0.runState, isoDate($0.lastUpdated)]
            }
        )
    }

    static func table(for rows: [SearchResultRow]) -> Table {
        Table(
            header: ["Custom Attribute", "Device", "OS", "Serial", "Value", "Result", "Date"],
            rows: rows.map { [$0.attribute, $0.deviceName, $0.os, $0.serial, $0.value, $0.runState, isoDate($0.lastUpdated)] }
        )
    }

    /// The compliance, configuration or managed apps table of the selected devices, with the columns shown on screen.
    static func table(for rows: [StatusRow], part: StatusPart) -> Table {
        switch part {
        case .compliance, .configuration:
            return Table(
                header: [part.itemTitle, "Device", "User (UPN)", "Serial", "OS version", "Run state", "Last updated"],
                rows: rows.map { [$0.name, $0.device, $0.user, $0.serial, $0.osVersion, $0.state, isoDate($0.date)] }
            )
        case .apps:
            return Table(
                header: ["Device", "OS", "Serial", part.itemTitle, "Version", "Status", "Date"],
                rows: rows.map { [$0.device, $0.os, $0.serial, $0.name, $0.version, $0.state, isoDate($0.date)] }
            )
        }
    }
}
