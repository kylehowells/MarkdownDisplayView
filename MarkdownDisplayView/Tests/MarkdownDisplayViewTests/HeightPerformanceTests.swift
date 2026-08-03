import Testing
import UIKit
@testable import MarkdownDisplayView

@available(iOS 15.0, *)
@MainActor
private func makeHeightTestView(width: CGFloat = 320, childHeight: CGFloat = 80) -> MarkdownViewTextKit {
    let view = MarkdownViewTextKit(frame: CGRect(x: 0, y: 0, width: width, height: 400))
    let child = UIView()
    child.translatesAutoresizingMaskIntoConstraints = false
    child.heightAnchor.constraint(equalToConstant: childHeight).isActive = true
    view.contentStackView.addArrangedSubview(child)
    view.layoutIfNeeded()
    return view
}

@available(iOS 15.0, *)
@MainActor
@Test func intrinsicHeightCachesRepeatedReadsAtTheSameWidth() {
    let view = makeHeightTestView()

    let first = view.intrinsicContentSize.height
    let measurementsAfterFirstRead = view.intrinsicHeightMeasurementCount
    let second = view.intrinsicContentSize.height

    #expect(first == second)
    #expect(measurementsAfterFirstRead == 1)
    #expect(view.intrinsicHeightMeasurementCount == measurementsAfterFirstRead)
}

@available(iOS 15.0, *)
@MainActor
@Test func intrinsicHeightRemeasuresAfterWidthChanges() {
    let view = makeHeightTestView()
    _ = view.intrinsicContentSize

    view.bounds.size.width = 240
    _ = view.intrinsicContentSize

    #expect(view.intrinsicHeightMeasurementCount == 2)
    #expect(view.cachedIntrinsicHeightWidth == 240)
}

@available(iOS 15.0, *)
@MainActor
@Test func subthresholdHeightChangesStillRefreshIntrinsicCache() {
    let view = MarkdownViewTextKit(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    view.isRealStreamingMode = true
    view.lastReportedHeight = 95
    var notifications: [CGFloat] = []
    view.onHeightChange = { notifications.append($0) }

    view.notifyHeightChange(knownStreamingHeight: 100)

    #expect(notifications.isEmpty)
    #expect(view.lastReportedHeight == 95)
    #expect(view.cachedIntrinsicHeight == 100)
    #expect(view.intrinsicContentSize.height == 100)
}

@available(iOS 15.0, *)
@MainActor
@Test func resetAndNewStreamingSessionInvalidateIntrinsicCache() {
    let view = MarkdownViewTextKit(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    view.cacheIntrinsicHeight(90)
    view.resetForReuse()
    #expect(view.cachedIntrinsicHeight == nil)

    view.cacheIntrinsicHeight(100)
    view.beginRealStreaming()
    #expect(view.cachedIntrinsicHeight == nil)
    view.resetForReuse()
}

@available(iOS 15.0, *)
@MainActor
@Test func realStreamingAccumulatorTakesPriorityOverIntrinsicCache() {
    let view = MarkdownViewTextKit(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    view.cacheIntrinsicHeight(40)
    view.realStreamHeightAccumulator.synchronize(totalHeight: 120)
    view.isRealStreamingMode = true

    #expect(view.intrinsicContentSize.height == 120)
}

@available(iOS 15.0, *)
@MainActor
@Test func fullHeightNotificationCachesTheFinalFittingHeight() {
    let view = makeHeightTestView(childHeight: 96)
    view.notifyHeightChange(force: true)
    let finalFittingHeight = view.contentStackView.systemLayoutSizeFitting(
        CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    ).height

    #expect(abs((view.cachedIntrinsicHeight ?? -1) - finalFittingHeight) < 0.5)
    #expect(abs(view.intrinsicContentSize.height - finalFittingHeight) < 0.5)
}

@available(iOS 15.0, *)
@MainActor
@Test func heightRequestsCoalesceForceAndDiscardOldGenerations() {
    let view = MarkdownViewTextKit(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    _ = view.consumeLayoutWidthChange(320)
    var scheduledActions: [() -> Void] = []
    view.heightNotificationClock = { 10 }
    view.heightNotificationScheduler = { _, action in scheduledActions.append(action) }

    view.scheduleHeightChangeNotification(knownStreamingHeight: 40)
    view.scheduleHeightChangeNotification(knownStreamingHeight: 41)
    view.scheduleHeightChangeNotification(force: true)
    #expect(scheduledActions.count == 1)
    #expect(view.pendingForcedHeightNotification)
    #expect(view.pendingRequiresFullHeightMeasurement)

    scheduledActions.removeFirst()()
    #expect(view.heightNotificationScheduled == false)
    #expect(view.pendingForcedHeightNotification == false)

    var notificationCount = 0
    view.onHeightChange = { _ in notificationCount += 1 }
    view.scheduleHeightChangeNotification(force: true)
    #expect(scheduledActions.count == 1)
    view.heightNotificationGeneration += 1
    view.heightNotificationScheduled = false
    scheduledActions.removeFirst()()
    #expect(notificationCount == 0)
}

@available(iOS 15.0, *)
@MainActor
@Test func realStreamingTypewriterHeightCommitsInTheCurrentFrame() {
    let view = MarkdownViewTextKit(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    view.isRealStreamingMode = true
    view.isStreaming = true
    view.realStreamHeightAccumulator.synchronize(totalHeight: 100)
    view.lastReportedHeight = 100
    var scheduledActions: [() -> Void] = []
    var reportedHeights: [CGFloat] = []
    view.heightNotificationScheduler = { _, action in scheduledActions.append(action) }
    view.onHeightChange = { reportedHeights.append($0) }

    view.handleTypewriterLayoutChange(.textHeightChanged(delta: 20))

    #expect(reportedHeights == [120])
    #expect(scheduledActions.isEmpty)
    #expect(view.heightNotificationScheduled == false)
}
