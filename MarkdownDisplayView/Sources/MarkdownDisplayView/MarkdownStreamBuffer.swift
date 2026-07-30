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

    // MARK: - Callbacks

    /// 当检测到完整模块时的回调
    var onModuleReady: ((String, [MarkdownRenderElement]) -> Void)?

    /// 当缓存状态变化时的回调（用于显示/隐藏等待动画）
    var onBufferStateChanged: ((Bool) -> Void)?

    // MARK: - Init

    init(containerWidth: CGFloat, minModuleLength: Int) {
        self.containerWidth = containerWidth
        self.minModuleLength = max(1, minModuleLength)
    }

    // MARK: - Public Methods

    /// 重置缓存状态
    func reset() {
        accumulatedText = ""
        lastSafePosition = 0
        committedElementCount = 0
        uncommittedText = ""
        isInsideCodeBlockAtSafePosition = false
        fenceCounter = DelimiterCounter(pattern: "```")
        dollarCounter = DelimiterCounter(pattern: "$$")
        currentLine = ""
        lastNonEmptyCompletedLine = ""
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
        accumulatedText += text
        uncommittedText += text
        fenceCounter.consume(text)
        dollarCounter.consume(text)
        trackLines(text)
        // 不打印累计长度：String.count 是 O(n) 的 grapheme 遍历，
        // 仅为一行日志就在每个 token 上重走一遍全文
        mdLog("[StreamBuffer] 📥 Appended \(text.count) chars")

        return detectCompleteModules()
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

        // 1. 检测未闭合的结构（代码块、表格等）
        //
        // 必须先判待闭合再算长度：未闭合的代码块会让尾部一直变长，而 String.count 是
        // O(n) 的 grapheme 遍历，在这条提前返回的路径上算一次就等于每个 token 重走整段代码块。
        if let pending = detectPendingStructure() {
            mdLog("[StreamBuffer] ⏳ Pending structure detected: \(pending.rawValue)")
            // ⭐️ 移除频繁的状态回调，避免 UI 闪烁
            return ModuleDetectionResult(
                completeModules: [],
                pendingText: uncommittedText,
                hasPendingStructure: true,
                pendingType: pending
            )
        }

        let totalCount = startPosition + uncommittedText.count

        // 2. 查找模块边界（基于标题行）
        let boundaries = findModuleBoundaries(from: startPosition, totalCount: totalCount)

        // 3. 如果没有新的完整模块，继续等待
        if boundaries.isEmpty {
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
            hasPendingStructure: false,
            pendingType: nil
        )
    }

    /// 检测文本中是否有未完成的结构
    private func detectPendingStructure() -> PendingStructureType? {
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
                    return .codeBlock
                }
            }
        }

        // 1. 检测未闭合的代码块 ```：计数在 append 时增量维护，这里只看奇偶
        if !fenceCounter.isBalanced {
            return .codeBlock
        }

        // 2. 检测未闭合的 LaTeX 块 $$
        if !dollarCounter.isBalanced {
            return .latexBlock
        }

        // 3. 检测未完成的表格（末尾以 | 开头但无空行结束）
        if let lastNonEmptyLine = lastNonEmptyLine() {
            let trimmedLine = lastNonEmptyLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("|") && trimmedLine.contains("|") && !accumulatedText.hasSuffix("\n\n") {
                return .table
            }
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
        var paragraphStart = startPosition
        var hasRenderableContentSinceParagraphStart = false

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            let isFenceMarker = trimmedLine.hasPrefix("```")
            let isOutsideCodeBlock = !isInsideCodeBlock
            // 最后一段没有换行符收尾，不计入那 1 个字符
            let nextPosition = currentPosition + line.count + (index < lines.count - 1 ? 1 : 0)

            let isH1 = isOutsideCodeBlock
                && trimmedLine.hasPrefix("# ") && !trimmedLine.hasPrefix("## ")
            let isH2 = isOutsideCodeBlock
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
            if isOutsideCodeBlock && trimmedLine.isEmpty && hasRenderableContentSinceParagraphStart {
                let moduleLength = nextPosition - paragraphStart
                if moduleLength >= minModuleLength {
                    paragraphBoundaries.append(nextPosition)
                    paragraphStart = nextPosition
                    hasRenderableContentSinceParagraphStart = false
                }
            }

            if isFenceMarker {
                isInsideCodeBlock.toggle()
            }

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
