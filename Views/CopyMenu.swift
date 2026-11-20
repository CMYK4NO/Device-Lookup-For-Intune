import AppKit
import SwiftUI

/// One column of a table row, as the row's Copy menu and ⌘C copy it: the full text, also when the cell cuts it short.
struct CopyField: Identifiable {
    let title: String
    let text: String
    var id: String { title }
}

/// Text helpers shared by the table cells and the copy commands.
enum TableText {
    /// Line breaks become spaces, so a one-line cell shows every line, not only the first.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    static func date(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
    }

    /// One line per row and a tab between columns, so it pastes into separate cells in Numbers or Excel.
    static func lines(of rows: [[CopyField]]) -> String {
        rows.map { fields in
            fields.map { oneLine($0.text).replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t")
        }
        .joined(separator: "\n")
    }

    /// What ⌘C copies for the selected rows.
    static func items(for rows: [[CopyField]]) -> [NSItemProvider] {
        rows.isEmpty ? [] : [NSItemProvider(object: lines(of: rows) as NSString)]
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// The context menu of a table row: each column and the whole row. Several selected rows are copied together.
struct CopyMenu: View {
    let rows: [[CopyField]]

    var body: some View {
        if rows.count == 1, let fields = rows.first {
            ForEach(fields) { field in
                Button("Copy \(field.title)") { TableText.copy(field.text) }
                    .disabled(field.text.isEmpty)
            }
            Divider()
            Button("Copy Row") { TableText.copy(TableText.lines(of: rows)) }
        } else if rows.count > 1 {
            Button("Copy \(rows.count) Rows") { TableText.copy(TableText.lines(of: rows)) }
        }
    }
}

extension AttributeRow {
    /// The columns of the attribute table, in order.
    func copyFields(includesValue: Bool) -> [CopyField] {
        var fields = [
            CopyField(title: "Device", text: device),
            CopyField(title: "User", text: user),
            CopyField(title: "Serial", text: serial),
            CopyField(title: "OS Version", text: osVersion),
        ]
        if includesValue { fields.append(CopyField(title: "Value", text: value)) }
        fields.append(CopyField(title: "Run State", text: runState))
        fields.append(CopyField(title: "Last Updated", text: TableText.date(lastUpdated)))
        return fields
    }
}

extension SearchResultRow {
    /// The columns of the search results table, in order.
    var copyFields: [CopyField] {
        [
            CopyField(title: "Custom Attribute", text: attribute),
            CopyField(title: "Device", text: deviceName),
            CopyField(title: "OS", text: os),
            CopyField(title: "Serial", text: serial),
            CopyField(title: "Value", text: value),
            CopyField(title: "Result", text: runState),
            CopyField(title: "Date", text: TableText.date(lastUpdated)),
        ]
    }
}

extension ManagedDevice {
    /// The columns of the devices table, in order.
    var copyFields: [CopyField] {
        [
            CopyField(title: "Device", text: deviceName ?? id),
            CopyField(title: "OS", text: operatingSystem ?? ""),
            CopyField(title: "OS Version", text: osVersion ?? ""),
            CopyField(title: "Last Check-in", text: TableText.date(lastCheckIn)),
            CopyField(title: "Enrolled", text: TableText.date(enrolled)),
            CopyField(title: "Serial", text: serialNumber ?? ""),
        ]
    }
}
