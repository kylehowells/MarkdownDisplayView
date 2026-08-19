import Testing
import UIKit
@testable import MarkdownDisplayView

private func renderedAttributedText(from elements: [MarkdownRenderElement]) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for element in elements {
        if case .attributedText(let text) = element {
            result.append(text)
        }
    }
    return result
}

private func inlineLatexAttachments(in text: NSAttributedString) -> [LaTeXAttachment] {
    var attachments: [LaTeXAttachment] = []
    text.enumerateAttribute(
        .attachment,
        in: NSRange(location: 0, length: text.length),
        options: []
    ) { value, _, _ in
        if let attachment = value as? LaTeXAttachment, attachment.isInline {
            attachments.append(attachment)
        }
    }
    return attachments
}

@available(iOS 15.0, *)
@MainActor
@Test func fractionCommandAliasesBuildFractionNodes() {
    for command in ["frac", "dfrac", "tfrac"] {
        let parser = LatexParser(
            latex: "\\\(command){f(b)-f(a)}{b-a}",
            font: UIFont.systemFont(ofSize: 20)
        )
        let node = parser.parse()

        #expect(node is FractionNode, "\\\(command) must render as a fraction")
    }
}

@available(iOS 15.0, *)
@MainActor
@Test func inlineCodeDelimitersRemainCodeInsteadOfBecomingMath() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let markdown = "Prefer `\\[ ... \\]` over `$$ ... $$`, and write `$E=mc^2$` literally."

    let result = renderer.render(markdown)
    let text = renderedAttributedText(from: result.elements)

    #expect(result.elements.allSatisfy { element in
        if case .latex = element { return false }
        return true
    })
    #expect(inlineLatexAttachments(in: text).isEmpty)
    #expect(text.string.contains("$$ ... $$"))
    #expect(text.string.contains("$E=mc^2$"))

    let codeRange = (text.string as NSString).range(of: "$$ ... $$")
    #expect(codeRange.location != NSNotFound)
    if codeRange.location != NSNotFound {
        let font = text.attribute(.font, at: codeRange.location, effectiveRange: nil) as? UIFont
        #expect(font == MarkdownConfiguration.default.codeFont)
    }
}

@available(iOS 15.0, *)
@MainActor
@Test func fencedLatexSourceRemainsACodeBlock() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let markdown = """
    ```latex
    The sum $\\sum_{i=1}^{n} i$ is inline.
    ```
    """

    let result = renderer.render(markdown)

    #expect(result.elements.count == 1)
    guard case .codeBlock(let language, let code) = result.elements.first else {
        Issue.record("A fenced latex source sample must remain a code block")
        return
    }
    #expect(language == "latex")
    #expect(code.string.contains("$\\sum_{i=1}^{n} i$"))
}

@available(iOS 15.0, *)
@MainActor
@Test func fencedMathRemainsAnExplicitDisplayMathExtension() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("""
    ```math
    E = mc^2
    ```
    """)

    #expect(result.elements == [.latex("E = mc^2\n")])
}

@available(iOS 15.0, *)
@MainActor
@Test func dollarWrappedContentInsideAnyFenceRemainsCode() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("""
    ```text
    $$E = mc^2$$
    ```
    """)

    guard case .codeBlock(let language, let code) = result.elements.first else {
        Issue.record("Fenced source must not be inferred as display math from its payload")
        return
    }
    #expect(language == "text")
    #expect(code.string == "$$E = mc^2$$")
}

@available(iOS 15.0, *)
@MainActor
@Test func standaloneDoubleDollarParagraphStillRendersAsDisplayMath() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("$$E = mc^2$$")

    #expect(result.elements == [.latex("E = mc^2")])
}

