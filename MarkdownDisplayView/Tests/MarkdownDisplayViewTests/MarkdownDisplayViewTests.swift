import Testing
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
