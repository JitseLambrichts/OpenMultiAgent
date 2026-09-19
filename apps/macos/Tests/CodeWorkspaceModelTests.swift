import Foundation
import AppKit
import SwiftUI
import Testing
@testable import OpenMultiAgent

struct FileTreeBuilderTests {
    @Test func nestsDirectoriesAndSortsFoldersFirst() {
        let nodes = FileTreeBuilder.nodes(from: [
            "src/index.ts",
            "README.md",
            "src/lib/util.ts",
            "assets/logo.svg",
        ])

        #expect(nodes.map(\.name) == ["assets", "src", "README.md"])
        #expect(nodes[1].children?.map(\.name) == ["lib", "index.ts"])
        #expect(nodes[1].children?.last?.path == "src/index.ts")
        #expect(nodes[1].children?.first?.children?.first?.path == "src/lib/util.ts")
    }
}

@MainActor
struct CodeHighlighterTests {
    @Test func defaultForegroundStaysLightOnDark() {
        let highlighted = CodeHighlighter.highlight("<html>\n", language: "text", font: Self.font)
        let color = highlighted.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == CodeHighlighter.textColor)
        #expect(color != NSColor.labelColor)
        #expect(color != NSColor.black)
    }

    @Test func swiftGetsSeveralTokenColors() {
        let source = "import Foundation\nstruct Foo {\n    let name: String = \"hoi\"\n}\n"
        #expect(distinctColors(CodeHighlighter.highlight(source, language: "swift", font: Self.font)) >= 4)
    }

    /// HTML en CSS vielen terug op "text" en bleven daardoor volledig wit.
    @Test func webLanguagesGetHighlighted() {
        let html = "<!DOCTYPE html>\n<html lang=\"nl\">\n<head><title>Hoi</title></head>\n</html>\n"
        let css = "body { color: #1a1a1a; margin: 0; }\n"

        #expect(CodeHighlighter.language(for: "index.html") == "xml")
        #expect(CodeHighlighter.language(for: "site.css") == "css")
        #expect(distinctColors(CodeHighlighter.highlight(html, language: "xml", font: Self.font)) > 1)
        #expect(distinctColors(CodeHighlighter.highlight(css, language: "css", font: Self.font)) > 1)
    }

    /// Highlightr legt het font van zijn thema op (Courier); onze monospace
    /// moet daar overheen, anders verspringt de tekst t.o.v. de regelnummers.
    @Test func theMonospacedFontSurvivesHighlighting() {
        let highlighted = CodeHighlighter.highlight("let x = 1\n", language: "swift", font: Self.font)
        var fonts = Set<String>()
        highlighted.enumerateAttribute(.font, in: NSRange(location: 0, length: highlighted.length)) { value, _, _ in
            if let font = value as? NSFont { fonts.insert(font.fontName) }
        }
        #expect(fonts == [Self.font.fontName])
    }

    /// Highlighten kost ~1,3 ms per KB: een erg groot bestand zou de UI
    /// seconden blokkeren, dus daarboven blijft het platte tekst.
    @Test func veryLargeFilesSkipHighlighting() {
        let huge = String(repeating: "let x = 1\n", count: CodeHighlighter.maximumHighlightedBytes / 5)
        #expect(huge.utf8.count > CodeHighlighter.maximumHighlightedBytes)
        #expect(distinctColors(CodeHighlighter.highlight(huge, language: "swift", font: Self.font)) == 1)
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
}

@MainActor
struct SourceEditorHighlightingTests {
    /// Regressie: `applyHighlight` zette na het plaatsen van de gekleurde
    /// tekst `textView.textColor`, en die setter kleurt de héle text storage
    /// in één kleur. Alle highlighting werd daarmee meteen weggegooid.
    @Test func applyHighlightKeepsTheTokenColors() {
        let host = EditorHostView(frame: .zero)
        let coordinator = SourceEditorView.Coordinator(text: .constant(""), path: "Demo.swift", onSave: {})

        coordinator.applyHighlight(to: host.textView, string: "import Foundation\nlet name = \"hoi\"\n")

        guard let storage = host.textView.textStorage else {
            Issue.record("geen text storage")
            return
        }
        #expect(distinctColors(storage) > 1)
    }
}

@MainActor
private func distinctColors(_ text: NSAttributedString) -> Int {
    var colors = Set<String>()
    text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
        if let color = value as? NSColor { colors.insert(color.description) }
    }
    return colors.count
}

struct EditorLayoutTests {
    @Test func containerWidthNeverCollapsesToZero() {
        #expect(EditorLayout.containerWidth(scrollWidth: 0) == EditorLayout.minimumContainerWidth)
        #expect(EditorLayout.containerWidth(scrollWidth: 10) == EditorLayout.minimumContainerWidth)
        #expect(EditorLayout.containerWidth(scrollWidth: 800) == 800 - EditorLayout.rulerThickness)
    }
}

