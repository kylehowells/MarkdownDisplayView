//
//  MarkdownViewTextKit+TablesFootnotesImages.swift
//  MarkdownDisplayView
//
//  Mechanical extension split from MarkdownDisplayView.swift.
//

import UIKit
import Foundation
import Combine
import NaturalLanguage

/// Immutable, shared regex set for streaming atomic ranges.
///
/// The order and overlap behavior intentionally match the original implementation:
/// results are sorted by location but overlapping image/link and math ranges are not merged.
enum AtomicRangeMatcher {
    private static let patterns = [
        "(?s)\\$\\$.*?\\$\\$", // block math
        "\\$[^\\n\\$]+?\\$",  // inline math
        "!\\[.*?\\]\\(.*?\\)", // image
        "\\[.*?\\]\\(.*?\\)",  // link
    ]

    private static let regularExpressions: [NSRegularExpression] = patterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [])
    }

    static func ranges(in text: String) -> [NSRange] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var ranges: [NSRange] = []

        for regex in regularExpressions {
            ranges.append(contentsOf: regex.matches(in: text, options: [], range: fullRange).map(\.range))
        }

        ranges.sort { $0.location < $1.location }
        return ranges
    }
}

@available(iOS 15.0, *)
extension MarkdownViewTextKit {
    // MARK: - Table View

    func createTableView(with tableData: MarkdownTableData, containerWidth: CGFloat) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        let tableStackView = UIStackView()
        tableStackView.axis = .vertical
        tableStackView.spacing = 0
        tableStackView.distribution = .fill
        tableStackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(tableStackView)

        // 计算列宽
        let columnCount = max(tableData.headers.count, tableData.rows.first?.count ?? 0)
        let cellPadding = configuration.tableCellPadding * 2  // 左右各 padding
        var columnWidths: [CGFloat] = Array(repeating: configuration.tableMinColumnWidth, count: columnCount)

