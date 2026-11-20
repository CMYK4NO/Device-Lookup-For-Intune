import Foundation

/// An Intune report answer: `Schema` lists the columns and `Values` holds the rows in that order.
struct ReportTable {
    let rows: [[String: String]]
    /// `TotalRowCount` of the whole report, when Intune sends it.
    let total: Int?

    init(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = root["Schema"] as? [[String: Any]],
              let values = root["Values"] as? [[Any]]
        else { throw GraphError.invalidResponse }
        total = (root["TotalRowCount"] as? NSNumber)?.intValue
        let columns = schema.map { $0["Column"] as? String ?? "" }
        rows = values.map { row in
            var fields: [String: String] = [:]
            for (column, value) in zip(columns, row) {
                switch value {
                case let text as String where !text.isEmpty: fields[column] = text
                case let number as NSNumber: fields[column] = number.stringValue
                default: break
                }
            }
            return fields
        }
    }
}
