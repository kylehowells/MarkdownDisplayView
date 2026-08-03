import Testing
import UIKit
@testable import MarkdownDisplayView

// MARK: - Chunking Helpers

/// 把文本切成固定长度的片段（按 Character，模拟不同的网络分包大小）
private func fixedChunks(_ text: String, size: Int) -> [String] {
    var chunks: [String] = []
    var current = ""
    for character in text {
        current.append(character)
        if current.count == size {
            chunks.append(current)
            current = ""
        }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
}

/// 用固定种子的线性同余伪随机切分，长度在 1...maxSize 之间。
/// 固定种子保证失败可复现。
private func pseudoRandomChunks(_ text: String, seed: UInt64, maxSize: Int) -> [String] {
    var state = seed
    func next(_ upperBound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(upperBound))
    }

    var chunks: [String] = []
    var current = ""
    var target = next(maxSize) + 1
    for character in text {
        current.append(character)
        if current.count >= target {
            chunks.append(current)
            current = ""
            target = next(maxSize) + 1
        }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
}

// MARK: - Buffer Drivers

/// 把切片依次喂给缓存器，收集"已提交模块 + flush 剩余"。
///
/// 这个序列必须与切分方式无关：真流式下 chunk 边界由网络决定，
/// 同一篇内容不能因为切在不同位置就渲染出不同结果。
@available(iOS 15.0, *)
private func streamedModules(_ chunks: [String], minModuleLength: Int = 10) -> [String] {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: minModuleLength)
    var modules: [String] = []
    for chunk in chunks {
        modules.append(contentsOf: buffer.append(chunk).completeModules)
    }
    let remaining = buffer.flush().trimmingCharacters(in: .whitespacesAndNewlines)
    if !remaining.isEmpty { modules.append(remaining) }
    return modules
}

/// 收集流式过程中出现过的未完成结构类型（去掉连续重复，只看出现顺序）
@available(iOS 15.0, *)
private func pendingTypeSequence(_ chunks: [String], minModuleLength: Int = 10) -> [PendingStructureType] {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: minModuleLength)
    var types: [PendingStructureType] = []
    for chunk in chunks {
        guard let type = buffer.append(chunk).pendingType else { continue }
        if types.last != type { types.append(type) }
    }
    return types
}

private final class StreamBufferEChartsParser: MarkdownCustomParser {
    let identifier = "echarts"
    let pattern = #"(?i)<echarts(?:\s+[^>]*)?>([\s\S]*?)</echarts\s*>"#
    let streamingBlockTagName: String? = "echarts"

    func parse(match: NSTextCheckingResult, in text: String) -> CustomElementData? {
        CustomElementData(type: identifier, rawText: (text as NSString).substring(with: match.range))
    }
}

private final class StreamBufferVideoParser: MarkdownCustomParser {
    let identifier = "video"
    let pattern = #"\[video:([^\]]+)\]"#

    func parse(match: NSTextCheckingResult, in text: String) -> CustomElementData? {
        CustomElementData(type: identifier, rawText: (text as NSString).substring(with: match.range))
    }
}

// MARK: - Samples

private let multiHeadingSample = """
# Alpha

Alpha body text is long enough.

# Beta

Beta body text is long enough.

"""

private let nestedHeadingSample = """
# Title

## One

Section one body text.

## Two

Section two body text.

"""

private let codeBlockSample = """
# Code

```swift
let a = 1

let b = 2
```

Tail paragraph after code.

"""

private let tableSample = """
# Table

| a | b |
| - | - |
| 1 | 2 |

Tail paragraph after table.

"""

private let latexSample = """
# Math

$$
x^2 + y^2 = z^2
$$

Tail paragraph after math.

"""

private let plainTextSample = """
First plain paragraph is long enough.

Second plain paragraph is long enough.

"""

private let allSamples: [(name: String, text: String)] = [
    ("multiHeading", multiHeadingSample),
    ("nestedHeading", nestedHeadingSample),
    ("codeBlock", codeBlockSample),
    ("table", tableSample),
    ("latex", latexSample),
    ("plainText", plainTextSample)
]

// MARK: - Chunk Invariance

