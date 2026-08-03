import Foundation
import Testing
import UIKit
@testable import MarkdownDisplayView

@Test func frameScheduleCatchesUpMultipleStepsWithOneTarget() {
    var schedule = TypewriterFrameSchedule(totalUTF16Length: 100)
    let first = schedule.start(charsPerStep: 6) { _ in 0.01 }
    let frame = schedule.advance(elapsed: 1.0 / 30.0, charsPerStep: 6) { _ in 0.01 }

    #expect(first.targetUTF16Offset == 6)
    #expect(frame.logicalStepCount == 3)
    #expect(frame.targetUTF16Offset == 24)
    #expect(schedule.revealedUTF16Offset == 24)
}

@Test func frameScheduleSamplesDelayOncePerLogicalStepAndPreservesPunctuation() {
    let text = "A，BC"
    let profile = TypewriterPunctuationProfile(text: text)
    var sampledOffsets: [Int] = []
    var jitterSamples = 0
    var schedule = TypewriterFrameSchedule(totalUTF16Length: (text as NSString).length)
    let delay: (Int) -> TimeInterval = { offset in
        sampledOffsets.append(offset)
        jitterSamples += 1
        return 0.01 + profile.extraDelay(atUTF16Offset: offset) + 0.002
    }

    _ = schedule.start(charsPerStep: 1, delay: delay)
    let beforeCommaPause = schedule.advance(elapsed: 0.013, charsPerStep: 1, delay: delay)
    let duringCommaPause = schedule.advance(elapsed: 0.02, charsPerStep: 1, delay: delay)
    let afterCommaPause = schedule.advance(elapsed: 0.03, charsPerStep: 1, delay: delay)

    #expect(beforeCommaPause.targetUTF16Offset == 2)
    #expect(duringCommaPause.targetUTF16Offset == nil)
    #expect(afterCommaPause.targetUTF16Offset == 3)
    #expect(sampledOffsets == [0, 1, 2])
    #expect(jitterSamples == 3)
}

@Test func frameScheduleCapsTargetsAtUTF16LengthAndFinishesAfterFinalDelay() {
    let text = "A😀B"
    let totalLength = (text as NSString).length
    var schedule = TypewriterFrameSchedule(totalUTF16Length: totalLength)

    let first = schedule.start(charsPerStep: 3) { _ in 0.01 }
    let finalReveal = schedule.advance(elapsed: 0.01, charsPerStep: 3) { _ in 0.01 }
    let completion = schedule.advance(elapsed: 0.01, charsPerStep: 3) { _ in 0.01 }

    #expect(totalLength == 4)
    #expect(first.targetUTF16Offset == 3)
    #expect(finalReveal.targetUTF16Offset == 4)
    #expect(finalReveal.completed == false)
    #expect(completion.completed)
    #expect(schedule.revealedUTF16Offset == totalLength)
}

@Test func resettingTimingDropsOldElapsedAndUsesNewStepSize() {
    var schedule = TypewriterFrameSchedule(totalUTF16Length: 20)
    _ = schedule.start(charsPerStep: 2) { _ in 1.0 }
    #expect(schedule.advance(elapsed: 0.9, charsPerStep: 2) { _ in 1.0 }.targetUTF16Offset == nil)

    schedule.resetTiming { _ in 0.1 }
    #expect(schedule.advance(elapsed: 0.09, charsPerStep: 4) { _ in 0.1 }.targetUTF16Offset == nil)
    #expect(schedule.advance(elapsed: 0.02, charsPerStep: 4) { _ in 0.1 }.targetUTF16Offset == 6)
}

@available(iOS 15.0, *)
@MainActor
@Test func typewriterDisplayLinkStopsAndCompletesWithoutDuplicateCallbacks() {
    let textView = MarkdownTextViewTK2()
    textView.typewriterTextMode = .append
    textView.attributedText = NSAttributedString(string: "abcdef")
    let engine = TypewriterEngine()
    engine.updateSpeed(charsPerStep: 2, baseDuration: 0.001, elementGapDuration: 0)
    var stepCount = 0
    var completionCount = 0
    engine.onTypewriterStep = { stepCount += 1 }
    engine.onComplete = { completionCount += 1 }

    engine.enqueue(view: textView, isRoot: false)
    engine.start()
    #expect(engine.hasActiveTextDisplayLink)
    #expect(textView.displayedAttributedString.length == 2)

    engine.advanceTextFrame(by: 1)
    #expect(textView.displayedAttributedString.string == "abcdef")
    #expect(engine.hasActiveTextDisplayLink == false)
    #expect(engine.isIdle)
    #expect(stepCount == 2) // immediate batch + one coalesced catch-up frame
    #expect(completionCount == 1)
    #expect(engine.outstandingTaskCount == 0)

    engine.advanceTextFrame(by: 1)
    #expect(stepCount == 2)
    #expect(completionCount == 1)
}

