import AppKit
import UniformTypeIdentifiers

/// Asks where to save a CSV file and writes it there.
@MainActor
enum CSVSavePanel {
    /// Returns false when the user cancels. Throws when the file cannot be written.
    @discardableResult
    static func save(_ data: Data, suggestedName: String) throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try data.write(to: url, options: .atomic)
        return true
    }
}
