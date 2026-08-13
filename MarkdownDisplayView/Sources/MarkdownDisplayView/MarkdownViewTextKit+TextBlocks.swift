//
//  MarkdownViewTextKit+TextBlocks.swift
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
    // MARK: - Text View Creation (修复版)

        func normalizedAttributedTextForRendering(
            _ text: NSAttributedString,
            trimLeadingNewlines: Bool = false,
            trimTrailingNewlines: Bool = true
        ) -> NSAttributedString {
            let mutable = NSMutableAttributedString(attributedString: text)

            if trimLeadingNewlines {
                while mutable.length > 0, mutable.string.hasPrefix("\n") {
                    mutable.deleteCharacters(in: NSRange(location: 0, length: 1))
                }
            }

            if trimTrailingNewlines {
                while mutable.length > 0, mutable.string.hasSuffix("\n") {
                    mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
                }
            }
            return mutable
        }
        
        func createTextView(
            with attributedString: NSAttributedString,
            width: CGFloat,
            insets: UIEdgeInsets = .zero,
            fixedHeight: CGFloat? = nil
        ) -> UIView {
            let normalizedText = normalizedAttributedTextForRendering(attributedString)

            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            
            let textView = MarkdownTextViewTK2()
            textView.attributedText = normalizedText
            textView.typewriterTextMode = configuration.typewriterTextMode
            textView.typewriterHeightUpdateInterval = configuration.typewriterHeightUpdateInterval
            textView.linkTextAttributes = [
                .foregroundColor: configuration.linkColor,
                .underlineStyle: configuration.linkUnderlineEnabled
                    ? NSUnderlineStyle.single.rawValue : 0,
            ]
            textView.onLinkTap = { [weak self] url in
                self?.handleLinkTap(url)
            }
            textView.onImageTap = { [weak self] urlString in
                self?.onImageTap?(urlString)
            }
            textView.translatesAutoresizingMaskIntoConstraints = false
            
            // 🔥 核心修复：立即应用布局
            // 计算文本实际可用的宽度（减去内边距）
            let contentWidth = width - insets.left - insets.right
            if contentWidth > 0 {
                let useAppendTypewriter = enableTypewriterEffect && configuration.typewriterTextMode == .append
                if let fixedHeight = fixedHeight {
                    // 完整块已经解析完成，直接采用最终高度；只对普通文字使用 1pt 增长路径。
                    textView.textContainer.size = CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
                    textView.setFixedHeight(fixedHeight)
                } else if useAppendTypewriter {
                    textView.textContainer.size = CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
                    textView.setFixedHeight(1)
                } else {
                    textView.applyLayout(width: contentWidth, force: true)
                }
            }
            
            container.addSubview(textView)
            
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
                textView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
                textView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
                textView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
            ])
            
            // 保持垂直方向的抗压缩优先级，防止被压缩
            container.setContentHuggingPriority(.required, for: .vertical)
            container.setContentCompressionResistancePriority(.required, for: .vertical)
            
            return container
        }
    
    func handleLinkTap(_ url: URL) {
        // 检查是否是内部锚点链接
        if url.scheme == nil || url.scheme == "markdown" {
            var fragment = url.fragment ?? url.absoluteString.replacingOccurrences(of: "#", with: "")
            
            if let decoded = fragment.removingPercentEncoding {
                fragment = decoded
            }
            
            if !fragment.isEmpty {
                if headingViews[fragment] != nil {
                    scrollToTOCItem(MarkdownTOCItem(level: 1, title: "", id: fragment))
                    return
                }
                
                if let item = tableOfContents.first(where: {
                    $0.title.contains(fragment) || fragment.contains($0.title)
                }) {
                    scrollToTOCItem(item)
                    return
                }
            }
        }
        
        onLinkTap?(url)
    }
    
    // MARK: - Quote View
    
    /// 创建引用块视图 - 支持嵌套块级元素（表格、代码块、子列表等）
    func createQuoteView(children: [MarkdownRenderElement], width: CGFloat, level: Int = 1) -> UIView {
        let outerContainer = UIView()
        outerContainer.translatesAutoresizingMaskIntoConstraints = false
        // 引用块内部可能包含多段文本、列表、表格甚至嵌套引用。流式打字时递归进入
        // 每个子节点会反复改变整块高度并触发全局布局；把引用作为一个完整块淡入。
        outerContainer.accessibilityIdentifier = "MarkdownAtomicQuote"

        let container = UIView()
        container.backgroundColor = configuration.blockquoteBackgroundColor
        container.layer.applyMarkdownBlockAppearance(configuration.blockquoteAppearance)
        container.layer.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        outerContainer.addSubview(container)

        // 左侧竖线
        let bar = UIView()
        bar.backgroundColor = configuration.blockquoteBarColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)

        // 创建内容 StackView - 支持垂直堆叠多个子元素
        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = configuration.blockquoteContentSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)

        // 每层应用固定的缩进增量，而不是累积值
        // Level 1: 0pt, Level 2+: 20pt (相对于父级)
        let leftIndent: CGFloat = (level > 1) ? 20 : 0

        // 计算子元素可用宽度
        let barWidth = configuration.blockquoteBarWidth
        let contentPadding = configuration.blockquoteContentPadding
        let padding = leftIndent + barWidth + contentPadding + contentPadding / 1.5  // leftIndent + barWidth + contentLeading + contentTrailing
        let contentWidth = max(0, width - padding)

        // 递归创建子视图
        for child in children {
            let childView = createView(for: child, containerWidth: contentWidth)
            contentStack.addArrangedSubview(childView)
        }

        let widthConstraint = outerContainer.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            widthConstraint,
            container.topAnchor.constraint(equalTo: outerContainer.topAnchor, constant: 4),
            container.leadingAnchor.constraint(equalTo: outerContainer.leadingAnchor, constant: leftIndent),
            container.trailingAnchor.constraint(equalTo: outerContainer.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: outerContainer.bottomAnchor),

            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: barWidth),

            contentStack.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: contentPadding),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -contentPadding / 1.5),
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: configuration.blockquoteContentSpacing),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -configuration.blockquoteContentSpacing),
        ])

        return outerContainer
    }
    
    // MARK: - Thematic Break View
    
    func createThematicBreakView(width: CGFloat) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        
        let lineView = UIView()
        lineView.backgroundColor = configuration.horizontalRuleColor
        lineView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lineView)
        
        let widthConstraint = container.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 24),
            widthConstraint,
            lineView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            lineView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lineView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lineView.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])
        
        return container
    }
    
    // MARK: - Details View

    func createDetailsView(
        summary: String,
        children: [MarkdownRenderElement],
        width: CGFloat
    ) -> UIView {
        let createTime = CFAbsoluteTimeGetCurrent()
        mdLog("[STREAM] 📦 Details 开始创建: \(summary), 包含 \(children.count) 个子元素")

        // 外层容器，添加上下间距
        let outerContainer = UIView()
        outerContainer.translatesAutoresizingMaskIntoConstraints = false
        // Details 在语法完整后作为整块显示，内部内容不再递归逐字。
        outerContainer.accessibilityIdentifier = "MarkdownAtomicDetails_\(streamingStartTimestamp)_\(createTime)"

        // 🔧 设置容器的内容优先级，防止被压缩（类似图片修复）
        outerContainer.setContentHuggingPriority(.required, for: .vertical)
        outerContainer.setContentCompressionResistancePriority(.required, for: .vertical)

        let container = UIStackView()
        container.axis = .vertical
        container.spacing = configuration.detailsSpacing  // 使用配置的间距
        container.alignment = .fill
        container.distribution = .fill
        container.translatesAutoresizingMaskIntoConstraints = false

        // 🔧 StackView也设置抗压缩优先级
        container.setContentHuggingPriority(.required, for: .vertical)
        container.setContentCompressionResistancePriority(.required, for: .vertical)

        outerContainer.addSubview(container)

        let summaryButton = UIButton(type: .system)

        // 使用 UIButton.Configuration 设置样式
        var buttonConfig = UIButton.Configuration.plain()
        buttonConfig.title = "▶ " + summary
        let buttonPadding = configuration.detailsContentPadding
        buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: buttonPadding * 0.8, leading: buttonPadding, bottom: buttonPadding * 0.8, trailing: buttonPadding)
        buttonConfig.background.backgroundColor = configuration.codeBackgroundColor.withAlphaComponent(0.3)
        buttonConfig.background.cornerRadius = max(0, configuration.detailsAppearance.cornerRadius)
        buttonConfig.baseForegroundColor = configuration.detailsSummaryTextColor
        buttonConfig.titleAlignment = .leading

        summaryButton.configuration = buttonConfig
        summaryButton.layer.applyMarkdownBlockAppearance(configuration.detailsAppearance)
        summaryButton.layer.masksToBounds = true
        summaryButton.titleLabel?.font = configuration.detailsSummaryFont
        summaryButton.contentHorizontalAlignment = .left
        summaryButton.isUserInteractionEnabled = true  // 确保可点击
        summaryButton.setContentHuggingPriority(.required, for: .vertical)
        summaryButton.setContentCompressionResistancePriority(.required, for: .vertical)

        // 🔧 核心修复：为按钮添加明确的最小高度约束，防止被压缩到0
        summaryButton.translatesAutoresizingMaskIntoConstraints = false
        let buttonHeightConstraint = summaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: configuration.detailsSummaryMinHeight)
        buttonHeightConstraint.priority = .required
        buttonHeightConstraint.isActive = true

        container.addArrangedSubview(summaryButton)

        // Wrapper View (Plain UIView to handle hiding cleanly)
        let contentWrapper = UIView()
        contentWrapper.isHidden = true
        contentWrapper.translatesAutoresizingMaskIntoConstraints = false
        contentWrapper.backgroundColor = configuration.codeBackgroundColor
        contentWrapper.layer.applyMarkdownBlockAppearance(configuration.detailsAppearance)
        contentWrapper.layer.masksToBounds = true
        container.addArrangedSubview(contentWrapper)

        let contentContainer = UIStackView()
        contentContainer.axis = .vertical
        contentContainer.spacing = 0
        contentContainer.alignment = .fill
        contentContainer.distribution = .fill
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        let contentPadding = configuration.detailsContentPadding
        contentContainer.layoutMargins = UIEdgeInsets(top: contentPadding * 0.67, left: contentPadding, bottom: contentPadding * 0.67, right: contentPadding)
        contentContainer.isLayoutMarginsRelativeArrangement = true
        contentWrapper.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: contentWrapper.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentWrapper.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: contentWrapper.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentWrapper.trailingAnchor)
        ])

        // 🔥 修复：正确计算内容宽度
        // layoutMargins 是 left + right，所以需要减去
        let contentWidth = width - contentPadding * 2
        var latexCount = 0
        var latexTotalTime: Double = 0
        for (index, child) in children.enumerated() {
            let childStart = CFAbsoluteTimeGetCurrent()
            let childView = createView(for: child, containerWidth: contentWidth)
            let childTime = CFAbsoluteTimeGetCurrent() - childStart

            // 统计 LaTeX
            if case .latex = child {
                latexCount += 1
                latexTotalTime += childTime
            }

            if childTime > 0.01 { // 超过 10ms 的子元素
                mdLog("[STREAM] 📦 Details 子元素 \(index + 1)/\(children.count) 耗时: \(String(format: "%.1f", childTime * 1000))ms")
            }

            if let textView = childView as? MarkdownTextViewTK2,
               textView.attributedText?.length == 0 {
                continue
            }
            contentContainer.addArrangedSubview(childView)
        }

        if latexCount > 0 {
            mdLog("[STREAM] 📦 Details 包含 \(latexCount) 个 LaTeX，LaTeX 总耗时: \(String(format: "%.1f", latexTotalTime * 1000))ms")
        }
        
        summaryButton.addAction(
            UIAction { [weak self, weak contentWrapper, weak contentContainer, weak summaryButton, weak container] _ in
                guard let self = self,
                      let wrapper = contentWrapper,
                      let content = contentContainer,
                      let btn = summaryButton,
                      let containerWrapper = container
                else { return }
                
                // 🔒 锁定流式更新，防止状态覆盖
                self.isUserInteractingWithDetails = true
                // 1秒后自动解锁，防止永久死锁
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.isUserInteractingWithDetails = false
                }
                
                let willShow = wrapper.isHidden

                // 更新按钮标题（使用 configuration）
                var config = btn.configuration
                config?.title = (willShow ? "▼ " : "▶ ") + summary
                btn.configuration = config

                // ⭐️ 使用动画平滑过渡，避免闪烁
                if willShow {
                    // [Expand Flow] - 先准备内容，再显示
                    wrapper.isHidden = false
                    wrapper.alpha = 0

                    // 恢复子视图优先级
                    content.arrangedSubviews.forEach {
                        $0.isHidden = false
                        $0.setContentCompressionResistancePriority(.required, for: .vertical)
                    }

                    // 计算实际可用宽度
                    let containerWidth = self.bounds.width > 0 ? self.bounds.width : UIScreen.main.bounds.width - 32
                    let contentWidth = containerWidth - 24

                    // 递归强制更新所有子视图的布局
                    for subview in content.arrangedSubviews {
                        self.recursivelyUpdateLayout(for: subview, width: contentWidth)
                    }

                    // 动画显示
                    UIView.animate(withDuration: 0.25) {
                        wrapper.alpha = 1
                        self.layoutIfNeeded()
                    }

                } else {
                    // [Collapse Flow] - 动画隐藏，完成后清理
                    UIView.animate(withDuration: 0.2, animations: {
                        wrapper.alpha = 0
                    }) { _ in
                        wrapper.isHidden = true

                        // 隐藏子视图 & 降低优先级
                        content.arrangedSubviews.forEach {
                            $0.isHidden = true
                            $0.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                        }

                        // ⭐️ 收起动画完成后再更新布局和高度
                        self.setNeedsLayout()
                        self.layoutIfNeeded()
                        self.invalidateIntrinsicContentSize()
                        self.contentStackView.layoutIfNeeded()

                        // 通知高度变化
                        var totalHeight: CGFloat = 0
                        for subview in self.contentStackView.arrangedSubviews {
                            if !subview.isHidden {
                                totalHeight += subview.frame.height
                            }
                        }
                        let visibleCount = self.contentStackView.arrangedSubviews.filter { !$0.isHidden }.count
                        if visibleCount > 1 {
                            totalHeight += CGFloat(visibleCount - 1) * self.contentStackView.spacing
                        }
                        totalHeight += self.contentStackView.layoutMargins.top + self.contentStackView.layoutMargins.bottom

                        if self.isRealStreamingMode {
                            self.realStreamHeightAccumulator.synchronize(totalHeight: totalHeight)
                            self.invalidateIntrinsicContentSize()
                        }
                        self.cacheIntrinsicHeight(totalHeight)
                        self.lastReportedHeight = totalHeight
                        self.onHeightChange?(totalHeight)
                    }
                    return  // ⭐️ 收起时直接返回，高度更新在动画完成后处理
                }

                // 3. 通知外部 (TableView) 更新（仅展开时执行）
                self.setNeedsLayout()
                self.layoutIfNeeded()
                self.invalidateIntrinsicContentSize()
                
                // 🔥 终极修复：不再依赖 systemLayoutSizeFitting，而是直接计算 StackView 的实际高度
                // 延迟一小段时间等待布局引擎稳定
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    // 强制再次刷新布局
                    self.contentStackView.layoutIfNeeded()
                    
                    // 手动计算高度：遍历所有子视图的 frame
                    var totalHeight: CGFloat = 0
                    for subview in self.contentStackView.arrangedSubviews {
                        if !subview.isHidden {
                            totalHeight += subview.frame.height
                        }
                    }
                    // 加上 spacing
                    let visibleCount = self.contentStackView.arrangedSubviews.filter { !$0.isHidden }.count
                    if visibleCount > 1 {
                        totalHeight += CGFloat(visibleCount - 1) * self.contentStackView.spacing
                    }
                    // 加上 insets (如果有)
                    totalHeight += self.contentStackView.layoutMargins.top + self.contentStackView.layoutMargins.bottom
                    
                    if self.isRealStreamingMode {
                        self.realStreamHeightAccumulator.synchronize(totalHeight: totalHeight)
                        self.invalidateIntrinsicContentSize()
                    }
                    self.cacheIntrinsicHeight(totalHeight)
                    // 强制通知
                    self.lastReportedHeight = totalHeight
                    self.onHeightChange?(totalHeight)
                }

            }, for: .touchUpInside)

        // 添加外层容器约束，添加上下间距（8pt）
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: outerContainer.topAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: outerContainer.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: outerContainer.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: outerContainer.bottomAnchor, constant: -8)
        ])

        // 🔍 调试日志：监控Details视图布局
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            mdLog("🔍 [Details Debug] outerContainer frame: \(outerContainer.frame)")
            mdLog("🔍 [Details Debug] container frame: \(container.frame)")
            mdLog("🔍 [Details Debug] summaryButton frame: \(summaryButton.frame)")
            mdLog("🔍 [Details Debug] summaryButton isUserInteractionEnabled: \(summaryButton.isUserInteractionEnabled)")
            mdLog("🔍 [Details Debug] container isUserInteractionEnabled: \(container.isUserInteractionEnabled)")
            mdLog("🔍 [Details Debug] outerContainer isUserInteractionEnabled: \(outerContainer.isUserInteractionEnabled)")
        }

        let totalTime = (CFAbsoluteTimeGetCurrent() - createTime) * 1000
        mdLog("[STREAM] 📦 Details 创建完成: \(summary), 总耗时: \(String(format: "%.1f", totalTime))ms")

        return outerContainer
    }
    
    // 递归查找并更新 MarkdownTextViewTK2 布局
    func recursivelyUpdateLayout(for view: UIView, width: CGFloat) {
        var currentWidth = width
        
        // 1. 如果遇到 StackView 且启用了 margins，减去 margins (处理嵌套 Details)
        if let stackView = view as? UIStackView, stackView.isLayoutMarginsRelativeArrangement {
            currentWidth = max(0, currentWidth - stackView.layoutMargins.left - stackView.layoutMargins.right)
        }
        
        // 2. 如果是 TextKit2 视图，直接应用布局
        if let textView = view as? MarkdownTextViewTK2 {
            // 优先使用实际宽度（更准确，支持多级嵌套），防止 layout 尚未完成时的 0 宽
            if textView.bounds.width > 1.0 {
                textView.applyLayout(width: textView.bounds.width, force: true)
                return
            }
            
            // Fallback: 使用递归传递下来的 calculated width
            // 需要结合 textView 自身的容器 padding 逻辑
            var availableWidth = currentWidth
            if let superview = textView.superview {
                // CodeBlock container
                if superview.accessibilityIdentifier == "CodeBlockContainer" {
                    availableWidth = max(0, currentWidth - 24)
                } 
                // Quote container
                else if superview.subviews.contains(where: { $0.backgroundColor == configuration.blockquoteBarColor }) {
                    // 简化的 Quote padding 计算
                    let padding: CGFloat = 4 + 12 + 8
                    availableWidth = max(0, currentWidth - padding)
                }
            }
            
            textView.applyLayout(width: availableWidth, force: true)
            return
        }
        
        // 3. 递归查找子视图
        for subview in view.subviews {
            recursivelyUpdateLayout(for: subview, width: currentWidth)
        }
    }

    /// 强制重绘容器内的所有 TextKit2 视图
    func forceRedrawVisibleTextViews(in view: UIView) {
        if let textView = view as? MarkdownTextViewTK2 {
            textView.setNeedsDisplay()
        }
        
        for subview in view.subviews {
            forceRedrawVisibleTextViews(in: subview)
        }
    }
    
}
