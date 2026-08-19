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

        // 4. 不是"追加"（前缀发生了变化：中间编辑/整体替换）
        //    hasPrefix 是 memcmp 级比较，远快于 cmark 解析，不会成为性能瓶颈。
        if !newMarkdown.hasPrefix(parseCache.parsedPrefix) {
            return true
        }

        return false
    }

    /// 是否可安全地做增量解析：旧内容以空行结尾（避免段落/列表/表格/引用跨边界合并），
    /// 且不存在未闭合的围栏/$$/details/自定义块。
    func canIncrementallyAppend(fullText: String) -> Bool {
        guard !parseCache.unclosedState.hasUnclosedStructure else { return false }
        let last = parseCache.lastParsedLength
        guard last >= 2 else { return false }
        let ns = fullText as NSString
        return ns.character(at: last - 1) == 0x0A && ns.character(at: last - 2) == 0x0A
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
        let stateBefore = parseCache.unclosedState

        // 只提取真正新增的内容（旧内容以空行结尾、无未闭合结构，故新内容从干净边界开始）
        let nsText = fullText as NSString
        let deltaRange = NSRange(location: lastParsedLength, length: newLength - lastParsedLength)
        let deltaText = nsText.substring(with: deltaRange)

        mdLog("⚡️ [Incremental] Delta: \(deltaText.count) chars (from \(lastParsedLength) to \(newLength))")

        renderQueue.async { [weak self] in
            guard let self else { return }

            let parseStart = CFAbsoluteTimeGetCurrent()

            // 预处理脚注（脚注变换是局部的，增量子串与全量结果一致）
            let (processedDelta, newFootnotes) = self.preprocessFootnotes(deltaText)

            let renderer = MarkdownRenderer(configuration: config, containerWidth: containerWidth)
            let (incrementalElements, newAttachments, newTOCItems, newTocId) = renderer.render(processedDelta)

            // 在现有未闭合状态基础上，增量扫描新增内容
            var newUnclosedState = stateBefore
            self.scanUnclosedStructureDelta(deltaText, into: &newUnclosedState)

            let parseEnd = CFAbsoluteTimeGetCurrent()
            let parseDuration = parseEnd - parseStart

            mdLog("⚡️ [Incremental] Parsed \(incrementalElements.count) elements in \(String(format: "%.1f", parseDuration * 1000))ms")

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                self.mergeIncrementalResults(
                    incrementalElements: incrementalElements,
                    newFootnotes: newFootnotes,
                    newAttachments: newAttachments,
                    newTOCItems: newTOCItems,
                    newTocId: newTocId,
                    newLength: newLength,
                    newFullText: fullText,
                    newUnclosedState: newUnclosedState,
                    containerWidth: containerWidth,
                    perfStartTime: perfStartTime,
                    parseDuration: parseDuration
                )
            }
        }
    }

    /// 合并增量解析结果（只追加新增元素，不做字符窗口对齐猜测）
    func mergeIncrementalResults(
        incrementalElements: [MarkdownRenderElement],
        newFootnotes: [MarkdownFootnote],
        newAttachments: [(attachment: MarkdownImageAttachment, urlString: String)],
        newTOCItems: [MarkdownTOCItem],
        newTocId: String?,
        newLength: Int,
        newFullText: String,
        newUnclosedState: ParseCache.UnclosedStructureState,
        containerWidth: CGFloat,
        perfStartTime: CFAbsoluteTime,
        parseDuration: Double
    ) {
        // 0️⃣ 移除旧的脚注视图（脚注区必须始终位于内容末尾，否则会被新元素挤到中间）
        if let existing = contentStackView.arrangedSubviews.first(where: { $0.accessibilityIdentifier == "FootnoteContainer" }) {
            existing.removeFromSuperview()
        }

        // 1️⃣ 追加新元素到缓存
        parseCache.cachedElements.append(contentsOf: incrementalElements)

        // 2️⃣ 只为新增元素创建视图（避免重复创建）
        for element in incrementalElements {
            let view = createView(for: element, containerWidth: containerWidth)
            contentStackView.addArrangedSubview(view)

            if case .heading(let id, _) = element {
                headingViews[id] = view
                if id == tocSectionId { tocSectionView = view }
            }
        }

        mdLog("⚡️ [Incremental] Appended \(incrementalElements.count) elements, total \(parseCache.cachedElements.count)")

        // 3️⃣ 合并其他数据（脚注追加而非覆盖）
        parseCache.cachedFootnotes.append(contentsOf: newFootnotes)
        parseCache.cachedAttachments.append(contentsOf: newAttachments)
        if !newTOCItems.isEmpty {
            parseCache.cachedTOCItems.append(contentsOf: newTOCItems)
        }
        parseCache.tocSectionId = newTocId ?? parseCache.tocSectionId

        // 4️⃣ 更新解析位置与未闭合结构状态
        parseCache.lastParsedLength = newLength
        parseCache.parsedPrefix = newFullText
        parseCache.unclosedState = newUnclosedState

        // 5️⃣ 更新全局状态
        self.imageAttachments = parseCache.cachedAttachments
        self.tableOfContents = parseCache.cachedTOCItems
        self.tocSectionId = parseCache.tocSectionId

        // 6️⃣ 更新 oldElements 用于后续 Diff
        self.oldElements = parseCache.cachedElements

        // 7️⃣ 重新渲染脚注（追加后脚注区仍位于末尾）
        if !parseCache.cachedFootnotes.isEmpty {
            UIView.performWithoutAnimation {
                let footnoteView = createFootnoteView(footnotes: parseCache.cachedFootnotes, width: containerWidth)
                contentStackView.addArrangedSubview(footnoteView)
            }
        }

        // 8️⃣ 加载新增图片并通知高度变化
        for newAttachment in newAttachments {
            loadImage(urlString: newAttachment.urlString, into: newAttachment.attachment)
        }
        invalidateIntrinsicContentSize()
        notifyHeightChange()
    }

    // MARK: - 未闭合结构检测（后台线程调用）

    /// 从头扫描文本，计算未闭合结构状态（全量解析后调用）。
    func computeUnclosedStructureState(in text: String) -> ParseCache.UnclosedStructureState {
        var state = ParseCache.UnclosedStructureState()
        scanUnclosedStructureDelta(text, into: &state)
        return state
    }

    /// 在现有状态基础上，增量扫描新增文本 delta，更新未闭合结构状态。
    func scanUnclosedStructureDelta(_ delta: String, into state: inout ParseCache.UnclosedStructureState) {
        let customTags = Self.customBlockTagNames()
        var inFence = state.pendingFenceMarker
        var latexOpen = state.pendingLatexOpen
        var detailsDepth = state.pendingDetailsDepth
        var customDepths = state.pendingCustomTagDepths

        for rawLine in delta.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let marker = inFence {
                // 围栏内：只识别同类型闭合围栏，其余（$$、HTML）均为字面量
                if Self.isClosingFenceLine(line, marker: marker) {
                    inFence = nil
                }
                continue
            }

            if let marker = Self.openingFenceMarker(line) {
                inFence = marker
                continue
            }

            // $$ 检测：按该行 $$ 出现次数的奇偶切换（跨行 $$ 块也能正确开关）
            let dollarCount = line.components(separatedBy: "$$").count - 1
            if dollarCount % 2 == 1 {
                latexOpen.toggle()
            }

            // <details> / </details> 深度
            detailsDepth += line.components(separatedBy: "<details").count - 1
            detailsDepth -= line.components(separatedBy: "</details").count - 1
            if detailsDepth < 0 { detailsDepth = 0 }

            // 自定义块深度
            for tag in customTags {
                let opens = line.components(separatedBy: "<\(tag)").count - 1
                let closes = line.components(separatedBy: "</\(tag)").count - 1
                let depthDelta = opens - closes
                guard depthDelta != 0 else { continue }
                let newDepth = (customDepths[tag] ?? 0) + depthDelta
                if newDepth <= 0 {
                    customDepths.removeValue(forKey: tag)
                } else {
                    customDepths[tag] = newDepth
                }
            }
        }

        state.pendingFenceMarker = inFence
        state.pendingLatexOpen = latexOpen
        state.pendingDetailsDepth = detailsDepth
        state.pendingCustomTagDepths = customDepths
    }

    // MARK: - 检测辅助

    /// 是否为围栏开头（行首 >= 3 个连续的 ` 或 ~）
    private static func openingFenceMarker(_ line: String) -> Character? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix { $0 == first }.count
        return count >= 3 ? first : nil
    }

    /// 是否为闭合围栏（整行都是同一个围栏标记，且 >= 3 个）
    private static func isClosingFenceLine(_ line: String, marker: Character) -> Bool {
        guard let first = line.first, first == marker, line.count >= 3 else { return false }
        return line.allSatisfy { $0 == marker }
    }

    /// 已注册的自定义流式块标签名（小写，排除内置 details）
    private static func customBlockTagNames() -> [String] {
        let registered = MarkdownCustomExtensionManager.shared.allParsers.compactMap {
            $0.streamingBlockTagName?.lowercased()
        }
        return Array(Set(registered)).filter { !$0.isEmpty && $0 != "details" }
    }
}
