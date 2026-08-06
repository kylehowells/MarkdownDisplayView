//
//  LatexMathView.swift
//  LateXDemo
//
//  Created by 朱继超 on 12/19/25.
//

import UIKit

/// 一次公式解析产生的不可变结果。
///
/// `rootNode` 和它的固有尺寸必须来自同一次解析，避免测量和绘制分别解析后
/// 得到不一致的节点树。对象身份本身即可表达本次渲染，不需要额外 UUID。
struct ParsedFormula {
    let latex: String
    let fontSize: CGFloat
    let rootNode: FormulaRenderNode
    let intrinsicSize: CGSize

    static func parse(latex: String, fontSize: CGFloat) -> ParsedFormula {
        let parser = LatexParser(latex: latex, font: UIFont.systemFont(ofSize: fontSize))
        return make(latex: latex, fontSize: fontSize, parse: parser.parse)
    }

    /// 解析入口可注入只用于验证解析次数；生产代码使用上面的便捷方法。
    static func make(
        latex: String,
        fontSize: CGFloat,
        parse: () -> FormulaRenderNode
    ) -> ParsedFormula {
        let rootNode = parse()
        return ParsedFormula(
            latex: latex,
            fontSize: fontSize,
            rootNode: rootNode,
            intrinsicSize: rootNode.size
        )
    }
}

/// 一个附件从测量到绘制共享的不可变渲染结果。
struct LatexRenderResult {
    let formula: ParsedFormula
    let padding: CGFloat
    let maxWidth: CGFloat
    let contentSize: CGSize
    let displaySize: CGSize

    init(formula: ParsedFormula, padding: CGFloat, maxWidth: CGFloat) {
        self.formula = formula
        self.padding = padding
        self.maxWidth = maxWidth

        let contentSize = CGSize(
            width: formula.intrinsicSize.width + padding,
            height: formula.intrinsicSize.height + padding
        )
        self.contentSize = contentSize
        self.displaySize = CGSize(
            width: min(contentSize.width, maxWidth),
            height: contentSize.height
        )
    }

    static func parse(
        latex: String,
        fontSize: CGFloat,
        padding: CGFloat,
        maxWidth: CGFloat
    ) -> LatexRenderResult {
        LatexRenderResult(
            formula: ParsedFormula.parse(latex: latex, fontSize: fontSize),
            padding: padding,
            maxWidth: maxWidth
        )
    }
}

// ==========================================
// MARK: - 6. 视图层 (View)
// ==========================================

class LatexMathView: UIView {

    private var _latex: String = ""
    private var _fontSize: CGFloat = 24.0

    /// 单独赋值仍会立即重解析；若同时要改公式和字号，请用 `configure(latex:fontSize:)`
    var latex: String {
        get { _latex }
        set { configure(latex: newValue, fontSize: _fontSize) }
    }

    var fontSize: CGFloat {
        get { _fontSize }
        set { configure(latex: _latex, fontSize: newValue) }
    }

    /// 一次性设置公式与字号，只触发一次解析。
    ///
    /// 原先 latex / fontSize 是两个独立 didSet，先后赋值会把同一个公式解析两遍。
    func configure(latex: String, fontSize: CGFloat) {
        guard _latex != latex || _fontSize != fontSize else { return }
        _latex = latex
        _fontSize = fontSize
        parseAndRender()
    }

    private var parsedFormula: ParsedFormula?

    /// 公式节点未显式指定颜色时使用的前景色。
    private(set) var formulaTextColor: UIColor = .label

    /// 供附件渲染链验证是否复用了同一次解析结果。
    var renderedFormula: ParsedFormula? { parsedFormula }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // 确保字体已注册
        FontLoader.ensureFontsRegistered()
    }

    convenience init(parsedFormula: ParsedFormula, textColor: UIColor = .label) {
        self.init(frame: .zero)
        formulaTextColor = textColor
        apply(parsedFormula)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        // 确保字体已注册
        FontLoader.ensureFontsRegistered()
    }
    
    private func parseAndRender() {
        let parseStart = CFAbsoluteTimeGetCurrent()
        apply(ParsedFormula.parse(latex: _latex, fontSize: _fontSize))
        mdLog("[STREAM] 📐📐 LaTeX 解析耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - parseStart) * 1000))ms")
    }

    private func apply(_ formula: ParsedFormula) {
        _latex = formula.latex
        _fontSize = formula.fontSize
        parsedFormula = formula
        setNeedsDisplay()
        invalidateIntrinsicContentSize()
    }
    
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let root = parsedFormula?.rootNode else { return }

        let resolvedTextColor = formulaTextColor.resolvedColor(with: traitCollection)
        
        // 居中绘制
        let startX = (rect.width - root.size.width) / 2
        let startY = (rect.height - root.size.height) / 2
        
        // 翻转坐标系 (如果需要的话，但这里我们尽量使用了 UIKit 坐标)
        // 我们的 Node 实现是基于左上角(Upper-Left)的逻辑，配合 UIKit
        
        root.draw(
            in: context,
            at: CGPoint(x: startX, y: startY),
            foregroundColor: resolvedTextColor
        )
    }
    
    override var intrinsicContentSize: CGSize {
        parsedFormula?.intrinsicSize ?? .zero
    }
}

