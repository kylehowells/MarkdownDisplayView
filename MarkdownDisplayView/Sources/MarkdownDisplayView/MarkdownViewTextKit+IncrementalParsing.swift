//
//  MarkdownViewTextKit+IncrementalParsing.swift
//  MarkdownDisplayView
//
//  Mechanical extension split from MarkdownDisplayView.swift.
//

import UIKit
import Foundation

@available(iOS 15.0, *)
extension MarkdownViewTextKit {
    // MARK: - Incremental Parsing

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
