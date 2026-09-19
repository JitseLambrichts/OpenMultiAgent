import AppKit
import SwiftUI

enum EditorLayout {
    static let rulerThickness: CGFloat = 36
    static let minimumContainerWidth: CGFloat = 240

    /// `NSScrollView.contentSize` is 0 during `makeNSView`. A 0-wide
    /// `NSTextContainer` still produces line fragments (so the ruler counts
    /// lines) but draws no visible glyphs.
    static func containerWidth(scrollWidth: CGFloat) -> CGFloat {
        max(scrollWidth - rulerThickness, minimumContainerWidth)
    }
}

struct SourceEditorView: NSViewRepresentable {
    @Binding var text: String
    var path: String
    var onSave: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, path: path, onSave: onSave)
    }

    func makeNSView(context: Context) -> EditorHostView {
        let host = EditorHostView()
        host.textView.delegate = context.coordinator
        host.textView.onSave = onSave
        context.coordinator.applyHighlight(to: host.textView, string: text)
        return host
    }

    func updateNSView(_ host: EditorHostView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.path = path
        context.coordinator.onSave = onSave
        host.textView.onSave = onSave
        if host.textView.string != text {
            let selected = host.textView.selectedRange()
            context.coordinator.applyHighlight(to: host.textView, string: text)
            let clamped = NSRange(location: min(selected.location, host.textView.string.utf16.count), length: 0)
            host.textView.setSelectedRange(clamped)
        }
        host.relayoutTextContainer()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 320)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var path: String
        var onSave: () -> Void
        private var isApplying = false

        init(text: Binding<String>, path: String, onSave: @escaping () -> Void) {
            self.text = text
            self.path = path
            self.onSave = onSave
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            applyHighlight(to: textView, string: textView.string, preserveSelection: true)
        }

        func applyHighlight(to textView: NSTextView, string: String, preserveSelection: Bool = false) {
            isApplying = true
            let selected = textView.selectedRange()
            let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
            let highlighted = CodeHighlighter.highlight(string, language: CodeHighlighter.language(for: path), font: font)
            if let storage = textView.textStorage {
                storage.beginEditing()
                storage.setAttributedString(highlighted)
                storage.endEditing()
            } else {
                textView.string = string
            }
            textView.textColor = CodeHighlighter.textColor
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: CodeHighlighter.textColor,
            ]
            if preserveSelection {
                let max = textView.string.utf16.count
                textView.setSelectedRange(NSRange(location: min(selected.location, max), length: min(selected.length, max)))
            }
            isApplying = false
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            textView.needsDisplay = true
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

final class EditorHostView: NSView {
    let scrollView = NSScrollView()
    let textView: EditorTextView
    private let textContainer: NSTextContainer

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: EditorLayout.minimumContainerWidth,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 5
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: EditorLayout.minimumContainerWidth, height: 200), textContainer: container)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.isRichText = true
        editor.importsGraphics = false
        editor.usesFontPanel = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.drawsBackground = true
        editor.backgroundColor = CodeHighlighter.backgroundColor
        editor.textColor = CodeHighlighter.textColor
        editor.insertionPointColor = CodeHighlighter.keywordColor
        editor.selectedTextAttributes = [
            .backgroundColor: NSColor(calibratedRed: 201 / 255, green: 246 / 255, blue: 111 / 255, alpha: 0.28),
            .foregroundColor: CodeHighlighter.textColor,
        ]

        self.textContainer = container
        self.textView = editor
        super.init(frame: frameRect)

        let dark = NSAppearance(named: .darkAqua)
        appearance = dark
        wantsLayer = true
        clipsToBounds = true
        layer?.backgroundColor = CodeHighlighter.backgroundColor.cgColor

        scrollView.appearance = dark
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CodeHighlighter.backgroundColor
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        scrollView.rulersVisible = true
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView?.appearance = dark
        addSubview(scrollView)

        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.defaultLow, for: axis)
            setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        relayoutTextContainer()
    }

    func relayoutTextContainer() {
        let width = EditorLayout.containerWidth(scrollWidth: bounds.width)
        // `makeNSView` draait met zero bounds: de container volgt dan een
        // 0-brede textView en legt de regels op de verkeerde breedte. Zodra de
        // host zijn echte breedte krijgt herberekent ensureLayout die, maar de
        // textView herschildert niet vanzelf — vandaar de expliciete
        // invalidatie bij een breedtewissel.
        let widthChanged = abs(textView.frame.size.width - width) > 0.5
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: width, height: bounds.height)
        textView.frame.size.width = width
        textView.layoutManager?.ensureLayout(for: textContainer)
        if widthChanged {
            textView.needsDisplay = true
        }
        scrollView.verticalRulerView?.needsDisplay = true
    }
}

final class EditorTextView: NSTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum LineNumberLayout {
    struct Label: Equatable {
        let number: Int
        let y: CGFloat
    }

    /// Eén label per bronregel — niet per regelfragment. Een regel die over
    /// meerdere visuele regels doorloopt houdt dus één nummer, anders lopen de
    /// nummers na elke omgeslagen regel uit de pas met het bestand.
    static func labels(
        text: NSString,
        layoutManager: NSLayoutManager,
        container: NSTextContainer,
        visible: NSRect,
        inset: CGFloat
    ) -> [Label] {
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Tel de bronregels die volledig boven het zichtbare gebied liggen, en
        // zak terug naar het begin van de regel waarin het eerste zichtbare
        // teken valt: dát is de regel waar het eerste nummer bij hoort.
        var number = 1
        var index = 0
        while index < charRange.location {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            guard line.length > 0, NSMaxRange(line) <= charRange.location else { break }
            index = NSMaxRange(line)
            number += 1
        }

        var labels: [Label] = []
        let end = NSMaxRange(charRange)
        while index < end {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            labels.append(Label(number: number, y: fragment.minY + inset - visible.origin.y))
            guard line.length > 0 else { break }
            index = NSMaxRange(line)
            number += 1
        }

        // Een bestand dat op een newline eindigt (of leeg is) heeft een lege
        // slotregel zonder glyphs; die krijgt zijn eigen extra line fragment.
        if index >= text.length, layoutManager.extraLineFragmentTextContainer != nil {
            let fragment = layoutManager.extraLineFragmentRect
            if fragment.maxY >= visible.minY, fragment.minY <= visible.maxY {
                labels.append(Label(number: number, y: fragment.minY + inset - visible.origin.y))
            }
        }
        return labels
    }
}

private final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = EditorLayout.rulerThickness
        // AppKit clipt een NSView sinds macOS 14 niet meer standaard op zijn
        // eigen bounds, en de ruler tekent ná de clipview. Zonder dit clipt
        // niets ons weg van het tekstgebied ernaast.
        clipsToBounds = true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // `rect` is zo breed als de hele scrollview, niet als de 36pt-strook
        // van de ruler. `rect.fill()` schildert dan de net getekende glyphs
        // weer weg: regelnummers zichtbaar, code onzichtbaar. Vul daarom enkel
        // het deel dat binnen onze eigen bounds valt.
        NSColor(OMAColor.elevated).setFill()
        bounds.intersection(rect).fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
        ]
        let labels = LineNumberLayout.labels(
            text: textView.string as NSString,
            layoutManager: layoutManager,
            container: container,
            visible: textView.visibleRect,
            inset: textView.textContainerInset.height
        )
        for label in labels {
            let string = "\(label.number)" as NSString
            let size = string.size(withAttributes: attributes)
            string.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: label.y), withAttributes: attributes)
        }
    }
}