@MainActor
struct EditorHostViewTests {
    /// Regressie: `makeNSView` draait met zero-bounds, daarna krijgt de host
    /// zijn echte breedte. `relayoutTextContainer` moet de textView dan op de
    /// volle breedte (min ruler) leggen en de layout verversen, anders blijft
    /// de ruler wel regelnummers tonen terwijl de tekst nooit wordt geschilderd
    /// (zie needsDisplay-fix in relayoutTextContainer).
    @Test func relayoutExpandsTextViewToHostWidth() {
        let host = EditorHostView(frame: .zero)
        host.textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: "# OpenMultiAgent\n",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: CodeHighlighter.textColor,
                ]
            )
        )

        host.frame = NSRect(x: 0, y: 0, width: 923, height: 346)
        host.layout()

        #expect(abs(host.textView.frame.size.width - (923 - EditorLayout.rulerThickness)) < 0.5)
        #expect(host.textView.string == "# OpenMultiAgent\n")
        #expect(host.textView.layoutManager?.numberOfGlyphs == 17)
    }

    /// Regressie: `NSRulerView` krijgt een dirty rect ter breedte van de hele
    /// scrollview, niet van zijn eigen 36pt-strook, en tekent ná de clipview.
    /// Vult de ruler die rect, dan schildert hij de zojuist getekende glyphs
    /// weer weg: regelnummers zichtbaar, code niet.
    @Test func rulerDoesNotPaintOverTheCode() {
        let host = EditorHostView(frame: .zero)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let source = (1...40).map { "let line\($0) = \"value \($0)\"" }.joined(separator: "\n")
        host.textView.textStorage?.setAttributedString(
            NSAttributedString(string: source, attributes: [
                .font: font,
                .foregroundColor: CodeHighlighter.textColor,
            ])
        )

        host.frame = NSRect(x: 0, y: 0, width: 923, height: 660)
        host.layout()
        host.layoutSubtreeIfNeeded()

        #expect(litPixelsRightOfRuler(in: host) > 1000)
    }

    /// Telt lichte pixels in het tekstgebied (rechts van de liniaal) van een
    /// gerenderde host. Nul betekent: er staan glyphs in de layout, maar er
    /// komt niets op het scherm.
    private func litPixelsRightOfRuler(in host: EditorHostView) -> Int {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let firstColumn = Int((EditorLayout.rulerThickness + 12) * scale)
        var lit = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: firstColumn, to: rep.pixelsWide, by: 2) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.genericRGB) else { continue }
                let brightness = (pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3
                if brightness > 0.5 { lit += 1 }
            }
        }
        return lit
    }
}

@MainActor
struct LineNumberLayoutTests {
    @Test func aWrappedLineKeepsASingleNumber() {
        let host = laidOutHost("first\n\(String(repeating: "x", count: 400))\nthird\n")

        // Bewijst dat de lange regel echt omslaat: meer fragmenten dan regels.
        #expect(fragmentCount(host) > 4)
        #expect(numbers(host) == [1, 2, 3, 4])
    }

    @Test func aScrolledViewportNumbersTheRightLines() {
        let host = laidOutHost((1...60).map { "row \($0)" }.joined(separator: "\n"))
        let visible = NSRect(x: 0, y: 300, width: host.textView.frame.width, height: 400)

        let got = numbers(host, visible: visible)

        #expect(got.first! > 1)
        #expect(got == Array(got.first!...got.last!))
    }

    @Test func aTrailingNewlineGetsItsOwnNumber() {
        #expect(numbers(laidOutHost("a\nb\n")) == [1, 2, 3])
        #expect(numbers(laidOutHost("a\nb")) == [1, 2])
        #expect(numbers(laidOutHost("")) == [1])
    }

    private func laidOutHost(_ source: String) -> EditorHostView {
        let host = EditorHostView(frame: .zero)
        host.textView.textStorage?.setAttributedString(
            NSAttributedString(string: source, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: CodeHighlighter.textColor,
            ])
        )
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layout()
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func numbers(_ host: EditorHostView, visible: NSRect? = nil) -> [Int] {
        guard let layoutManager = host.textView.layoutManager, let container = host.textView.textContainer else {
            return []
        }
        return LineNumberLayout.labels(
            text: host.textView.string as NSString,
            layoutManager: layoutManager,
            container: container,
            visible: visible ?? host.textView.visibleRect,
            inset: host.textView.textContainerInset.height
        ).map(\.number)
    }

    private func fragmentCount(_ host: EditorHostView) -> Int {
        guard let layoutManager = host.textView.layoutManager else { return 0 }
        var count = 0
        var index = 0
        while index < layoutManager.numberOfGlyphs {
            var range = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            count += 1
            index = max(NSMaxRange(range), index + 1)
        }
        return count
    }
}

@MainActor
struct CodeWorkspaceModelTests {
    @Test func loadsTreeAndOpensAFile() async {
        let client = EditorClientStub(
            tree: ["README.md", "src/index.ts"],
            files: ["README.md": "# hello\n", "src/index.ts": "export {}\n"]
        )
        let model = CodeWorkspaceModel(project: .cockpitSample, client: client)

        await model.loadTree()
        await model.openFile("README.md")

        #expect(model.tree.map(\.name) == ["src", "README.md"])
        #expect(model.selectedBuffer?.content == "# hello\n")
        #expect(model.selectedIsDirty == false)
    }

