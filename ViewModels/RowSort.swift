import Foundation

/// Sorts table rows by the column the user clicked. `sorted(using:)` with key paths compares strings with the
/// system's localized collation, which is slow across thousands of rows. Here every row's key is lowercased once and the
/// keys are compared plainly, so a sort of a large table takes a fraction of the time. Ties keep their order.
enum RowSort {
    private static let textColumns: [(PartialKeyPath<AttributeRow>, (AttributeRow) -> String)] = [
        (\AttributeRow.device, { $0.device }),
        (\AttributeRow.user, { $0.user }),
        (\AttributeRow.serial, { $0.serial }),
        (\AttributeRow.osVersion, { $0.osVersion }),
        (\AttributeRow.value, { $0.value }),
        (\AttributeRow.runState, { $0.runState }),
    ]

    static func sorted(_ rows: [AttributeRow], using order: [KeyPathComparator<AttributeRow>]) -> [AttributeRow] {
        guard let first = order.first else { return rows }
        let ascending = first.order == .forward
        if let column = textColumns.first(where: { $0.0 == first.keyPath }) {
            let keys = rows.map { column.1($0).lowercased() }
            return rows.indices.sorted { a, b in
                keys[a] == keys[b] ? a < b : (keys[a] < keys[b]) == ascending
            }.map { rows[$0] }
        }
        if first.keyPath == \AttributeRow.lastUpdatedSort {
            let dates = rows.map(\.lastUpdatedSort)
            return rows.indices.sorted { a, b in
                dates[a] == dates[b] ? a < b : (dates[a] < dates[b]) == ascending
            }.map { rows[$0] }
        }
        return rows.sorted(using: order)
    }
}