@available(iOS 15.0, *)
@Test func charByCharAppendMatchesSingleShotAppend() async throws {
    for sample in allSamples {
        let expected = streamedModules([sample.text])
        let actual = streamedModules(sample.text.map(String.init))
        #expect(actual == expected, "sample \(sample.name) 逐字符切分结果与整篇一致性被破坏")
    }
}

@available(iOS 15.0, *)
@Test func fixedSizeChunkAppendMatchesSingleShotAppend() async throws {
    for sample in allSamples {
        let expected = streamedModules([sample.text])
        for size in [2, 3, 5, 7, 13] {
            let actual = streamedModules(fixedChunks(sample.text, size: size))
            #expect(actual == expected, "sample \(sample.name) 按 \(size) 字符切分结果不一致")
        }
    }
}

@available(iOS 15.0, *)
@Test func randomChunkSizeAppendMatchesSingleShotAppend() async throws {
    for sample in allSamples {
        let expected = streamedModules([sample.text])
        for seed in UInt64(1)...UInt64(8) {
            let chunks = pseudoRandomChunks(sample.text, seed: seed, maxSize: 7)
            let actual = streamedModules(chunks)
            #expect(actual == expected, "sample \(sample.name) seed=\(seed) 随机切分结果不一致")
        }
    }
}

// MARK: - Golden Snapshots

@available(iOS 15.0, *)
@Test func streamedModuleSnapshotsAreStable() async throws {
    #expect(streamedModules(multiHeadingSample.map(String.init)) == [
        "# Alpha\n\nAlpha body text is long enough.",
        "# Beta\n\nBeta body text is long enough."
    ])

    #expect(streamedModules(nestedHeadingSample.map(String.init)) == [
        "# Title\n\n## One\n\nSection one body text.",
        "## Two\n\nSection two body text."
    ])

    #expect(streamedModules(codeBlockSample.map(String.init)) == [
        "# Code\n\n```swift\nlet a = 1\n\nlet b = 2\n```",
        "Tail paragraph after code."
    ])

    #expect(streamedModules(plainTextSample.map(String.init)) == [
        "First plain paragraph is long enough.",
        "Second plain paragraph is long enough."
    ])
}

// MARK: - Delimiters Split Across Chunk Boundaries

@available(iOS 15.0, *)
@Test func codeBlockFenceSplitAcrossChunkBoundaryIsDetectedAsPending() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)

    // 围栏被切成 "``" + "`"：第一段末尾是不完整的围栏
    let firstHalf = buffer.append("# Title\n\n``")
    #expect(firstHalf.hasPendingStructure)
    #expect(firstHalf.pendingType == .codeBlock)

    // 拼上剩下的反引号后围栏完整，但代码块本身仍未闭合
    let opened = buffer.append("`swift\nlet a = 1\n")
    #expect(opened.hasPendingStructure)
    #expect(opened.pendingType == .codeBlock)
    #expect(opened.completeModules.isEmpty)
}

@available(iOS 15.0, *)
@Test func codeBlockFenceSplitAcrossChunkBoundaryClosesCorrectly() async throws {
    let chunks = ["# Title\n\n``", "`swift\nlet a = 1\n", "``", "`\n\nTail paragraph is here.\n\n"]
    let modules = streamedModules(chunks)

    #expect(modules == [
        "# Title\n\n```swift\nlet a = 1\n```",
        "Tail paragraph is here."
    ])
}

@available(iOS 15.0, *)
@Test func latexBlockDollarSignSplitAcrossChunkBoundary() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)

    _ = buffer.append("# Math\n\n$")
    // 拼成一个 $$ 后是奇数个分隔符，公式块未闭合
    let opened = buffer.append("$\nx^2 + y^2\n")
    #expect(opened.pendingType == .latexBlock)

    let closed = buffer.append("$$\n\nTail paragraph is here.\n\n")
    #expect(closed.hasPendingStructure == false)
}

