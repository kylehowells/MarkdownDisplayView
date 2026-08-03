//
//  MarkdownStreamBuffer.swift
//  MarkdownDisplayView
//
//  Created by 朱继超 on 12/15/25.
//

import Foundation
import UIKit

// MARK: - Stream Buffer

/// 智能流式缓存器，用于真流式场景下的模块检测和渲染控制
/// 负责缓存网络到达的字节流，检测完整的 Markdown 模块（标题+内容），
/// 并在模块完整时通知外部进行渲染
@available(iOS 15.0, *)
final class MarkdownStreamBuffer {

    private struct PendingStructure {
        let type: PendingStructureType?
        let debugName: String
        /// Character offset inside `uncommittedText` where the unsafe tail starts.
        /// Nil means the start cannot be proven, so no prefix is committed.
        let unsafeTailOffset: Int?
    }

    private struct UnmatchedMarkdownDelimiters {
        var codeBlockOffset: Int?
        var latexBlockOffset: Int?
        var customBlockOffset: Int?
        var customBlockName: String?
    }

    // MARK: - 模块检测结果

    /// 模块检测结果
    struct ModuleDetectionResult {
        /// 检测到的完整模块（可渲染的 Markdown 文本）
        let completeModules: [String]
        /// 剩余的未完成文本（需要继续缓存）
        let pendingText: String
        /// 是否有未完成的结构（代码块、表格等未闭合）
        let hasPendingStructure: Bool
        /// 未完成结构类型
        let pendingType: PendingStructureType?
    }

    // MARK: - 分隔符增量计数

    /// 贪婪不重叠地增量统计某个分隔符出现了多少次。
    ///
    /// 分隔符可能被 chunk 边界切断（上一片段结尾是 "``"、本片段开头是 "`"），
    /// 因此保留一段"未被任何匹配消耗掉"的尾巴，与下一片段拼接后再扫。尾巴长度取
    /// `pattern.count - 1`，短于分隔符本身，所以其中不可能藏着已经计过数的匹配。
    ///
    /// 计数语义必须与原先 `NSString.range(of:)` 逐次跳过匹配长度的写法一致：
    /// 4 个连续反引号只算 1 个围栏，6 个算 2 个。
    private struct DelimiterCounter {
        private let pattern: String
        private var count = 0
        private var carry = ""

        init(pattern: String) {
            self.pattern = pattern
        }

        /// 奇数次出现意味着结构未闭合
        var isBalanced: Bool { count % 2 == 0 }

        mutating func consume(_ chunk: String) {
            let segment = carry + chunk
            var searchStart = segment.startIndex
            while let found = segment.range(of: pattern, range: searchStart..<segment.endIndex) {
                count += 1
                searchStart = found.upperBound
            }
            carry = String(segment[searchStart...].suffix(pattern.count - 1))
        }
    }

    // MARK: - Properties

    /// 累积的缓存文本
    private(set) var accumulatedText: String = ""

    /// 上次成功解析到的安全位置
    private(set) var lastSafePosition: Int = 0

    /// 已提交渲染的元素数量
    private(set) var committedElementCount: Int = 0

    // MARK: - 增量扫描状态
    //
    // 已提交前缀 [0, lastSafePosition) 不会再变化，因此它对检测结果的贡献可以一次性固化，
    // 之后每次 append 只需要扫描未提交的尾部。尾部长度由模块大小决定、与整段回复的总长度
    // 无关 —— 这是把"每个 token 重扫全文"降为常量级的关键。
    //
    // 分隔符奇偶与"最后一个非空行"连未提交尾部都不用整段重扫：它们只依赖新到达的片段，
    // 于是未闭合代码块这种"尾部会一直变长"的场景也不会退化。

    /// 未提交的尾部文本，即 accumulatedText 中 [lastSafePosition, 末尾) 的部分
    private var uncommittedText: String = ""
    private var uncommittedCharacterCount = 0
    private let performanceDiagnostics = MarkdownStreamBufferPerformanceDiagnostics()