        for (index, header) in tableData.headers.enumerated() {
            let width = header.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: configuration.tableRowHeight),
                options: [.usesLineFragmentOrigin],
                context: nil
            ).width + cellPadding
            columnWidths[index] = max(columnWidths[index], width)
        }

        for row in tableData.rows {
            for (index, cell) in row.enumerated() where index < columnCount {
                let width = cell.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: configuration.tableRowHeight),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                ).width + cellPadding
                columnWidths[index] = max(columnWidths[index], width)
            }
        }

        columnWidths = columnWidths.map { min($0, configuration.tableMaxColumnWidth) }
        let totalWidth = columnWidths.reduce(0, +)

        // 表头行
        let headerRow = createTableRow(cells: tableData.headers, columnWidths: columnWidths, isHeader: true)
        tableStackView.addArrangedSubview(headerRow)

        // 分隔线
        let separator = UIView()
        separator.backgroundColor = configuration.tableBorderColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: configuration.tableSeparatorHeight).isActive = true
        tableStackView.addArrangedSubview(separator)

        // 数据行
        for (index, row) in tableData.rows.enumerated() {
            let rowView = createTableRow(cells: row, columnWidths: columnWidths, isHeader: false)
            if index % 2 == 1 {
                rowView.backgroundColor = configuration.tableAlternateRowBackgroundColor
            } else {
                rowView.backgroundColor = configuration.tableRowBackgroundColor
            }
            tableStackView.addArrangedSubview(rowView)
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            tableStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            tableStackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            tableStackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            tableStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            tableStackView.widthAnchor.constraint(equalToConstant: totalWidth),
        ])

        let rowHeight = configuration.tableRowHeight
        let tableHeight = rowHeight * CGFloat(tableData.rows.count + 1) + configuration.tableSeparatorHeight
        container.heightAnchor.constraint(equalToConstant: tableHeight).isActive = true

        return container
    }
    
    func createTableRow(
        cells: [NSAttributedString],
        columnWidths: [CGFloat],
        isHeader: Bool
    ) -> UIView {
        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.spacing = 0
        rowStack.distribution = .fill
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        
        if isHeader {
            rowStack.backgroundColor = configuration.tableHeaderBackgroundColor
        }
        
        for (index, cell) in cells.enumerated() {
            let cellView = UIView()
            cellView.translatesAutoresizingMaskIntoConstraints = false
            
            let label = UILabel()
            label.attributedText = cell
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            
            if isHeader {
                label.font = UIFont.systemFont(ofSize: configuration.bodyFont.pointSize, weight: .semibold)
            }
            
            cellView.addSubview(label)
            
            if index < cells.count - 1 {
                let border = UIView()
                border.backgroundColor = configuration.tableBorderColor.withAlphaComponent(0.3)
                border.translatesAutoresizingMaskIntoConstraints = false
                cellView.addSubview(border)
                
                NSLayoutConstraint.activate([
                    border.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 8),
                    border.bottomAnchor.constraint(equalTo: cellView.bottomAnchor, constant: -8),
                    border.trailingAnchor.constraint(equalTo: cellView.trailingAnchor),
                    border.widthAnchor.constraint(equalToConstant: 0.5),
                ])
            }
            
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: cellView.bottomAnchor, constant: -10),
                label.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -12),
            ])
            
            let width = index < columnWidths.count ? columnWidths[index] : 80
            cellView.widthAnchor.constraint(equalToConstant: width).isActive = true
            
            rowStack.addArrangedSubview(cellView)
        }
        
        rowStack.heightAnchor.constraint(equalToConstant: 44).isActive = true
        
        return rowStack
    }
    
    // MARK: - Footnote View

    func createFootnoteView(footnotes: [MarkdownFootnote], width: CGFloat) -> UIView {
        // [FOOTNOTE_DEBUG] 脚注视图创建
        mdLog("[FOOTNOTE_DEBUG] 🎨 createFootnoteView called! count=\(footnotes.count), isRealStreamingMode=\(isRealStreamingMode)")
        #if DEBUG
        let callStack = Thread.callStackSymbols.prefix(6).joined(separator: "\n")
        mdLog("[FOOTNOTE_DEBUG] 🎨 Call stack:\n\(callStack)")
        #endif

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        // ⭐️ 标记为原子块，让打字机引擎将其视为整体淡入，而不是逐字打印
        container.accessibilityIdentifier = "FootnoteContainer"
        
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.alignment = .leading // 使用 .leading 允许分隔线宽度自定义
        stackView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stackView)
        
        // 1. 分隔线
        let separator = UIView()
        separator.backgroundColor = configuration.horizontalRuleColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(separator)
        
        NSLayoutConstraint.activate([
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
            separator.widthAnchor.constraint(equalToConstant: width * 0.3)
        ])
        
        // 2. 合并所有脚注到一个 AttributedString (性能优化：O(N) Views -> O(1) View)
        let allFootnotesText = NSMutableAttributedString()
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 6 // 脚注之间的间距
        paragraphStyle.lineHeightMultiple = 1.1
        
        for (index, footnote) in footnotes.enumerated() {
            // 添加换行 (除第一个外)
            if index > 0 {
                allFootnotesText.append(NSAttributedString(string: "\n"))
            }
            
            // ID: ⁽1⁾
            let idText = NSAttributedString(
                string: "⁽\(footnote.id)⁾ ",
                attributes: [
                    .font: UIFont.systemFont(ofSize: configuration.bodyFont.pointSize - 2),
                    .foregroundColor: configuration.linkColor,
                    .baselineOffset: 3,
                    .paragraphStyle: paragraphStyle
                ])
            allFootnotesText.append(idText)
            
            // Content
            let contentText = NSAttributedString(
                string: footnote.content,
                attributes: [
                    .font: UIFont.systemFont(ofSize: configuration.bodyFont.pointSize - 2),
                    .foregroundColor: configuration.textColor.withAlphaComponent(0.8),
                    .paragraphStyle: paragraphStyle
                ])
            allFootnotesText.append(contentText)
        }
        
        // 3. 创建唯一的 TextView
        // 注意：我们显式传递 width 确保 createTextView 内部正确计算布局
        let textView = createTextView(
            with: allFootnotesText,
            width: width,
            insets: UIEdgeInsets(top: 8, left: 0, bottom: 16, right: 0)
        )
        
        // 确保 TextView 占满全宽 (因为 StackView 是 .leading 对齐)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.widthAnchor.constraint(equalToConstant: width).isActive = true
        
        stackView.addArrangedSubview(textView)
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        
        return container
    }
    
    // MARK: - Footnote Preprocessing
    
    func preprocessFootnotes(_ text: String) -> (String, [MarkdownFootnote]) {
        // Optimization: Fast check for footnote syntax markers.
        // If neither definition marker nor reference marker exists, skip regex entirely.
        if !text.contains("[^") {
            return (text, [])
        }
        
        var processedText = text
        var footnotes: [MarkdownFootnote] = []
        
        let definitionPattern = #"\[\^([^\]]+)\]:\s*(.+)$"#
        if let regex = try? NSRegularExpression(pattern: definitionPattern, options: .anchorsMatchLines) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            
            for match in matches.reversed() {
                if let idRange = Range(match.range(at: 1), in: text),
                   let contentRange = Range(match.range(at: 2), in: text),
                   let fullRange = Range(match.range, in: text) {
                    let id = String(text[idRange])
                    let content = String(text[contentRange])
                    footnotes.insert(MarkdownFootnote(id: id, content: content), at: 0)
                    processedText = processedText.replacingCharacters(in: fullRange, with: "")
                }
            }
        }
        
        let referencePattern = #"\[\^([^\]]+)\]"#
        if let regex = try? NSRegularExpression(pattern: referencePattern, options: []) {
            let matches = regex.matches(in: processedText, range: NSRange(processedText.startIndex..., in: processedText))
            
            for match in matches.reversed() {
                if let idRange = Range(match.range(at: 1), in: processedText),
                   let fullRange = Range(match.range, in: processedText) {
                    let id = String(processedText[idRange])
                    let replacement = "⁽\(id)⁾"
                    processedText = processedText.replacingCharacters(in: fullRange, with: replacement)
                }
            }
        }
        
        return (processedText, footnotes)
    }
    
    // MARK: - Image Loading
    
    func loadImages() {
        for (attachment, urlString) in imageAttachments {
            loadImage(urlString: urlString, into: attachment)
        }
    }
    
    func loadImage(urlString: String, into attachment: MarkdownImageAttachment) {
        var processedURLString = urlString
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            processedURLString = "https://" + urlString
        }
        
        guard let url = URL(string: processedURLString) else { return }
        
        ImageLoader.shared.loadImage(from: url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                guard let self = self, let image = image else { return }
                
                let imageSize = image.size
                var targetSize = CGSize(width: 100, height: 100)
                
                if imageSize.width > 0 && imageSize.height > 0 {
                    let aspectRatio = ceilf(Float(imageSize.width / imageSize.height))
                    var targetWidth = imageSize.width
                    var targetHeight = imageSize.height
                    
                    // 按宽度缩放
                    if attachment.maxWidth > 0 && targetWidth > attachment.maxWidth {
                        targetWidth = attachment.maxWidth
                        targetHeight = targetWidth / CGFloat(aspectRatio)
                    }
                    
                    // 按高度缩放
                    if attachment.maxHeight > 0 && targetHeight > attachment.maxHeight {
                        targetHeight = attachment.maxHeight
                        targetWidth = targetHeight * CGFloat(aspectRatio)
                    }
                    
                    targetSize = CGSize(width: ceil(targetWidth), height: ceil(targetHeight))
                }
                
                // 直接生成缩放后的图片
                let renderer = UIGraphicsImageRenderer(size: targetSize)
                let scaledImage = renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: targetSize))
                }
                
                attachment.bounds = CGRect(origin: .zero, size: targetSize)
                attachment.image = scaledImage
                
                self.refreshWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.refreshTextViews()
                }
                self.refreshWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
            }
            .store(in: &cancellables)
    }
    
    func refreshTextViews() {
        for container in contentStackView.arrangedSubviews {
            for childView in container.subviews {
                if let textView = childView as? MarkdownTextViewTK2 {
                    textView.setNeedsDisplay()
                }
            }
        }
        
        invalidateIntrinsicContentSize()
        notifyHeightChange()
    }
    
    func measuredVisibleContentStackHeight() -> CGFloat {
        let visibleSubviews = contentStackView.arrangedSubviews.filter { !$0.isHidden }
        var totalHeight: CGFloat = visibleSubviews.reduce(0) { $0 + $1.frame.height }

        if visibleSubviews.count > 1 {
            totalHeight += CGFloat(visibleSubviews.count - 1) * contentStackView.spacing
        }

        totalHeight += contentStackView.layoutMargins.top + contentStackView.layoutMargins.bottom
        return max(0, totalHeight)
    }

    func notifyHeightChange(force: Bool = false) {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            recordCost(for: "Layout Calculation", duration: CFAbsoluteTimeGetCurrent() - start)
        }

        // ⭐️ 强制 StackView 立即更新布局
        if force {
            self.contentStackView.invalidateIntrinsicContentSize()
        }
        self.layoutIfNeeded()
        self.contentStackView.layoutIfNeeded()

        // 使用稳定的测量宽度，避免父视图尚未完成布局时出现 width=0 导致测高抖动
        let fallbackWidth = max(1, UIScreen.main.bounds.width - 32)
        let fittingWidth: CGFloat = {
            if self.bounds.width > 0 { return self.bounds.width }
            if self.contentStackView.bounds.width > 0 { return self.contentStackView.bounds.width }
            return fallbackWidth
        }()

        let size = self.contentStackView.systemLayoutSizeFitting(
            CGSize(width: fittingWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        let frameBasedHeight = measuredVisibleContentStackHeight()
        let hasVisibleContent = contentStackView.arrangedSubviews.contains { !$0.isHidden }

        var newHeight = size.height
        var usedFrameFallback = false

        if !newHeight.isFinite || newHeight <= 0 {
            newHeight = frameBasedHeight
            usedFrameFallback = true
        }

        // 有可见内容但高度仍为 0，通常是布局尚未稳定；本轮跳过，等待下一次布局回调
        if newHeight <= 0, hasVisibleContent, !force {
            mdLog("📏 [Height] ⏳ Deferred notification (transient 0 with visible content)")
            return
        }

        // 🔍 诊断日志：打印高度变化
        let heightDiff = newHeight - lastReportedHeight
        mdLog("🔍 [Height] Current: \(String(format: "%.1f", newHeight))pt | Last: \(String(format: "%.1f", lastReportedHeight))pt | Diff: \(String(format: "%.1f", heightDiff))pt | Force: \(force) | Width: \(String(format: "%.1f", fittingWidth)) | Source: \(usedFrameFallback ? "frame" : "fitting")")

        // 只有高度变化超过阈值才通知，避免浮点数误差导致的死循环
        // 如果 force 为 true，忽略防抖检查
        if force || abs(newHeight - lastReportedHeight) > 9.0 {
            mdLog("📏 [Height] ✅ Notifying parent: \(String(format: "%.1f", lastReportedHeight)) -> \(String(format: "%.1f", newHeight))")
            lastReportedHeight = newHeight
            self.onHeightChange?(newHeight)

            // ⭐️ 关键修复：上面的 layoutIfNeeded() 只解算了 self（markdownView）这一层。
            // 当宿主是 ScrollableMarkdownViewTextKit 时，真正持有 contentSize 的是外层
            // UIScrollView，它的 bottomAnchor 通过 contentLayoutGuide 依赖 markdownView 的高度。
            // 在异步（离屏渲染 / 打字机）路径里手动调 layoutIfNeeded() 会让 markdownView 自己
            // 提前解算完毕，但不会顺带触发祖先 scrollView 的布局 —— 于是 scrollView 的
            // contentSize 和内部子视图 frame 停留在旧状态，直到用户触屏滚动、系统才被动调用
            // UIScrollView.layoutSubviews() 重新从约束里取值。这里主动把父 scrollView 也
            // 一起刷新，消除"必须手动滑一下才能恢复正常布局"的问题。
            //
            // ⚠️ 注意：嵌在 UITableView/UICollectionView cell 里时不能这样做 —— UITableView
            // 本身也是 UIScrollView，findParentScrollView() 会一路找到它。流式打字机期间
            // notifyHeightChange 每秒触发几十次，若每次都强制整张表 layoutIfNeeded()，
            // 代价是对全表重新布局而非仅这一行 cell，且可能与 self-sizing cell 自身的
            // 高度计算产生时序冲突。这类场景已经通过 cell 侧的 onHeightChange 回调
            // （tableView.beginUpdates/endUpdates 或 performBatchUpdates）来驱动高度变化，
            // 不需要也不应该在这里代劳。
            if !isEmbeddedInReusableCell(), let scrollView = findParentScrollView() {
                scrollView.setNeedsLayout()
                scrollView.layoutIfNeeded()
            }
        } else {
            mdLog("📏 [Height] ⚠️ Skipped notification (diff < 9.0pt)")
        }
    }
    
    public override var intrinsicContentSize: CGSize {
        let size = contentStackView.systemLayoutSizeFitting(
            CGSize(
                width: bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32,
                height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        
        // ⭐️ 关键修复：在布局完成后检查高度是否需要修正
        // 这解决了"初始宽度不准导致高度计算错误"的问题（Chicken & Egg problem）
        // 通过对比 lastReportedHeight，我们只在真正需要时触发更新，从而避免死循环
        notifyHeightChange()
    }
    
    //MARK: - streaming method
    /// 计算需要原子化输出的区间（公式、图片、链接）
        func calculateAtomicRanges(in text: String) -> [NSRange] {
            AtomicRangeMatcher.ranges(in: text)
        }

}
