//
//  MarkdownViewTextKit+FakeStreaming.swift
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
    // 增加 onStart 参数：通知外部"分词完成，马上开始喷字"
    // 方法签名中增加 onStart 和 onComplete
    public func startStreaming(
            _ text: String,
            unit: StreamingUnit = .word,
            unitsPerChunk: Int = 1,
            interval: TimeInterval = 0.05,
            autoScrollBottom: Bool = false,
            onStart: (() -> Void)? = nil,
            onComplete: (() -> Void)? = nil
        ) {
            autoScrollEnabled = autoScrollBottom
            userScrolledAway = false
            stopStreaming()
            isStreaming = true
            self.onStreamComplete = onComplete

            // ⚡️ 初始化流式显示状态
            streamPreParseCompleted = false
            streamDisplayedCount = 0
            streamParsedElements = []
            streamTotalTextLength = text.count
            fakeStreamLastSafePosition = 0
            fakeStreamUseIncrementalParse = true
            fakeStreamLastParseTime = 0
            fakeStreamParseScheduled = false
            fakeStreamChunks = []
            fakeStreamChunkIndex = 0
            fakeStreamParsedText = ""

            let streamStartTime = CFAbsoluteTimeGetCurrent()
            self.streamingStartTimestamp = streamStartTime  // ⭐️ 保存流式开始时间
            self.firstLatexShown = false  // ⭐️ 重置首个公式标记

            // 准备震动反馈
            prepareHapticFeedback()

            mdLog("[STREAM] ========== START ==========")
            mdLog("[STREAM] 开始流式，文本长度: \(text.count) 字符")

            // ⭐️ 新方案：后台预解析整个文本 + 分段显示
            let containerWidth = currentContainerWidthForParsing()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                let parseStartTime = CFAbsoluteTimeGetCurrent()
                mdLog("[STREAM] 后台解析开始...")

                // 1. 预处理脚注
                let (processedMarkdown, footnotes) = self.preprocessFootnotes(text)
                let footnoteTime = CFAbsoluteTimeGetCurrent() - parseStartTime
                mdLog("[STREAM] 脚注预处理完成: \(String(format: "%.1f", footnoteTime * 1000))ms")

                // 2. 一次性解析整个文本
                let markdownParseStart = CFAbsoluteTimeGetCurrent()
                let config = self.configuration
                let renderer = MarkdownRenderer(configuration: config, containerWidth: containerWidth)
                let (elements, attachments, tocItems, tocId) = renderer.render(processedMarkdown)
                let markdownParseTime = CFAbsoluteTimeGetCurrent() - markdownParseStart
                mdLog("[STREAM] Markdown解析完成: \(elements.count) 个元素, 耗时 \(String(format: "%.1f", markdownParseTime * 1000))ms")

                // 3. 按标题分割，计算每个分片包含的元素范围
                let chunkRanges = self.calculateChunkElementRanges(
                    text: processedMarkdown,
                    elements: elements
                )

                let totalParseTime = CFAbsoluteTimeGetCurrent() - parseStartTime
                mdLog("[STREAM] 后台解析全部完成: \(chunkRanges.count) 个分片, 总耗时 \(String(format: "%.1f", totalParseTime * 1000))ms")

                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isStreaming else { return }

                    let mainThreadStart = CFAbsoluteTimeGetCurrent()
                    mdLog("[STREAM] 主线程开始显示...")

                    // 保存解析结果
                    self.streamParsedFootnotes = footnotes
                    self.streamParsedElements = elements
                    self.streamParsedAttachments = attachments
                    self.imageAttachments = attachments
                    self.tableOfContents = tocItems
                    self.tocSectionId = tocId
                    self.fakeStreamParsedText = processedMarkdown
                    self.streamFullText = processedMarkdown
                    self.streamPreParseCompleted = true

                    // 开始分段显示
                    self.displayChunksSequentially(
                        chunkRanges: chunkRanges,
                        currentIndex: 0,
                        onStart: onStart,
                        streamStartTime: streamStartTime
                    )
                }
            }
        }

        /// ⭐️ 新增：计算每个分片对应的元素范围
        func calculateChunkElementRanges(
            text: String,
            elements: [MarkdownRenderElement]
        ) -> [(startIndex: Int, endIndex: Int)] {
            let totalElements = elements.count

            // ⭐️ 优化：设置合理的分片参数
            let maxChunks = 20           // 最多20个分片，避免过多延迟
            let minElementsPerChunk = 8  // 每片至少8个元素

            // 计算合适的分片数量
            let idealChunkCount = max(1, totalElements / minElementsPerChunk)
            let chunkCount = min(idealChunkCount, maxChunks)
            let elementsPerChunk = max(minElementsPerChunk, totalElements / chunkCount)

            mdLog("[STREAM] 分片策略: 总元素 \(totalElements), 分片数 \(chunkCount), 每片约 \(elementsPerChunk) 个元素")

            var ranges: [(startIndex: Int, endIndex: Int)] = []
            var currentStart = 0

            for i in 0..<chunkCount {
                let isLastChunk = (i == chunkCount - 1)
                let endIndex = isLastChunk ? totalElements : min(currentStart + elementsPerChunk, totalElements)

                if currentStart < endIndex {
                    ranges.append((currentStart, endIndex))
                    currentStart = endIndex
                }
            }

            // 确保所有元素都被包含
            if currentStart < totalElements {
                if ranges.isEmpty {
                    ranges.append((currentStart, totalElements))
                } else {
                    // 扩展最后一个分片
                    let last = ranges.removeLast()
                    ranges.append((last.startIndex, totalElements))
                }
            }

            return ranges
        }

        /// ⭐️ 新增：按顺序显示分片
        func displayChunksSequentially(
            chunkRanges: [(startIndex: Int, endIndex: Int)],
            currentIndex: Int,
            onStart: (() -> Void)?,
            streamStartTime: CFAbsoluteTime
        ) {
            guard isStreaming else { return }
            guard currentIndex < chunkRanges.count else {
                // 所有分片显示完成
                let elapsed = (CFAbsoluteTimeGetCurrent() - streamStartTime) * 1000
                mdLog("[STREAM] 所有分片显示完成, 总耗时: \(String(format: "%.1f", elapsed))ms")
                finishChunkedParsing()
                return
            }

            let range = chunkRanges[currentIndex]
            let isFirstChunk = (currentIndex == 0)
            let chunkStartTime = CFAbsoluteTimeGetCurrent()

            mdLog("[STREAM] 显示分片 \(currentIndex + 1)/\(chunkRanges.count): 元素 \(range.startIndex)..<\(range.endIndex)")

            // 显示当前分片的元素
            let containerWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32

            var latexCount = 0
            var latexTotalTime: Double = 0

            for i in range.startIndex..<range.endIndex {
                guard i < streamParsedElements.count else { break }
                let element = streamParsedElements[i]

                let viewStartTime = CFAbsoluteTimeGetCurrent()
                let view = createView(for: element, containerWidth: containerWidth)
                let viewTime = CFAbsoluteTimeGetCurrent() - viewStartTime

                // 记录 LaTeX 创建时间
                if case .latex = element {
                    latexCount += 1
                    latexTotalTime += viewTime
                    mdLog("[STREAM] LaTeX #\(latexCount) 创建耗时: \(String(format: "%.1f", viewTime * 1000))ms")
                }

                view.tag = 1000 + i

                if enableTypewriterEffect {
                    view.isHidden = true
                    contentStackView.addArrangedSubview(view)
                    typewriterEngine.enqueue(view: view)
                } else {
                    contentStackView.addArrangedSubview(view)
                }

                // 注册 heading
                if case .heading(let id, _) = element {
                    headingViews[id] = view
                    if id == tocSectionId { tocSectionView = view }
                }
            }

            let chunkTime = CFAbsoluteTimeGetCurrent() - chunkStartTime
            mdLog("[STREAM] 分片 \(currentIndex + 1) 完成: \(range.endIndex - range.startIndex) 个元素, 耗时 \(String(format: "%.1f", chunkTime * 1000))ms" +
                  (latexCount > 0 ? ", 其中 \(latexCount) 个LaTeX耗时 \(String(format: "%.1f", latexTotalTime * 1000))ms" : ""))

            streamDisplayedCount = range.endIndex
            oldElements = Array(streamParsedElements.prefix(range.endIndex))

            // 第一个分片显示后触发 onStart
            if isFirstChunk {
                let elapsed = (CFAbsoluteTimeGetCurrent() - streamStartTime) * 1000
                mdLog("[STREAM] 首个分片完成，触发 onStart, 从开始到现在: \(String(format: "%.1f", elapsed))ms")
                onStart?()
            }

            if enableTypewriterEffect {
                typewriterEngine.start()
            }

            notifyHeightChange()

            // 延迟显示下一个分片（给 UI 喘息时间）
            // ⭐️ 优化：从50ms降到20ms，配合最多20个分片，最大延迟 = 20 × 20ms = 400ms
            let elapsedSoFar = (CFAbsoluteTimeGetCurrent() - streamStartTime) * 1000
            mdLog("[STREAM] ⏱️ 准备显示分片 \(currentIndex + 2)/\(chunkRanges.count), 已累计耗时: \(String(format: "%.1f", elapsedSoFar))ms, 即将等待20ms...")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.displayChunksSequentially(
                    chunkRanges: chunkRanges,
                    currentIndex: currentIndex + 1,
                    onStart: nil,  // onStart 只在第一个分片触发
                    streamStartTime: streamStartTime
                )
            }
        }

        /// 将 Markdown 文本按标题分成多个模块（智能分片）
        func splitIntoChunks(_ text: String) -> [String] {
            var chunks: [String] = []

            // 使用正则匹配标题行（# ## ### 等）
            // 匹配行首的 1-6 个 # 后跟空格和内容
            let headingPattern = "(?m)^(#{1,6})\\s+.+"

            guard let regex = try? NSRegularExpression(pattern: headingPattern, options: []) else {
                // 正则失败，返回整个文本作为一个分片
                return [text]
            }

            let nsText = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

            if matches.isEmpty {
                // 没有标题，返回整个文本
                return [text]
            }

            // 提取所有标题位置
            var headingPositions: [(location: Int, level: Int)] = []
            for match in matches {
                let headingLine = nsText.substring(with: match.range)
                // 计算标题级别（# 的数量）
                var level = 0
                for char in headingLine {
                    if char == "#" {
                        level += 1
                    } else {
                        break
                    }
                }
                headingPositions.append((match.range.location, level))
            }

            // 按标题位置分割文本
            for (index, heading) in headingPositions.enumerated() {
                let startPos = heading.location
                let endPos: Int

                if index + 1 < headingPositions.count {
                    // 下一个标题的位置
                    endPos = headingPositions[index + 1].location
                } else {
                    // 最后一个标题，到文本末尾
                    endPos = nsText.length
                }

                let chunkRange = NSRange(location: startPos, length: endPos - startPos)
                let chunk = nsText.substring(with: chunkRange)

                if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append(chunk)
                }
            }

            // 如果第一个标题之前有内容，添加为第一个分片
            if let firstHeading = headingPositions.first, firstHeading.location > 0 {
                let prefixRange = NSRange(location: 0, length: firstHeading.location)
                let prefix = nsText.substring(with: prefixRange)
                if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.insert(prefix, at: 0)
                }
            }

            mdLog("📦 [Fake-Stream] Split by headings: \(chunks.count) chunks")
            for (i, chunk) in chunks.enumerated() {
                let firstLine = chunk.components(separatedBy: .newlines).first ?? ""
                let preview = String(firstLine.prefix(50))
                mdLog("  ├─ Chunk[\(i)]: \"\(preview)...\" (\(chunk.count) chars)")
            }

            return chunks
        }

        /// 解析下一个片段
        /// ⭐️ 重构：分片解析完成后直接显示，不再需要 token 流式
        func parseNextChunk(
            fullText: String,
            unit: StreamingUnit,
            unitsPerChunk: Int,
            interval: TimeInterval,
            onStart: (() -> Void)?
        ) {
            guard isStreaming else { return }
            guard fakeStreamChunkIndex < fakeStreamChunks.count else {
                // ⭐️ 所有片段解析完成，直接结束流式（不再启动 token 流式）
                mdLog("✅ [Fake-Stream] All chunks parsed, finishing stream...")
                finishChunkedParsing()
                return
            }

            let chunkToAdd = fakeStreamChunks[fakeStreamChunkIndex]
            fakeStreamChunkIndex += 1

            // 累积已解析的文本
            fakeStreamParsedText += chunkToAdd

            let textToParse = fakeStreamParsedText
            let isFirstChunk = (fakeStreamChunkIndex == 1)

            mdLog("📝 [Fake-Stream] Parsing chunk \(fakeStreamChunkIndex)/\(fakeStreamChunks.count)...")

            // 后台解析当前累积的文本
            let containerWidth = currentContainerWidthForParsing()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                let parseStartTime = CFAbsoluteTimeGetCurrent()

                let config = self.configuration
                let renderer = MarkdownRenderer(configuration: config, containerWidth: containerWidth)
                let (elements, attachments, tocItems, tocId) = renderer.render(textToParse)

                let parseDuration = CFAbsoluteTimeGetCurrent() - parseStartTime

                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isStreaming else { return }

                    let previousCount = self.streamParsedElements.count
                    let newElements = Array(elements.dropFirst(previousCount))

                    mdLog("✅ [Fake-Stream] Chunk \(self.fakeStreamChunkIndex) parsed: +\(newElements.count) elements, " +
                          "total: \(elements.count), time: \(String(format: "%.1f", parseDuration * 1000))ms")

                    // 更新解析结果
                    self.streamParsedElements = elements
                    self.streamParsedAttachments = attachments
                    self.imageAttachments = attachments
                    self.tableOfContents = tocItems
                    self.tocSectionId = tocId

                    // ⭐️ 第一个分片解析完成时触发 onStart
                    if isFirstChunk {
                        onStart?()
                    }

                    // 显示新元素（立即触发 TypewriterEngine 动画）
                    if !newElements.isEmpty {
                        self.displayNewStreamElements()
                    }

                    // ⭐️ 继续解析下一个分片（移除对 startTokenStreamingAfterParse 的调用）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                        self?.parseNextChunk(fullText: fullText, unit: unit, unitsPerChunk: unitsPerChunk, interval: interval, onStart: onStart)
                    }
                }
            }
        }

        /// ⭐️ 新增：分片解析完成后的收尾工作
        func finishChunkedParsing() {
            guard isStreaming else { return }

            // 1. ⭐️ 先设置 markdown 和 streamFullText（此时 isStreaming 还是 true，scheduleRerender 会跳过）
            markdown = fakeStreamParsedText
            streamFullText = fakeStreamParsedText  // ⭐️ 修复：确保 performFinalParse 使用正确的文本

            // ⚠️ 注意：不要在这里设置 isStreaming = false
            // 而是在 finishBlock 执行完毕后才设置，确保整个显示过程中滚动都能正常工作

            mdLog("🎉 [Fake-Stream] All chunks parsed, waiting for TypewriterEngine to finish...")

            // 3. ⭐️ 核心修复：脚注必须等 TypewriterEngine 动画完成后再渲染
            //    否则会出现"目录渲染完脚注就出来了"的问题
            let footnotes = streamParsedFootnotes
            let completionHandler = onStreamComplete

            // 定义收尾逻辑（脚注渲染 + 最终解析 + 回调）
            let finishBlock: () -> Void = { [weak self] in
                guard let self = self else { return }

                // ⚠️ 现在才标记流式结束
                self.isStreaming = false

                // 渲染脚注（最后才渲染）
                if !footnotes.isEmpty {
                    let containerWidth = self.bounds.width > 0 ? self.bounds.width : UIScreen.main.bounds.width - 32
                    let elementCount = self.streamParsedElements.count
                    mdLog("🔖 [Footnotes] TypewriterEngine finished, rendering \(footnotes.count) footnote(s) now")
                    self.updateFootnotes(footnotes, width: containerWidth, newElementCount: elementCount)
                }

                // 执行最终解析确保 TOC 完整
                self.performFinalParse()

                // 触发完成回调
                completionHandler?()

                mdLog("🎉 [Fake-Stream] Streaming completed!")
            }

            // ⭐️ 关键检查：如果 TypewriterEngine 已经空闲，直接执行收尾逻辑
            if typewriterEngine.isIdle {
                mdLog("📌 [Fake-Stream] TypewriterEngine already idle, executing finish block immediately")
                finishBlock()
            } else {
                // TypewriterEngine 还在运行，设置完成回调
                let originalOnComplete = typewriterEngine.onComplete
                typewriterEngine.onComplete = { [weak self] in
                    // 恢复原回调
                    self?.typewriterEngine.onComplete = originalOnComplete
                    originalOnComplete?()

                    // 执行收尾逻辑
                    finishBlock()
                }
            }

            // 清理外部回调引用
            onStreamComplete = nil
        }

        /// 分片解析完成后启动 Token 流式
        func startTokenStreamingAfterParse(
            _ text: String,
            unit: StreamingUnit,
            unitsPerChunk: Int,
            interval: TimeInterval,
            onStart: (() -> Void)?
        ) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                let fullText = text
                let tokens = self.tokenize(fullText, unit: unit)
                let atomicRanges = self.calculateAtomicRanges(in: fullText)

                DispatchQueue.main.async {
                    guard self.isStreaming else { return }

                    self.currentStreamingUnit = unit
                    self.markdown = ""
                    onStart?()

                    self.streamFullText = fullText
                    self.streamTokens = tokens
                    self.streamAtomicRanges = atomicRanges
                    self.atomicRangeStartSet = Set(atomicRanges.map { $0.location })
                    self.streamTokenIndex = 0

                    // 预渲染脚注
                    self.prerenderFootnotesInBackground(fullText: fullText)

                    // 启动 Timer（使用原有的 appendNextTokensAtomic）
                    self.streamTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                        self?.appendNextTokensAtomic(count: unitsPerChunk)
                    }
                }
            }
        }

        /// 开始增量解析模式的 Token 流式追加（保留但不再使用）
        func startTokenStreamingIncremental(
            _ text: String,
            unit: StreamingUnit,
            unitsPerChunk: Int,
            interval: TimeInterval,
            onStart: (() -> Void)?
        ) {
            // 已被 parseNextChunk + startTokenStreamingAfterParse 替代
        }

        /// 智能追加 Token + 增量解析（保留但不再使用）
        func appendNextTokensWithIncrementalParse(count: Int) {
            // 已被 appendNextTokensAtomic 替代
        }

        /// 触发增量解析（节流模式：每 200ms 最多解析一次）
        func triggerIncrementalParseIfNeeded() {
            // 分片解析模式下不需要此方法
        }

        /// 执行假流式的增量解析
        func performIncrementalParseForFakeStream() {
            // 分片解析模式下不需要此方法
        }

        /// 显示新解析出的元素（使用 TypewriterEngine）
        func displayNewStreamElements() {
            guard streamDisplayedCount < streamParsedElements.count else { return }

            let containerWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32

            mdLog("📺 [Fake-Stream] Showing elements \(streamDisplayedCount)..<\(streamParsedElements.count)")

            for i in streamDisplayedCount..<streamParsedElements.count {
                let element = streamParsedElements[i]
                mdLog("  ├─ Element[\(i)]: \(elementTypeString(element))")

                let view = createView(for: element, containerWidth: containerWidth)
                view.tag = 1000 + i

                // ⭐️ 恢复：所有元素都走 TypewriterEngine，保持统一的动画节奏
                if enableTypewriterEffect {
                    view.isHidden = true
                    contentStackView.addArrangedSubview(view)
                    typewriterEngine.enqueue(view: view)
                } else {
                    contentStackView.addArrangedSubview(view)
                }

                // 注册 heading
                if case .heading(let id, _) = element {
                    headingViews[id] = view
                    if id == tocSectionId { tocSectionView = view }
                }
            }

            streamDisplayedCount = streamParsedElements.count
            oldElements = streamParsedElements

            if enableTypewriterEffect {
                typewriterEngine.start()
            }

            notifyHeightChange()
        }

        /// 判断是否为块级元素（保留方法，供后续使用）
        func isBlockLevelElement(_ element: MarkdownRenderElement) -> Bool {
            switch element {
            case .latex, .table, .codeBlock, .image, .thematicBreak, .rawHTML:
                return true
            case .details, .list, .quote:
                return true
            case .heading, .attributedText:
                return false
            case .custom:
                return true  // 自定义元素默认作为块级元素
            }
        }

        /// 最终完整解析（确保所有元素都正确显示）
        func performFinalParse() {
            let fullText = streamFullText
            let containerWidth = currentContainerWidthForParsing()

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                let config = self.configuration
                let renderer = MarkdownRenderer(configuration: config, containerWidth: containerWidth)
                let (elements, attachments, tocItems, tocId) = renderer.render(fullText)

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    // 检查是否有遗漏的元素
                    if elements.count > self.streamParsedElements.count {
                        mdLog("🔧 [Fake-Stream] Final parse found \(elements.count - self.streamParsedElements.count) missing elements")

                        // 添加遗漏的元素
                        let containerWidth = self.bounds.width > 0 ? self.bounds.width : UIScreen.main.bounds.width - 32

                        for i in self.streamParsedElements.count..<elements.count {
                            let element = elements[i]
                            let view = self.createView(for: element, containerWidth: containerWidth)
                            view.tag = 1000 + i

                            if self.enableTypewriterEffect {
                                view.isHidden = true
                                self.contentStackView.addArrangedSubview(view)
                                self.typewriterEngine.enqueue(view: view)
                            } else {
                                self.contentStackView.addArrangedSubview(view)
                            }

                            if case .heading(let id, _) = element {
                                self.headingViews[id] = view
                                if id == tocId { self.tocSectionView = view }
                            }
                        }

                        self.streamParsedElements = elements
                        self.streamDisplayedCount = elements.count

                        if self.enableTypewriterEffect {
                            self.typewriterEngine.start()
                        }
                    }

                    self.imageAttachments = attachments
                    self.tableOfContents = tocItems
                    self.tocSectionId = tocId
                    self.oldElements = elements

                    self.notifyHeightChange()
                }
            }
        }

}