@available(iOS 15.0, *)
@MainActor
@Test func displayMathAfterAHistoryListLabelRemainsABlockFormula() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("""
    1. **圆的周长公式**：
       $$
       C = \\pi d = 2\\pi r
       $$
    """)

    guard case .list(let items, _) = result.elements.first,
          let item = items.first else {
        Issue.record("History-style display math must remain inside its list item")
        return
    }

    #expect(item.children.contains { element in
        if case .latex("C = \\pi d = 2\\pi r") = element { return true }
        return false
    })
    #expect(item.children.allSatisfy { element in
        guard case .attributedText(let text) = element else { return true }
        return !text.string.contains("$$")
    })
}

@available(iOS 15.0, *)
@MainActor
@Test func doubleDollarCodeInsideAListLabelRemainsLiteral() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("1. Prefer `$$ ... $$` for this literal example.")

    guard case .list(let items, _) = result.elements.first,
          let item = items.first else {
        Issue.record("Expected one rendered list item")
        return
    }

    #expect(item.children.allSatisfy { element in
        if case .latex = element { return false }
        return true
    })
    #expect(item.children.contains { element in
        guard case .attributedText(let text) = element else { return false }
        return text.string.contains("$$ ... $$")
    })
}

@available(iOS 15.0, *)
@MainActor
@Test func inlineMathPreservesSurroundingMarkdownStyles() throws {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("**Energy** is $E=mc^2$ and *mass* matters.")
    let text = renderedAttributedText(from: result.elements)

    #expect(result.elements.count == 1)
    #expect(inlineLatexAttachments(in: text).map(\.latex) == ["E=mc^2"])

    let energyRange = (text.string as NSString).range(of: "Energy")
    let massRange = (text.string as NSString).range(of: "mass")
    let energyFont = try #require(text.attribute(.font, at: energyRange.location, effectiveRange: nil) as? UIFont)
    let massFont = try #require(text.attribute(.font, at: massRange.location, effectiveRange: nil) as? UIFont)
    #expect(energyFont.fontDescriptor.symbolicTraits.contains(.traitBold))
    #expect(massFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
}

@available(iOS 15.0, *)
@MainActor
@Test func inlineMathUsesTransparentAppearanceAndInkSafetyInsets() throws {
    let configuration = MarkdownConfiguration.default
    let renderer = MarkdownRenderer(configuration: configuration, containerWidth: 320)
    let result = renderer.render("Variables $C$, $d$, and $r$ stay readable.")
    let text = renderedAttributedText(from: result.elements)
    let attachments = inlineLatexAttachments(in: text)

    #expect(attachments.map(\.latex) == ["C", "d", "r"])
    for attachment in attachments {
        let addedWidth = attachment.renderResult.contentSize.width
            - attachment.renderResult.formula.intrinsicSize.width
        let addedHeight = attachment.renderResult.contentSize.height
            - attachment.renderResult.formula.intrinsicSize.height
        let minimumSafety = max(8, configuration.bodyFont.pointSize * 0.6)

        #expect(attachment.backgroundColor.cgColor.alpha == 0)
        #expect(attachment.appearance.cornerRadius == 0)
        #expect(attachment.appearance.borderWidth == 0)
        #expect(addedWidth >= minimumSafety - 0.001)
        #expect(addedHeight >= minimumSafety - 0.001)
    }
}

@available(iOS 15.0, *)
@MainActor
@Test func multipleInlineMathViewsRemainVisibleAcrossSoftWraps() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render(
        "Real inline math stays in the sentence: energy is $E=mc^2$, "
            + "and the Pythagorean theorem is $a^2+b^2=c^2$."
    )
    let text = renderedAttributedText(from: result.elements)
    #expect(inlineLatexAttachments(in: text).count == 2)
    // One-point steps cover the narrow widths where an attachment lands exactly at a
    // soft-wrapped line start and TextKit reports CGRect.zero for its attachment frame.
    for width in stride(from: CGFloat(280), through: 440, by: 1) {
        let textView = MarkdownTextViewTK2()
        textView.attributedText = text
        textView.applyLayout(width: width, force: true)

        #expect(textView.subviews.count == 2, "width=\(width)")
        #expect(textView.subviews.allSatisfy { !$0.isHidden }, "width=\(width)")
        #expect(
            textView.subviews.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 },
            "width=\(width)"
        )
        #expect(
            textView.subviews.allSatisfy {
                $0.frame.minX >= 0
                    && $0.frame.maxX <= width + 0.5
                    && $0.frame.minY >= 0
                    && $0.frame.maxY <= textView.intrinsicContentSize.height + 0.5
            },
            "width=\(width), frames=\(textView.subviews.map(\.frame)), bounds=\(textView.intrinsicContentSize)"
        )
    }
}

