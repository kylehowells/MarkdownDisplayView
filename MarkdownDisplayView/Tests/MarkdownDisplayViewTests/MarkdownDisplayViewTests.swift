import Testing
import UIKit
@testable import MarkdownDisplayView

@Test func listWrapperPaddingDefaultsToZero() async throws {
    let configuration = MarkdownConfiguration.default

    #expect(configuration.listTopPadding == 0)
    #expect(configuration.listBottomPadding == 0)
}

@Test func blockAppearanceDefaultsPreserveExistingCornerRadii() async throws {
    let configuration = MarkdownConfiguration.default

    #expect(configuration.codeBlockAppearance.cornerRadius == 8)
    #expect(configuration.blockquoteAppearance.cornerRadius == 4)
    #expect(configuration.tableAppearance.cornerRadius == 0)
    #expect(configuration.imageAppearance.cornerRadius == 8)
    #expect(configuration.latexAppearance.cornerRadius == 8)
    #expect(configuration.detailsAppearance.cornerRadius == 6)

    #expect(configuration.codeBlockAppearance.borderWidth == 0)
    #expect(configuration.blockquoteAppearance.borderWidth == 0)
    #expect(configuration.tableAppearance.borderWidth == 0)
    #expect(configuration.imageAppearance.borderWidth == 0)
    #expect(configuration.latexAppearance.borderWidth == 0)
    #expect(configuration.detailsAppearance.borderWidth == 0)
}

@Test func latexTextColorHasAdaptiveDefaults() async throws {
    #expect(MarkdownConfiguration.default.latexTextColor.isEqual(UIColor.label))
    #expect(MarkdownConfiguration.dark.latexTextColor.isEqual(UIColor.white))
}

@MainActor
@Test func customBlockAppearanceAppliesWithoutChangingViewConstraints() async throws {
    var configuration = MarkdownConfiguration.default
    let borderColor = UIColor(red: 0.22, green: 0.18, blue: 0.72, alpha: 1)
    configuration.codeBlockAppearance = MarkdownBlockAppearance(
        cornerRadius: 14,
        borderWidth: 2,
        borderColor: borderColor
    )
    configuration.blockquoteAppearance = MarkdownBlockAppearance(
        cornerRadius: 10,
        borderWidth: 1,
        borderColor: borderColor
    )

    let markdownView = MarkdownViewTextKit()
    markdownView.configuration = configuration

    let codeBlock = markdownView.createCodeBlockView(
        with: NSAttributedString(string: "let value = 1"),
        width: 320
    )
    #expect(codeBlock.layer.cornerRadius == 14)
    #expect(codeBlock.layer.borderWidth == 2)
    #expect(UIColor(cgColor: try #require(codeBlock.layer.borderColor)).isEqual(borderColor))

    let quote = markdownView.createQuoteView(children: [], width: 320)
    let quoteContainer = try #require(quote.subviews.first)
    #expect(quoteContainer.layer.cornerRadius == 10)
    #expect(quoteContainer.layer.borderWidth == 1)
    #expect(UIColor(cgColor: try #require(quoteContainer.layer.borderColor)).isEqual(borderColor))

    let widthConstraint = codeBlock.constraints.first {
        $0.firstAttribute == .width && $0.relation == .equal
    }
    #expect(widthConstraint?.constant == 320)
}

@available(iOS 15.0, *)
@Test func imageViewNormalizesImageURLsBeforeLoading() async throws {
    let httpURL = try #require(ImageView.normalizedImageURL(from: "http://example.com/photo.png"))
    let bareURL = try #require(ImageView.normalizedImageURL(from: "example.com/photo"))
    let casedExtensionURL = try #require(ImageView.normalizedImageURL(from: "https://example.com/PHOTO.PNG"))

    #expect(httpURL.absoluteString == "https://example.com/photo.png")
    #expect(bareURL.absoluteString == "https://example.com/photo")
    #expect(casedExtensionURL.absoluteString == "https://example.com/PHOTO.PNG")
}

@available(iOS 15.0, *)
@Test func singleHeadingMarkdownStreamsParagraphByParagraph() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)
    let markdown = """
    # Title

    Paragraph one is long enough to stream.

    Paragraph two is also long enough.

    """

    let result = buffer.append(markdown)

    #expect(result.completeModules.count == 2)
    #expect(result.completeModules[0] == "# Title\n\nParagraph one is long enough to stream.")
    #expect(result.completeModules[1] == "Paragraph two is also long enough.")
    #expect(result.pendingText.isEmpty)
    #expect(result.hasPendingStructure == false)
}

