import Foundation
import Testing
@testable import MarkdownDisplayView

@available(iOS 15.0, *)
@MainActor
@Test func atomicRangesPreserveExistingUTF16AndOverlapBehavior() {
    let markdown = "😀 before $$x\ny$$ and $z$ ![alt](image.png) [link](https://example.com)"
    let markdownView = MarkdownViewTextKit()

    let ranges = markdownView.calculateAtomicRanges(in: markdown)
    let nsMarkdown = markdown as NSString
    let matchedStrings = ranges.map { nsMarkdown.substring(with: $0) }

    #expect(ranges == ranges.sorted { $0.location < $1.location })
    // Preserve the exact legacy overlap behavior. In particular, the inline-math
    // regex sees the closing `$` of the block and the opening `$` of `$z$` as
    // one range. Correcting that parser behavior is outside this cache-only pass.
    #expect(matchedStrings == [
        "$$x\ny$$",
        "$ and $",
        "![alt](image.png)",
        "[alt](image.png)",
        "[link](https://example.com)",
    ])

    let blockMathRange = nsMarkdown.range(of: "$$x\ny$$")
    #expect(ranges.contains(blockMathRange))
    // Emoji occupies two UTF-16 code units; lock the existing NSRange coordinate space.
    #expect(blockMathRange.location == 10)

    // Repeated calls must remain deterministic when regex instances become shared.
    #expect(markdownView.calculateAtomicRanges(in: markdown) == ranges)
}