@available(iOS 15.0, *)
@MainActor
@Test func oversizedInlineMathViewGetsANonzeroFrameAfterWrapping() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render(
        "A long inline expression scales to the real line width without clipping: "
            + "$x=\\frac{-b\\pm\\sqrt{b^2-4ac}}{2a}+\\sum_{i=1}^{n}i$."
    )
    let text = renderedAttributedText(from: result.elements)
    #expect(inlineLatexAttachments(in: text).count == 1)
    for width in stride(from: CGFloat(280), through: 440, by: 20) {
        let textView = MarkdownTextViewTK2()
        textView.attributedText = text
        textView.applyLayout(width: width, force: true)

        #expect(textView.subviews.count == 1, "width=\(width)")
        #expect(textView.subviews.first?.isHidden == false, "width=\(width)")
        #expect((textView.subviews.first?.frame.width ?? 0) > 0, "width=\(width)")
        if let formulaView = textView.subviews.first {
            #expect(
                formulaView.frame.minX >= 0
                    && formulaView.frame.maxX <= width + 0.5
                    && formulaView.frame.minY >= 0
                    && formulaView.frame.maxY <= textView.intrinsicContentSize.height + 0.5,
                "width=\(width), frame=\(formulaView.frame), bounds=\(textView.intrinsicContentSize)"
            )
        }
    }
}

@available(iOS 15.0, *)
@MainActor
@Test func inlineMathViewsAreCreatedForEveryParagraphInOneTextView() {
    let renderer = MarkdownRenderer(containerWidth: 360)
    let result = renderer.render(
        "First paragraph ends with $E=mc^2$.\n\n"
            + "Second paragraph contains $x=\\frac{-b\\pm\\sqrt{b^2-4ac}}{2a}$."
    )
    let text = renderedAttributedText(from: result.elements)
    #expect(inlineLatexAttachments(in: text).count == 2)

    let textView = MarkdownTextViewTK2()
    textView.attributedText = text
    textView.applyLayout(width: 360, force: true)

    #expect(textView.subviews.count == 2)
    #expect(textView.subviews.allSatisfy { !$0.isHidden })
    #expect(textView.subviews.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
}

@available(iOS 15.0, *)
@MainActor
@Test func inlineMathUsesTheActualLineFragmentWidthWithoutClipping() {
    let node = InlineFormulaNodeStub(size: CGSize(width: 600, height: 40))
    let formula = ParsedFormula.make(latex: "wide", fontSize: 20) { node }
    let renderResult = LatexRenderResult(
        formula: formula,
        padding: 2,
        maxWidth: .greatestFiniteMagnitude
    )
    let attachment = LaTeXAttachment(
        latex: formula.latex,
        fontSize: formula.fontSize,
        maxWidth: renderResult.maxWidth,
        padding: renderResult.padding,
        backgroundColor: .clear,
        renderResult: renderResult,
        isInline: true,
        inlineCapHeight: UIFont.systemFont(ofSize: 20).capHeight
    )

    let bounds = attachment.attachmentBounds(
        for: nil,
        proposedLineFragment: CGRect(x: 0, y: 0, width: 120, height: 30),
        glyphPosition: .zero,
        characterIndex: 0
    )

    let expectedScale = 120 / renderResult.contentSize.width
    #expect(abs(bounds.width - 120) < 0.001)
    #expect(abs(bounds.height - renderResult.contentSize.height * expectedScale) < 0.001)

    let mathView = LatexMathView(parsedFormula: formula)
    mathView.frame = CGRect(origin: .zero, size: bounds.size)
    let renderer = UIGraphicsImageRenderer(size: bounds.size)
    _ = renderer.image { _ in
        mathView.draw(mathView.bounds)
    }

    let transform = node.drawTransform
    let expectedDrawScale = min(bounds.width / node.size.width, bounds.height / node.size.height)
    #expect(transform != nil)
    if let transform {
        #expect(abs(abs(transform.a) / UIScreen.main.scale - expectedDrawScale) < 0.01)
        #expect(abs(abs(transform.d) / UIScreen.main.scale - expectedDrawScale) < 0.01)
    }
}