@available(iOS 15.0, *)
@Test func doubleNewlinesInsideCodeBlocksDoNotCreateBoundaries() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)
    let markdown = """
    # Title

    ```swift
    let first = 1

    let second = 2
    ```

    Closing paragraph is outside the code block.

    """

    let result = buffer.append(markdown)

    #expect(result.completeModules.count == 2)
    #expect(result.completeModules[0].contains("let second = 2"))
    #expect(result.completeModules[0].contains("```swift"))
    #expect(result.completeModules[1] == "Closing paragraph is outside the code block.")
    #expect(result.pendingText.isEmpty)
}

@available(iOS 15.0, *)
@Test func rendererPreparesReusableContentWithEstimatedHeight() async throws {
    let renderer = MarkdownRenderer(configuration: .default, containerWidth: 320)
    let prepared = renderer.prepare("""
    # Title

    This is a paragraph with **strong** text.

    - First
    - Second
    """)

    #expect(prepared.elements.isEmpty == false)
    #expect(prepared.estimatedTotalHeight > 0)
    #expect(prepared.preparedWidth == 320)
}

@available(iOS 15.0, *)
@MainActor
@Test func repeatedLayoutAtSameWidthDoesNotRequestAnotherHeightMeasurement() async throws {
    let view = MarkdownViewTextKit()

    #expect(view.consumeLayoutWidthChange(320))
    #expect(view.consumeLayoutWidthChange(320) == false)
    #expect(view.consumeLayoutWidthChange(320.2) == false)
    #expect(view.consumeLayoutWidthChange(321))
}

@available(iOS 15.0, *)
@MainActor
@Test func repeatedTextLayoutAtSameSizeDoesNotInvalidateDisplayAgain() async throws {
    let textView = MarkdownTextViewTK2()

    #expect(textView.consumeDisplayBoundsChange(CGSize(width: 320, height: 44)))
    #expect(textView.consumeDisplayBoundsChange(CGSize(width: 320, height: 44)) == false)
    #expect(textView.consumeDisplayBoundsChange(CGSize(width: 320.2, height: 44.2)) == false)
    #expect(textView.consumeDisplayBoundsChange(CGSize(width: 320, height: 60)))
}

@available(iOS 15.0, *)
@MainActor
@Test func atomicQuoteDoesNotEnqueueEachNestedTextView() async throws {
    let markdownView = MarkdownViewTextKit()
    let quote = markdownView.createQuoteView(children: [], width: 320)
    let nestedText = MarkdownTextViewTK2()
    nestedText.attributedText = NSAttributedString(string: "quoted text")
    quote.addSubview(nestedText)

    #expect(quote.accessibilityIdentifier == "MarkdownAtomicQuote")

    let engine = TypewriterEngine()
    engine.enqueue(view: quote)

    #expect(engine.outstandingTaskCount == 1)
    #expect(nestedText.displayedAttributedString.string == "quoted text")
}

@available(iOS 15.0, *)
@MainActor
@Test func tableLayoutReusesAttributesWhileGeometryIsUnchanged() async throws {
    let layout = MarkdownTableLayout()
    layout.columnWidths = [100, 120]
    layout.rowHeights = [44, 60]

    layout.prepare()
    layout.prepare()

    #expect(layout.layoutRebuildCount == 1)
    #expect(layout.collectionViewContentSize == CGSize(width: 220, height: 104))

    layout.rowHeights = [44, 80]
    layout.prepare()
    #expect(layout.layoutRebuildCount == 2)
    #expect(layout.collectionViewContentSize == CGSize(width: 220, height: 124))
}

