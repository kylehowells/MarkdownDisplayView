//
//  LatexMathView.swift
//  LateXDemo
//
//  Created by 朱继超 on 12/19/25.
//

import UIKit

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

    private var rootNode: FormulaRenderNode?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // 确保字体已注册
        FontLoader.ensureFontsRegistered()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        // 确保字体已注册
        FontLoader.ensureFontsRegistered()
    }
    
    private func parseAndRender() {
        let parseStart = CFAbsoluteTimeGetCurrent()
        let parser = LatexParser(latex: _latex, font: UIFont.systemFont(ofSize: _fontSize))
        rootNode = parser.parse()
        mdLog("[STREAM] 📐📐 LaTeX 解析耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - parseStart) * 1000))ms")
        setNeedsDisplay()
        invalidateIntrinsicContentSize()
    }
    
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let root = rootNode else { return }
        
        // 居中绘制
        let startX = (rect.width - root.size.width) / 2
        let startY = (rect.height - root.size.height) / 2
        
        // 翻转坐标系 (如果需要的话，但这里我们尽量使用了 UIKit 坐标)
        // 我们的 Node 实现是基于左上角(Upper-Left)的逻辑，配合 UIKit
        
        root.draw(in: context, at: CGPoint(x: startX, y: startY))
    }
    
    override var intrinsicContentSize: CGSize {
        return rootNode?.size ?? .zero
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
          backgroundColor: UIColor = UIColor.systemGray6.withAlphaComponent(0.5)
      ) -> (view: UIView, contentSize: CGSize) {
          let totalStart = CFAbsoluteTimeGetCurrent()
          mdLog("[STREAM] 📐📐 createScrollableView 开始: \(latex.prefix(40))...")

          // 1. 创建 MathView（一次 configure 只解析一次）
          let mathViewStart = CFAbsoluteTimeGetCurrent()
          let mathView = LatexMathView()
          mathView.configure(latex: latex, fontSize: fontSize)
          mathView.backgroundColor = backgroundColor
          mathView.layer.cornerRadius = 8
          mathView.layer.masksToBounds = true
          mdLog("[STREAM] 📐📐 LatexMathView 实例化耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - mathViewStart) * 1000))ms")

          // 2. 计算尺寸
          let sizeStart = CFAbsoluteTimeGetCurrent()
          let mathSize = mathView.intrinsicContentSize
          let contentWidth = mathSize.width + padding
          let contentHeight = mathSize.height + padding
          mdLog("[STREAM] 📐📐 intrinsicContentSize 计算耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - sizeStart) * 1000))ms, 尺寸: \(mathSize)")

          let contentSize = CGSize(width: contentWidth, height: contentHeight)

          // 3. 判断是否需要滚动
          if contentWidth <= maxWidth {
              // 不需要滚动，直接返回 mathView
              mathView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
              mdLog("[STREAM] 📐📐 createScrollableView 完成(无滚动)，总耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - totalStart) * 1000))ms")
              return (mathView, contentSize)
          } else {
              // 需要滚动，包裹在 ScrollView 中
              let scrollView = UIScrollView()
              scrollView.contentSize = contentSize
              scrollView.showsHorizontalScrollIndicator = false
              scrollView.alwaysBounceHorizontal = false
              scrollView.backgroundColor = .clear

              mathView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
              scrollView.addSubview(mathView)

              // 设置 scrollView 的 frame
              scrollView.frame = CGRect(x: 0, y: 0, width: maxWidth, height: contentHeight)

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
          let mathView = LatexMathView()
          mathView.configure(latex: latex, fontSize: fontSize)
          let intrinsicSize = mathView.intrinsicContentSize
          let result = CGSize(
              width: intrinsicSize.width + padding,
              height: intrinsicSize.height + padding
          )
          mdLog("[STREAM] 📐📐 calculateSize 完成，耗时: \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 1000))ms")
          return result
      }
  }