@available(iOS 15.0, *)
@Test func completedHeadingModuleIsReleasedBeforeUnclosedLatexTail() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)
    let result = buffer.append("""
    ## One

    First formula is complete.

    $$x = 1$$

    ## Two

    Second formula is still arriving.

    $$y =
    """)

    #expect(result.completeModules == [
        "## One\n\nFirst formula is complete.\n\n$$x = 1$$"
    ])
    let expectedTail = "## Two\n\nSecond formula is still arriving.\n\n$$y ="
    #expect(result.pendingType == .latexBlock)
    #expect(result.pendingText == expectedTail)
    #expect(result.hasPendingStructure)
    #expect(buffer.lastSafePosition == result.pendingText.count.distance(to: buffer.accumulatedText.count))
}

@available(iOS 15.0, *)
@Test func completedHeadingModuleIsReleasedBeforeUnclosedCodeBlockTail() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)
    let result = buffer.append("""
    ## One

    First section is complete and ready.

    ## Two

    ```swift
    let value = 1
    """)

    #expect(result.completeModules == [
        "## One\n\nFirst section is complete and ready."
    ])
    let expectedTail = "## Two\n\n```swift\nlet value = 1"
    #expect(result.pendingType == .codeBlock)
    #expect(result.pendingText == expectedTail)
    #expect(result.hasPendingStructure)
    #expect(buffer.lastSafePosition == result.pendingText.count.distance(to: buffer.accumulatedText.count))
}

@available(iOS 15.0, *)
@Test func echartsBlockDoesNotSubmitInternalJSONBeforeClosingTag() async throws {
    MarkdownCustomExtensionManager.shared.register(parser: StreamBufferEChartsParser())
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)
    let opened = buffer.append("""
    ## Chart

    <echarts>
    {
      "series": [
        { "type": "bar", "data": [1, 2, 3] }
      ]

    """)

    #expect(opened.completeModules.isEmpty)
    #expect(opened.hasPendingStructure)
    #expect(opened.pendingType == nil)

    let closed = buffer.append("}\n</echarts>\n\n## Next\n\nNext section body.\n\n")
    #expect(closed.hasPendingStructure == false)
    #expect(closed.completeModules == [
        "## Chart\n\n<echarts>\n{\n  \"series\": [\n    { \"type\": \"bar\", \"data\": [1, 2, 3] }\n  ]\n}\n</echarts>",
        "## Next\n\nNext section body."
    ])
    #expect(closed.pendingText.isEmpty)

    let renderer = MarkdownRenderer(configuration: .default, containerWidth: 320)
    let rendered = renderer.render(closed.completeModules[0]).elements
    #expect(rendered.contains { element in
        if case .custom(let data) = element { return data.type == "echarts" }
        return false
    })
}

@available(iOS 15.0, *)
@Test func echartsClosingTagSplitAcrossChunksStaysAtomic() async throws {
    MarkdownCustomExtensionManager.shared.register(parser: StreamBufferEChartsParser())
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)
    let first = buffer.append("<echarts>\n{\"series\": [{\"type\": \"bar\"}]}\n")
    let second = buffer.append("</ech")

    #expect(first.completeModules.isEmpty)
    #expect(first.hasPendingStructure)
    #expect(second.completeModules.isEmpty)
    #expect(second.hasPendingStructure)

    let final = buffer.append("arts>\n\n")
    #expect(final.completeModules == ["<echarts>\n{\"series\": [{\"type\": \"bar\"}]}\n</echarts>"])
    #expect(final.pendingText.isEmpty)
    #expect(final.hasPendingStructure == false)
}

@available(iOS 15.0, *)
@Test func echartsBlockHandlesRandomChunksAndPayloadDelimiters() async throws {
    MarkdownCustomExtensionManager.shared.register(parser: StreamBufferEChartsParser())
    let sample = "## Chart\n\n<echarts>\n{\"text\": \"$$ and ```\", \"series\": []}\n</echarts>\n\n"

    for seed in UInt64(1)...UInt64(8) {
        let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)
        var modules: [String] = []
        for chunk in pseudoRandomChunks(sample, seed: seed, maxSize: 7) {
            modules.append(contentsOf: buffer.append(chunk).completeModules)
        }
        let remaining = buffer.flush().trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty { modules.append(remaining) }
        #expect(modules == [sample.trimmingCharacters(in: .whitespacesAndNewlines)])
    }
}

