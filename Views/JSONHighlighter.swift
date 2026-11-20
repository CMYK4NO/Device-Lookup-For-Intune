import SwiftUI

/// Colours pretty-printed JSON and shows line breaks inside string values as real line breaks.
enum JSONHighlighter {
    private static let keyLine = try! NSRegularExpression(pattern: #"^(\s*)("(?:[^"\\]|\\.)*") : (.*)$"#)

    static func attributed(_ json: String) -> AttributedString {
        var result = AttributedString()
        let lines = json.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            let range = NSRange(line.startIndex..., in: line)
            if let match = keyLine.firstMatch(in: line, range: range),
               let indent = Range(match.range(at: 1), in: line),
               let key = Range(match.range(at: 2), in: line),
               let value = Range(match.range(at: 3), in: line) {
                result += AttributedString(String(line[indent]))
                result += styled(String(line[key]), .cyan)
                result += AttributedString(" : ")
                result += valueText(String(line[value]), indent: String(line[indent]))
            } else {
                let indent = String(line.prefix { $0 == " " })
                result += AttributedString(indent)
                result += valueText(String(line.dropFirst(indent.count)), indent: indent)
            }
        }
        return result
    }

    private static func valueText(_ text: String, indent: String) -> AttributedString {
        let comma = text.hasSuffix(",")
        let token = comma ? String(text.dropLast()) : text
        var out: AttributedString
        if token.hasPrefix("\""), let decoded = try? JSONDecoder().decode(String.self, from: Data(token.utf8)) {
            let shown = decoded.replacingOccurrences(of: "\n", with: "\n" + indent + "  ")
            out = styled("\"" + shown + "\"", .green)
        } else if token == "null" || token == "true" || token == "false" || Double(token) != nil {
            out = styled(token, .orange)
        } else {
            out = AttributedString(token)
        }
        if comma { out += AttributedString(",") }
        return out
    }

    private static func styled(_ text: String, _ color: Color) -> AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = color
        return out
    }
}