    /// 已提交前缀结束处是否正处于代码块内部
    private var isInsideCodeBlockAtSafePosition = false

    /// 全文中 ``` 的出现次数（增量维护，奇数表示代码块未闭合）
    private var fenceCounter = DelimiterCounter(pattern: "```")

    /// 全文中 $$ 的出现次数（增量维护，奇数表示公式块未闭合）
    private var dollarCounter = DelimiterCounter(pattern: "$$")

    /// 尚未见到换行的尾部残段
    private var currentLine = ""

    /// 已换行收尾的行里最后一个非空行（表格检测只需要它）
    private var lastNonEmptyCompletedLine = ""

    /// 最小模块长度（防止过于频繁的模块检测）
    private var minModuleLength: Int

    /// 容器宽度
    private var containerWidth: CGFloat

    /// HTML 风格原子扩展标签。扩展通常在 App 启动时注册，流式会话开始/reset 时取一次快照，
    /// 避免每个网络 chunk 都加锁复制 parser 注册表。
    private var protectedCustomBlockTagNames: [String] = ["details"]

    // MARK: - Callbacks

    /// 当检测到完整模块时的回调
    var onModuleReady: ((String, [MarkdownRenderElement]) -> Void)?

    /// 当缓存状态变化时的回调（用于显示/隐藏等待动画）
    var onBufferStateChanged: ((Bool) -> Void)?

    // MARK: - Init

    init(containerWidth: CGFloat, minModuleLength: Int) {
        self.containerWidth = containerWidth
        self.minModuleLength = max(1, minModuleLength)
        refreshCustomBlockTagNames()
    }

    // MARK: - Public Methods

    /// 重置缓存状态
    func reset() {
        accumulatedText = ""
        lastSafePosition = 0
        committedElementCount = 0
        uncommittedText = ""
        uncommittedCharacterCount = 0
        performanceDiagnostics.reset()
        isInsideCodeBlockAtSafePosition = false
        fenceCounter = DelimiterCounter(pattern: "```")
        dollarCounter = DelimiterCounter(pattern: "$$")
        currentLine = ""
        lastNonEmptyCompletedLine = ""
        refreshCustomBlockTagNames()
        mdLog("[StreamBuffer] 🔄 Buffer reset")
    }

    /// 更新容器宽度
    func updateContainerWidth(_ width: CGFloat) {
        self.containerWidth = width
    }

    /// 更新最小模块长度
    func updateMinModuleLength(_ length: Int) {
        minModuleLength = max(1, length)
    }

    /// 追加新到达的文本数据
    /// - Parameter text: 新到达的文本片段
    /// - Returns: 检测结果，包含可渲染的完整模块
    func append(_ text: String) -> ModuleDetectionResult {
        let diagnosticsEnabled = MarkdownStreamPerformanceDiagnostics.enabled
        let diagnosticsStart = diagnosticsEnabled ? CACurrentMediaTime() : 0
        let inputCharacterCount = diagnosticsEnabled ? text.count : 0
        accumulatedText += text
        uncommittedText += text
        if diagnosticsEnabled { uncommittedCharacterCount += inputCharacterCount }
        fenceCounter.consume(text)
        dollarCounter.consume(text)
        trackLines(text)
        // 不打印累计长度：String.count 是 O(n) 的 grapheme 遍历，
        // 仅为一行日志就在每个 token 上重走一遍全文
        mdLog("[StreamBuffer] 📥 Appended \(text.count) chars")

        let result = detectCompleteModules()
        if diagnosticsEnabled {
            performanceDiagnostics.record(
                inputCharacters: inputCharacterCount,
                tailCharacters: uncommittedCharacterCount,
                durationMS: (CACurrentMediaTime() - diagnosticsStart) * 1000,
                modules: result.completeModules.count,
                hasPendingStructure: result.hasPendingStructure,
                pendingType: result.pendingType
            )
        }
        return result
    }

