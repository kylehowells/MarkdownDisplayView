import Foundation
import Testing
@testable import MarkdownDisplayView

@Test func punctuationProfileUsesUTF16OffsetsForUnicodeText() {
    let text = "A，😀。\nB"
    let profile = TypewriterPunctuationProfile(text: text)

    #expect((text as NSString).length == 7)
    #expect(profile.extraDelay(atUTF16Offset: 0) == 0)
    #expect(profile.extraDelay(atUTF16Offset: 1) == 0.03)
    // Emoji occupies two UTF-16 code units and neither unit is punctuation.
    #expect(profile.extraDelay(atUTF16Offset: 2) == 0)
    #expect(profile.extraDelay(atUTF16Offset: 3) == 0)
    #expect(profile.extraDelay(atUTF16Offset: 4) == 0.08)
    #expect(profile.extraDelay(atUTF16Offset: 5) == 0.08)
    #expect(profile.extraDelay(atUTF16Offset: 6) == 0)
    #expect(profile.extraDelay(atUTF16Offset: -1) == 0)
    #expect(profile.extraDelay(atUTF16Offset: 7) == 0)
}

@Test func punctuationProfileClassifiesExistingPunctuationSet() {
    let text = "，,、。！？!?;；\n"
    let profile = TypewriterPunctuationProfile(text: text)

    for offset in 0..<3 {
        #expect(profile.extraDelay(atUTF16Offset: offset) == 0.03)
    }
    for offset in 3..<(text as NSString).length {
        #expect(profile.extraDelay(atUTF16Offset: offset) == 0.08)
    }
}

@Test func pendingQueuePreservesFIFOAndCanBeReusedAfterDrain() {
    var queue = TypewriterPendingQueue<Int>()
    for value in 0..<1_000 {
        queue.append(value)
    }

    #expect(queue.count == 1_000)
    for expected in 0..<1_000 {
        #expect(queue.popFirst() == expected)
    }
    #expect(queue.isEmpty)
    #expect(queue.count == 0)
    #expect(queue.popFirst() == nil)

    queue.append(42)
    #expect(queue.popFirst() == 42)
    #expect(queue.isEmpty)
}

@Test func pendingQueueUpdatesAndClearsOnlyPendingElements() {
    var queue = TypewriterPendingQueue<Int>()
    queue.append(1)
    queue.append(2)
    queue.append(3)

    #expect(queue.popFirst() == 1)
    queue.updateEach { $0 *= 10 }

    #expect(queue.contains { $0 == 10 } == false)
    #expect(queue.contains { $0 == 20 })
    #expect(queue.popFirst() == 20)
    queue.removeAll()
    #expect(queue.isEmpty)
    #expect(queue.popFirst() == nil)
}
