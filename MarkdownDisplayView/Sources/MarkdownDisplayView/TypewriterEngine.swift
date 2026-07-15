//
//  TypewriterEngine.swift
//  MarkdownDisplayView
//
//  Created by 朱继超 on 12/15/25.
//

import UIKit
import Foundation

// MARK: - Typewriter Engine

@available(iOS 15.0, *)
class TypewriterEngine {

    enum TaskType {
        case show(UIView)
        case text(MarkdownTextViewTK2)
        case label(UILabel)
        case block(UIView)
    }

    private var taskQueue: [TaskType] = []
    private var isRunning = false
    private var isPaused = false

    private var watchdogTimer: Timer?

    // 追踪当前正在执行的任务，以便超时后强制完成
    private var currentTask: TaskType?
    private var currentTaskToken: UUID?

    // 基础耗时
    // ⭐️ 优化：降低基础延迟，加快打字速度
    private var baseDuration: TimeInterval = 0.012  // 从18ms降到12ms

    // ⭐️ 优化：批量显示字符数
    private var charsPerStep: Int = 6  // 每次显示6个字符（从4增加到6）

    // ⭐️ 新增：元素间的额外延迟（块级元素结束后的等待时间）
    private var elementGapDuration: TimeInterval = 0.04  // 从120ms降到40ms

    // ⭐️ 新增：标记上一个任务是否是块级任务（用于判断是否需要添加间隔）
    private var lastTaskWasBlock: Bool = false

    var onComplete: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    /// 每次输出内容时的回调（用于震动反馈等）
    var onTypewriterStep: (() -> Void)?

    func updateSpeed(charsPerStep: Int? = nil,
                     baseDuration: TimeInterval? = nil,
                     elementGapDuration: TimeInterval? = nil) {
        if let charsPerStep {
            self.charsPerStep = max(1, charsPerStep)
        }
        if let baseDuration {
            self.baseDuration = max(0.001, baseDuration)
        }
        if let elementGapDuration {
            self.elementGapDuration = max(0, elementGapDuration)
        }
    }

    func enqueue(view: UIView, isRoot: Bool = true) {
        // 完整块只执行根视图的 show：先不占 StackView 高度，轮到它时整块插入并淡入。
        // 普通文本继续递归到 MarkdownTextViewTK2，保持逐字显示。
        let isAtomicRoot = isRoot && view.accessibilityIdentifier?.hasPrefix("MarkdownAtomic") == true
        if isRoot {
            // 🆕 根视图初始设为透明，通过 .show 任务渐显
            view.alpha = 0
            taskQueue.append(.show(view))
            print("[TYPEWRITER] 🎬 enqueue root: \(type(of: view)), subviews: \(view.subviews.count)")
        }

        if isAtomicRoot {
            return
        }

        // 1. 文本组件
        if let textView = view as? MarkdownTextViewTK2 {
            print("[TYPEWRITER] ✅ 识别到 MarkdownTextViewTK2, 字符数: \(textView.attributedText?.length ?? 0)")
            textView.prepareForTypewriter()
            taskQueue.append(.text(textView))
            return
        }

        // 2. UILabel
        if let label = view as? UILabel {
            label.alpha = 0
            taskQueue.append(.label(label))
            return
        }

        // 3. UIButton
        if view is UIButton {
            view.alpha = 0
            taskQueue.append(.block(view))
            return
        }

        // 4. StackView 递归
        if let stackView = view as? UIStackView {
            for subview in stackView.arrangedSubviews {
                enqueue(view: subview, isRoot: false)
            }
            return
        }

        // 兼容旧的非 attachment 代码块容器。
        if view.accessibilityIdentifier == "CodeBlockContainer" {
            // 1. 先添加容器显示任务（显示背景色）
            view.alpha = 0
            taskQueue.append(.show(view))
            print("[TYPEWRITER] 🎨 代码块容器: 先显示背景，再递归子视图")

            // 2. 递归处理内部的 MarkdownTextViewTK2
            for subview in view.subviews {
                enqueue(view: subview, isRoot: false)
            }
            return
        }

        // 5. 普通容器递归
        // ⭐️ 合并两个版本：使用前缀匹配（更灵活），并保留脚注容器检查
        // ⭐️ 注意：CodeBlockContainer 不再作为原子块，允许内部 MarkdownTextViewTK2 逐字显示
        let isAtomicBlock = (view is UIImageView) ||
                            (view.accessibilityIdentifier?.hasPrefix("MarkdownAtomic") == true) ||
                            (view.accessibilityIdentifier?.hasPrefix("latex_") == true) ||
                            (view.accessibilityIdentifier == "FootnoteContainer")
        if view.subviews.count > 0 && !isAtomicBlock {
            print("[TYPEWRITER] 📦 递归容器: \(type(of: view)), 子视图数: \(view.subviews.count), 子视图类型: \(view.subviews.map { type(of: $0) })")
            for subview in view.subviews {
                enqueue(view: subview, isRoot: false)
            }
            return
        }

        // 6. 原子 Block
        print("[TYPEWRITER] ⬛️ 原子块: \(type(of: view)), id: \(view.accessibilityIdentifier ?? "nil")")
        view.alpha = 0
        taskQueue.append(.block(view))
    }