@available(iOS 15.0, *)
@MainActor
@Test func smartStreamingPreservesOrderWithoutDuplicateViews() async throws {
    let view = MarkdownViewTextKit(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
    view.enableTypewriterEffect = false
    view.beginRealStreaming()

    let blocks = [
        "# 目录\n\n1. [第一章](#第一章)\n2. [第二章](#第二章)\n",
        "## 第一章\n\n第一章正文。\n",
        "## 第二章\n\n第二章正文。\n",
    ]
    for block in blocks {
        view.appendStreamData(block)
    }

    await withCheckedContinuation { continuation in
        view.endRealStreaming {
            continuation.resume()
        }
    }

    let headingTitles = view.tableOfContents.map(\.title)
    let headingIDs = view.tableOfContents.map(\.id)
    let viewTags = view.contentStackView.arrangedSubviews.map(\.tag)
    #expect(headingTitles.contains("目录"))
    #expect(headingTitles.contains("第一章"))
    #expect(headingTitles.contains("第二章"))
    #expect(Set(headingIDs).count == headingIDs.count)
    #expect(view.headingViews.count == headingIDs.count)
    #expect(view.tocSectionId == headingIDs.first)
    #expect(view.tocSectionView === view.headingViews[headingIDs[0]])
    #expect(view.oldElements.count == view.contentStackView.arrangedSubviews.count)
    #expect(Set(viewTags).count == viewTags.count)
    for block in blocks {
        #expect(view.markdown.contains(block.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    view.beginRealStreaming()
    view.appendStreamData("# 新目录\n\n新内容。\n")
    await withCheckedContinuation { continuation in
        view.endRealStreaming { continuation.resume() }
    }
    #expect(view.tableOfContents.map(\.title) == ["新目录"])
    #expect(view.imageAttachments.isEmpty)
}

@available(iOS 15.0, *)
@MainActor
@Test func appendTypewriterSeparatesCharacterRevealFromHeightChanges() async throws {
    let textView = MarkdownTextViewTK2()
    textView.typewriterTextMode = .append
    textView.typewriterHeightUpdateInterval = 20
    textView.attributedText = NSAttributedString(
        string: String(repeating: "a", count: 40),
        attributes: [.font: UIFont.systemFont(ofSize: 16)]
    )
    textView.textContainer.size = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
    textView.setFixedHeight(1)
    textView.prepareForTypewriter()

    let firstCharacter = textView.revealCharacter(upto: 1)
    #expect(firstCharacter.didReveal)
    #expect(firstCharacter.didChangeHeight == false)

    let firstMeasurement = textView.revealCharacter(upto: 20)
    #expect(firstMeasurement.didReveal)
    #expect(firstMeasurement.didChangeHeight)
    #expect(firstMeasurement.heightDelta > 0)

    let sameLineCharacter = textView.revealCharacter(upto: 21)
    #expect(sameLineCharacter.didReveal)
    #expect(sameLineCharacter.didChangeHeight == false)

    let completion = textView.revealCharacter(upto: 40)
    #expect(completion.didReveal)
    let completedHeight = textView.intrinsicContentSize.height
    textView.applyLayout(width: 1_000, force: true)
    #expect(textView.intrinsicContentSize.height == completedHeight)

    textView.finishAppendTypewriterPlayback()
    textView.applyLayout(width: 1_000, force: true)
    #expect(textView.intrinsicContentSize.height < completedHeight)
}

@available(iOS 15.0, *)
@MainActor
@Test func appendTypewriterDoesNotExposePrecalculatedFinalHeightBeforeTyping() async throws {
    let textView = MarkdownTextViewTK2()
    textView.typewriterTextMode = .append
    textView.attributedText = NSAttributedString(
        string: String(repeating: "precalculated content ", count: 8),
        attributes: [.font: UIFont.systemFont(ofSize: 16)]
    )
    textView.textContainer.size = CGSize(width: 220, height: CGFloat.greatestFiniteMagnitude)
    textView.setFixedHeight(180)

    textView.prepareForTypewriter()

    #expect(textView.intrinsicContentSize.height == 1)
}

@available(iOS 15.0, *)
@MainActor
@Test func stoppingTypewriterReleasesHeightFloorsForCurrentAndQueuedText() async throws {
    func makeTextView(_ text: String) -> MarkdownTextViewTK2 {
        let textView = MarkdownTextViewTK2()
        textView.typewriterTextMode = .append
        textView.attributedText = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 16)]
        )
        textView.textContainer.size = CGSize(width: 80, height: CGFloat.greatestFiniteMagnitude)
        textView.setFixedHeight(160)
        return textView
    }

    let currentText = makeTextView(String(repeating: "current text ", count: 12))
    let queuedText = makeTextView(String(repeating: "queued text ", count: 12))
    let engine = TypewriterEngine()
    engine.enqueue(view: currentText)
    engine.enqueue(view: queuedText)
    engine.start()
    engine.stop()

    currentText.applyLayout(width: 1_000, force: true)
    queuedText.applyLayout(width: 1_000, force: true)

    #expect(currentText.intrinsicContentSize.height < 160)
    #expect(queuedText.intrinsicContentSize.height < 160)
    #expect(engine.isIdle)
    #expect(engine.isViewInQueue(currentText) == false)
    #expect(engine.isViewInQueue(queuedText) == false)
}