extension LatexMathView {

      /// 创建可滚动的公式视图（当公式过长时可以水平滚动）
      /// - Parameters:
      ///   - latex: LaTeX 公式
      ///   - fontSize: 字体大小
      ///   - maxWidth: 最大显示宽度，超过则启用滚动
      ///   - padding: 内边距
      ///   - backgroundColor: 背景色
      /// - Returns: 包装好的视图（如果需要滚动返回 UIScrollView，否则返回 LatexMathView 本身）
      ///   与其内容尺寸 —— 尺寸随视图一起返回，避免调用方再走一次 calculateSize 重复解析
      static func createScrollableView(
          latex: String,
          fontSize: CGFloat = 22,
          maxWidth: CGFloat,
          padding: CGFloat = 20,
          backgroundColor: UIColor = UIColor.systemGray6.withAlphaComponent(0.5),
          textColor: UIColor = .label,
          appearance: MarkdownBlockAppearance = MarkdownBlockAppearance(cornerRadius: 8)
      ) -> (view: UIView, contentSize: CGSize) {
          let renderResult = LatexRenderResult.parse(
              latex: latex,
              fontSize: fontSize,
              padding: padding,
              maxWidth: maxWidth
          )
          return createScrollableView(
              renderResult: renderResult,
              backgroundColor: backgroundColor,
              textColor: textColor,
              appearance: appearance
          )
      }

      /// 使用已经解析好的结果创建视图，测量与绘制不会再次解析公式。
      static func createScrollableView(
          renderResult: LatexRenderResult,
          backgroundColor: UIColor = UIColor.systemGray6.withAlphaComponent(0.5),
          textColor: UIColor = .label,
          appearance: MarkdownBlockAppearance = MarkdownBlockAppearance(cornerRadius: 8)
      ) -> (view: UIView, contentSize: CGSize) {
          let totalStart = CFAbsoluteTimeGetCurrent()
          mdLog("[STREAM] 📐📐 createScrollableView 开始: \(renderResult.formula.latex.prefix(40))...")

          // 1. MathView 直接使用附件解析结果，不再解析。
          let mathViewStart = CFAbsoluteTimeGetCurrent()
          let mathView = LatexMathView(parsedFormula: renderResult.formula, textColor: textColor)
          mathView.backgroundColor = backgroundColor
          mdLog("[STREAM] 📐📐 LatexMathView 实例化耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - mathViewStart) * 1000))ms")

          // 2. 计算尺寸
          let sizeStart = CFAbsoluteTimeGetCurrent()
          let mathSize = renderResult.formula.intrinsicSize
          let contentWidth = renderResult.contentSize.width
          let contentHeight = renderResult.contentSize.height
          mdLog("[STREAM] 📐📐 intrinsicContentSize 计算耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - sizeStart) * 1000))ms, 尺寸: \(mathSize)")

          let contentSize = renderResult.contentSize

          // 3. 判断是否需要滚动
          if contentWidth <= renderResult.maxWidth {
              // 不需要滚动，直接返回 mathView
              mathView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
              mathView.layer.applyMarkdownBlockAppearance(appearance)
              mathView.layer.masksToBounds = true
              mdLog("[STREAM] 📐📐 createScrollableView 完成(无滚动)，总耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - totalStart) * 1000))ms")
              return (mathView, contentSize)
          } else {
              // 需要滚动，包裹在 ScrollView 中
              let scrollView = UIScrollView()
              scrollView.contentSize = contentSize
              scrollView.showsHorizontalScrollIndicator = false
              scrollView.alwaysBounceHorizontal = false
              scrollView.backgroundColor = backgroundColor
              scrollView.layer.applyMarkdownBlockAppearance(appearance)
              scrollView.layer.masksToBounds = true

              mathView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
              scrollView.addSubview(mathView)

              // 设置 scrollView 的 frame
              scrollView.frame = CGRect(
                  x: 0,
                  y: 0,
                  width: renderResult.displaySize.width,
                  height: renderResult.displaySize.height
              )

              mdLog("[STREAM] 📐📐 createScrollableView 完成(带滚动)，总耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - totalStart) * 1000))ms")
              return (scrollView, contentSize)
          }
      }

      /// 便捷方法：直接获取尺寸信息
      static func calculateSize(
          latex: String,
          fontSize: CGFloat = 22,
          padding: CGFloat = 20
      ) -> CGSize {
          let start = CFAbsoluteTimeGetCurrent()
          let formula = ParsedFormula.parse(latex: latex, fontSize: fontSize)
          let result = CGSize(
              width: formula.intrinsicSize.width + padding,
              height: formula.intrinsicSize.height + padding
          )
          mdLog("[STREAM] 📐📐 calculateSize 完成，耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 1000))ms")
          return result
      }
  }