@available(iOS 15.0, *)
@MainActor
@Test func stopAndWatchdogInvalidateActiveTextDisplayLinks() {
    func makeEngine() -> (TypewriterEngine, MarkdownTextViewTK2) {
        let textView = MarkdownTextViewTK2()
        textView.attributedText = NSAttributedString(string: String(repeating: "text", count: 20))
        let engine = TypewriterEngine()
        engine.updateSpeed(charsPerStep: 1, baseDuration: 1)
        engine.enqueue(view: textView, isRoot: false)
        engine.start()
        return (engine, textView)
    }

    let (stoppedEngine, _) = makeEngine()
    stoppedEngine.stop()
    #expect(stoppedEngine.hasActiveTextDisplayLink == false)
    #expect(stoppedEngine.outstandingTaskCount == 0)

    let (watchdogEngine, watchdogText) = makeEngine()
    watchdogEngine.forceFinishCurrentTask()
    #expect(watchdogEngine.hasActiveTextDisplayLink == false)
    #expect(watchdogEngine.isIdle)
    #expect(watchdogText.displayedAttributedString.length == watchdogText.attributedText?.length)
}

@available(iOS 15.0, *)
@MainActor
@Test func consecutiveTextTasksCreateFreshDisplayLinkTimelines() {
    func makeText(_ value: String) -> MarkdownTextViewTK2 {
        let textView = MarkdownTextViewTK2()
        textView.typewriterTextMode = .append
        textView.attributedText = NSAttributedString(string: value)
        return textView
    }

    let first = makeText("first")
    let second = makeText("second")
    let engine = TypewriterEngine()
    engine.updateSpeed(charsPerStep: 1, baseDuration: 0.001, elementGapDuration: 0)
    var completionCount = 0
    engine.onComplete = { completionCount += 1 }
    engine.enqueue(view: first, isRoot: false)
    engine.enqueue(view: second, isRoot: false)

    engine.start()
    engine.advanceTextFrame(by: 1)
    #expect(first.displayedAttributedString.string == "first")
    #expect(second.displayedAttributedString.length == 1)
    #expect(engine.hasActiveTextDisplayLink)
    #expect(engine.outstandingTaskCount == 1)

    engine.advanceTextFrame(by: 1)
    #expect(second.displayedAttributedString.string == "second")
    #expect(engine.isIdle)
    #expect(completionCount == 1)
}

@available(iOS 15.0, *)
@MainActor
@Test func blockGapKeepsDisplayLinkStoppedUntilNextTextTaskStarts() {
    let block = UIButton(type: .system)
    let textView = MarkdownTextViewTK2()
    textView.typewriterTextMode = .append
    textView.attributedText = NSAttributedString(string: "after block")
    let engine = TypewriterEngine()
    var gapActions: [() -> Void] = []
    engine.taskGapScheduler = { _, action in gapActions.append(action) }
    engine.enqueue(view: block, isRoot: false)
    engine.enqueue(view: textView, isRoot: false)

    engine.start()
    engine.forceFinishCurrentTask()
    #expect(gapActions.count == 1)
    #expect(engine.hasActiveTextDisplayLink == false)
    #expect(textView.displayedAttributedString.length == 0)

    gapActions.removeFirst()()
    #expect(engine.hasActiveTextDisplayLink)
    #expect(textView.displayedAttributedString.length > 0)
    engine.stop()
}

@Test func verboseLoggingRequiresExplicitFlagAndPerformanceOnlyWins() {
    #expect(MarkdownLogConfiguration.verboseEnabled(environment: [:]) == false)
    #expect(MarkdownLogConfiguration.verboseEnabled(environment: ["MD_VERBOSE_LOG": "1"]))
    #expect(MarkdownLogConfiguration.verboseEnabled(environment: ["MD_VERBOSE_LOG": "true"]) == false)
    #expect(MarkdownLogConfiguration.verboseEnabled(environment: ["MD_STREAM_PERF_ONLY": "1"]) == false)
    #expect(MarkdownLogConfiguration.verboseEnabled(environment: [
        "MD_VERBOSE_LOG": "1",
        "MD_STREAM_PERF_ONLY": "1",
    ]) == false)
}
