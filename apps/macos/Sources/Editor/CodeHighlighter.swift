import AppKit

enum CodeHighlighter {
    /// Fixed light-on-dark colors. Dynamic `labelColor` follows the AppKit
    /// view appearance, which stays light inside an NSViewRepresentable even
    /// when the SwiftUI app is dark-only — black glyphs on the surface grey.
    static let textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
    static let backgroundColor = NSColor(calibratedRed: 27 / 255, green: 27 / 255, blue: 27 / 255, alpha: 1)
    static let keywordColor = NSColor(calibratedRed: 201 / 255, green: 246 / 255, blue: 111 / 255, alpha: 1)
    static let stringColor = NSColor(calibratedRed: 247 / 255, green: 154 / 255, blue: 62 / 255, alpha: 1)
    static let commentColor = NSColor(calibratedRed: 140 / 255, green: 160 / 255, blue: 120 / 255, alpha: 1)
    static let numberColor = NSColor(calibratedRed: 180 / 255, green: 160 / 255, blue: 255 / 255, alpha: 1)

    static func language(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": "swift"
        case "ts", "tsx", "mts": "typescript"
        case "js", "jsx", "mjs", "cjs": "javascript"
        case "py": "python"
        case "json": "json"
        case "md", "markdown": "markdown"
        case "yml", "yaml": "yaml"
        case "sh", "bash", "zsh": "shell"
        default: "text"
        }
    }

    static func highlight(_ source: String, language: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ])
        guard language != "text", !source.isEmpty else { return result }

        let keywords = keywords(for: language)
        if !keywords.isEmpty {
            apply(pattern: "\\b(\(keywords.joined(separator: "|")))\\b", to: result, color: keywordColor)
        }
        apply(pattern: "\"([^\"\\\\]|\\\\.)*\"|'([^'\\\\]|\\\\.)*'", to: result, color: stringColor)
        apply(pattern: language == "python" ? "#[^\n]*" : "//[^\n]*", to: result, color: commentColor)
        if language == "markdown" {
            apply(pattern: "^#{1,6} .+$", to: result, color: keywordColor)
        }
        apply(pattern: "\\b-?\\d+(?:\\.\\d+)?\\b", to: result, color: numberColor)
        return result
    }

    private static func keywords(for language: String) -> [String] {
        switch language {
        case "swift":
            ["import", "let", "var", "func", "return", "if", "else", "guard", "struct", "class", "enum", "protocol", "async", "await", "try", "throws", "private", "public", "internal", "static", "switch", "case", "default", "for", "in", "while", "true", "false", "nil", "self"]
        case "typescript", "javascript":
            ["import", "export", "from", "const", "let", "var", "function", "return", "if", "else", "async", "await", "class", "extends", "new", "true", "false", "null", "undefined", "type", "interface", "switch", "case"]
        case "python":
            ["import", "from", "def", "class", "return", "if", "elif", "else", "for", "in", "while", "True", "False", "None", "async", "await", "with", "as", "try", "except", "yield"]
        case "shell":
            ["if", "then", "else", "fi", "for", "in", "do", "done", "case", "esac", "function", "export", "local", "return"]
        default:
            []
        }
    }

    private static func apply(pattern: String, to text: NSMutableAttributedString, color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        let range = NSRange(location: 0, length: text.length)
        regex.enumerateMatches(in: text.string, options: [], range: range) { match, _, _ in
            guard let match else { return }
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}