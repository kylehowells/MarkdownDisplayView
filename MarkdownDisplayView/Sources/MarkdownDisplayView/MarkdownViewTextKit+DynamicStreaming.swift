//
//  MarkdownViewTextKit+DynamicStreaming.swift
//  MarkdownDisplayView
//
//  Mechanical extension split from MarkdownDisplayView.swift.
//

import UIKit
import Foundation
import Combine
import NaturalLanguage

@available(iOS 15.0, *)
extension MarkdownViewTextKit {
    // MARK: - Dynamic Streaming Updates

    /// Appends new text to the streaming buffer without interrupting current rendering.
    /// - Parameter text: The new text chunk to append (e.g. from network).
    public func appendStreamingContent(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isStreaming else { return }
            self.appendStreamingState(newChunk: text)
        }
    }

    /// Updates the streaming buffer with new full text.
    /// Use this if the stream source provides the full accumulated text.
    /// - Parameter text: The new full text.
    public func updateStreamingContent(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isStreaming else { return }
            self.updateStreamingState(newFullText: text)
        }
    }

    func appendStreamingState(newChunk: String) {
        let unit = self.currentStreamingUnit
        // Capture current state to avoid threading issues
        let currentFullText = self.streamFullText
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 1. Tokenize ONLY the new chunk (Optimization)
            let newTokens = self.tokenize(newChunk, unit: unit)
            
            // 2. Update Full Text
            let newFullText = currentFullText + newChunk
            
            // 3. Recalculate Atomic Ranges (Still need full scan for correctness of nested/late-closing tags)
            // Note: This is O(N) but much faster than O(N) tokenization + String allocation
            let newAtomicRanges = self.calculateAtomicRanges(in: newFullText)
            
            DispatchQueue.main.async {
                guard self.isStreaming else { return }

                self.streamFullText = newFullText
                self.streamTokens.append(contentsOf: newTokens)
                self.streamAtomicRanges = newAtomicRanges
                // ⚡️ 同步更新原子区间起始位置索引
                self.atomicRangeStartSet = Set(newAtomicRanges.map { $0.location })

                // No need to adjust streamTokenIndex for append mode
                // as we are just adding to the end.
            }
        }
    }

    func updateStreamingState(newFullText: String) {
        let unit = self.currentStreamingUnit
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let newTokens = self.tokenize(newFullText, unit: unit)
            let newAtomicRanges = self.calculateAtomicRanges(in: newFullText)
            
            DispatchQueue.main.async {
                guard self.isStreaming else { return }

                // Determine where we are relative to the new tokens
                let currentMarkdownCount = self.markdown.count

                self.streamFullText = newFullText
                self.streamTokens = newTokens
                self.streamAtomicRanges = newAtomicRanges
                // ⚡️ 同步更新原子区间起始位置索引
                self.atomicRangeStartSet = Set(newAtomicRanges.map { $0.location })
                
                var accumulatedLength = 0
                var newIndex = 0
                var partialTokenSuffix: String? = nil
                
                for (i, token) in newTokens.enumerated() {
                    let tokenLen = token.count
                    let tokenEnd = accumulatedLength + tokenLen
                    
                    if tokenEnd > currentMarkdownCount {
                        if accumulatedLength < currentMarkdownCount {
                             // Overlap: token started before cursor but ends after
                             let overlap = currentMarkdownCount - accumulatedLength
                             partialTokenSuffix = String(token.dropFirst(overlap))
                             newIndex = i + 1
                        } else {
                             // Next token starts at or after cursor
                             newIndex = i
                        }
                        break
                    }
                    accumulatedLength += tokenLen
                    
                    // Exact match boundary
                    if tokenEnd == currentMarkdownCount {
                        newIndex = i + 1
                        break
                    }
                }
                
                if let suffix = partialTokenSuffix {
                    self.markdown += suffix
                }
                
                self.streamTokenIndex = newIndex
            }
        }
    }
    
    /// 智能追加 Token，支持原子区间跳跃
        func appendNextTokensAtomic(count: Int) {
            guard streamTokenIndex < streamTokens.count else {
                // ⚡️ 流式渲染完成
                // 1. 先停止 Timer（但不清除脚注缓存）
                streamTimer?.invalidate()
                streamTimer = nil
                isPausedForDisplay = false

                // 2. ⚡️ 优化：如果有脚注，则延迟结束流式状态，等待打字机动画完成后渲染脚注
                //    这样可以确保脚注渲染时仍然能触发外部容器的自动滚动
                if cachedFootnoteView != nil || !streamParsedFootnotes.isEmpty {
                    pendingFootnoteRender = true
                    mdLog("🔖 [Footnotes] Deferred rendering until typewriter animations complete")
                    // ⚡️ 保持 isStreaming = true，直到脚注渲染完成
                    // 这样外部容器（如 TableView）仍然会自动滚动
                    return
                }

                // 3. 没有脚注，立即结束流式模式
                isStreaming = false

                // 4. 清理视图缓存（脚注渲染完成后再清理）
                clearViewCache()

                // 5. ⭐️ 执行最终解析，确保 TOC 等数据完整
                performFinalParse()

                // 6. 触发完成回调
                onStreamComplete?()
                onStreamComplete = nil

                return
            }
            
            // 当前 Markdown 的长度（光标位置）
            let currentLength = (markdown as NSString).length

            // 1. 检查当前光标是否位于某个原子区间的"起点"
            // ⚡️ 性能优化：先用 O(1) 的 Set 查找，再用 O(N) 的数组查找具体 range
            if atomicRangeStartSet.contains(currentLength),
               let atomicRange = streamAtomicRanges.first(where: { $0.location == currentLength }) {
                
                // 🎯 命中原子区间！
                // 直接截取这整个区间的内容
                let fullTextInfo = streamFullText as NSString
                // 确保 range 不越界（理论上预计算的不会越界，但安全第一）
                if atomicRange.upperBound <= fullTextInfo.length {
                    let chunk = fullTextInfo.substring(with: atomicRange)
                    
                    // 一次性追加整个公式/图片字符串
                    markdown += chunk
                    
                    // ⏩ 关键：我们需要更新 streamTokenIndex，跳过这些 token
                    // 因为 tokens 是碎片化的，我们需要计算跳过了多少字符
                    var skippedLength = 0
                    let targetLength = atomicRange.length
                    
                    // 向前推进 token index，直到跳过的字符总数 >= 原子区间的长度
                    while streamTokenIndex < streamTokens.count {
                        let tokenLen = streamTokens[streamTokenIndex].count
                        skippedLength += tokenLen
                        streamTokenIndex += 1
                        
                        if skippedLength >= targetLength {
                            break
                        }
                    }
                    
                    // 处理自动滚动
                    handleAutoScroll()
                    return // 本次 Tick 结束，等待下一次 Timer
                }
            }
            
            // 2. 如果没有命中原子区间，走普通逻辑
            var nextChunk = ""
            var tokensAdded = 0
            
            // 循环取出 count 个 token
            while streamTokenIndex < streamTokens.count && tokensAdded < count {
                let token = streamTokens[streamTokenIndex]
                
                // 🛑 二次检查：在普通追加的过程中，会不会"误入"原子区间的内部？
                // 现在的逻辑是：如果普通追加的 token 开始位置正好是原子区间的起点，我们应该停止普通追加，
                // 留给下一次 Timer tick 去处理上面的 "if let atomicRange" 逻辑。
                let nextCursor = currentLength + (nextChunk as NSString).length
                // ⚡️ 性能优化：用 O(1) 的 Set 查找替代 O(N) 的数组遍历
                if atomicRangeStartSet.contains(nextCursor) {
                    // 撞到了原子区间的门口，立即停止，把机会留给下一次循环处理整体输出
                    break
                }
                
                nextChunk += token
                streamTokenIndex += 1
                tokensAdded += 1
            }
            
            markdown += nextChunk
            handleAutoScroll()
        }
        
        func handleAutoScroll() {
            guard autoScrollEnabled else { return }

            autoScrollWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.autoScrollToBottomIfAppropriate()
            }
            autoScrollWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }

        /// 仅在用户未接管滚动、且视图仍贴近底部时才滚动
        func autoScrollToBottomIfAppropriate() {
            guard autoScrollEnabled, let sv = findEnclosingScrollView() else { return }

            // 用户手指在屏幕上或惯性滚动中：视为接管，不再抢夺
            if sv.isDragging || sv.isTracking || sv.isDecelerating {
                userScrolledAway = true
                return
            }

            let distance = distanceFromBottom(sv)

            if distance <= Self.autoScrollBottomTolerance {
                // 已贴回底部，恢复跟随
                userScrolledAway = false
            } else if userScrolledAway {
                return
            } else if distance > max(Self.autoScrollBottomTolerance, sv.bounds.height * 0.5) {
                // 拖拽在两次 token 之间结束、且无惯性时 isDragging/isDecelerating 都已复位，
                // 此处用距离兜底：单个 token 的内容增量不可能造成半屏以上的偏离
                userScrolledAway = true
                return
            }

            scrollToBottom(animated: false)
        }

        /// 当前偏移距底部的距离
        func distanceFromBottom(_ sv: UIScrollView) -> CGFloat {
            let maxOffsetY = max(0, sv.contentSize.height - sv.bounds.height + sv.contentInset.bottom)
            return maxOffsetY - sv.contentOffset.y
        }

    func tokenize(_ text: String, unit: StreamingUnit) -> [String] {
        switch unit {
        case .character:
            return text.map { String($0) }
            
        case .word, .sentence:
            let nlUnit: NLTokenUnit = unit == .word ? .word : .sentence
            var tokens: [String] = []
            
            let tokenizer = NLTokenizer(unit: nlUnit)
            tokenizer.string = text
            
            var lastEnd = text.startIndex
            
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                if lastEnd < range.lowerBound {
                    tokens.append(String(text[lastEnd..<range.lowerBound]))
                }
                tokens.append(String(text[range]))
                lastEnd = range.upperBound
                return true
            }
            
            if lastEnd < text.endIndex {
                tokens.append(String(text[lastEnd..<text.endIndex]))
            }
            
            return tokens
        }
    }

    /// 追加下一批 token
    func appendNextTokens(count: Int) {
        guard streamTokenIndex < streamTokens.count else {
            stopStreaming()
            return
        }
        
        let endIndex = min(streamTokenIndex + count, streamTokens.count)
        let chunk = streamTokens[streamTokenIndex..<endIndex].joined()
        
        markdown += chunk
        streamTokenIndex = endIndex
        
        // 自动滚动到底部
        handleAutoScroll()
    }

    /// ⚡️ 如果有待渲染的脚注，则渲染（在打字机动画完成后调用）
    func renderFootnotesIfPending() {
        mdLog("[FOOTNOTE_DEBUG] 📍 renderFootnotesIfPending called, isRealStreamingMode=\(isRealStreamingMode), pendingFootnoteRender=\(pendingFootnoteRender)")

        // ⭐️ 关键修复：真流式模式下不在这里渲染脚注
        // 脚注应该在 endRealStreaming() 中统一处理
        guard !isRealStreamingMode else {
            mdLog("[FOOTNOTE_DEBUG] ⏭️ Skipping - in real streaming mode")
            return
        }

        guard pendingFootnoteRender else {
            mdLog("[FOOTNOTE_DEBUG] ⏭️ Skipping - pendingFootnoteRender is false")
            return
        }

        mdLog("[FOOTNOTE_DEBUG] ⚠️ WILL RENDER FOOTNOTES NOW!")
        pendingFootnoteRender = false
        renderFootnotesAfterStreaming()

        // ⚡️ 脚注渲染完成，现在可以结束流式状态了
        if isStreaming {
            isStreaming = false
            mdLog("✅ [Stream] Completed after footnote rendering")

            // 触发完成回调
            onStreamComplete?()
            onStreamComplete = nil
        }
    }

    /// 流式渲染完成后渲染脚注
    func renderFootnotesAfterStreaming() {
        // ⚠️ 必须在主线程调用
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.renderFootnotesAfterStreaming()
            }
            return
        }

        // ⚡️ 优先使用预渲染的缓存视图（避免重新创建导致的闪烁）
        if let cachedView = cachedFootnoteView {
            mdLog("🔖 [Footnotes] Using prerendered cached view (instant add)")

            // ⚡️ 正确计算元素数量
            let elementCount = oldElements.count

            // 使用无动画直接添加预渲染的视图
            UIView.performWithoutAnimation {
                // 移除旧脚注（如果有）
                if contentStackView.arrangedSubviews.count > elementCount {
                    contentStackView.arrangedSubviews.last?.removeFromSuperview()
                }

                // 直接添加缓存的视图
                contentStackView.addArrangedSubview(cachedView)
                cachedView.layoutIfNeeded()
            }

            // 清理缓存
            cachedFootnoteView = nil
            mdLog("✅ [Footnotes] Cached view added, no flicker")

            // ⚡️ 关键修复：先布局，再通知外部容器高度已改变
            self.layoutIfNeeded()
            notifyHeightChange()
            return
        }

        // ⚠️ 降级方案：如果没有缓存（不应该发生），回退到常规渲染
        mdLog("⚠️ [Footnotes] No cached view, falling back to regular rendering")

        // 重新解析脚注
        let (_, footnotes) = preprocessFootnotes(markdown)
        guard !footnotes.isEmpty else { return }

        // ⚡️ 正确计算元素数量
        let elementCount = oldElements.count
        let containerWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32

        mdLog("🔖 [Footnotes] Rendering \(footnotes.count) footnote(s) after streaming (elementCount=\(elementCount))")
        updateFootnotes(footnotes, width: containerWidth, newElementCount: elementCount)

        // ⚡️ 关键修复：先布局，再通知外部容器高度已改变
        self.layoutIfNeeded()
        notifyHeightChange()
    }

    /// ⚡️ 在后台预渲染脚注视图（流式开始时调用，避免流式完成时的闪烁）
    /// - Note: ⭐️ 修复：直接使用已保存的 streamParsedFootnotes，而不是重新解析文本
    ///         因为传入的 fullText 可能是已处理过的文本（不含脚注定义），
    ///         重新解析会找不到脚注。
    func prerenderFootnotesInBackground(fullText: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // ⭐️ 修复：优先使用已保存的脚注，如果没有才尝试解析
            let footnotes: [MarkdownFootnote]

            // 在主线程安全获取已解析的脚注
            let savedFootnotes = DispatchQueue.main.sync {
                self.streamParsedFootnotes
            }

            if !savedFootnotes.isEmpty {
                // 使用已保存的脚注（假流式模式下已在 startStreaming 时解析）
                footnotes = savedFootnotes
                mdLog("🔖 [Footnotes] Using pre-parsed \(footnotes.count) footnote(s)")
            } else {
                // 降级：尝试从原始文本解析（真流式模式或其他情况）
                let (_, parsedFootnotes) = self.preprocessFootnotes(fullText)
                footnotes = parsedFootnotes
            }

            guard !footnotes.isEmpty else {
                mdLog("🔖 [Footnotes] No footnotes to prerender")
                return
            }

            mdLog("🔖 [Footnotes] Prerendering \(footnotes.count) footnote(s) in background")

            // 获取容器宽度
            let containerWidth = DispatchQueue.main.sync {
                self.bounds.width > 0 ? self.bounds.width : UIScreen.main.bounds.width - 32
            }

            // 在后台创建脚注视图（离屏渲染）
            let footnoteView = self.createFootnoteView(footnotes: footnotes, width: containerWidth)

            // 缓存预渲染的视图
            DispatchQueue.main.async {
                self.cachedFootnoteView = footnoteView
                mdLog("✅ [Footnotes] Prerendering completed, cached view ready")
            }
        }
    }

    /// 停止流式渲染
    public func stopStreaming() {
        streamTimer?.invalidate()
        streamTimer = nil
        isPausedForDisplay = false  // 重置暂停状态
        // ⚡️ 流式结束，清理视图缓存
        clearViewCache()
        // 停止震动反馈
        stopHapticFeedback()
    }

    /// 立即显示全部内容
    public func finishStreaming() {
        stopStreaming()
        isStreaming = false
        markdown = streamFullText
        // 设置 markdown 会触发 scheduleRerender()，自动渲染包括脚注
    }

    /// 用于可复用场景（如 UITableViewCell）强制清理解析与视图缓存
    public func resetForReuse() {
        renderWorkItem?.cancel()
        offscreenRenderWorkItem?.cancel()
        autoScrollWorkItem?.cancel()
        autoScrollWorkItem = nil
        userScrolledAway = false
        streamTimer?.invalidate()
        streamTimer = nil
        waitingDetectionTimer?.invalidate()
        waitingAnimationTimer?.invalidate()

        renderVersionLock.lock()
        renderVersion += 1
        renderVersionLock.unlock()

        isStreaming = false
        isRealStreamingMode = false
        realStreamRenderGeneration += 1
        pendingRealStreamElements.removeAll()
        realStreamRenderPumpScheduled = false
        realStreamParseInFlightCount = 0
        pendingSmartStreamModules.removeAll()
        smartStreamParseActive = false
        realStreamDrainCompletion = nil
        isEndingRealStream = false
        realStreamBackpressureActive = false
        heightNotificationScheduled = false
        pendingForcedHeightNotification = false
        lastHeightNotificationTimestamp = 0
        lastLayoutWidthForHeightMeasurement = 0
        streamPreParseCompleted = false
        streamDisplayedCount = 0
        streamParsedElements = []
        streamParsedFootnotes = []
        streamParsedAttachments = []
        streamTotalTextLength = 0
        streamFullText = ""
        streamCurrentIndex = 0
        streamTokens = []
        streamTokenIndex = 0
        pendingFootnoteRender = false
        currentFootnotes = []
        cachedFootnoteView?.removeFromSuperview()
        cachedFootnoteView = nil

        parseCache = ParseCache()
        cachedContainerWidth = 0
        configurationHash = 0
        oldElements = []
        headingViews.removeAll()
        tocSectionView = nil
        tocSectionId = nil
        tableOfContents = []
        imageAttachments = []

        typewriterEngine.stop()
        clearViewCache()
        streamBuffer.reset()
        contentStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: - 等待动画控制

    /// ⭐️ 启动等待检测（在真流式开始时调用）
    func startWaitingDetection() {
        stopWaitingDetection()
        lastDataReceivedTime = CFAbsoluteTimeGetCurrent()

        // 每 0.2 秒检测一次是否需要显示等待动画
        waitingDetectionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.checkAndUpdateWaitingIndicator()
        }
    }

    /// ⭐️ 停止等待检测
    func stopWaitingDetection() {
        waitingDetectionTimer?.invalidate()
        waitingDetectionTimer = nil
    }

    /// ⭐️ 检测并更新等待动画状态
    /// 只有当 TypewriterEngine 空闲且超过延迟时间未收到新数据时才显示
    func checkAndUpdateWaitingIndicator() {
        guard isRealStreamingMode else {
            hideWaitingIndicator()
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let timeSinceLastData = now - lastDataReceivedTime
        let hasRenderBacklog = realStreamParseInFlightCount > 0 || !pendingRealStreamElements.isEmpty || realStreamRenderPumpScheduled
        let isEngineIdle = typewriterEngine.isIdle && !hasRenderBacklog

        // ⭐️ 调试日志
        mdLog("[WaitingIndicator] 检测: isEngineIdle=\(isEngineIdle), renderBacklog=\(hasRenderBacklog), timeSinceLastData=\(String(format: "%.2f", timeSinceLastData))s, delay=\(waitingIndicatorDelay)s, isShowing=\(isShowingWaitingIndicator)")

        // ⭐️ 核心逻辑：只有当 TypewriterEngine 空闲且超过延迟时间未收到数据时才显示
        if isEngineIdle && timeSinceLastData > waitingIndicatorDelay {
            if !isShowingWaitingIndicator {
                mdLog("[WaitingIndicator] ✅ 条件满足，显示等待动画")
                showWaitingIndicator()
            }
        } else {
            if isShowingWaitingIndicator {
                hideWaitingIndicator()
            }
        }
    }

    /// ⭐️ 标记收到新数据（在 appendStreamData/appendBlock 时调用）
    func markDataReceived() {
        lastDataReceivedTime = CFAbsoluteTimeGetCurrent()
        // 收到数据时立即隐藏等待动画
        if isShowingWaitingIndicator {
            hideWaitingIndicator()
        }
    }

    // MARK: - 流式输出震动反馈

    /// 准备震动反馈生成器（在流式开始时调用）
    func prepareHapticFeedback() {
        guard configuration.streamingHapticFeedbackStyle != .none else { return }

        if #available(iOS 13.0, *) {
            if let style = configuration.streamingHapticFeedbackStyle.impactStyle {
                hapticFeedbackGenerator = UIImpactFeedbackGenerator(style: style)
                hapticFeedbackGenerator?.prepare()
            }
        }
    }

    /// 触发震动反馈（带节流控制）
    func triggerHapticFeedback() {
        guard configuration.streamingHapticFeedbackStyle != .none else { return }

        let currentTime = CACurrentMediaTime()
        let minInterval = configuration.streamingHapticMinInterval

        // 节流控制：避免过于频繁的震动
        guard currentTime - lastHapticFeedbackTime >= minInterval else { return }

        lastHapticFeedbackTime = currentTime
        hapticFeedbackGenerator?.impactOccurred()
    }

    /// 停止震动反馈（在流式结束时调用）
    func stopHapticFeedback() {
        hapticFeedbackGenerator = nil
        lastHapticFeedbackTime = 0
    }

    /// 更新等待动画显示状态（保留用于兼容）
    func updateWaitingIndicator(visible: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if visible && !self.isShowingWaitingIndicator {
                self.showWaitingIndicator()
            } else if !visible && self.isShowingWaitingIndicator {
                self.hideWaitingIndicator()
            }
        }
    }

    /// 显示等待动画
    func showWaitingIndicator() {
        guard !isShowingWaitingIndicator else { return }
        isShowingWaitingIndicator = true

        // 添加到 StackView 末尾
        if waitingIndicatorView.superview == nil {
            contentStackView.addArrangedSubview(waitingIndicatorView)
        }
        waitingIndicatorView.isHidden = false

        // 启动跳动动画
        startWaitingAnimation()

        mdLog("[StreamBuffer] 💫 Waiting indicator shown")
    }

    /// 隐藏等待动画
    func hideWaitingIndicator() {
        guard isShowingWaitingIndicator else { return }
        isShowingWaitingIndicator = false

        // 停止动画
        stopWaitingAnimation()

        // 从 StackView 移除
        waitingIndicatorView.isHidden = true
        waitingIndicatorView.removeFromSuperview()

        mdLog("[StreamBuffer] 💫 Waiting indicator hidden")
    }

    /// 启动等待动画（三点跳动）
    func startWaitingAnimation() {
        waitingAnimationTimer?.invalidate()

        var animationStep = 0
        waitingAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self = self, self.isShowingWaitingIndicator else {
                timer.invalidate()
                return
            }

            // 找到所有的点
            for i in 0..<3 {
                if let dot = self.waitingIndicatorView.viewWithTag(100 + i) {
                    let isActive = (i == animationStep % 3)
                    UIView.animate(withDuration: 0.15) {
                        dot.transform = isActive ? CGAffineTransform(scaleX: 1.3, y: 1.3) : .identity
                        dot.alpha = isActive ? 1.0 : 0.5
                    }
                }
            }
            animationStep += 1
        }
    }

    /// 停止等待动画
    func stopWaitingAnimation() {
        waitingAnimationTimer?.invalidate()
        waitingAnimationTimer = nil

        // 重置所有点的状态
        for i in 0..<3 {
            if let dot = waitingIndicatorView.viewWithTag(100 + i) {
                dot.transform = .identity
                dot.alpha = 1.0
            }
        }
    }

}