@available(iOS 15.0, *)
@MainActor
@Test func revealTypewriterKeepsInlineMathHiddenUntilItsCharacter() throws {
    let attachment = LaTeXAttachment(
        latex: "E=mc^2",
        fontSize: 18,
        maxWidth: .greatestFiniteMagnitude,
        padding: 2,
        backgroundColor: .clear,
        isInline: true,
        inlineCapHeight: UIFont.systemFont(ofSize: 18).capHeight
    )
    let text = NSMutableAttributedString(string: "A ")
    text.append(NSAttributedString(attachment: attachment))
    text.append(NSAttributedString(string: " B"))

    let textView = MarkdownTextViewTK2()
    textView.typewriterTextMode = .reveal
    textView.attributedText = text
    textView.applyLayout(width: 240, force: true)
    textView.prepareForTypewriter()

    let formulaView = try #require(textView.subviews.first)
    #expect(formulaView.isHidden)

    _ = textView.revealCharacter(upto: 2)
    #expect(formulaView.isHidden)

    _ = textView.revealCharacter(upto: 3)
    #expect(formulaView.isHidden == false)
}

@available(iOS 15.0, *)
@MainActor
@Test func lateCreatedInlineMathProviderInheritsTheTypewriterRevealLimit() throws {
    let attachment = LaTeXAttachment(
        latex: "x",
        fontSize: 18,
        maxWidth: .greatestFiniteMagnitude,
        padding: 2,
        backgroundColor: .clear,
        isInline: true,
        inlineCapHeight: UIFont.systemFont(ofSize: 18).capHeight
    )
    let text = NSMutableAttributedString(string: "A ")
    text.append(NSAttributedString(attachment: attachment))

    let textView = MarkdownTextViewTK2()
    textView.typewriterTextMode = .reveal
    textView.attributedText = text

    // Whether TextKit eagerly creates the provider or creates it after a later layout is
    // an implementation detail. Both paths must inherit the reveal limit and stay hidden.
    textView.prepareForTypewriter()
    #expect(textView.subviews.allSatisfy { $0.isHidden })

    textView.applyLayout(width: 240, force: true)
    let formulaView = try #require(textView.subviews.first)
    #expect(formulaView.isHidden)
}

@available(iOS 15.0, *)
@MainActor
@Test func appendTypewriterShowsInlineMathOnlyWhenItIsAppended() throws {
    let attachment = LaTeXAttachment(
        latex: "x",
        fontSize: 18,
        maxWidth: .greatestFiniteMagnitude,
        padding: 2,
        backgroundColor: .clear,
        isInline: true,
        inlineCapHeight: UIFont.systemFont(ofSize: 18).capHeight
    )
    let text = NSMutableAttributedString(string: "A ")
    text.append(NSAttributedString(attachment: attachment))

    let textView = MarkdownTextViewTK2()
    textView.typewriterTextMode = .append
    textView.attributedText = text
    textView.textContainer.size = CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
    textView.prepareForTypewriter()

    _ = textView.revealCharacter(upto: 2)
    #expect(textView.subviews.isEmpty)

    _ = textView.revealCharacter(upto: 3)
    let formulaView = try #require(textView.subviews.first)
    #expect(formulaView.isHidden == false)
}

