//
//  MarkdownViewTextKit+Rendering.swift
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
    // MARK: - Rendering

    /// 判断两个元素是否完全相等（用于嵌套复用检查）
    func elementsAreEqual(_ old: MarkdownRenderElement, _ new: MarkdownRenderElement) -> Bool {
        switch (old, new) {
        case (.latex(let oldLatex), .latex(let newLatex)):
            return oldLatex == newLatex

        case (.attributedText(let oldText), .attributedText(let newText)):
            return oldText == newText

        case (.heading(let oldId, let oldText), .heading(let newId, let newText)):
            return oldId == newId && oldText == newText

        case (.codeBlock(let oldCode), .codeBlock(let newCode)):
            return oldCode == newCode

        case (.image(let oldSrc, let oldAlt), .image(let newSrc, let newAlt)):
            return oldSrc == newSrc && oldAlt == newAlt

        case (.thematicBreak, .thematicBreak):
            return true

        case (.rawHTML(let oldHTML), .rawHTML(let newHTML)):
            return oldHTML == newHTML

        // ⚡️ 嵌套结构的深度比较
        case (.quote(let oldChildren, let oldLevel), .quote(let newChildren, let newLevel)):
            guard oldLevel == newLevel, oldChildren.count == newChildren.count else { return false }
            for (oldChild, newChild) in zip(oldChildren, newChildren) {
                if !elementsAreEqual(oldChild, newChild) { return false }
            }
            return true

        case (.list(let oldItems, let oldLevel), .list(let newItems, let newLevel)):
            guard oldLevel == newLevel, oldItems.count == newItems.count else { return false }
            for (oldItem, newItem) in zip(oldItems, newItems) {
                guard oldItem.marker == newItem.marker,
                      oldItem.children.count == newItem.children.count else { return false }
                for (oldChild, newChild) in zip(oldItem.children, newItem.children) {
                    if !elementsAreEqual(oldChild, newChild) { return false }
                }
            }
            return true

        case (.details(let oldSummary, let oldChildren), .details(let newSummary, let newChildren)):
            guard oldSummary == newSummary, oldChildren.count == newChildren.count else { return false }
            for (oldChild, newChild) in zip(oldChildren, newChildren) {
                if !elementsAreEqual(oldChild, newChild) { return false }
            }
            return true

        case (.table(let oldData), .table(let newData)):
            // 简单比较行列数
            return oldData.headers.count == newData.headers.count &&
                   oldData.rows.count == newData.rows.count

        case (.custom(let oldData), .custom(let newData)):
            return oldData == newData

        default:
            return false  // 类型不匹配
        }
    }

    /// ⭐️ 判断元素是否可以复用（不需要删除重建）
    func canReuseElement(old: MarkdownRenderElement, new: MarkdownRenderElement) -> Bool {
        switch (old, new) {
        case (.attributedText, .attributedText):
            return true  // 文本类型相同，可以原地更新
        case (.heading, .heading):
            return true  // 标题类型相同，即使ID不同也可以更新
        case (.latex(let oldLatex), .latex(let newLatex)):
            // mdLog("🔍 [canReuseElement] LaTeX: old=\(oldLatex.prefix(20))... new=\(newLatex.prefix(20))... → true")
            return true  // LaTeX类型相同，即使内容不同也可以更新
        case (.codeBlock, .codeBlock):
            return true  // 代码块可以原地更新
        case (.quote(_, let oldLevel), .quote(_, let newLevel)):
            return oldLevel == newLevel  // 层级相同可复用
        case (.image, .image):
            return true  // 图片类型相同，可以重新加载
        case (.thematicBreak, .thematicBreak):
            return true
        case (.table, .table):
            return true  // 表格现在使用 CollectionView，支持原地更新
        case (.details, .details):
            return true   // 允许复用 Details 视图，以保持展开/收起状态
        case (.list(_, let oldLevel), .list(_, let newLevel)):
            return oldLevel == newLevel  // 层级相同可复用
        case (.custom(let oldData), .custom(let newData)):
            return oldData.type == newData.type  // 类型相同可复用
        default:
            return false  // 类型不同，不可复用
        }
    }

    /// ⭐️ 尝试原地更新元素
    /// - Returns: 是否更新成功。如果返回 false，说明视图结构不兼容（例如 LaTeX 需要变更为滚动视图），需要重建。
    func updateViewInPlace(_ view: UIView, old: MarkdownRenderElement, new: MarkdownRenderElement, containerWidth: CGFloat) -> Bool {
        // mdLog("[MarkdownDisplayView] 🔧 updateViewInPlace: old=\(old), new=\(new)")

        switch (old, new) {
        case (.attributedText(_), .attributedText(let newText)):
            // 查找 TextKit2 TextView
            var textView: MarkdownTextViewTK2?
            if let tv = view as? MarkdownTextViewTK2 {
                textView = tv
            } else if let tv = view.subviews.first(where: { $0 is MarkdownTextViewTK2 }) as? MarkdownTextViewTK2 {
                textView = tv
            }

            if let textView = textView {
                let normalizedText = normalizedAttributedTextForRendering(newText)
                if textView.attributedText != normalizedText {
                    // 1. 更新文本
                    textView.attributedText = normalizedText
                    textView.linkTextAttributes = [
                        .foregroundColor: configuration.linkColor,
                        .underlineStyle: configuration.linkUnderlineEnabled
                            ? NSUnderlineStyle.single.rawValue : 0,
                    ]
                    
                    // ⭐️ 核心修复：显式指定 containerWidth 进行布局计算
                    // 之前的 didSet 逻辑使用的是 textView.bounds.width，这可能是旧的或者错误的（例如 Cell 复用时）
                    // 导致计算出的高度不匹配当前的实际宽度要求 -> 文字被截断
                    textView.applyLayout(width: containerWidth, force: true)
                }
                return true
            }

        case (.heading(let oldId, _), .heading(let newId, let newText)):
            // 更新 ID 映射
            if oldId != newId {
                if let mappedView = headingViews[oldId], mappedView == view {
                    headingViews.removeValue(forKey: oldId)
                    headingViews[newId] = view
                    if tocSectionId == oldId {
                        tocSectionId = newId
                    }
                }
            }
            
            // 更新文本并强制布局
            if let textView = view as? MarkdownTextViewTK2 {
                if textView.attributedText != newText {
                    textView.attributedText = newText
                    textView.applyLayout(width: containerWidth, force: true)
                }
            } else if let textView = view.subviews.first(where: { $0 is MarkdownTextViewTK2 }) as? MarkdownTextViewTK2 {
                if textView.attributedText != newText {
                    textView.attributedText = newText
                    textView.applyLayout(width: containerWidth, force: true)
                }
            }
            return true

        case (.codeBlock, .codeBlock(let newLang, let newCode)):
            if let textView = view.subviews.first(where: { $0 is MarkdownTextViewTK2 }) as? MarkdownTextViewTK2 {
                if textView.attributedText != newCode {
                    textView.attributedText = newCode
                    // CodeBlock padding: leading 12 + trailing 12 = 24
                    let codeBlockWidth = max(0, containerWidth - 24)
                    textView.applyLayout(width: codeBlockWidth, force: true)
                }
            }
            return true

        // ⚡️ Quote 子元素复用优化（避免重复创建嵌套公式）
        case (.quote(let oldChildren, let oldLevel), .quote(let newChildren, let newLevel)):
            // 层级不同，需要重建
            if oldLevel != newLevel {
                mdLog("⚠️ [Quote] Level changed: \(oldLevel) → \(newLevel), rebuilding")
                return false
            }

            // 1. 验证视图结构 (Quote: outerContainer -> container -> contentStack)
            guard let outerContainer = view as? UIView,
                  outerContainer.subviews.count > 0,
                  let container = outerContainer.subviews.first,
                  let contentStack = container.subviews.first(where: { $0 is UIStackView }) as? UIStackView
            else {
                mdLog("⚠️ [Quote] View structure validation failed, rebuilding. view type: \(type(of: view)), subviews: \(view.subviews.count)")
                return false
            }

            // 2. 计算内容宽度 (Quote padding: leftIndent + 4 + 12 + 8)
            let leftIndent: CGFloat = (oldLevel > 1) ? 20 : 0
            let padding = leftIndent + 4 + 12 + 8
            let contentWidth = max(0, containerWidth - padding)

            // 3. Diff & Patch 子视图（类似 Details 的实现）
            var newSubviews: [UIView] = []
            var consumedOldIndices = Set<Int>()
            var searchStart = 0
            let existingSubviews = contentStack.arrangedSubviews

            for (childIndex, newChild) in newChildren.enumerated() {
                var foundIndex = -1
                let searchEnd = min(searchStart + 5, oldChildren.count)

                // 在窗口范围内查找可复用的视图
                for i in searchStart..<searchEnd {
                    if consumedOldIndices.contains(i) { continue }
                    if i >= existingSubviews.count { continue }

                    let oldChild = oldChildren[i]
                    if canReuseElement(old: oldChild, new: newChild) {
                        let candidateView = existingSubviews[i]
                        if updateViewInPlace(candidateView, old: oldChild, new: newChild, containerWidth: contentWidth) {
                            foundIndex = i
                            break
                        }
                    }
                }

                if foundIndex != -1 {
                    // 找到可复用的视图
                    consumedOldIndices.insert(foundIndex)
                    if foundIndex == searchStart { searchStart += 1 }
                    newSubviews.append(existingSubviews[foundIndex])
                } else {
                    // 创建新视图
                    let newView = createView(for: newChild, containerWidth: contentWidth)
                    newSubviews.append(newView)
                }
            }

            // 4. Reconcile Subviews
            for (index, subview) in newSubviews.enumerated() {
                if index < contentStack.arrangedSubviews.count {
                    let current = contentStack.arrangedSubviews[index]
                    if current != subview {
                        contentStack.insertArrangedSubview(subview, at: index)
                    }
                } else {
                    contentStack.addArrangedSubview(subview)
                }
            }

            // 移除多余的旧视图
            while contentStack.arrangedSubviews.count > newSubviews.count {
                contentStack.arrangedSubviews.last?.removeFromSuperview()
            }

            return true

        case (.table(let oldData), .table(let newData)):
            if oldData == newData { return true }
            
            // Re-create attachment with new data
            let attachment = MarkdownTableAttachment(
                data: newData,
                config: configuration,
                containerWidth: containerWidth,
                onLinkTap: { [weak self] url in
                    self?.handleLinkTap(url)
                }
            )
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left
            
            let attrString = NSMutableAttributedString(attachment: attachment)
            attrString.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attrString.length))
            
            // Find and update TextView
            if let textView = view as? MarkdownTextViewTK2 {
                textView.attributedText = attrString
                textView.applyLayout(width: containerWidth, force: true)
                return true
            } else if let textView = view.subviews.first(where: { $0 is MarkdownTextViewTK2 }) as? MarkdownTextViewTK2 {
                textView.attributedText = attrString
                textView.applyLayout(width: containerWidth, force: true)
                return true
            }
            return false

        case (.details(let oldSummary, let oldChildren), .details(let newSummary, let newChildren)):
            // 🛑 如果用户正在交互，跳过本次 Details 的更新，防止状态重置/冲突
            if isUserInteractingWithDetails {
                return true
            }

            // 1. 验证视图结构 (支持 Content Wrapper 结构)
            let containerStack = (view as? UIStackView)
                ?? view.subviews.first(where: { $0 is UIStackView }) as? UIStackView
            guard let containerStack,
                  containerStack.arrangedSubviews.count >= 2,
                  let summaryButton = containerStack.arrangedSubviews[0] as? UIButton,
                  let contentWrapper = containerStack.arrangedSubviews[1] as? UIView,
                  let contentContainer = contentWrapper.subviews.first as? UIStackView
            else { return false }
            
            // 2. 更新 Summary
            // 保持当前的展开状态符号 (基于 wrapper 可见性)
            let isExpanded = !contentWrapper.isHidden
            let prefix = isExpanded ? "▼ " : "▶ "
            if oldSummary != newSummary {
                summaryButton.setTitle(prefix + newSummary, for: .normal)
            }
            
            // 3. 更新 Children (Diff & Patch)
            let contentWidth = max(
                0,
                containerWidth - configuration.detailsContentPadding * 2
            )
            
            var newSubviews: [UIView] = []
            var consumedOldIndices = Set<Int>()
            var searchStart = 0
            let existingSubviews = contentContainer.arrangedSubviews
            
            for (childIndex, newChild) in newChildren.enumerated() {
                var foundIndex = -1
                let searchEnd = min(searchStart + 5, oldChildren.count)

                for i in searchStart..<searchEnd {
                    if consumedOldIndices.contains(i) { continue }
                    if i >= existingSubviews.count { continue }

                    let oldChild = oldChildren[i]
                    if canReuseElement(old: oldChild, new: newChild) {
                        let candidateView = existingSubviews[i]
                        if updateViewInPlace(candidateView, old: oldChild, new: newChild, containerWidth: contentWidth) {
                            foundIndex = i
                            break
                        }
                    }
                }

                if foundIndex != -1 {
                    consumedOldIndices.insert(foundIndex)
                    if foundIndex == searchStart { searchStart += 1 }
                    newSubviews.append(existingSubviews[foundIndex])
                } else {
                    // 创建新视图
                    let newView = createView(for: newChild, containerWidth: contentWidth)
                    newSubviews.append(newView)
                }
            }
            
            // Reconcile Subviews
            for (index, subview) in newSubviews.enumerated() {
                if index < contentContainer.arrangedSubviews.count {
                    let current = contentContainer.arrangedSubviews[index]
                    if current != subview {
                        contentContainer.insertArrangedSubview(subview, at: index)
                    }
                } else {
                    contentContainer.addArrangedSubview(subview)
                }
            }
            
            while contentContainer.arrangedSubviews.count > newSubviews.count {
                contentContainer.arrangedSubviews.last?.removeFromSuperview()
            }
            
            // 如果当前是展开状态，强制子视图重新布局
            if isExpanded {
                 for subview in contentContainer.arrangedSubviews {
                     recursivelyUpdateLayout(for: subview, width: contentWidth)
                 }
            }
            
            return true

        case (.image(let oldSrc, _), .image(let newSrc, _)):
            if oldSrc != newSrc {
                if let imageView = view.subviews.first(where: { $0 is ImageView }) as? ImageView {
                    imageView.accessibilityIdentifier = newSrc
                    imagePublisher(for: newSrc)
                        .sink { [weak imageView] image in
                            guard let image else { return }
                            imageView?.image = image
                        }
                        .store(in: &cancellables)
                }
            }
            return true
            
        case (.latex(let oldLatex), .latex(let newLatex)):
             // ⚡️ 性能优化：如果 LaTeX 内容没有变化，直接复用，避免 TextKit2 重新创建 ViewProvider
             if oldLatex == newLatex {
                 return true
             }
             // 如果内容变了（流式更新中比较少见，除非公式本身在变），目前没有原地更新逻辑，返回 false 触发重建
             return false
            
        case (.thematicBreak, .thematicBreak):
            return true

        // ⚡️ List 子元素复用优化（支持流式增量更新）
        case (.list(let oldItems, let oldLevel), .list(let newItems, let newLevel)):
            // 在可复用 Cell 场景下，列表原地更新容易残留旧布局状态，优先保证稳定性
            if isEmbeddedInReusableCell() {
                return false
            }

            // 层级不同，需要重建
            if oldLevel != newLevel {
                mdLog("⚠️ [List] Level changed: \(oldLevel) → \(newLevel), rebuilding")
                return false
            }

            // ⚡️ 允许 items 数量不同（流式渲染场景）
            // 只要新增的 items，其他部分可以复用
            mdLog("♻️ [List] Updating list: oldItems=\(oldItems.count) → newItems=\(newItems.count)")

            // 1. 验证视图结构 (List: indentWrapper (UIView) -> container (UIStackView))
            // ⚠️ 注意：createListView 返回的是 indentWrapper，不是 container！
            guard view.subviews.count > 0,
                  let container = view.subviews.first as? UIStackView else {
                let firstSubviewType = view.subviews.first.map { "\(type(of: $0))" } ?? "nil"
                mdLog("⚠️ [List] View structure validation failed, view type: \(type(of: view)), subviews: \(view.subviews.count), first subview: \(firstSubviewType)")
                return false
            }

            container.distribution = .fill
            container.isLayoutMarginsRelativeArrangement = false
            container.layoutMargins = .zero
            container.setContentHuggingPriority(.required, for: .vertical)
            container.setContentCompressionResistancePriority(.required, for: .vertical)

            // 2. 计算内容宽度和标记宽度
            let indent: CGFloat = configuration.listIndent
            let currentIndent = (oldLevel > 1) ? indent : 0
            let contentMaxWidth = max(0, containerWidth - currentIndent)
            updateListWrapperLayoutConstraints(view, width: containerWidth, indent: currentIndent)

            // 预计算最大标记宽度
            let maxMarkerWidth: CGFloat = {
                var maxWidth: CGFloat = configuration.listMarkerMinWidth
                for item in newItems {
                    let markerText = item.marker as NSString
                    let size = markerText.size(withAttributes: [.font: configuration.bodyFont])
                    maxWidth = max(maxWidth, ceil(size.width) + configuration.listMarkerSpacing)
                }
                return maxWidth
            }()

            let itemContentWidth = contentMaxWidth - maxMarkerWidth - configuration.listMarkerSpacing

            // 3. Diff & Patch 列表项
            let existingItemViews = container.arrangedSubviews
            var needsReconcile = false

            for (itemIndex, newItem) in newItems.enumerated() {
                if itemIndex < oldItems.count && itemIndex < existingItemViews.count {
                    // 尝试复用现有列表项
                    let oldItem = oldItems[itemIndex]
                    if let itemStack = existingItemViews[itemIndex] as? UIStackView,
                       itemStack.arrangedSubviews.count >= 2,
                       let contentStack = itemStack.arrangedSubviews[1] as? UIStackView {
                        itemStack.isLayoutMarginsRelativeArrangement = false
                        itemStack.layoutMargins = .zero
                        contentStack.isLayoutMarginsRelativeArrangement = false
                        contentStack.layoutMargins = .zero
                        itemStack.setContentHuggingPriority(.required, for: .vertical)
                        itemStack.setContentCompressionResistancePriority(.required, for: .vertical)
                        contentStack.setContentHuggingPriority(.required, for: .vertical)
                        contentStack.setContentCompressionResistancePriority(.required, for: .vertical)
                        // 统一项内间距，避免历史视图或增量更新路径出现 spacing 漂移
                        contentStack.spacing = 0
                        applyListDebugStyleIfNeeded(to: itemStack, color: .systemBlue)
                        applyListDebugStyleIfNeeded(to: contentStack, color: .systemGreen)
                    }

                    let oldVisibleChildren = visibleListChildren(in: oldItem)
                    let newVisibleChildren = visibleListChildren(in: newItem)

                    if oldItem.marker == newItem.marker,
                       oldVisibleChildren.count == newVisibleChildren.count {
                        // 检查子元素是否完全相同
                        var allChildrenMatch = true
                        for (oldChild, newChild) in zip(oldVisibleChildren, newVisibleChildren) {
                            if !elementsAreEqual(oldChild, newChild) {
                                allChildrenMatch = false
                                break
                            }
                        }

                        if allChildrenMatch {
                            // 完全相同，直接复用，无需操作
                            continue
                        } else {
                            // 子元素不同，尝试更新
                            if let itemStack = existingItemViews[itemIndex] as? UIStackView,
                               itemStack.arrangedSubviews.count >= 2,
                               let contentStack = itemStack.arrangedSubviews[1] as? UIStackView {

                                var newChildViews: [UIView] = []
                                let existingChildViews = contentStack.arrangedSubviews
                                contentStack.spacing = 0

                                for (childIndex, newChild) in newVisibleChildren.enumerated() {
                                    if childIndex < oldVisibleChildren.count,
                                       childIndex < existingChildViews.count {
                                        let oldChild = oldVisibleChildren[childIndex]
                                        if canReuseElement(old: oldChild, new: newChild) {
                                            let childView = existingChildViews[childIndex]
                                            if updateViewInPlace(childView, old: oldChild, new: newChild, containerWidth: itemContentWidth) {
                                                applyListDebugStyleIfNeeded(to: childView, color: .systemPink)
                                                newChildViews.append(childView)
                                                continue
                                            }
                                        }
                                    }
                                    // 创建新子视图
                                    let isFirst = (childIndex == 0)
                                    let childView = createView(for: newChild, containerWidth: itemContentWidth, suppressTopSpacing: isFirst, suppressBottomSpacing: true)
                                    applyListDebugStyleIfNeeded(to: childView, color: .systemPink)
                                    newChildViews.append(childView)
                                }

                                // Reconcile 子视图
                                for (index, subview) in newChildViews.enumerated() {
                                    if index < contentStack.arrangedSubviews.count {
                                        let current = contentStack.arrangedSubviews[index]
                                        if current != subview {
                                            contentStack.insertArrangedSubview(subview, at: index)
                                        }
                                    } else {
                                        contentStack.addArrangedSubview(subview)
                                    }
                                }

                                while contentStack.arrangedSubviews.count > newChildViews.count {
                                    contentStack.arrangedSubviews.last?.removeFromSuperview()
                                }

                                normalizeListContentStackLayout(contentStack, itemContentWidth: itemContentWidth)
                                continue
                            } else {
                                // 视图结构不符合预期，需要重建此项
                                needsReconcile = true
                                break
                            }
                        }
                    } else {
                        // marker 或子元素数量不同，需要重建此项
                        needsReconcile = true
                        break
                    }
                } else {
                    // ⚡️ 新增的列表项：创建新视图并添加
                    let itemStack = UIStackView()
                    itemStack.axis = .horizontal
                    itemStack.alignment = .top
                    itemStack.spacing = configuration.listMarkerSpacing
                    itemStack.isLayoutMarginsRelativeArrangement = false
                    itemStack.layoutMargins = .zero
                    itemStack.translatesAutoresizingMaskIntoConstraints = false
                    itemStack.setContentHuggingPriority(.required, for: .vertical)
                    itemStack.setContentCompressionResistancePriority(.required, for: .vertical)
                    applyListDebugStyleIfNeeded(to: itemStack, color: .systemBlue)

                    // 标记
                    let markerLabel = UILabel()
                    markerLabel.text = newItem.marker
                    markerLabel.font = configuration.bodyFont
                    markerLabel.textColor = configuration.textColor
                    markerLabel.setContentHuggingPriority(.required, for: .horizontal)
                    markerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
                    markerLabel.widthAnchor.constraint(equalToConstant: maxMarkerWidth).isActive = true
                    markerLabel.textAlignment = .right
                    applyListDebugStyleIfNeeded(to: markerLabel, color: .systemYellow)
                    itemStack.addArrangedSubview(markerLabel)

                    // 内容容器
                    let contentStack = UIStackView()
                    contentStack.axis = .vertical
                    contentStack.spacing = 0
                    contentStack.alignment = .fill
                    contentStack.isLayoutMarginsRelativeArrangement = false
                    contentStack.layoutMargins = .zero
                    contentStack.translatesAutoresizingMaskIntoConstraints = false
                    contentStack.setContentHuggingPriority(.required, for: .vertical)
                    contentStack.setContentCompressionResistancePriority(.required, for: .vertical)
                    applyListDebugStyleIfNeeded(to: contentStack, color: .systemGreen)

                    let visibleChildren = visibleListChildren(in: newItem)
                    for (childIndex, childElement) in visibleChildren.enumerated() {
                        let isFirst = (childIndex == 0)
                        let childView = createView(for: childElement, containerWidth: itemContentWidth, suppressTopSpacing: isFirst, suppressBottomSpacing: true)
                        applyListDebugStyleIfNeeded(to: childView, color: .systemPink)
                        contentStack.addArrangedSubview(childView)
                    }

                    normalizeListContentStackLayout(contentStack, itemContentWidth: itemContentWidth)
                    itemStack.addArrangedSubview(contentStack)
                    container.addArrangedSubview(itemStack)
                }
            }

            // 如果出现需要重建的情况，返回 false 触发完整重建
            if needsReconcile {
                mdLog("⚠️ [List] needsReconcile=true, triggering full rebuild")
                return false
            }

            // 移除多余的旧列表项
            while container.arrangedSubviews.count > newItems.count {
                container.arrangedSubviews.last?.removeFromSuperview()
            }

            // 自愈旧布局状态：即使内容未变化，也按当前宽度统一重排一次，避免首项高度沿用旧值
            for arranged in container.arrangedSubviews {
                guard let itemStack = arranged as? UIStackView,
                      itemStack.arrangedSubviews.count >= 2,
                      let contentStack = itemStack.arrangedSubviews[1] as? UIStackView else { continue }
                normalizeListContentStackLayout(contentStack, itemContentWidth: itemContentWidth)
            }

            mdLog("✅ [List] Successfully updated, reused existing views")
            return true

        case (.custom(let oldData), .custom(let newData)):
            // 自定义元素：如果类型相同且数据相同，直接复用
            if oldData == newData {
                return true
            }
            // 类型相同但数据不同，重新创建视图
            return false

        default:
            break
        }

        return false
    }
    
    func scheduleRerender() {
        renderWorkItem?.cancel()
        // ⚡️ 取消待执行的离屏渲染任务（因为内容已变更）
        offscreenRenderWorkItem?.cancel()

        // ⚡️ 移除占位视图（如果存在）
        if let placeholder = placeholderView {
            placeholder.removeFromSuperview()
            placeholderView = nil
        }

        // Real streaming owns its incremental parse/render pipeline.
        if isStreaming {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.performRender()
        }
        renderWorkItem = workItem

        // 🔍 性能监控：打印调度延迟
        if renderStartTime > 0 {
            let elapsed = (CFAbsoluteTimeGetCurrent() - renderStartTime) * 1000
            mdLog("🔍 [Perf] scheduleRerender: +\(String(format: "%.1f", elapsed))ms (delay 16ms)")
        }

        // 延迟执行以合并多次快速更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: workItem)
    }

}
