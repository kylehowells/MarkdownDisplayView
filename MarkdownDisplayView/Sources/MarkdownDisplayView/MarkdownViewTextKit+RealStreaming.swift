//
//  MarkdownViewTextKit+RealStreaming.swift
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
    // MARK: - ⭐️ 真流式 Append 模式（Real Streaming）

    /// 开始真流式模式
    /// - Parameters:
    ///   - autoScrollBottom: 是否自动滚动到底部
    ///   - useSmartBuffer: 是否使用智能缓存模式（自动检测完整模块）
    ///   - onComplete: 流式完成回调
    public func beginRealStreaming(autoScrollBottom: Bool = true, useSmartBuffer: Bool = false, onComplete: (() -> Void)? = nil) {
        mdLog("[FOOTNOTE_DEBUG] 🟢 beginRealStreaming called, useSmartBuffer=\(useSmartBuffer)")

        // 停止任何现有流式
        stopStreaming()

        // Cell 可能刚在 configure 中调度过普通 Markdown 渲染。进入真流式前必须
        // 同时取消尚未执行的任务，并让已经在后台解析的结果失效，禁止其回写流式 UI。
        renderWorkItem?.cancel()
        renderWorkItem = nil
        offscreenRenderWorkItem?.cancel()
        offscreenRenderWorkItem = nil
        renderVersionLock.lock()
        renderVersion += 1
        renderVersionLock.unlock()

        // 初始化真流式状态
        isRealStreamingMode = true
        isStreaming = true
        useSmartBufferMode = useSmartBuffer
        mdLog("[FOOTNOTE_DEBUG] 🟢 isRealStreamingMode set to TRUE")
        autoScrollEnabled = autoScrollBottom
        userScrolledAway = false
        realStreamAccumulatedText = ""
        realStreamParsedElementCount = 0
        realStreamBlockQueue = []
        realStreamOnComplete = onComplete
        realStreamRenderGeneration += 1
        pendingRealStreamElements.removeAll()
        realStreamRenderPumpScheduled = false
        realStreamParseInFlightCount = 0
        pendingSmartStreamModules.removeAll()
        smartStreamParseActive = false
        realStreamDrainCompletion = nil
        isEndingRealStream = false
        realStreamBackpressureActive = false
        realStreamNextModuleSequence = 0
        streamPerformanceDiagnostics.begin(generation: realStreamRenderGeneration)

        // 清空现有内容
        markdown = ""
        oldElements = []
        contentStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        headingViews.removeAll()
        tocSectionView = nil
        tableOfContents.removeAll()
        tocSectionId = nil
        imageAttachments.removeAll()

        // 重置 TypewriterEngine
        typewriterEngine.stop()

        // 重置 StreamBuffer（智能缓存模式）
        if useSmartBuffer {
            streamBuffer.reset()
            streamBuffer.updateContainerWidth(bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32)
        }

        // ⭐️ 修复：启动等待检测，而不是直接显示等待动画
        // 等待动画只在 TypewriterEngine 空闲且一段时间无数据到达时显示
        startWaitingDetection()

        // 准备震动反馈
        prepareHapticFeedback()

        // 记录开始时间
        streamingStartTimestamp = CFAbsoluteTimeGetCurrent()

        mdLog("🎬 [RealStream] Started real streaming mode, smartBuffer=\(useSmartBuffer)")
    }

    /// ⭐️ 新 API：追加流式数据（智能缓存模式）
    /// 自动检测完整模块并渲染，无需外部预分割
    /// - Parameter data: 网络到达的原始文本数据
    public func appendStreamData(_ data: String) {
        // 该方法会同步阻塞调用方并直接改动视图层级，必须在主线程调用
        dispatchPrecondition(condition: .onQueue(.main))

        guard isRealStreamingMode else {
            mdLog("⚠️ [RealStream] Not in real streaming mode, call beginRealStreaming() first")
            return
        }
        guard !isEndingRealStream else { return }

        // ⭐️ 标记收到新数据，用于等待动画检测
        markDataReceived()

        mdLog("📥 [SmartBuffer] Received data: \(data.count) chars")
        if MarkdownStreamPerformanceDiagnostics.enabled {
            streamPerformanceDiagnostics.recordReceive(characters: data.count)
        }

        // 使用 StreamBuffer 检测完整模块
        let result = streamBuffer.append(data)

        // 串行后台队列保持模块顺序，同时避免 Markdown 解析阻塞主线程。
        if !result.completeModules.isEmpty {
            for (index, moduleText) in result.completeModules.enumerated() {
                mdLog("📦 [SmartBuffer] Processing module \(index + 1)/\(result.completeModules.count): \(moduleText.prefix(50))...")
                enqueueSmartStreamModule(moduleText)
            }
        }

        // 如果有未完成的结构，日志记录
        if result.hasPendingStructure, let pending = result.pendingType {
            mdLog("⏳ [SmartBuffer] Waiting for \(pending.rawValue) to close...")
        }
    }

    /// 串行后台解析模块。renderQueue 保证完成顺序与输入顺序一致；UIKit 更新只回到主线程执行。
    func enqueueSmartStreamModule(_ moduleText: String, appendSeparator: Bool = true) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRealStreamingMode else { return }

        realStreamAccumulatedText += moduleText
        if appendSeparator { realStreamAccumulatedText += "\n\n" }
        realStreamParseInFlightCount += 1
        let moduleSequence = realStreamNextModuleSequence
        realStreamNextModuleSequence += 1
        renderVersionLock.lock()
        let currentRenderVersion = renderVersion
        renderVersionLock.unlock()
        pendingSmartStreamModules.append(PendingSmartStreamModule(
            text: moduleText,
            renderVersion: currentRenderVersion,
            renderGeneration: realStreamRenderGeneration,
            sequence: moduleSequence
        ))
        streamPerformanceDiagnostics.recordModuleQueued(
            pendingModules: realStreamParseInFlightCount
        )
        startNextSmartStreamParseIfPossible()
    }

    func startNextSmartStreamParseIfPossible() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRealStreamingMode,
              !smartStreamParseActive,
              !realStreamBackpressureActive,
              pendingRealStreamElements.count < realStreamTypewriterHighWatermark * 2,
              let module = pendingSmartStreamModules.popFirst() else { return }

        smartStreamParseActive = true
        let containerWidth = currentContainerWidthForParsing()
        let config = configuration

        renderQueue.async { [weak self] in
            guard let self else { return }
            self.renderVersionLock.lock()
            let isCurrentVersion = self.renderVersion == module.renderVersion
            self.renderVersionLock.unlock()
            guard isCurrentVersion else { return }

            let parseStart = CFAbsoluteTimeGetCurrent()
            let (processedText, _) = self.preprocessFootnotes(module.text)
            let renderer = MarkdownRenderer(configuration: config, containerWidth: containerWidth)
            let result = renderer.render(processedText)
            let parseDuration = (CFAbsoluteTimeGetCurrent() - parseStart) * 1000

            DispatchQueue.main.async { [weak self] in
                guard let self, module.renderGeneration == self.realStreamRenderGeneration else { return }
                self.smartStreamParseActive = false
                self.realStreamParseInFlightCount = max(0, self.realStreamParseInFlightCount - 1)
                guard self.isRealStreamingMode else { return }

                let (parsedElements, attachments, parsedTOCItems, parsedTOCId) = result
                let (elements, tocItems, tocId) = self.rebaseRealStreamHeadingIDs(
                    elements: parsedElements,
                    tocItems: parsedTOCItems,
                    tocSectionId: parsedTOCId
                )
                let previousElementCount = self.realStreamParsedElementCount
                self.realStreamParsedElementCount += elements.count
                self.imageAttachments.append(contentsOf: attachments)
                self.tableOfContents.append(contentsOf: tocItems)
                if let tocId { self.tocSectionId = tocId }

                mdLog("✅ [SmartBuffer] Parsed module: \(elements.count) elements, parse: \(String(format: "%.1f", parseDuration))ms, UI backlog: \(self.pendingRealStreamElements.count), typewriter: \(self.typewriterEngine.outstandingTaskCount)")
                self.streamPerformanceDiagnostics.recordModuleParsed(
                    sequence: module.sequence,
                    durationMS: parseDuration,
                    elements: elements.count,
                    pendingModules: self.realStreamParseInFlightCount,
                    pendingViews: self.pendingRealStreamElements.count,
                    typewriter: self.typewriterEngine.outstandingTaskCount
                )
                if !elements.isEmpty {
                    self.displayRealStreamElements(
                        elements,
                        startIndex: previousElementCount,
                        moduleSequence: module.sequence
                    )
                }
                self.startNextSmartStreamParseIfPossible()
                self.tryFinishRealStreamDrain()
            }
        }
    }

    /// 每个完整模块都会使用新的 MarkdownParser，局部标题 ID 会从 heading-0 重新开始。
    /// 合并模块前将标题及 TOC ID 重定位到当前文档的全局序号，避免 headingViews 被覆盖。
    func rebaseRealStreamHeadingIDs(
        elements: [MarkdownRenderElement],
        tocItems: [MarkdownTOCItem],
        tocSectionId: String?
    ) -> (elements: [MarkdownRenderElement], tocItems: [MarkdownTOCItem], tocSectionId: String?) {
        let offset = tableOfContents.count
        let idMap = Dictionary(uniqueKeysWithValues: tocItems.enumerated().map { index, item in
            (item.id, "heading-\(offset + index)")
        })

        func remap(_ element: MarkdownRenderElement) -> MarkdownRenderElement {
            switch element {
            case .heading(let id, let text):
                return .heading(id: idMap[id] ?? id, text: text)
            case .quote(let children, let level):
                return .quote(children: children.map(remap), level: level)
            case .details(let summary, let children):
                return .details(summary: summary, children: children.map(remap))
            case .list(let items, let level):
                let remappedItems = items.map { item in
                    ListNodeItem(marker: item.marker, children: item.children.map(remap))
                }
                return .list(items: remappedItems, level: level)
            default:
                return element
            }
        }

        let rebasedTOCItems = tocItems.enumerated().map { index, item in
            MarkdownTOCItem(level: item.level, title: item.title, id: "heading-\(offset + index)")
        }

        return (
            elements.map(remap),
            rebasedTOCItems,
            tocSectionId.flatMap { idMap[$0] }
        )
    }

    /// 追加一个完整的 Markdown 块（保持向后兼容）
    /// - Parameter block: 完整的 Markdown 块（如标题+内容、段落、代码块等）
    /// - Note: 每个块应该是完整的 Markdown 结构，不会在语法中间截断
    public func appendBlock(_ block: String) {
        guard isRealStreamingMode, !isEndingRealStream else {
            mdLog("⚠️ [RealStream] Not in real streaming mode, call beginRealStreaming() first")
            return
        }

        // 如果使用智能缓存模式，委托给 appendStreamData
        if useSmartBufferMode {
            appendStreamData(block)
            return
        }

        // ⭐️ 标记收到新数据，用于等待动画检测
        markDataReceived()

        mdLog("📝 [RealStream] Appending block: \(block.prefix(50))... (\(block.count) chars)")

        // 完整块也必须进入串行解析队列。旧实现会为每个块并发重解析累计全文，
        // 多个结果可能使用相同的 previousElementCount 并乱序回写，造成 View 重复、
        // tag 冲突及目录状态被旧结果覆盖。
        enqueueSmartStreamModule(block, appendSeparator: false)
    }

    /// 显示真流式新增的元素
    func displayRealStreamElements(
        _ elements: [MarkdownRenderElement],
        startIndex: Int,
        moduleSequence: Int
    ) {
        guard useSmartBufferMode else {
            displayLegacyRealStreamElements(elements, startIndex: startIndex)
            return
        }

        for (index, element) in elements.enumerated() {
            pendingRealStreamElements.append(PendingRealStreamElement(
                element: element,
                globalIndex: startIndex + index,
                moduleSequence: moduleSequence
            ))
        }
        scheduleRealStreamRenderPump()
    }

    private func displayLegacyRealStreamElements(_ elements: [MarkdownRenderElement], startIndex: Int) {
        let containerWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32
        if isShowingWaitingIndicator { hideWaitingIndicator() }

        for (index, element) in elements.enumerated() {
            let globalIndex = startIndex + index
            let view = createView(for: element, containerWidth: containerWidth)
            view.tag = 1000 + globalIndex
            if enableTypewriterEffect {
                view.isHidden = true
                contentStackView.addArrangedSubview(view)
                typewriterEngine.enqueue(view: view)
            } else {
                contentStackView.addArrangedSubview(view)
            }
            if case .heading(let id, _) = element {
                headingViews[id] = view
                if id == tocSectionId { tocSectionView = view }
            }
            oldElements.append(element)
        }

        if enableTypewriterEffect { typewriterEngine.start() }
        scheduleHeightChangeNotification()
        handleAutoScroll()
    }

    func scheduleRealStreamRenderPump() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRealStreamingMode,
              !pendingRealStreamElements.isEmpty,
              !realStreamRenderPumpScheduled else {
            tryFinishRealStreamDrain()
            return
        }

        if enableTypewriterEffect,
           typewriterEngine.outstandingTaskCount >= realStreamTypewriterHighWatermark {
            realStreamBackpressureActive = true
            mdLog("⏸️ [SmartBuffer] UI backpressure: typewriter=\(typewriterEngine.outstandingTaskCount), pendingViews=\(pendingRealStreamElements.count)")
            return
        }

        realStreamRenderPumpScheduled = true
        let generation = realStreamRenderGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            guard let self else { return }
            self.realStreamRenderPumpScheduled = false
            guard generation == self.realStreamRenderGeneration, self.isRealStreamingMode else { return }
            self.processRealStreamRenderFrame()
        }
    }

    func processRealStreamRenderFrame() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRealStreamingMode else { return }

        if isShowingWaitingIndicator { hideWaitingIndicator() }

        let frameStart = CACurrentMediaTime()
        let containerWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32
        var createdCount = 0

        repeat {
            guard let item = pendingRealStreamElements.popFirst() else { break }
            guard item.globalIndex <= oldElements.count else {
                assertionFailure("Real-stream element order gap: expected at most \(oldElements.count), got \(item.globalIndex)")
                mdLog("❌ [SmartBuffer] Dropped out-of-order UI element: expected<=\(oldElements.count), actual=\(item.globalIndex)")
                break
            }
            let createStart = CFAbsoluteTimeGetCurrent()
            let duplicateElement = item.globalIndex < oldElements.count
            let view = createView(for: item.element, containerWidth: containerWidth)
            let createDuration = (CFAbsoluteTimeGetCurrent() - createStart) * 1000
            view.tag = 1000 + item.globalIndex

            if enableTypewriterEffect {
                view.isHidden = true
                contentStackView.addArrangedSubview(view)
                typewriterEngine.enqueue(view: view)
            } else {
                contentStackView.addArrangedSubview(view)
            }

            if case .heading(let id, _) = item.element {
                headingViews[id] = view
                if id == tocSectionId { tocSectionView = view }
            }

            if item.globalIndex == oldElements.count {
                oldElements.append(item.element)
            } else if item.globalIndex < oldElements.count {
                oldElements[item.globalIndex] = item.element
            }

            createdCount += 1
            if MarkdownStreamPerformanceDiagnostics.enabled {
                streamPerformanceDiagnostics.recordViewCreated(
                    sequence: item.moduleSequence,
                    index: item.globalIndex,
                    type: elementTypeString(item.element),
                    durationMS: createDuration,
                    duplicate: duplicateElement
                )
            }
            mdLog("⚙️ [SmartBuffer] View created: index=\(item.globalIndex), type=\(elementTypeString(item.element)), cost=\(String(format: "%.1f", createDuration))ms")

            if enableTypewriterEffect,
               typewriterEngine.outstandingTaskCount >= realStreamTypewriterHighWatermark {
                realStreamBackpressureActive = true
                break
            }
        } while CACurrentMediaTime() - frameStart < realStreamFrameBudget

        if enableTypewriterEffect, createdCount > 0 {
            typewriterEngine.start()
        }

        if createdCount > 0 {
            // 打字机模式下新 View 仍是 hidden，不会改变可见高度；真正 show/文字增高时
            // TypewriterEngine.onLayoutChange 会统一触发测高。这里提前测只会空跑整棵布局树。
            if !enableTypewriterEffect {
                scheduleHeightChangeNotification()
            }
            handleAutoScroll()
            mdLog("⚙️ [SmartBuffer] UI frame: created=\(createdCount), cost=\(String(format: "%.1f", (CACurrentMediaTime() - frameStart) * 1000))ms, pendingViews=\(pendingRealStreamElements.count), typewriter=\(typewriterEngine.outstandingTaskCount)")
        }

        streamPerformanceDiagnostics.recordRenderFrame(
            durationMS: (CACurrentMediaTime() - frameStart) * 1000,
            created: createdCount,
            pendingModules: realStreamParseInFlightCount,
            pendingViews: pendingRealStreamElements.count,
            typewriter: typewriterEngine.outstandingTaskCount,
            arrangedSubviews: contentStackView.arrangedSubviews.count
        )

        if !realStreamBackpressureActive { scheduleRealStreamRenderPump() }
        startNextSmartStreamParseIfPossible()
        tryFinishRealStreamDrain()
    }

    /// 结束真流式模式
    /// - Parameter completion: 完成回调，在 TypewriterEngine 完全结束且脚注渲染完毕后触发
    public func endRealStreaming(completion: (() -> Void)? = nil) {
        mdLog("[FOOTNOTE_DEBUG] 🔴 endRealStreaming called, isRealStreamingMode=\(isRealStreamingMode)")
        guard isRealStreamingMode else {
            completion?()
            return
        }
        guard !isEndingRealStream else { return }
        isEndingRealStream = true

        mdLog("🎉 [RealStream] Ending real streaming mode")

        // ⭐️ 停止等待检测定时器
        stopWaitingDetection()

        // ⭐️ 隐藏等待动画
        hideWaitingIndicator()

        // ⭐️ 智能缓存模式：处理剩余的未完成内容
        if useSmartBufferMode {
            let remainingText = streamBuffer.flush()
            if !remainingText.isEmpty {
                mdLog("📦 [SmartBuffer] Flushing remaining content: \(remainingText.prefix(50))...")
                enqueueSmartStreamModule(remainingText)
            }
        }

        // 更新 markdown 属性（用于后续非流式访问）
        markdown = realStreamAccumulatedText

        // ⚠️ 解析脚注，但延迟到 TypewriterEngine 完成后再渲染
        let (_, footnotes) = preprocessFootnotes(realStreamAccumulatedText)
        mdLog("[FOOTNOTE_DEBUG] 🔴 endRealStreaming parsed \(footnotes.count) footnotes, will defer rendering")

        // ⭐️ 关键修复：保存脚注和完成回调，等待 TypewriterEngine 完成后统一处理
        let pendingFootnotes = footnotes
        let pendingCompletion = realStreamOnComplete
        let externalCompletion = completion  // ⭐️ 新增：保存外部传入的 completion
        realStreamOnComplete = nil

        // 定义收尾逻辑
        let finishBlock: () -> Void = { [weak self] in
            guard let self = self else {
                externalCompletion?()
                return
            }

            mdLog("[FOOTNOTE_DEBUG] 🔴 finishBlock executing, rendering \(pendingFootnotes.count) footnotes")

            // 1. 先渲染脚注（此时 TypewriterEngine 已完成，内容已全部显示）
            if !pendingFootnotes.isEmpty {
                let containerWidth = self.bounds.width > 0 ? self.bounds.width : UIScreen.main.bounds.width - 32
                self.updateFootnotes(pendingFootnotes, width: containerWidth, newElementCount: self.oldElements.count)
                mdLog("📝 [RealStream] Processed \(pendingFootnotes.count) footnotes at end")
            }

            // 2. 重置状态
            self.isRealStreamingMode = false
            self.isStreaming = false
            self.useSmartBufferMode = false
            self.stopHapticFeedback()
            mdLog("[FOOTNOTE_DEBUG] 🔴 isRealStreamingMode set to FALSE")

            // 3. 通知最终高度
            self.notifyHeightChange()
            self.streamPerformanceDiagnostics.end(
                pendingModules: self.realStreamParseInFlightCount,
                pendingViews: self.pendingRealStreamElements.count,
                typewriter: self.typewriterEngine.outstandingTaskCount,
                arrangedSubviews: self.contentStackView.arrangedSubviews.count
            )

            // 4. 触发完成回调（先内部回调，再外部回调）
            pendingCompletion?()
            externalCompletion?()

            let elapsed = (CFAbsoluteTimeGetCurrent() - self.streamingStartTimestamp) * 1000
            mdLog("✅ [RealStream] Completed in \(String(format: "%.1f", elapsed))ms")
            mdLog("Full text is:\n\(self.realStreamAccumulatedText)")
        }

        realStreamDrainCompletion = finishBlock
        scheduleRealStreamRenderPump()
        tryFinishRealStreamDrain()
    }

    func tryFinishRealStreamDrain() {
        guard let completion = realStreamDrainCompletion,
              realStreamParseInFlightCount == 0,
              pendingRealStreamElements.isEmpty,
              !realStreamRenderPumpScheduled,
              typewriterEngine.isIdle else { return }

        realStreamDrainCompletion = nil
        completion()
    }

    // MARK: - ⭐️ 暂停/恢复显示 API

    /// 暂停显示更新（停止 UI 刷新，但保留流式状态）
    /// 适用场景：用户滚动到上方阅读时，避免底部流式输出导致的 UI 闪烁
    public func pauseDisplayUpdates() {
        guard isStreaming, !isPausedForDisplay else { return }

        isPausedForDisplay = true
        // 停止 Timer，避免继续追加 token
        streamTimer?.invalidate()
        streamTimer = nil
        // 注意：不设置 isStreaming = false，保留流式状态
    }

    /// 恢复显示更新（10倍速追赶）
    /// 快速流式输出剩余内容，避免一次性渲染卡顿
    public func resumeDisplayUpdates() {
        guard isStreaming, isPausedForDisplay else { return }

        isPausedForDisplay = false

        // ⭐️ 计算剩余内容
        let remainingTokens = streamTokens.count - streamTokenIndex

        if remainingTokens <= 0 {
            // 已经全部输出完毕
            // 1. ⚡️ 优化：如果有脚注，则延迟结束流式状态
            if cachedFootnoteView != nil || !streamParsedFootnotes.isEmpty {
                pendingFootnoteRender = true
                mdLog("🔖 [Footnotes] Deferred rendering (resume completed)")
                // 保持 isStreaming = true，直到脚注渲染完成
                return
            }

            // 2. 没有脚注，立即结束流式模式
            isStreaming = false
            // 3. 清理缓存（脚注已在上方延迟处理，这里仅清理缓存）
            clearViewCache()
            // 4. 触发完成回调
            onStreamComplete?()
            onStreamComplete = nil
            return
        }

        // ⭐️ 10倍速追赶（150ms间隔，50个token/次）
        // 相比暂停前的 15ms/5token，这是 10 倍速
        let catchUpChunkSize = 50
        let catchUpInterval: TimeInterval = 0.15

        streamTimer = Timer.scheduledTimer(withTimeInterval: catchUpInterval, repeats: true) { [weak self] _ in
            self?.appendNextTokensAtomic(count: catchUpChunkSize)
        }
    }

    func appendNextChunk(chunkSize: Int) {
        guard streamCurrentIndex < streamFullText.count else {
            stopStreaming()
            return
        }
        
        var endIndex = min(streamCurrentIndex + chunkSize, streamFullText.count)
        
        // 尝试在空格或换行处断开，更自然
        let searchEnd = min(endIndex + 10, streamFullText.count)
        let startIdx = streamFullText.index(streamFullText.startIndex, offsetBy: endIndex)
        let searchIdx = streamFullText.index(streamFullText.startIndex, offsetBy: searchEnd)
        let searchRange = startIdx..<searchIdx
        
        if let spaceRange = streamFullText.range(of: " ", range: searchRange) {
            endIndex = streamFullText.distance(from: streamFullText.startIndex, to: spaceRange.lowerBound) + 1
        }
        
        let index = streamFullText.index(streamFullText.startIndex, offsetBy: endIndex)
        markdown = String(streamFullText[..<index])
        streamCurrentIndex = endIndex
    }
    
    /// 向上查找宿主 UIScrollView
    func findEnclosingScrollView() -> UIScrollView? {
        var superview = self.superview
        while let current = superview {
            if let sv = current as? UIScrollView { return sv }
            superview = current.superview
        }
        return nil
    }

    /// 滚动到底部
    public func scrollToBottom(animated: Bool = true) {
        guard let sv = findEnclosingScrollView() else { return }

        let bottomOffset = CGPoint(
            x: 0,
            y: max(0, sv.contentSize.height - sv.bounds.height + sv.contentInset.bottom)
        )
        sv.setContentOffset(bottomOffset, animated: animated)
    }

    /// 滚动到顶部
    public func scrollToTop(animated: Bool = true) {
        guard let sv = findEnclosingScrollView() else { return }
        sv.setContentOffset(CGPoint(x: 0, y: -sv.contentInset.top), animated: animated)
    }
    
}