    /// 强制提交所有剩余内容（流式结束时调用）
    /// - Returns: 剩余的所有文本
    func flush() -> String {
        let remaining = uncommittedText
        mdLog("[StreamBuffer] 🚿 Flushing remaining: \(remaining.count) chars")
        advanceSafePosition(to: lastSafePosition + remaining.count)
        return remaining
    }

    /// 获取完整的累积文本
    func getFullText() -> String {
        return accumulatedText
    }

    // MARK: - 增量状态维护

    /// 从新到达的片段里切出已换行收尾的完整行，记住其中最后一个非空行。
    ///
    /// 残段留在 currentLine 里等下一片段拼接，因此分隔符与 grapheme 都不会被 chunk 边界切断。
    private func trackLines(_ text: String) {
        currentLine += text
        while let newlineIndex = currentLine.firstIndex(where: { $0.isNewline }) {
            let line = String(currentLine[currentLine.startIndex..<newlineIndex])
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lastNonEmptyCompletedLine = line
            }
            currentLine.removeSubrange(currentLine.startIndex...newlineIndex)
        }
    }

    /// 前进安全位置，并把被提交掉的那段文本对检测结果的贡献固化下来。
    ///
    /// 模块边界总是落在行首（标题行起点 / 空行之后 / 全文末尾），所以行与分隔符都不会
    /// 跨越边界被切断。
    private func advanceSafePosition(to newPosition: Int) {
        let delta = newPosition - lastSafePosition
        guard delta > 0 else { return }

        absorbIntoCommittedState(String(uncommittedText.prefix(delta)))
        uncommittedText.removeFirst(min(delta, uncommittedText.count))
        if MarkdownStreamPerformanceDiagnostics.enabled {
            uncommittedCharacterCount = max(0, uncommittedCharacterCount - delta)
        }
        lastSafePosition = newPosition
    }

    /// 把一段即将离开扫描范围的文本折叠进"边界处是否位于代码块内"这一状态
    private func absorbIntoCommittedState(_ committedChunk: String) {
        for line in committedChunk.components(separatedBy: "\n")
        where line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            isInsideCodeBlockAtSafePosition.toggle()
        }
    }

    // MARK: - Module Detection

    /// 检测完整的 Markdown 模块
    private func detectCompleteModules() -> ModuleDetectionResult {
        let startPosition = lastSafePosition
        let pending = detectPendingStructure()

        // 如果只能确认“有未闭合结构”而无法确认它的起点，保持旧的保守行为。
        // 能确认起点时仍继续查找其之前的自然模块边界，避免一个未闭合尾部扣住数个完整模块。
        if let pending, pending.unsafeTailOffset == nil {
            mdLog("[StreamBuffer] ⏳ Pending structure detected: \(pending.debugName)")
            return ModuleDetectionResult(
                completeModules: [],
                pendingText: uncommittedText,
                hasPendingStructure: true,
                pendingType: pending.type
            )
        }

        let totalCount = startPosition + uncommittedText.count

        // 2. 查找模块边界（基于标题行）
        var boundaries = findModuleBoundaries(from: startPosition, totalCount: totalCount)
        if let unsafeTailOffset = pending?.unsafeTailOffset {
            let safeLimit = startPosition + unsafeTailOffset
            boundaries = boundaries.filter { $0 <= safeLimit }
        }

        // 3. 如果没有新的完整模块，继续等待
        if boundaries.isEmpty {
            if let pending {
                mdLog("[StreamBuffer] ⏳ Pending structure detected: \(pending.debugName)")
                return ModuleDetectionResult(
                    completeModules: [],
                    pendingText: uncommittedText,
                    hasPendingStructure: true,
                    pendingType: pending.type
                )
            }

            // 检查是否有足够的纯文本内容（无标题的情况）
            let remainingText = uncommittedText
            if remainingText.count > minModuleLength * 3 && remainingText.hasSuffix("\n\n")
                || (isPlainText(remainingText) && remainingText.count > minModuleLength && remainingText.hasSuffix("\n")) {
                // 有大量文本且以双换行结束，可以提交
                let completeText = remainingText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !completeText.isEmpty {
                    advanceSafePosition(to: totalCount)
                    mdLog("[StreamBuffer] ✅ No heading found, but submitting text block: \(completeText.prefix(50))...")
                    return ModuleDetectionResult(
                        completeModules: [completeText],
                        pendingText: "",
                        hasPendingStructure: false,
                        pendingType: nil
                    )
                }
            }

            // ⭐️ 移除频繁的状态回调，避免 UI 闪烁
            return ModuleDetectionResult(
                completeModules: [],
                pendingText: uncommittedText,
                hasPendingStructure: false,
                pendingType: nil
            )
        }

        // 4. 提取完整的模块（偏移仍是全文口径，提取时换算成未提交尾部的相对偏移）
        var completeModules: [String] = []
        var lastBoundary = startPosition

        for boundary in boundaries {
            if boundary > lastBoundary {
                let moduleText = extractModule(start: lastBoundary, end: boundary, tailOrigin: startPosition)
                if !moduleText.isEmpty {
                    completeModules.append(moduleText)
                    mdLog("[StreamBuffer] ✅ Complete module found: \(moduleText.prefix(50))... (\(moduleText.count) chars)")
                }
            }
            lastBoundary = boundary
        }

        // 更新安全位置（必须在提取之后：提取依赖尚未截断的尾部）
        advanceSafePosition(to: lastBoundary)

        // ⭐️ 移除频繁的状态回调，避免 UI 闪烁
        // 当有内容渲染时，等待动画会被自然推开

        return ModuleDetectionResult(
            completeModules: completeModules,
            pendingText: uncommittedText,
            hasPendingStructure: pending != nil,
            pendingType: pending?.type
        )
    }

    /// 检测文本中是否有未完成的结构
    private func detectPendingStructure() -> PendingStructure? {
        var candidates: [PendingStructure] = []

        // ⭐️ 检测末尾是否有不完整的代码块标记（如 ` 或 ``）
        // 这是数据流被随机分割导致的。suffix 从尾部反向取，代价与取的长度成正比。
        let trimmedEnd = accumulatedText.suffix(10)  // 检查末尾10个字符
        if trimmedEnd.contains("`") {
            // 检查是否是完整的 ``` 开头或结尾
            let backtickSuffix = String(accumulatedText.suffix(5))
            // 如果末尾有1-2个反引号但不是3个，可能是被截断了
            if backtickSuffix.hasSuffix("`") && !backtickSuffix.hasSuffix("```") {
                let backtickCount = backtickSuffix.reversed().prefix(while: { $0 == "`" }).count
                if backtickCount == 1 || backtickCount == 2 {
                    mdLog("[StreamBuffer] ⏳ Incomplete backtick detected at end: \(backtickCount) backticks")
                    candidates.append(PendingStructure(
                        type: .codeBlock,
                        debugName: PendingStructureType.codeBlock.rawValue,
                        unsafeTailOffset: max(0, uncommittedText.count - backtickCount)
                    ))
                }
            }
        }

        // 全局 counter 是快速否定条件；真正定位时使用上下文扫描，避免把代码块或
        // 自定义 HTML 块内部的 $$ / ``` 错当成外层结构。
        let unmatchedDelimiters = scanUnmatchedMarkdownDelimiters(in: uncommittedText)

        if let codeBlockOffset = unmatchedDelimiters.codeBlockOffset {
            candidates.append(PendingStructure(
                type: .codeBlock,
                debugName: PendingStructureType.codeBlock.rawValue,
                unsafeTailOffset: codeBlockOffset
            ))
        }

        // 2. 检测未闭合的 LaTeX 块 $$
        if let latexBlockOffset = unmatchedDelimiters.latexBlockOffset {
            candidates.append(PendingStructure(
                type: .latexBlock,
                debugName: PendingStructureType.latexBlock.rawValue,
                unsafeTailOffset: latexBlockOffset
            ))
        } else if uncommittedText.hasSuffix("$") {
            // chunk 可能正好切在 $$ 中间；保留最后一个 $，下一片到达后再判断。
            candidates.append(PendingStructure(
                type: .latexBlock,
                debugName: PendingStructureType.latexBlock.rawValue,
                unsafeTailOffset: max(0, uncommittedText.count - 1)
            ))
        }

        // 3. HTML 风格自定义扩展必须整体到达后再交给 parser。
        // 标签名来自扩展注册表，避免在核心库硬编码 ECharts；details 是内置结构。
        if let offset = unmatchedDelimiters.customBlockOffset,
           let tagName = unmatchedDelimiters.customBlockName {
            candidates.append(PendingStructure(type: nil, debugName: "<\(tagName)>", unsafeTailOffset: offset))
        }

        // 4. 检测未完成的表格（末尾以 | 开头但无空行结束）
        if let lastNonEmptyLine = lastNonEmptyLine() {
            let trimmedLine = lastNonEmptyLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("|") && trimmedLine.contains("|") && !accumulatedText.hasSuffix("\n\n") {
                candidates.append(PendingStructure(type: .table, debugName: PendingStructureType.table.rawValue, unsafeTailOffset: nil))
            }
        }

        return candidates.min { lhs, rhs in
            switch (lhs.unsafeTailOffset, rhs.unsafeTailOffset) {
            case let (left?, right?): return left < right
            // 无法证明起点的结构必须最保守地支配其它候选，禁止越过它提交前缀。
            case (.some, nil): return false
            case (nil, .some): return true
            case (nil, nil): return false
            }
        }
    }

    private func scanUnmatchedMarkdownDelimiters(in text: String) -> UnmatchedMarkdownDelimiters {
        var result = UnmatchedMarkdownDelimiters()
        var searchStart = text.startIndex
        let opaqueTags = customBlockTagNames().filter { $0 != "details" }
        var detailsDepth = 0
        var detailsOuterOffset: Int?

        while searchStart < text.endIndex {
            if result.codeBlockOffset != nil {
                guard let closing = text.range(of: "```", range: searchStart..<text.endIndex) else { break }
                result.codeBlockOffset = nil
                searchStart = closing.upperBound
                continue
            }
            if result.latexBlockOffset != nil {
                guard let closing = text.range(of: "$$", range: searchStart..<text.endIndex) else { break }
                result.latexBlockOffset = nil
                searchStart = closing.upperBound
                continue
            }

            var candidates: [(range: Range<String.Index>, kind: Int, tagName: String?)] = []
            if let code = text.range(of: "```", range: searchStart..<text.endIndex) {
                candidates.append((code, 0, nil))
            }
            if let latex = text.range(of: "$$", range: searchStart..<text.endIndex) {
                candidates.append((latex, 1, nil))
            }
            for tagName in opaqueTags {
                if let tag = nextValidTagPrefix("<\(tagName)", in: text, from: searchStart) {
                    candidates.append((tag, 2, tagName))
                }
            }
            if let detailsOpen = nextValidTagPrefix("<details", in: text, from: searchStart) {
                candidates.append((detailsOpen, 3, "details"))
            }
            if detailsDepth > 0,
               let detailsClose = nextValidTagPrefix("</details", in: text, from: searchStart) {
                candidates.append((detailsClose, 4, "details"))
            }

            guard let next = candidates.min(by: { $0.range.lowerBound < $1.range.lowerBound }) else { break }
            switch next.kind {
            case 0:
                result.codeBlockOffset = text.distance(from: text.startIndex, to: next.range.lowerBound)
                searchStart = next.range.upperBound
            case 1:
                result.latexBlockOffset = text.distance(from: text.startIndex, to: next.range.lowerBound)
                searchStart = next.range.upperBound
            default:
                if next.kind == 3 {
                    if detailsDepth == 0 {
                        detailsOuterOffset = text.distance(from: text.startIndex, to: next.range.lowerBound)
                    }
                    detailsDepth += 1
                    searchStart = next.range.upperBound
                } else if next.kind == 4 {
                    detailsDepth = max(0, detailsDepth - 1)
                    if detailsDepth == 0 { detailsOuterOffset = nil }
                    searchStart = next.range.upperBound
                } else {
                    guard let tagName = next.tagName,
                          let closing = nextValidTagPrefix("</\(tagName)", in: text, from: next.range.upperBound) else {
                        result.customBlockOffset = text.distance(from: text.startIndex, to: next.range.lowerBound)
                        result.customBlockName = next.tagName
                        return result
                    }
                    searchStart = closing.upperBound
                }
            }
        }

        if let detailsOuterOffset {
            result.customBlockOffset = detailsOuterOffset
            result.customBlockName = "details"
        }

        return result
    }

    private func customBlockTagNames() -> [String] {
        protectedCustomBlockTagNames
    }

    private func refreshCustomBlockTagNames() {
        let registered = MarkdownCustomExtensionManager.shared.allParsers.compactMap {
            $0.streamingBlockTagName?.lowercased()
        }
        protectedCustomBlockTagNames = Array(Set(registered + ["details"]))
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
    }

    private func nextValidTagPrefix(
        _ prefix: String,
        in text: String,
        from startIndex: String.Index
    ) -> Range<String.Index>? {
        var searchStart = startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: prefix,
                options: [.caseInsensitive],
                range: searchStart..<text.endIndex
              ) {
            if range.upperBound == text.endIndex {
                return range
            }

            let next = text[range.upperBound]
            if next == ">" || next == "/" || next.isWhitespace {
                return range
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    /// 全文的最后一个非空行：优先看尚未换行的残段，否则回退到已收尾的行
    private func lastNonEmptyLine() -> String? {
        if !currentLine.trimmingCharacters(in: .whitespaces).isEmpty {
            return currentLine
        }
        return lastNonEmptyCompletedLine.isEmpty ? nil : lastNonEmptyCompletedLine
    }

    /// 判断文本是否为纯文本（不包含 Markdown 块级/行级标记）
    /// 用于决定是否可以在 \n（而非 \n\n）处提前提交模块
    private func isPlainText(_ text: String) -> Bool {
        let markdownMarkers = ["#", "> ", "```", "---", "***", "- ", "* ", "+ ", "| ",
                                "1. ", "2. ", "3. ", "![", "[$"]
        for marker in markdownMarkers {
            if text.contains(marker) { return false }
        }
        // 内联标记不影响段落结构，但仍算 markdown 内容
        if text.contains("**") || text.contains("__") || text.contains("`") || text.contains("$$") {
            return false
        }
        return true
    }

    /// 查找模块边界（自适应策略）
    /// ⭐️ 自适应分割策略：
    /// 1. 如果有多个一级标题 → 按一级标题分割
    /// 2. 如果只有一个/没有一级标题但有多个二级标题 → 按二级标题分割
    /// 3. 如果都没有 → 按双换行分割段落
    ///
    /// 只扫描未提交尾部：原实现每次都从第 0 行遍历全文，但 startPosition 之前的行既不参与
    /// 标题收集、也不参与段落切分，唯一会跨越边界的状态就是"是否在代码块内"，而它已在
    /// `isInsideCodeBlockAtSafePosition` 里固化。
    /// - Parameters:
    ///   - startPosition: 未提交尾部在全文中的起始偏移
    ///   - totalCount: 全文的 Character 总数
    /// - Returns: 模块边界位置数组（每个位置是模块的结束位置，即下一个模块的开始位置）
    private func findModuleBoundaries(from startPosition: Int, totalCount: Int) -> [Int] {
        let lines = uncommittedText.components(separatedBy: "\n")
        var currentPosition = startPosition

        // 收集各级标题位置（尾部之内的行天然都在搜索范围里）
        var h1Positions: [Int] = []  // # 一级标题
        var h2Positions: [Int] = []  // ## 二级标题
        var paragraphBoundaries: [Int] = []

        // 追踪代码块状态
        var isInsideCodeBlock = isInsideCodeBlockAtSafePosition
        var isInsideLatexBlock = false
        let protectedTagNames = customBlockTagNames()
        var customTagDepths = Dictionary(uniqueKeysWithValues: protectedTagNames.map { ($0, 0) })
        var paragraphStart = startPosition
        var hasRenderableContentSinceParagraphStart = false

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            let isInsideCustomBlock = customTagDepths.values.contains { $0 > 0 }
            let isOutsideProtectedBlock = !isInsideCodeBlock && !isInsideLatexBlock && !isInsideCustomBlock
            // 最后一段没有换行符收尾，不计入那 1 个字符
            let nextPosition = currentPosition + line.count + (index < lines.count - 1 ? 1 : 0)

            let isH1 = isOutsideProtectedBlock
                && trimmedLine.hasPrefix("# ") && !trimmedLine.hasPrefix("## ")
            let isH2 = isOutsideProtectedBlock
                && trimmedLine.hasPrefix("## ") && !trimmedLine.hasPrefix("### ")

            if isH1 {
                h1Positions.append(currentPosition)
            } else if isH2 {
                h2Positions.append(currentPosition)
            }

            if !trimmedLine.isEmpty && !isH1 && !isH2 {
                hasRenderableContentSinceParagraphStart = true
            }

            // fallback 段落切分只在代码块外生效，且标题后的第一个空行不会单独切出“只有标题”的模块
            if isOutsideProtectedBlock && trimmedLine.isEmpty && hasRenderableContentSinceParagraphStart {
                let moduleLength = nextPosition - paragraphStart
                if moduleLength >= minModuleLength {
                    paragraphBoundaries.append(nextPosition)
                    paragraphStart = nextPosition
                    hasRenderableContentSinceParagraphStart = false
                }
            }

            advanceProtectedBoundaryState(
                through: line,
                tagNames: protectedTagNames,
                isInsideCodeBlock: &isInsideCodeBlock,
                isInsideLatexBlock: &isInsideLatexBlock,
                customTagDepths: &customTagDepths
            )

            currentPosition = nextPosition
        }

        // ⭐️ 自适应选择分割级别
        let headingLevel: String
        var boundaries: [Int] = []

        if h1Positions.count >= 2 {
            // 策略1：有多个一级标题，按一级标题分割
            headingLevel = "H1"
            boundaries = headingBoundaries(h1Positions, startPosition: startPosition, totalCount: totalCount)
        } else if h2Positions.count >= 2 {
            // 策略2：只有一个/没有一级标题，但有多个二级标题，按二级标题分割
            headingLevel = "H2"
            boundaries = headingBoundaries(h2Positions, startPosition: startPosition, totalCount: totalCount)
        } else {
            // 策略3：没有足够的标题，按双换行分割段落
            headingLevel = "paragraph"
            boundaries = paragraphBoundaries
        }

        mdLog("[StreamBuffer] 📊 Strategy: \(headingLevel), H1=\(h1Positions.count), H2=\(h2Positions.count), startPos=\(startPosition)")

        mdLog("[StreamBuffer] 📊 Found \(boundaries.count) boundaries: \(boundaries)")
        return boundaries
    }

    private func advanceProtectedBoundaryState(
        through line: String,
        tagNames: [String],
        isInsideCodeBlock: inout Bool,
        isInsideLatexBlock: inout Bool,
        customTagDepths: inout [String: Int]
    ) {
        var searchStart = line.startIndex

        while searchStart < line.endIndex {
            if isInsideCodeBlock {
                guard let closing = line.range(of: "```", range: searchStart..<line.endIndex) else { return }
                isInsideCodeBlock = false
                searchStart = closing.upperBound
                continue
            }
            if isInsideLatexBlock {
                guard let closing = line.range(of: "$$", range: searchStart..<line.endIndex) else { return }
                isInsideLatexBlock = false
                searchStart = closing.upperBound
                continue
            }
            if let activeOpaqueTag = tagNames.first(where: { $0 != "details" && (customTagDepths[$0] ?? 0) > 0 }) {
                guard let closing = nextValidTagPrefix("</\(activeOpaqueTag)", in: line, from: searchStart) else { return }
                customTagDepths[activeOpaqueTag] = 0
                searchStart = closing.upperBound
                continue
            }

            var candidates: [(range: Range<String.Index>, kind: Int, tagName: String?)] = []
            if let code = line.range(of: "```", range: searchStart..<line.endIndex) {
                candidates.append((code, 0, nil))
            }
            if let latex = line.range(of: "$$", range: searchStart..<line.endIndex) {
                candidates.append((latex, 1, nil))
            }
            for tagName in tagNames {
                if let opening = nextValidTagPrefix("<\(tagName)", in: line, from: searchStart) {
                    candidates.append((opening, 2, tagName))
                }
            }
            if (customTagDepths["details"] ?? 0) > 0,
               let closing = nextValidTagPrefix("</details", in: line, from: searchStart) {
                candidates.append((closing, 3, "details"))
            }

            guard let next = candidates.min(by: { $0.range.lowerBound < $1.range.lowerBound }) else { return }
            switch next.kind {
            case 0:
                isInsideCodeBlock = true
            case 1:
                isInsideLatexBlock = true
            case 2:
                guard let tagName = next.tagName else { return }
                customTagDepths[tagName, default: 0] += 1
            default:
                customTagDepths["details"] = max(0, (customTagDepths["details"] ?? 0) - 1)
            }
            searchStart = next.range.upperBound
        }
    }

    /// 把标题位置转成模块边界：第一个标题是当前模块的开头，不算边界；
    /// 末尾内容够长且已用空行收尾时，把全文末尾也算作一个边界。
    private func headingBoundaries(_ positions: [Int], startPosition: Int, totalCount: Int) -> [Int] {
        var boundaries = positions.dropFirst().filter { $0 > startPosition }

        if let lastHeadingPosition = positions.last {
            let contentAfterLast = totalCount - lastHeadingPosition
            if contentAfterLast > minModuleLength && accumulatedText.hasSuffix("\n\n") {
                boundaries.append(totalCount)
            }
        }

        return boundaries
    }

    /// 提取模块文本
    ///
    /// 偏移是全文口径，但索引在未提交尾部上做：从全文开头 `offsetBy` 会随回复变长而变慢，
    /// 而尾部长度只与模块大小相关。
    /// - Parameters:
    ///   - start: 模块起点（全文偏移）
    ///   - end: 模块终点（全文偏移）
    ///   - tailOrigin: 未提交尾部在全文中的起始偏移
    private func extractModule(start: Int, end: Int, tailOrigin: Int) -> String {
        let tail = uncommittedText
        let relativeStart = start - tailOrigin
        let relativeEnd = end - tailOrigin
        guard relativeStart >= 0, relativeStart < relativeEnd, relativeEnd <= tail.count else { return "" }

        // 使用 limitedBy 安全获取索引，防止 Unicode 字符边界导致崩溃
        guard let startIndex = tail.index(tail.startIndex, offsetBy: relativeStart, limitedBy: tail.endIndex),
              let endIndex = tail.index(tail.startIndex, offsetBy: relativeEnd, limitedBy: tail.endIndex),
              startIndex < endIndex else {
            return ""
        }

        return String(tail[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