@available(iOS 15.0, *)
@Test func parserIdentifierIsNotImplicitlyTreatedAsHTMLTag() async throws {
    MarkdownCustomExtensionManager.shared.register(parser: StreamBufferVideoParser())
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)
    let result = buffer.append("<video>ordinary HTML without a closing tag\n")
    #expect(result.hasPendingStructure == false)
}

@available(iOS 15.0, *)
@Test func opaqueBlocksIgnoreMarkdownDelimitersInsideTheirPayload() async throws {
    MarkdownCustomExtensionManager.shared.register(parser: StreamBufferEChartsParser())
    let echarts = "<echarts>\n{\"title\": {\"text\": \"cost $$ and ``` markers\"}}\n</echarts>\n\n"
    let chartModules = streamedModules(fixedChunks(echarts, size: 5))
    #expect(chartModules == [echarts.trimmingCharacters(in: .whitespacesAndNewlines)])

    let code = "```text\nprice is $$5\n```\n\n"
    let codeModules = streamedModules(fixedChunks(code, size: 3))
    #expect(codeModules == [code.trimmingCharacters(in: .whitespacesAndNewlines)])
}

@available(iOS 15.0, *)
@Test func ignoredDelimiterDoesNotCancelFollowingRealLatexOpener() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)
    _ = buffer.append("```text\nprice is $$5\n```\n\n")
    let result = buffer.append("## Math\n\n$$\nx = 1")
    #expect(result.hasPendingStructure)
    #expect(result.pendingType == .latexBlock)
}

@available(iOS 15.0, *)
@Test func customTagLiteralInsideCodeAndLatexDoesNotBecomePending() async throws {
    MarkdownCustomExtensionManager.shared.register(parser: StreamBufferEChartsParser())
    let code = "```html\n<echarts>\n```\n\n"
    let latex = "$$\n\\text{<echarts>}\n$$\n\n"
    #expect(streamedModules(fixedChunks(code, size: 3)) == [code.trimmingCharacters(in: .whitespacesAndNewlines)])
    #expect(streamedModules(fixedChunks(latex, size: 3)) == [latex.trimmingCharacters(in: .whitespacesAndNewlines)])
}

@available(iOS 15.0, *)
@Test func inlineOpaqueBlockPayloadDoesNotLeakLatexStateIntoFollowingHeading() async throws {
    MarkdownCustomExtensionManager.shared.register(parser: StreamBufferEChartsParser())
    let sample = "<echarts>{\"text\":\"$$\"}</echarts>\n\n## Next\n\nNext body is complete.\n\n"
    let modules = streamedModules(fixedChunks(sample, size: 7))
    #expect(modules == [
        "<echarts>{\"text\":\"$$\"}</echarts>",
        "## Next\n\nNext body is complete."
    ])
}

@available(iOS 15.0, *)
@Test func closedLatexBlockIgnoresInternalBlankLinesAndHeadingMarkers() async throws {
    let latex = "$$\na + b\n\n## not a heading\n\nc + d\n$$\n\n"
    #expect(streamedModules(fixedChunks(latex, size: 4)) == [
        latex.trimmingCharacters(in: .whitespacesAndNewlines)
    ])
}

// MARK: - Greedy Non-Overlapping Match Semantics

@available(iOS 15.0, *)
@Test func fourConsecutiveBackticksCountAsSingleFenceMatch() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)

    // 4 个反引号：贪婪不重叠匹配只消耗 3 个，剩下 1 个凑不成围栏，
    // 因此仍是"奇数个围栏"= 未闭合
    let result = buffer.append("# Title\n\n````\ncode line\n")
    #expect(result.pendingType == .codeBlock)
}

@available(iOS 15.0, *)
@Test func sixConsecutiveBackticksAreTreatedAsTwoClosedFences() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)

    // 6 个反引号 = 2 个围栏，偶数 → 已闭合
    let result = buffer.append("# Title\n\n``````\ncode line\n")
    #expect(result.hasPendingStructure == false)
}

// MARK: - Unicode Boundaries

