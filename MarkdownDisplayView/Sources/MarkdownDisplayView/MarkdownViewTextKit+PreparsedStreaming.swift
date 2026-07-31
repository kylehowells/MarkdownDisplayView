//
//  MarkdownViewTextKit+PreparsedStreaming.swift
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
    // MARK: - 预解析流式显示核心函数

    /// 基于当前字符进度更新流式显示（简化版：百分比映射 + 节流）
    func updateStreamDisplay() {
        guard streamPreParseCompleted else { return }
        guard streamTotalTextLength > 0 else { return }
        guard !streamParsedElements.isEmpty else { return }

        let currentLength = (markdown as NSString).length
        let containerWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32

        // 简单百分比映射（避免字符估算误差）
        let progress = Double(currentLength) / Double(streamTotalTextLength)
        var targetIndex = Int(Double(streamParsedElements.count) * progress)

        // 确保至少显示1个，最多显示全部
        targetIndex = max(1, min(streamParsedElements.count, targetIndex))

        var hasChanges = false

        // 显示新增的元素
        if targetIndex > streamDisplayedCount {
            // ⚡️ 公式优化：智能控制批次大小，避免一次性渲染太多公式导致卡顿
            var actualTargetIndex = streamDisplayedCount
            var elementsInBatch = 0
            var latexCountInBatch = 0
            let maxElementsPerBatch = 5  // 普通元素每次最多5个
            let maxLatexPerBatch = 2     // 公式每次最多2个

            // 智能计算实际显示到哪个索引
            for i in streamDisplayedCount..<targetIndex {
                let element = streamParsedElements[i]
                let isLatex = elementTypeString(element).contains("LaTeX")

                // 检查是否超过批次限制
                if isLatex {
                    if latexCountInBatch >= maxLatexPerBatch {
                        break  // 公式数量达到上限，停止本批次
                    }
                    latexCountInBatch += 1
                }

                elementsInBatch += 1
                actualTargetIndex = i + 1

                // 如果已经达到普通元素上限，停止
                if elementsInBatch >= maxElementsPerBatch {
                    break
                }
            }

            mdLog("📺 [Stream] Showing elements \(streamDisplayedCount)..<\(actualTargetIndex) (target: \(targetIndex), \(latexCountInBatch) LaTeX in batch)")
            for i in streamDisplayedCount..<actualTargetIndex {
                let element = streamParsedElements[i]
                mdLog("  ├─ Element[\(i)]: \(elementTypeString(element))")
                let view = createView(for: element, containerWidth: containerWidth)
                view.tag = 1000 + i
                
                // 3. ⭐️ 核心修改：如果是打字机模式，接管显示逻辑
                if enableTypewriterEffect {
                    // 🆕 先隐藏视图（不占高度），等待打字机队列来开启
                    view.isHidden = true
                    contentStackView.addArrangedSubview(view)
                    
                    // 将视图加入打字机队列 (enqueue 内部会将文字设透明 / Block设不可见)
                    // enqueue 会自动添加一个 .show 任务来 unhide
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

            streamDisplayedCount = actualTargetIndex
            oldElements = Array(streamParsedElements.prefix(streamDisplayedCount))
            hasChanges = true

            // 4. ⭐️ 启动打字机 (如果还没跑的话)
            if enableTypewriterEffect {
                typewriterEngine.start()
            }

            // ⚡️ 如果还有未显示的元素，继续触发下一批渲染
            if actualTargetIndex < targetIndex {
                // 如果本批次包含公式，延迟时间稍长一点，让公式渲染完成
                let delay: TimeInterval = latexCountInBatch > 0 ? 0.2 : 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.updateStreamDisplay()
                }
            }
        }

        // ⚡️ 流式结束时，显示所有剩余元素 + 脚注
        if currentLength >= streamTotalTextLength {
            // 显示剩余元素
            if streamDisplayedCount < streamParsedElements.count {
                mdLog("🎬 [Stream Complete] Showing remaining \(streamParsedElements.count - streamDisplayedCount) elements")

                for i in streamDisplayedCount..<streamParsedElements.count {
                    let element = streamParsedElements[i]
                    let view = createView(for: element, containerWidth: containerWidth)
                    view.tag = 1000 + i
                    
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
                }

                streamDisplayedCount = streamParsedElements.count
                oldElements = streamParsedElements
                hasChanges = true
                
                if enableTypewriterEffect {
                    typewriterEngine.start()
                }
            }

            // ⚡️ 优化：脚注渲染延迟到打字机动画完成后
            // 这样可以避免脚注过早出现影响自动滚动
            if !streamParsedFootnotes.isEmpty && !pendingFootnoteRender {
                pendingFootnoteRender = true
                mdLog("🔖 [Footnotes] Deferred rendering (stream complete in updateViews)")
            }
        }

        if hasChanges {
            notifyHeightChange()
        }
    }


    // MARK: - 增量解析优化

    /// 判断是否需要清空缓存并重新全量解析（仅用于非流式场景）
    func shouldInvalidateCache(newMarkdown: String, containerWidth: CGFloat) -> Bool {
        // 1. 内容变短（用户删除内容）
        if (newMarkdown as NSString).length < parseCache.lastParsedLength {
            return true
        }

        // 2. 宽度变化超过1pt（影响表格/代码块布局）
        if abs(containerWidth - cachedContainerWidth) > 1.0 {
            return true
        }

        // 3. 缓存为空（首次渲染）
        if parseCache.lastParsedLength == 0 {
            return true
        }

        return false
    }

    /// 执行增量解析（仅解析新增内容）
    func performIncrementalParse(
        fullText: String,
        config: MarkdownConfiguration,
        containerWidth: CGFloat,
        perfStartTime: CFAbsoluteTime
    ) {
        let newLength = (fullText as NSString).length
        let lastParsedLength = parseCache.lastParsedLength

        // 1️⃣ 计算上下文窗口（向前回溯，处理跨行结构如列表、引用块）
        // ⚡️ 性能优化：减小窗口避免过度解析（500 → 100）
        let contextWindowSize = 100  // 回溯100字符（足够捕获列表/引用块前缀）
        let parseStartIndex = max(0, lastParsedLength - contextWindowSize)

        // 2️⃣ 提取需要解析的片段
        let nsText = fullText as NSString
        let incrementalRange = NSRange(location: parseStartIndex, length: newLength - parseStartIndex)
        let incrementalText = nsText.substring(with: incrementalRange)

        let deltaSize = newLength - lastParsedLength
        let parseSize = incrementalText.count
        mdLog("⚡️ [Incremental] Range: \(parseStartIndex)..\(newLength) | Delta: \(deltaSize) chars | Parse: \(parseSize) chars (window: \(contextWindowSize))")
        mdLog("⚡️ [Incremental] Cache: \(parseCache.cachedElements.count) elements, \(lastParsedLength) chars")

        // 3️⃣ 异步解析增量内容
        renderQueue.async { [weak self] in
            guard let self else { return }

            let parseStart = CFAbsoluteTimeGetCurrent()

            // 预处理脚注
            let (processedIncremental, newFootnotes) = self.preprocessFootnotes(incrementalText)

            // 解析增量内容
            let renderer = MarkdownRenderer(configuration: config, containerWidth: containerWidth)
            let (incrementalElements, newAttachments, newTOCItems, newTocId) = renderer.render(processedIncremental)

            let parseEnd = CFAbsoluteTimeGetCurrent()
            let parseDuration = parseEnd - parseStart

            mdLog("⚡️ [Incremental] Parse completed: \(incrementalElements.count) elements in \(String(format: "%.1f", parseDuration * 1000))ms")

            // 4️⃣ 回到主线程合并结果
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                self.mergeIncrementalResults(
                    incrementalElements: incrementalElements,
                    contextWindowSize: contextWindowSize,
                    newFootnotes: newFootnotes,
                    newAttachments: newAttachments,
                    newTOCItems: newTOCItems,
                    newTocId: newTocId,
                    newLength: newLength,
                    containerWidth: containerWidth,
                    perfStartTime: perfStartTime,
                    parseDuration: parseDuration
                )
            }
        }
    }

    /// 智能合并增量解析结果
    func mergeIncrementalResults(
        incrementalElements: [MarkdownRenderElement],
        contextWindowSize: Int,
        newFootnotes: [MarkdownFootnote],
        newAttachments: [(attachment: MarkdownImageAttachment, urlString: String)],
        newTOCItems: [MarkdownTOCItem],
        newTocId: String?,
        newLength: Int,
        containerWidth: CGFloat,
        perfStartTime: CFAbsoluteTime,
        parseDuration: Double
    ) {
        // 🧩 合并策略：
        // ⚡️ 性能优化：流式渲染时不移除任何视图，只追加真正新增的元素

        let oldElementCount = parseCache.cachedElements.count

        // 1️⃣ 增量解析返回的元素包含：上下文窗口元素 + 新增元素
        // 我们需要跳过上下文窗口内的元素（已经渲染过了）

        // 计算上下文窗口可能对应的元素数量（保守估计1-2个）
        let contextOverlapEstimate = min(2, parseCache.cachedElements.count)

        // 2️⃣ 只追加真正新增的元素（跳过上下文重叠部分）
        let trueNewElements = incrementalElements.count > contextOverlapEstimate
            ? Array(incrementalElements.dropFirst(contextOverlapEstimate))
            : []

        mdLog("⚡️ [Incremental] Parsed \(incrementalElements.count) elements, skipping \(contextOverlapEstimate) overlap, adding \(trueNewElements.count) new")

        // 3️⃣ 追加新元素到缓存
        parseCache.cachedElements.append(contentsOf: trueNewElements)

        // 4️⃣ 只为真正新增的元素创建视图（避免重复创建）
        for element in trueNewElements {
            let view = createView(for: element, containerWidth: containerWidth)
            contentStackView.addArrangedSubview(view)
        }

        mdLog("⚡️ [Incremental] Total elements: \(parseCache.cachedElements.count), views: \(contentStackView.arrangedSubviews.count)")

        // 4️⃣ 合并其他数据
        parseCache.cachedFootnotes = newFootnotes
        parseCache.cachedAttachments.append(contentsOf: newAttachments)

        if !newTOCItems.isEmpty {
            parseCache.cachedTOCItems.append(contentsOf: newTOCItems)
        }
        parseCache.tocSectionId = newTocId ?? parseCache.tocSectionId
        parseCache.lastParsedLength = newLength

        // 5️⃣ 更新全局状态
        self.imageAttachments = parseCache.cachedAttachments
        self.tableOfContents = parseCache.cachedTOCItems
        self.tocSectionId = parseCache.tocSectionId

        // 6️⃣ 更新 oldElements 用于下次Diff（如果需要全量渲染）
        self.oldElements = parseCache.cachedElements

        // 7️⃣ 通知高度变化
        notifyHeightChange()
    }

}