    func start() {
        if !isRunning {
            runNext()
        }
    }

    func stop() {
        isPaused = true
        watchdogTimer?.invalidate()

        // TextView 在入队时已经 prepare；停止播放时必须同时清理当前任务和
        // 尚未执行的文字任务，否则它们会永久保留播放期的高度下限。
        if case .text(let textView) = currentTask {
            textView.finishAppendTypewriterPlayback()
        }
        for task in taskQueue {
            if case .text(let textView) = task {
                textView.finishAppendTypewriterPlayback()
            }
        }

        taskQueue.removeAll()
        isRunning = false
        currentTask = nil
        currentTaskToken = nil
        lastTaskWasBlock = false  // ⭐️ 重置状态
    }

    /// ⭐️ 新增：检查 TypewriterEngine 是否已完成（队列为空且不在运行）
    var isIdle: Bool {
        return taskQueue.isEmpty && !isRunning
    }

    /// ⭐️ 检查视图是否在队列中
    func isViewInQueue(_ view: UIView) -> Bool {
        for task in taskQueue {
            switch task {
            case .show(let v):
                if v === view { return true }
            case .text(let tv):
                if tv === view { return true }
            case .label(let lbl):
                if lbl === view { return true }
            case .block(let bv):
                if bv === view { return true }
            }
        }
        return false
    }

    /// ⭐️ 替换队列中的视图（替换所有匹配的任务）
    func replaceView(_ oldView: UIView, with newView: UIView) {
        var replacedCount = 0

        for i in 0..<taskQueue.count {
            switch taskQueue[i] {
            case .show(let v):
                if v === oldView {
                    newView.alpha = 0
                    taskQueue[i] = .show(newView)
                    replacedCount += 1
                    print("[TYPEWRITER] 🔄 Replaced .show task view")
                }
            case .text(let tv):
                if tv === oldView, let newTv = newView.subviews.compactMap({ $0 as? MarkdownTextViewTK2 }).first ?? (newView as? MarkdownTextViewTK2) {
                    newTv.prepareForTypewriter()
                    taskQueue[i] = .text(newTv)
                    replacedCount += 1
                    print("[TYPEWRITER] 🔄 Replaced .text task view")
                }
            case .label(let lbl):
                if lbl === oldView, let newLbl = newView as? UILabel {
                    taskQueue[i] = .label(newLbl)
                    replacedCount += 1
                    print("[TYPEWRITER] 🔄 Replaced .label task view")
                }
            case .block(let bv):
                if bv === oldView {
                    newView.alpha = 0
                    taskQueue[i] = .block(newView)
                    replacedCount += 1
                    print("[TYPEWRITER] 🔄 Replaced .block task view")
                }
            }
        }

        if replacedCount == 0 {
            print("[TYPEWRITER] ⚠️ View not found in queue for replacement")
        } else {
            print("[TYPEWRITER] ✅ Replaced \(replacedCount) tasks for view")
        }
    }