    @Test func savePersistsEditsAndClearsDirty() async {
        let client = EditorClientStub(tree: ["README.md"], files: ["README.md": "# hello\n"])
        let model = CodeWorkspaceModel(project: .cockpitSample, client: client)
        await model.loadTree()
        await model.openFile("README.md")

        model.updateContent("# hello\nchanged\n", for: "README.md")
        #expect(model.selectedIsDirty == true)

        let saved = await model.saveSelected()

        #expect(saved)
        #expect(model.selectedIsDirty == false)
        #expect(await client.written["README.md"] == "# hello\nchanged\n")
    }

    @Test func reloadKeepsDirtyBuffersAndRefreshesCleanOnes() async {
        let client = EditorClientStub(tree: ["a.ts", "b.ts"], files: ["a.ts": "a1", "b.ts": "b1"])
        let model = CodeWorkspaceModel(project: .cockpitSample, client: client)
        await model.openFile("a.ts")
        await model.openFile("b.ts")
        model.updateContent("a-dirty", for: "a.ts")
        await client.replace(path: "a.ts", content: "a2")
        await client.replace(path: "b.ts", content: "b2")

        await model.reloadCleanBuffers()

        #expect(model.buffers.first { $0.path == "a.ts" }?.content == "a-dirty")
        #expect(model.buffers.first { $0.path == "b.ts" }?.content == "b2")
    }

    @Test func revealOpensASessionWorktreeFile() async {
        let client = EditorClientStub(
            tree: ["README.md"],
            files: ["README.md": "# main\n"],
            sessionFiles: ["s1": ["README.md": "# session\n"]]
        )
        let model = CodeWorkspaceModel(project: .cockpitSample, client: client)

        await model.reveal(path: "README.md", sessionID: "s1")

        #expect(model.root == .session(id: "s1"))
        #expect(model.selectedBuffer?.content == "# session\n")
        #expect(await client.lastSessionID == "s1")
    }
}

@MainActor
struct ProjectCockpitEditorNavigationTests {
    @Test func openingAnEditorFromChangesLeavesTheSessionDetail() async {
        let client = AppModelClientStub()
        let model = AppModel(client: client)
        model.selectedProject = .cockpitSample
        model.selectedSession = .sample(id: "s1", status: "active")

        model.openProjectEditor(sessionID: "s1", path: "README.md")

        #expect(model.selectedSession == nil)
        #expect(model.selection == .projects)
        #expect(model.consumeEditorOpen() == EditorOpenRequest(sessionID: "s1", path: "README.md"))
        #expect(model.consumeEditorOpen() == nil)
    }
}

private actor EditorClientStub: DesktopAPI {
    var tree: [String]
    var files: [String: String]
    var sessionFiles: [String: [String: String]]
    var written: [String: String] = [:]
    var lastSessionID: String?

    init(tree: [String], files: [String: String], sessionFiles: [String: [String: String]] = [:]) {
        self.tree = tree
        self.files = files
        self.sessionFiles = sessionFiles
    }

    func hello() async throws -> HelloDTO { HelloDTO(protocolVersion: 1, appVersion: "test", agents: []) }
    func health() async throws -> HealthDTO { HealthDTO(ok: true, tmuxAvailable: true) }
    func listProjects() async throws -> [ProjectDTO] { [.cockpitSample] }
    func addProject(repoPath: String, displayName: String?) async throws -> ProjectDTO { .cockpitSample }
    func removeProject(id: String) async throws {}

    func fsTree(projectID: String, sessionID: String?) async throws -> FileTreeDTO {
        lastSessionID = sessionID
        return FileTreeDTO(paths: tree)
    }

    func fsRead(projectID: String, sessionID: String?, path: String) async throws -> FileContentDTO {
        lastSessionID = sessionID
        let content: String
        if let sessionID, let scoped = sessionFiles[sessionID]?[path] {
            content = scoped
        } else if let file = files[path] {
            content = file
        } else {
            throw SidecarClientError.unavailable("missing \(path)")
        }
        return FileContentDTO(path: path, content: content)
    }

    func fsWrite(projectID: String, sessionID: String?, path: String, content: String) async throws -> FileWriteDTO {
        lastSessionID = sessionID
        files[path] = content
        written[path] = content
        return FileWriteDTO(path: path, bytesWritten: content.utf8.count)
    }

    func replace(path: String, content: String) {
        files[path] = content
    }
}

private actor AppModelClientStub: DesktopAPI {
    func hello() async throws -> HelloDTO { HelloDTO(protocolVersion: 1, appVersion: "test", agents: []) }
    func health() async throws -> HealthDTO { HealthDTO(ok: true, tmuxAvailable: true) }
    func listProjects() async throws -> [ProjectDTO] { [] }
    func addProject(repoPath: String, displayName: String?) async throws -> ProjectDTO { .cockpitSample }
    func removeProject(id: String) async throws {}
    func pendingPromotionCount() async throws -> PendingPromotionCountDTO { PendingPromotionCountDTO(count: 0) }
}