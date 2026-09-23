import AppKit
import Highlightr

enum CodeHighlighter {
    /// Fixed light-on-dark colors for the editor chrome. Dynamic
    /// `labelColor` follows the AppKit appearance, which stays light inside an
    /// NSViewRepresentable even when the SwiftUI app is dark.
    static let textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
    static let backgroundColor = NSColor(calibratedRed: 27 / 255, green: 27 / 255, blue: 27 / 255, alpha: 1)
    static let keywordColor = NSColor(calibratedRed: 201 / 255, green: 246 / 255, blue: 111 / 255, alpha: 1)

    /// Highlighting costs about 1.3 ms per KB. Above this it blocks the UI
    /// longer than it is worth, so we show plain text.
    static let maximumHighlightedBytes = 200_000

    /// The theme owns token colors; we ignore its background because the
    /// editor keeps its own `backgroundColor`. Highlightr does not put
    /// background attributes on tokens, so that does not clash.
    private static let themeName = "atom-one-dark"

    @MainActor private static let engine: Highlightr? = {
        let highlightr = Highlightr()
        highlightr?.setTheme(to: themeName)
        return highlightr
    }()

    /// The color the theme gives to text that is not a token. Newly typed
    /// characters get it immediately so they do not look off in the 150 ms
    /// before rehighlighting runs.
    @MainActor static let plainTextColor: NSColor = {
        guard let engine,
              let probe = engine.highlight("placeholder", as: "plaintext"),
              probe.length > 0,
              let color = probe.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        else { return textColor }
        return color
    }()

    /// Highlight.js language names, not the file extension: HTML maps to `xml`.
    static func language(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": "swift"
        case "ts", "mts", "cts": "typescript"
        case "tsx", "jsx": "typescript"
        case "js", "mjs", "cjs": "javascript"
        case "py": "python"
        case "rb": "ruby"
        case "go": "go"
        case "rs": "rust"
        case "java": "java"
        case "kt", "kts": "kotlin"
        case "c", "h": "c"
        case "cpp", "cc", "hpp", "hh": "cpp"
        case "m", "mm": "objectivec"
        case "cs": "csharp"
        case "php": "php"
        case "sql": "sql"
        case "json": "json"
        case "md", "markdown": "markdown"
        case "yml", "yaml": "yaml"
        case "toml": "ini"
        case "ini", "conf": "ini"
        case "xml", "plist", "svg": "xml"
        case "html", "htm", "vue", "svelte": "xml"
        case "css": "css"
        case "scss", "sass": "scss"
        case "less": "less"
        case "sh", "bash", "zsh", "fish": "bash"
        case "dockerfile": "dockerfile"
        case "diff", "patch": "diff"
        case "gradle", "groovy": "groovy"
        case "lua": "lua"
        default: "text"
        }
    }

    @MainActor
    static func highlight(_ source: String, language: String, font: NSFont) -> NSAttributedString {
        let plain = NSAttributedString(string: source, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ])
        guard language != "text",
              !source.isEmpty,
              source.utf8.count <= maximumHighlightedBytes,
              let engine,
              let highlighted = engine.highlight(source, as: language),
              highlighted.string == source
        else {
            return plain
        }

        let result = NSMutableAttributedString(attributedString: highlighted)
        // The theme ships its own font (Courier). Without this line
        // the text shifts relative to the line numbers.
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }
}
