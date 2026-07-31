//
//  LaTeXAttachment.swift
//  MarkdownDisplayView
//
//  Created by AI Assistant on 12/19/25.
//

import UIKit

/// LaTeX 公式附件，用于在 TextKit 2 中显示数学公式
@available(iOS 15.0, *)
public final class LaTeXAttachment: NSTextAttachment {

    /// LaTeX 公式内容
    let latex: String

    /// 字体大小
    let fontSize: CGFloat

    /// 容器最大宽度（用于滚动）
    let maxWidth: CGFloat

    /// 内边距
    let padding: CGFloat

    /// 背景颜色
    let backgroundColor: UIColor

    /// 测量和绘制全链路共享的唯一渲染结果。
    let renderResult: LatexRenderResult

    /// 缓存的 ViewProvider 实例（避免重复创建）
    private var cachedViewProvider: LaTeXAttachmentViewProvider?

    /// 初始化 LaTeX 附件
    /// - Parameters:
    ///   - latex: LaTeX 公式字符串
    ///   - fontSize: 字体大小
    ///   - maxWidth: 最大宽度
    ///   - padding: 内边距
    ///   - backgroundColor: 背景颜色
    public convenience init(
        latex: String,
        fontSize: CGFloat = 22,
        maxWidth: CGFloat,
        padding: CGFloat = 20,
        backgroundColor: UIColor = UIColor.systemGray6.withAlphaComponent(0.5)
    ) {
        let calcStart = CFAbsoluteTimeGetCurrent()
        let renderResult = LatexRenderResult.parse(
            latex: latex,
            fontSize: fontSize,
            padding: padding,
            maxWidth: maxWidth
        )
        mdLog("[STREAM] 📐📐📐 LaTeXAttachment 解析与尺寸计算耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - calcStart) * 1000))ms")
        self.init(
            latex: latex,
            fontSize: fontSize,
            maxWidth: maxWidth,
            padding: padding,
            backgroundColor: backgroundColor,
            renderResult: renderResult
        )
    }

    init(
        latex: String,
        fontSize: CGFloat,
        maxWidth: CGFloat,
        padding: CGFloat,
        backgroundColor: UIColor,
        renderResult: LatexRenderResult
    ) {
        let initStart = CFAbsoluteTimeGetCurrent()
        mdLog("[STREAM] 📐📐📐 LaTeXAttachment 初始化开始: \(latex.prefix(40))...")

        self.latex = latex
        self.fontSize = fontSize
        self.maxWidth = maxWidth
        self.padding = padding
        self.backgroundColor = backgroundColor
        self.renderResult = renderResult

        super.init(data: nil, ofType: nil)

        // Set an empty image to prevent the default placeholder icon from appearing
        self.image = UIImage()

        // ⚡️ 注册 ViewProvider 类
        self.lineLayoutPadding = 0

        mdLog("[STREAM] 📐📐📐 LaTeXAttachment 初始化完成，总耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - initStart) * 1000))ms")
    }

    /// 提供自定义 ViewProvider（缓存实例避免重复创建）
    public override func viewProvider(
        for parentView: UIView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        // ⚡️ 如果已有缓存实例，直接返回
        if let cached = cachedViewProvider {
            return cached
        }

        // 创建新实例并缓存
        let provider = LaTeXAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        cachedViewProvider = provider
        return provider
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 返回附件的边界
    public override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        // 返回独立一行的尺寸
        CGRect(origin: .zero, size: renderResult.displaySize)
    }
}

/// LaTeX 附件视图提供者
@available(iOS 15.0, *)
public final class LaTeXAttachmentViewProvider: NSTextAttachmentViewProvider {

    /// 标记视图是否已经创建过
    private var isViewLoaded = false

    override public init(
        textAttachment: NSTextAttachment,
        parentView: UIView?,
        textLayoutManager: NSTextLayoutManager?,
        location: NSTextLocation
    ) {
        super.init(
            textAttachment: textAttachment,
            parentView: parentView,
            textLayoutManager: textLayoutManager,
            location: location
        )
    }

    /// 加载视图
    override public func loadView() {
        let loadStart = CFAbsoluteTimeGetCurrent()

        // ⚡️ 如果已经加载过，直接返回（避免重复创建）
        if isViewLoaded {
            mdLog("[STREAM] 📐📐📐 loadView() 已缓存，跳过创建")
            return
        }

        guard let attachment = textAttachment as? LaTeXAttachment else {
            super.loadView()
            return
        }

        mdLog("[STREAM] 📐📐📐 loadView() 开始创建公式视图: \(attachment.latex.prefix(30))...")

        // 直接复用 Attachment 初始化时的解析树和尺寸，不再解析或重新测量。
        let viewStart = CFAbsoluteTimeGetCurrent()
        let (formulaView, _) = LatexMathView.createScrollableView(
            renderResult: attachment.renderResult,
            backgroundColor: attachment.backgroundColor
        )
        mdLog("[STREAM] 📐📐📐 loadView 视图创建耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - viewStart) * 1000))ms")

        // ⚡️ 设置明确的 frame（NSTextAttachmentViewProvider 需要）
        formulaView.frame = CGRect(origin: .zero, size: attachment.renderResult.displaySize)

        // 设置视图并标记已加载
        self.view = formulaView
        isViewLoaded = true

        mdLog("[STREAM] 📐📐📐 loadView() 完成，总耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - loadStart) * 1000))ms")
    }

    
}
