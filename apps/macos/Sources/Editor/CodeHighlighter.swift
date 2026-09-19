import AppKit
import Highlightr

enum CodeHighlighter {
    /// Vaste licht-op-donker kleuren voor de editorchroom. De dynamische
    /// `labelColor` volgt de AppKit-appearance, die binnen een
    /// NSViewRepresentable licht blijft ook als de SwiftUI-app donker is.
    static let textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
    static let backgroundColor = NSColor(calibratedRed: 27 / 255, green: 27 / 255, blue: 27 / 255, alpha: 1)
    static let keywordColor = NSColor(calibratedRed: 201 / 255, green: 246 / 255, blue: 111 / 255, alpha: 1)

    /// Highlighten kost ongeveer 1,3 ms per KB. Daarboven blokkeert het de UI
    /// langer dan het oplevert, dus dan tonen we platte tekst.
    static let maximumHighlightedBytes = 200_000

    /// Het thema bepaalt de tokenkleuren; zijn achtergrond negeren we, want de
    /// editor houdt zijn eigen `backgroundColor`. Highlightr zet geen
    /// achtergrondattributen op tokens, dus dat botst niet.
    private static let themeName = "atom-one-dark"

    @MainActor private static let engine: Highlightr? = {
        let highlightr = Highlightr()
        highlightr?.setTheme(to: themeName)
        return highlightr
    }()

    /// De kleur die het thema geeft aan tekst die geen token is. Nieuw getypte
    /// tekens krijgen die meteen, zodat ze niet afwijken in de 150 ms voordat
    /// de rehighlight langskomt.
    @MainActor static let plainTextColor: NSColor = {
        guard let engine,
              let probe = engine.highlight("placeholder", as: "plaintext"),
              probe.length > 0,
              let color = probe.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        else { return textColor }
        return color
    }()

    /// Highlight.js-taalnamen, niet de bestandsextensie: HTML valt onder `xml`.
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
        // Het thema levert zijn eigen font (Courier) mee. Zonder deze regel
        // verspringt de tekst ten opzichte van de regelnummers.
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }
}
