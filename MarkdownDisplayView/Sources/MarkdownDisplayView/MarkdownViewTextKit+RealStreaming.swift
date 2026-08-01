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

        // 清空现有内容
        markdown = ""
        oldElements = []
        contentStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        headingViews.removeAll()
        tocSectionView = nil

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
    func enqueueSmartStreamModule(_ moduleText: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRealStreamingMode else { return }

        realStreamAccumulatedText += moduleText + "\n\n"
        realStreamParseInFlightCount += 1
        renderVersionLock.lock()
        let currentRenderVersion = renderVersion
        renderVersionLock.unlock()
        pendingSmartStreamModules.append(PendingSmartStreamModule(
            text: moduleText,
            renderVersion: currentRenderVersion,
            renderGeneration: realStreamRenderGeneration
        ))
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

                let (elements, attachments, tocItems, tocId) = result
                let previousElementCount = self.realStreamParsedElementCount
                self.realStreamParsedElementCount += elements.count
                self.imageAttachments.append(contentsOf: attachments)
                self.tableOfContents.append(contentsOf: tocItems)
                if let tocId { self.tocSectionId = tocId }

                mdLog("✅ [SmartBuffer] Parsed module: \(elements.count) elements, parse: \(String(format: "%.1f", parseDuration))ms, UI backlog: \(self.pendingRealStreamElements.count), typewriter: \(self.typewriterEngine.outstandingTaskCount)")
                if !elements.isEmpty {
                    self.displayRealStreamElements(elements, startIndex: previousElementCount)
                }
                self.startNextSmartStreamParseIfPossible()
                self.tryFinishRealStreamDrain()
            }
        }
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

        // 累积文本
        realStreamAccumulatedText += block

        // 异步解析新增内容
        parseAndDisplayNewContent()
    }

    /// 解析并显示新增内容
    func parseAndDisplayNewContent() {
        let textToParse = realStreamAccumulatedText
        let previousElementCount = realStreamParsedElementCount
        let containerWidth = currentContainerWidthForParsing()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, self.isRealStreamingMode else { return }

            let parseStart = CFAbsoluteTimeGetCurrent()

            // ⭐️ 关键修复：必须预处理脚注，移除脚注定义（如 [^1]: xxx）
            // 否则脚注定义会被 MarkdownParser 当作普通文本解析并渲染
            // 注意：这里只移除脚注定义，不保存脚注用于渲染
            // 脚注的实际渲染在 endRealStreaming() 中进行
            let (processedText, removedFootnotes) = self.preprocessFootnotes(textToParse)

            // [FOOTNOTE_DEBUG] 检查脚注预处理
            if !removedFootnotes.isEmpty {
                mdLog("[FOOTNOTE_DEBUG] 📋 parseAndDisplayNewContent: preprocessFootnotes removed \(removedFootnotes.count) footnotes")
                mdLog("[FOOTNOTE_DEBUG] 📋 Original length: \(textToParse.count), Processed length: \(processedText.count)")
            }

            // 解析 Markdown
            let config = self.configuration
            let renderer = MarkdownRenderer(configuration: config, containerWidth: containerWidth)
            let (elements, attachments, tocItems, tocId) = renderer.render(processedText)

            let parseDuration = (CFAbsoluteTimeGetCurrent() - parseStart) * 1000

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRealStreamingMode else { return }

                // 计算新增的元素
                let newElementCount = elements.count
                let addedElements = Array(elements.dropFirst(previousElementCount))

                mdLog("✅ [RealStream] Parsed: +\(addedElements.count) elements (total: \(newElementCount)), time: \(String(format: "%.1f", parseDuration))ms")

                // [CODEBLOCK_DEBUG] 打印新增元素类型
                for (idx, elem) in addedElements.enumerated() {
                    switch elem {
                    case .codeBlock(let lang, _):
                        mdLog("[CODEBLOCK_DEBUG] 🟢 Added codeBlock[\(previousElementCount + idx)]: lang=\(lang ?? "nil")")
                    case .heading(let id, let attr):
                        mdLog("[CODEBLOCK_DEBUG] 📌 Added heading[\(previousElementCount + idx)]: id=\(id), text=\(attr.string.prefix(30))")
                    case .attributedText(let attr):
                        let preview = attr.string.prefix(50).replacingOccurrences(of: "\n", with: "⏎")
                        mdLog("[CODEBLOCK_DEBUG] 📝 Added text[\(previousElementCount + idx)]: \(preview)")
                    default:
                        mdLog("[CODEBLOCK_DEBUG] ➕ Added element[\(previousElementCount + idx)]: \(String(describing: elem).prefix(50))")
                    }
                }

                // ⭐️ 关键修复：检测已有元素内容变化并更新视图
                // 解决代码块分块到达时第一次为空、后续内容不更新的问题
                self.updateExistingElementsIfNeeded(elements: elements, previousCount: previousElementCount)

                // 更新状态（不更新脚注，脚注在 endRealStreaming 中处理）
                self.realStreamParsedElementCount = newElementCount
                // self.streamParsedFootnotes = footnotes  // ⚠️ 移除，不在这里处理脚注
                self.imageAttachments = attachments
                self.tableOfContents = tocItems
                self.tocSectionId = tocId

                // 显示新增元素
                if !addedElements.isEmpty {
                    self.displayRealStreamElements(addedElements, startIndex: previousElementCount)
                }
            }
        }
    }

    /// 显示真流式新增的元素
    func displayRealStreamElements(_ elements: [MarkdownRenderElement], startIndex: Int) {
        guard useSmartBufferMode else {
            displayLegacyRealStreamElements(elements, startIndex: startIndex)
            return
        }

        for (index, element) in elements.enumerated() {
            pendingRealStreamElements.append(PendingRealStreamElement(element: element, globalIndex: startIndex + index))
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
            scheduleHeightChangeNotification()
            handleAutoScroll()
            mdLog("⚙️ [SmartBuffer] UI frame: created=\(createdCount), cost=\(String(format: "%.1f", (CACurrentMediaTime() - frameStart) * 1000))ms, pendingViews=\(pendingRealStreamElements.count), typewriter=\(typewriterEngine.outstandingTaskCount)")
        }

        if !realStreamBackpressureActive { scheduleRealStreamRenderPump() }
        startNextSmartStreamParseIfPossible()
        tryFinishRealStreamDrain()
    }

    /// 检测并更新已有元素的内容变化
    /// 解决代码块、LaTeX 等块级元素分块到达时内容不更新的问题
    func updateExistingElementsIfNeeded(elements: [MarkdownRenderElement], previousCount: Int) {
        let containerWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32

        // 分帧创建期间，解析结果可能先更新尚未建 View 的元素。直接合并到待创建命令，
        // 避免先创建旧版本、下一轮又找不到对应 arrangedSubview。
        pendingRealStreamElements.updateEach { pending in
            guard pending.globalIndex < min(previousCount, elements.count) else { return }
            pending.element = elements[pending.globalIndex]
        }

        // 只检查已有的元素（索引 < previousCount）
        for i in 0..<min(previousCount, elements.count, oldElements.count) {
            let newElement = elements[i]
            let oldElement = oldElements[i]

            // 检查代码块内容是否有变化（长度增加）
            if case .codeBlock(let newLang, let newAttr) = newElement,
               case .codeBlock(_, let oldAttr) = oldElement {
                // 如果新内容比旧内容长，需要更新视图
                if newAttr.length > oldAttr.length {
                    mdLog("[CODEBLOCK_DEBUG] 🔄 Updating codeBlock[\(i)]: \(oldAttr.length) -> \(newAttr.length) chars, lang=\(newLang ?? "nil")")
                    updateElementView(at: i, with: newElement, containerWidth: containerWidth)
                    oldElements[i] = newElement
                }
            }

            // 检查 LaTeX 内容是否有变化
            if case .latex(let newLatex) = newElement,
               case .latex(let oldLatex) = oldElement {
                if newLatex.count > oldLatex.count {
                    mdLog("[CODEBLOCK_DEBUG] 🔄 Updating latex[\(i)]: \(oldLatex.count) -> \(newLatex.count) chars")
                    updateElementView(at: i, with: newElement, containerWidth: containerWidth)
                    oldElements[i] = newElement
                }
            }

            // 检查 attributedText 内容变化
            if case .attributedText(let newAttr) = newElement,
               case .attributedText(let oldAttr) = oldElement {
                let newInline = newAttr.attribute(inlineSegmentAttributeKey, at: 0, effectiveRange: nil) != nil
                let oldInline = oldAttr.attribute(inlineSegmentAttributeKey, at: 0, effectiveRange: nil) != nil
                if newAttr.string != oldAttr.string || newInline != oldInline {
                    mdLog("[CODEBLOCK_DEBUG] 🔄 Updating text[\(i)]: \(oldAttr.length) -> \(newAttr.length) chars")
                    updateElementView(at: i, with: newElement, containerWidth: containerWidth)
                    oldElements[i] = newElement
                }
            }
        }
    }

    /// 更新指定索引处的元素视图
    func updateElementView(at index: Int, with element: MarkdownRenderElement, containerWidth: CGFloat) {
        let viewTag = 1000 + index

        // 查找对应的视图
        guard let oldView = contentStackView.arrangedSubviews.first(where: { $0.tag == viewTag }) else {
            mdLog("[CODEBLOCK_DEBUG] ⚠️ Cannot find view with tag \(viewTag) for update")
            return
        }

        // 获取旧视图在 StackView 中的索引
        guard let stackIndex = contentStackView.arrangedSubviews.firstIndex(of: oldView) else {
            mdLog("[CODEBLOCK_DEBUG] ⚠️ Cannot find stackIndex for view with tag \(viewTag)")
            return
        }

        // 创建新视图
        let newView = createView(for: element, containerWidth: containerWidth)
        newView.tag = viewTag

        // 检查旧视图是否在 TypewriterEngine 队列中
        let wasInQueue = typewriterEngine.isViewInQueue(oldView)
        let wasHidden = oldView.isHidden

        // 替换视图
        oldView.removeFromSuperview()
        contentStackView.insertArrangedSubview(newView, at: stackIndex)

        // 如果启用打字机效果且原视图还在队列中，将新视图加入队列
        if enableTypewriterEffect && wasInQueue {
            newView.isHidden = wasHidden
            typewriterEngine.replaceView(oldView, with: newView)
        }

        mdLog("[CODEBLOCK_DEBUG] ✅ View[\(index)] updated at stackIndex=\(stackIndex)")
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
