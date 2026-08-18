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

    // 本用例的原意是「低于阈值时 intrinsic 缓存仍然要刷新」，这一点不变。
    //
    // 但它原本还断言 `notifications.isEmpty` —— 即 5pt 的增长不通知宿主。那正是流式
    // 闪烁的根因：intrinsic 已经按 100 走，宿主 Cell 的 UIView-Encapsulated-Layout-Height
    // 还停在 95，中间 5pt 只能靠压缩 textView（heightConstraint 仅 999）吸收，
    // 也就是把正在打字的文字裁掉。增量路径的阈值因此降到 0.5pt，这里同步更新。
    #expect(notifications == [100])
    #expect(view.lastReportedHeight == 100)
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

@available(iOS 15.0, *)
@MainActor
@Test func realStreamingReportsSubNinePointGrowthInsteadOfLettingTheCellClipIt() {
    // 流式增量路径曾经复用全量测高的 9pt 防抖阈值，但两者的宿主契约完全不同：
    // isRealStreamingMode 下 intrinsicContentSize 直接读累加器，markdownView 自身是
    // 每帧跟随内容的；宿主 Cell 的 UIView-Encapsulated-Layout-Height 却是 required。
    // 一旦这里按 9pt 拦截，差额就只能靠压缩 textView（heightConstraint 仅 999）来吸收，
    // 也就是把正在打字的文字裁掉，直到累积跨过阈值才一次性弹出——即流式闪烁。
    //
    // 因此断言：小于 9pt、但大于累加器 0.5pt 噪声门限的增长，必须逐次上报给宿主。
    let view = MarkdownViewTextKit(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
    view.isRealStreamingMode = true
    view.isStreaming = true
    view.realStreamHeightAccumulator.synchronize(totalHeight: 100)
    view.lastReportedHeight = 100

    var reportedHeights: [CGFloat] = []
    view.heightNotificationScheduler = { _, _ in
        Issue.record("增量路径不应退化到延迟调度")
    }
    view.onHeightChange = { reportedHeights.append($0) }

    // 连续三次 6pt 增长：旧实现累计到 18pt 才报一次，新实现每次都报
    view.handleTypewriterLayoutChange(.textHeightChanged(delta: 6))
    view.handleTypewriterLayoutChange(.textHeightChanged(delta: 6))
    view.handleTypewriterLayoutChange(.textHeightChanged(delta: 6))

    #expect(reportedHeights == [106, 112, 118])
    #expect(view.lastReportedHeight == 118)

    // 低于累加器噪声门限的抖动仍然被吃掉，避免把 performBatchUpdates 打爆
    view.handleTypewriterLayoutChange(.textHeightChanged(delta: 0.2))
    #expect(reportedHeights == [106, 112, 118])
}