private final class InlineFormulaNodeStub: FormulaRenderNode {
    let size: CGSize
    private(set) var drawTransform: CGAffineTransform?

    init(size: CGSize) {
        self.size = size
    }

    func layout() {}
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        drawTransform = context.ctm
    }
}

@available(iOS 15.0, *)
@MainActor
@Test func inlineImageKeepsItsPositionInParagraphWithoutMath() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("before ![alt](https://e.com/a.png) after")

    #expect(result.elements.count == 3)
    guard result.elements.count == 3 else { return }
    guard case .attributedText(let first) = result.elements[0] else {
        Issue.record("first should be text")
        return
    }
    guard case .image = result.elements[1] else {
        Issue.record("image must sit between the two text runs")
        return
    }
    guard case .attributedText(let third) = result.elements[2] else {
        Issue.record("third should be text")
        return
    }
    #expect(first.string.trimmingCharacters(in: .whitespacesAndNewlines) == "before")
    #expect(third.string.trimmingCharacters(in: .whitespacesAndNewlines) == "after")
}

@available(iOS 15.0, *)
@MainActor
@Test func inlineImageKeepsItsPositionBetweenInlineMath() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("before $x$ ![alt](https://e.com/a.png) after $y$")

    #expect(result.elements.count == 3)
    guard result.elements.count == 3 else { return }
    guard case .attributedText(let first) = result.elements[0] else { return }
    guard case .image = result.elements[1] else {
        Issue.record("image must sit between the two text runs")
        return
    }
    guard case .attributedText(let third) = result.elements[2] else { return }

    #expect(inlineLatexAttachments(in: first).map(\.latex) == ["x"])
    #expect(inlineLatexAttachments(in: third).map(\.latex) == ["y"])
}

@available(iOS 15.0, *)
@MainActor
@Test func headingInlineMathRendersAsAttachment() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("## Energy $E=mc^2$")
    guard case .heading(_, let text) = result.elements.first else {
        Issue.record("expected heading")
        return
    }
    #expect(inlineLatexAttachments(in: text).map(\.latex) == ["E=mc^2"])
    #expect(!text.string.contains("$"))
}

@available(iOS 15.0, *)
@MainActor
@Test func headingInlineCodeDollarRemainsLiteral() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("## Use `$E=mc^2$`")
    guard case .heading(_, let text) = result.elements.first else {
        Issue.record("expected heading")
        return
    }
    #expect(inlineLatexAttachments(in: text).isEmpty)
    #expect(text.string.contains("$E=mc^2$"))
}

@available(iOS 15.0, *)
@MainActor
@Test func tableCellInlineMathRendersAsAttachment() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("| Formula |\n| --- |\n| $E=mc^2$ |")
    guard case .table(let data) = result.elements.first, !data.rows.isEmpty else {
        Issue.record("expected table with rows")
        return
    }
    let cell = data.rows[0][0]
    #expect(inlineLatexAttachments(in: cell).map(\.latex) == ["E=mc^2"])
}

@available(iOS 15.0, *)
@MainActor
@Test func blockquoteInlineMathStillWorks() {
    let renderer = MarkdownRenderer(containerWidth: 320)
    let result = renderer.render("> Energy $E=mc^2$")
    guard case .quote(let children, _) = result.elements.first else {
        Issue.record("expected blockquote")
        return
    }
    let attachments = children.compactMap { child -> [LaTeXAttachment] in
        guard case .attributedText(let text) = child else { return [] }
        return inlineLatexAttachments(in: text)
    }.flatMap { $0 }
    #expect(attachments.map(\.latex) == ["E=mc^2"])
}