@available(iOS 15.0, *)
@MainActor
@Test func revealTypewriterRestoresOriginalAttributesRunByRun() async throws {
    let url = try #require(URL(string: "https://example.com"))
    let text = NSMutableAttributedString(
        string: "plain",
        attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.label]
    )
    text.append(NSAttributedString(
        string: "link",
        attributes: [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.systemBlue,
            .link: url
        ]
    ))

    let textView = MarkdownTextViewTK2()
    textView.typewriterTextMode = .reveal
    textView.attributedText = text
    textView.textContainer.size = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
    textView.prepareForTypewriter()

    // prepare 后整篇透明占位，且 .link 被移除（否则系统会强制渲染链接色，文字藏不住）
    let prepared = textView.displayedAttributedString
    #expect(prepared.length == text.length)
    for index in 0..<prepared.length {
        #expect(prepared.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor == UIColor.clear)
        #expect(prepared.attribute(.link, at: index, effectiveRange: nil) == nil)
    }

    let heightAfterPrepare = textView.intrinsicContentSize.height

    // 揭示范围跨越两个属性 run，两个 run 的原始属性都要按 run 还原
    let revealed = textView.revealCharacter(upto: 7)
    #expect(revealed.didReveal)
    #expect(revealed.didChangeHeight == false)
    #expect(textView.intrinsicContentSize.height == heightAfterPrepare)

    let afterReveal = textView.displayedAttributedString
    #expect(afterReveal.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == UIColor.label)
    #expect(afterReveal.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? UIColor == UIColor.systemBlue)
    #expect(afterReveal.attribute(.link, at: 6, effectiveRange: nil) as? URL == url)

    // 未揭示部分仍是透明占位
    #expect(afterReveal.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? UIColor == UIColor.clear)
    #expect(afterReveal.attribute(.link, at: 8, effectiveRange: nil) == nil)

    #expect(textView.revealCharacter(upto: 7).didReveal == false)
    #expect(textView.revealCharacter(upto: text.length + 1).didReveal == false)
}

@available(iOS 15.0, *)
@MainActor
@Test func streamingHeightAccumulatorAddsRootsAndTextDeltasWithoutDoubleCounting() async throws {
    var accumulator = StreamingHeightAccumulator()
    accumulator.reset(verticalMargins: 12)

    let firstRoot = UIView()
    let secondRoot = UIView()

    #expect(accumulator.rootBecameVisible(firstRoot, measuredHeight: 20, spacing: 8) == 32)
    #expect(accumulator.rootBecameVisible(firstRoot, measuredHeight: 20, spacing: 8) == 32)
    #expect(accumulator.rootBecameVisible(secondRoot, measuredHeight: 30, spacing: 8) == 70)
    #expect(accumulator.textHeightChanged(delta: 18) == 88)
    #expect(accumulator.textHeightChanged(delta: 0.1) == nil)
    #expect(accumulator.totalHeight == 88)
    accumulator.synchronize(totalHeight: 120)
    #expect(accumulator.textHeightChanged(delta: 10) == 130)
}

@available(iOS 15.0, *)
@MainActor
@Test func smartStreamIncrementalHeightMatchesFinalStackFitting() async throws {
    let view = MarkdownViewTextKit(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
    view.enableTypewriterEffect = true
    view.updateTypewriterSpeed(charsPerStep: 1_000, baseDuration: 0.001, elementGapDuration: 0)
    view.layoutIfNeeded()
    view.beginRealStreaming()
    view.appendStreamData("""
    # Height Test

    A paragraph that wraps onto more than one line when rendered in a narrow container.

    - first list item
    - second list item

    > atomic quote content

    """)

    await withCheckedContinuation { continuation in
        view.endRealStreaming { continuation.resume() }
    }

    view.layoutIfNeeded()
    view.contentStackView.layoutIfNeeded()
    let finalFittingHeight = view.contentStackView.systemLayoutSizeFitting(
        CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    ).height
    #expect(
        abs(view.realStreamHeightAccumulator.totalHeight - finalFittingHeight) < 2,
        "cached=\(view.realStreamHeightAccumulator.totalHeight), final=\(finalFittingHeight)"
    )
}
