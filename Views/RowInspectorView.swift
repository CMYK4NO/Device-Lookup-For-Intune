import SwiftUI

/// Intune inventory and raw JSON of one row. The JSON is coloured once per row, not on every redraw of the table.
struct RowInspectorView: View {
    let row: AttributeRow
    let valueField: String
    let operatingSystem: String
    @State private var highlighted = AttributedString()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if row.valueIsFallback {
                    Text("\"\(valueField)\" is empty, so Value lists all populated fields.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !row.value.isEmpty {
                    Text("Value").font(.headline)
                    Text(row.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Intune inventory").font(.headline)
                Text("Serial: \(row.serial.isEmpty ? "—" : row.serial)    OS: \(operatingSystem.isEmpty ? "—" : operatingSystem)")
                    .textSelection(.enabled)
                Text("Raw JSON").font(.headline)
                Text(highlighted)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .task(id: row.id) {
            highlighted = JSONHighlighter.attributed(row.raw)
        }
    }
}