    private func feedWatchdog() {
        watchdogTimer?.invalidate()
        // ⚡️ 延长看门狗时间到 4.0 秒，防止复杂渲染（如LaTeX）卡顿导致提前结束
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            print("🐶 [Watchdog] Task timed out, forcing completion...")
            self?.forceFinishCurrentTask()
        }
    }

    /// 超时强制完成当前任务
    private func forceFinishCurrentTask() {
        guard let task = currentTask else {
            finishCurrentTask()
            return
        }

        switch task {
        case .text(let textView):
            if let len = textView.attributedText?.length {
                if textView.revealCharacter(upto: len).didChangeHeight {
                    onLayoutChange?()
                }
            }
        case .block(let view):
            view.layer.removeAllAnimations()
            view.alpha = 1.0
        case .label(let label):
            label.layer.removeAllAnimations()
            label.alpha = 1.0
        case .show(let view):
            view.layer.removeAllAnimations()
            view.isHidden = false
            view.alpha = 1.0
            onLayoutChange?() // 强制完成时也要通知
        }

        finishCurrentTask()
    }

    private func runNext() {
        watchdogTimer?.invalidate()

        guard !isRunning, !taskQueue.isEmpty else {
            if taskQueue.isEmpty {
                currentTask = nil
                onComplete?()
            }
            return
        }

        isRunning = true
        isPaused = false

        let task = taskQueue.removeFirst()
        currentTask = task

        let token = UUID()
        currentTaskToken = token

        feedWatchdog()

        switch task {
        case .show(let view):
            // 🆕 渐显根视图，解决闪烁和突兀感
            view.isHidden = false
            view.alpha = 0

            // ⭐️ 添加日志：追踪视图显示时机
            let viewType = view.accessibilityIdentifier ?? String(describing: type(of: view))
            print("[STREAM] 👁️ 视图开始显示: \(viewType), tag=\(view.tag)")

            // [CODEBLOCK_DEBUG] 特殊日志：追踪代码块显示
            if view.accessibilityIdentifier == "CodeBlockContainer" {
                print("[CODEBLOCK_DEBUG] 🎬 CodeBlock .show task executing: frame=\(view.frame), subviews=\(view.subviews.count)")
            }

            // ⚡️ 关键修复：视图显示后立即通知高度变化
            onLayoutChange?()

            // 注意：.show 是容器/根视图渐显，不触发震动反馈

            let showStartTime = CFAbsoluteTimeGetCurrent()
            UIView.animate(withDuration: 0.15, animations: {
                view.alpha = 1.0
            }) { _ in
                print("[STREAM] 👁️ 视图显示完成: \(viewType), 动画耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - showStartTime) * 1000))ms")
                self.finishCurrentTask()
            }

        case .block(let view):
            // ⭐️ 添加日志：追踪块级视图显示时机
            let blockViewType = view.accessibilityIdentifier ?? String(describing: type(of: view))
            let now = CFAbsoluteTimeGetCurrent()

            // [CODEBLOCK_DEBUG] 特殊日志：追踪代码块显示
            if view.accessibilityIdentifier == "CodeBlockContainer" {
                print("[CODEBLOCK_DEBUG] 🎬 CodeBlock .block task executing: alpha=\(view.alpha), isHidden=\(view.isHidden), frame=\(view.frame)")
            }

            // 解析时间戳
            // 格式: LatexContainer_<streamStartTime>_<createTime> 或 DetailsContainer_<streamStartTime>_<createTime>
            var delayInfo: String = ""
            if let identifier = view.accessibilityIdentifier {
                let isLatex = identifier.hasPrefix("LatexContainer_")
                let isDetails = identifier.hasPrefix("DetailsContainer_")

                if isLatex || isDetails {
                    let parts = identifier.split(separator: "_")
                    if parts.count >= 3,
                       let streamStart = Double(parts[1]),
                       let createTime = Double(parts[2]),
                       streamStart > 0 {  // 确保是流式模式
                        let totalDelay = (now - streamStart) * 1000  // 从流式开始到显示
                        let queueDelay = (now - createTime) * 1000   // 从创建到显示（排队时间）

                        let label = isLatex ? "【公式上屏】" : "【Details上屏】"
                        delayInfo = "\n    ⏱️ \(label) 从流式开始: \(String(format: "%.1f", totalDelay))ms, 排队等待: \(String(format: "%.1f", queueDelay))ms"
                    }
                }
            }

            print("[STREAM] 📦 块视图开始显示: \(blockViewType), tag=\(view.tag)\(delayInfo)")
            let blockStartTime = now

            UIView.animate(withDuration: 0.2, animations: {
                view.alpha = 1.0
            }, completion: { [weak self] _ in
                print("[STREAM] 📦 块视图显示完成: \(blockViewType), 动画耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - blockStartTime) * 1000))ms")
                // 块级元素动画完成时触发震动反馈
                self?.onTypewriterStep?()
                self?.finishCurrentTask()
            })

        case .label(let label):
            // 注意：.label 是小元素，不触发震动反馈
            UIView.animate(withDuration: 0.1, animations: {
                label.alpha = 1.0
            }, completion: { _ in
                self.finishCurrentTask()
            })

        case .text(let textView):
            let textLen = textView.attributedText?.length ?? 0
            let textPreview = textView.attributedText?.string.prefix(30) ?? ""
            print("[TYPEWRITER] 📝 开始执行 .text 任务, 文本长度: \(textLen), 内容: \(textPreview)...")
            if textLen == 0 {
                _ = textView.revealCharacter(upto: 0)
                finishCurrentTask()
            } else {
                typeNextCharacter(textView, currentIndex: 0, token: token)
            }
        }
    }

    private func typeNextCharacter(_ textView: MarkdownTextViewTK2, currentIndex: Int, token: UUID) {
        guard token == self.currentTaskToken else { return }
        guard !isPaused else { return }

        feedWatchdog()

        guard let totalLen = textView.attributedText?.length else {
            finishCurrentTask()
            return
        }

        if currentIndex >= totalLen {
            if textView.revealCharacter(upto: totalLen).didChangeHeight {
                onLayoutChange?()
            }
            finishCurrentTask()
            return
        }

        // ⭐️ 优化：批量显示字符（每次显示 charsPerStep 个）
        let nextIndex = min(currentIndex + charsPerStep, totalLen)
        let revealResult = textView.revealCharacter(upto: nextIndex)
        if revealResult.didReveal {
            if revealResult.didChangeHeight {
                onLayoutChange?()
            }
            // 只在有实际内容显示时触发震动反馈
            onTypewriterStep?()
        }

        let delay = calculateDelay(at: currentIndex, text: textView.attributedText?.string ?? "")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.typeNextCharacter(textView, currentIndex: nextIndex, token: token)
        }
    }

    private func finishCurrentTask() {
        watchdogTimer?.invalidate()

        // ⭐️ 记录当前任务类型，用于判断是否需要添加间隔
        let isBlockTask: Bool
        if let task = currentTask {
            switch task {
            case .block, .show:
                isBlockTask = true
            case .text, .label:
                isBlockTask = false
            }
        } else {
            isBlockTask = false
        }
        lastTaskWasBlock = isBlockTask

        if Thread.isMainThread {
            self._finish()
        } else {
            DispatchQueue.main.async { self._finish() }
        }
    }

    private func _finish() {
        // 正常完成、空文本和 watchdog 强制完成最终都会汇聚到主线程的这里。
        // 此时最后一次字符测高已经结束，可以解除播放期的单调高度保护。
        if case .text(let textView) = currentTask {
            textView.finishAppendTypewriterPlayback()
        }

        isRunning = false
        // ⭐️ 优化：如果上一个任务是块级任务，添加额外延迟，让元素之间有明显间隔
        if lastTaskWasBlock && !taskQueue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + elementGapDuration) { [weak self] in
                self?.runNext()
            }
        } else {
            runNext()
        }
    }

    private func calculateDelay(at index: Int, text: String) -> TimeInterval {
        var delay = baseDuration
        // 使用 limitedBy 安全获取索引，防止 Unicode 字符边界导致崩溃
        if index >= 0,
           index < text.count,
           let charIndex = text.index(text.startIndex, offsetBy: index, limitedBy: text.endIndex) {
            let char = text[charIndex]
            if "，,、".contains(char) { delay += 0.03 }
            else if "。！？!?;；\n".contains(char) { delay += 0.08 }
        }
        return delay + Double.random(in: 0...0.005)
    }
}
