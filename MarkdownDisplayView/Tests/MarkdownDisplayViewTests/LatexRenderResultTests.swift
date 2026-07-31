import Testing
import UIKit
@testable import MarkdownDisplayView

private final class FormulaNodeStub: FormulaRenderNode {
    let size: CGSize

    init(size: CGSize) {
        self.size = size
    }

    func layout() {}
    func draw(in context: CGContext, at point: CGPoint) {}
}

@MainActor
@Test func latexRenderResultParsesOnceAndReusesNodeForDrawing() throws {
    var parseCount = 0
    let rootNode = FormulaNodeStub(size: CGSize(width: 120, height: 40))
    let formula = ParsedFormula.make(latex: "x^2", fontSize: 22) {
        parseCount += 1
        return rootNode
    }
    let result = LatexRenderResult(formula: formula, padding: 20, maxWidth: 300)

    let created = LatexMathView.createScrollableView(renderResult: result)
    let mathView = try #require(created.view as? LatexMathView)
    let renderedFormula = try #require(mathView.renderedFormula)

    #expect(parseCount == 1)
    #expect(renderedFormula.rootNode as AnyObject === rootNode)
    #expect(created.contentSize == CGSize(width: 140, height: 60))
    #expect(result.displaySize == CGSize(width: 140, height: 60))
}

@MainActor
@Test func latexAttachmentAndViewUseTheSameDisplaySize() {
    let formula = ParsedFormula.make(latex: "x", fontSize: 22) {
        FormulaNodeStub(size: CGSize(width: 120, height: 40))
    }
    let result = LatexRenderResult(formula: formula, padding: 20, maxWidth: 300)
    let attachment = LaTeXAttachment(
        latex: formula.latex,
        fontSize: formula.fontSize,
        maxWidth: result.maxWidth,
        padding: result.padding,
        backgroundColor: .clear,
        renderResult: result
    )

    let bounds = attachment.attachmentBounds(
        for: nil,
        proposedLineFragment: .zero,
        glyphPosition: .zero,
        characterIndex: 0
    )

    #expect(bounds.size == result.displaySize)
    #expect(result.contentSize == CGSize(width: 140, height: 60))
    #expect(result.displaySize == CGSize(width: 140, height: 60))
}

@MainActor
@Test func wideLatexUsesContentWidthForScrollingAndClampedDisplayWidth() throws {
    let rootNode = FormulaNodeStub(size: CGSize(width: 600, height: 40))
    let formula = ParsedFormula.make(latex: "wide", fontSize: 22) { rootNode }
    let result = LatexRenderResult(formula: formula, padding: 20, maxWidth: 300)

    let created = LatexMathView.createScrollableView(renderResult: result)
    let scrollView = try #require(created.view as? UIScrollView)
    let mathView = try #require(scrollView.subviews.first as? LatexMathView)
    let renderedFormula = try #require(mathView.renderedFormula)

    #expect(created.contentSize == CGSize(width: 620, height: 60))
    #expect(result.displaySize == CGSize(width: 300, height: 60))
    #expect(scrollView.frame.size == result.displaySize)
    #expect(scrollView.contentSize == result.contentSize)
    #expect(mathView.frame.size == result.contentSize)
    #expect(renderedFormula.rootNode as AnyObject === rootNode)
}
