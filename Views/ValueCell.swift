import AppKit
import SwiftUI

/// A script output in a one-line table cell. Line breaks become spaces so every line shows, not only the first; the
/// whole text, line breaks included, is the tooltip.
struct ValueCell: View {
    let value: String

    var body: some View {
        Text(TableText.oneLine(value)).help(value)
    }

    /// Wide enough to show the longest value on one line, between 320 and 700 points. Table rows on macOS are always one
    /// line high, so a longer value is shown in full under the search results, in the inspector and in the Copy menu.
    static func idealWidth(for values: some Sequence<String>) -> CGFloat {
        guard let longest = values.max(by: { $0.utf8.count < $1.utf8.count }) else { return 320 }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let width = (TableText.oneLine(longest) as NSString).size(withAttributes: [.font: font]).width + 16
        return min(max(width, 320), 700)
    }
}
