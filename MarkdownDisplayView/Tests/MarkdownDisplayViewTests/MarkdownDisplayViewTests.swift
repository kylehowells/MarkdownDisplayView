import Testing
import UIKit
@testable import MarkdownDisplayView

@Test func listWrapperPaddingDefaultsToZero() async throws {
    let configuration = MarkdownConfiguration.default

    #expect(configuration.listTopPadding == 0)
    #expect(configuration.listBottomPadding == 0)
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