@available(iOS 15.0, *)
@Test func appendSplitsEmojiZWJSequenceAcrossChunksWithoutMiscounting() async throws {
    let sample = """
    # Family

    Here is a family emoji 👨‍👩‍👧‍👦 inside a long enough paragraph.

    Second paragraph is also long enough.

    """

    let expected = streamedModules([sample])
    // 按 unicodeScalar 切分会把 ZWJ 序列切开，比按 Character 切更苛刻
    let scalarChunks = sample.unicodeScalars.map { String($0) }

    #expect(streamedModules(scalarChunks) == expected)
}

@available(iOS 15.0, *)
@Test func appendHandlesCombiningDiacriticalMarksSplitAcrossChunks() async throws {
    // "e" + U+0301 组成一个 grapheme，Character 偏移不能切在组合标记中间
    let sample = "# Cafe\u{0301}\n\nBody text about cafe\u{0301} is long enough.\n\nSecond body paragraph here.\n\n"

    let expected = streamedModules([sample])
    let scalarChunks = sample.unicodeScalars.map { String($0) }

    #expect(streamedModules(scalarChunks) == expected)
    #expect(expected.joined().contains("Cafe\u{0301}"))
}

// MARK: - Cross-Call State

@available(iOS 15.0, *)
@Test func incrementalAppendKeepsCodeBlockOpenAcrossMultipleBlankLinesInside() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)

    _ = buffer.append("# Code\n\n```swift\n")
    // 代码块内部的空行分多次到达，isInsideCodeBlock 不能丢
    for chunk in ["let a = 1\n", "\n", "\n", "let b = 2\n", "\n\n", "let c = 3\n"] {
        let result = buffer.append(chunk)
        #expect(result.pendingType == .codeBlock, "代码块内的空行不应结束待闭合状态")
        #expect(result.completeModules.isEmpty, "代码块内部不应切出模块")
    }

    let closed = buffer.append("```\n\nTail paragraph is here.\n\n")
    #expect(closed.hasPendingStructure == false)
}

@available(iOS 15.0, *)
@Test func committedHeadingsAreNotDoubleCountedAfterModuleSubmission() async throws {
    // 三个一级标题分批到达：已提交的标题不能继续参与后续的分割级别判断，
    // 否则模块会被重复切分或漏切
    let sample = """
    # One

    First body text is long enough.

    # Two

    Second body text is long enough.

    # Three

    Third body text is long enough.

    """

    let expected = streamedModules([sample])
    #expect(streamedModules(sample.map(String.init)) == expected)
    #expect(streamedModules(fixedChunks(sample, size: 9)) == expected)
    #expect(Set(expected).count == expected.count, "不应出现重复模块")
}

@available(iOS 15.0, *)
@Test func appendWithoutTrailingNewlineDoesNotPrematurelyCloseParagraph() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)

    // 不以换行结尾的尾段是"未完成的行"，不能当成段落结束
    let result = buffer.append("First paragraph is long enough but unfinished")
    #expect(result.completeModules.isEmpty)

    let stillOpen = buffer.append(" and still going")
    #expect(stillOpen.completeModules.isEmpty)

    let closed = buffer.append(".\n\n")
    #expect(closed.completeModules == ["First paragraph is long enough but unfinished and still going."])
}

@available(iOS 15.0, *)
@Test func resetClearsAllIncrementalScanState() async throws {
    let buffer = MarkdownStreamBuffer(containerWidth: 320, minModuleLength: 10)

    // 留下"代码块未闭合 + 已前进的安全位置"这样的脏状态
    _ = buffer.append("# Code\n\n```swift\nlet a = 1\n")
    #expect(buffer.accumulatedText.isEmpty == false)

    buffer.reset()

    #expect(buffer.accumulatedText.isEmpty)
    #expect(buffer.lastSafePosition == 0)
    #expect(buffer.committedElementCount == 0)

    // reset 后的首次 append 必须和全新实例完全一致（不带入上一轮的奇偶/代码块状态）
    var afterReset: [String] = []
    for chunk in fixedChunks(multiHeadingSample, size: 5) {
        afterReset.append(contentsOf: buffer.append(chunk).completeModules)
    }
    let remaining = buffer.flush().trimmingCharacters(in: .whitespacesAndNewlines)
    if !remaining.isEmpty { afterReset.append(remaining) }

    #expect(afterReset == streamedModules(fixedChunks(multiHeadingSample, size: 5)))
}
