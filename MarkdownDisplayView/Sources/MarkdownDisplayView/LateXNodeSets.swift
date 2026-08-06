//
//  LateXNodeSets.swift
//  LateXDemo
//
//  Created by 朱继超 on 12/19/25.
//

import Foundation
import UIKit

// ==========================================
// MARK: - 2. 渲染节点协议 (Protocol)
// ==========================================

protocol FormulaRenderNode {
    var size: CGSize { get }
    func layout() // 计算布局
    // ✅ 新增：基线偏移量 (距离底部的距离，或者距离顶部的距离，看你坐标系)
    // 这里假设：从 Node 的底部 (Bottom) 向上到基线 (Baseline) 的距离
    var baselineOffset: CGFloat { get }
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) // 绘制
}

// ✅ 核心魔法：提供默认实现，让它变成“可选”的
extension FormulaRenderNode {
    // 默认情况下，认为基线就是底部 (0)，或者根据 Font 自动推导
    var baselineOffset: CGFloat {
        return 0
    }
}

// ==========================================
// MARK: - 3. 具体节点实现
// ==========================================

// 3.1 基础文本节点 (数字、字母、符号)
class TextNode: FormulaRenderNode {
      let text: String
      let font: UIFont
      var size: CGSize = .zero

      // 缓存真实的 ascent 和 descent
      private var ascent: CGFloat = 0
      private var descent: CGFloat = 0

    var baselineOffset: CGFloat {
          // 对于单字母，使用字体统一基线
          if text.count == 1 && text.first?.isLetter == true {
              return font.ascender
          }
          // 其他字符使用实际 ascent
          return ascent
      }

      init(text: String, font: UIFont) {
          self.text = text
          self.font = font
          layout()
      }

      func layout() {
          let attributes: [NSAttributedString.Key: Any] = [.font: font]
          let attrString = NSAttributedString(string: text, attributes: attributes)
          let line = CTLineCreateWithAttributedString(attrString)

          var leading: CGFloat = 0
          let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

          self.size = CGSize(width: width, height: ascent + descent)
      }

      func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
          let attributes: [NSAttributedString.Key: Any] = [
              .font: font,
              .foregroundColor: foregroundColor
          ]
          let attrString = NSAttributedString(string: text, attributes: attributes)
          let line = CTLineCreateWithAttributedString(attrString)

          context.saveGState()
          context.textMatrix = .identity
          context.translateBy(x: point.x, y: point.y + size.height)
          context.scaleBy(x: 1.0, y: -1.0)

          // 直接使用缓存的 descent
          context.textPosition = CGPoint(x: 0, y: descent)
          CTLineDraw(line, context)

          context.restoreGState()
      }
  }

// 3.2 水平容器节点 (用于排列一系列元素)
class HorizontalNode: FormulaRenderNode {
    let children: [FormulaRenderNode]
    var size: CGSize = .zero
    let spacing: CGFloat = 1.0
    
    // 1. 实现协议属性：基线高度
        // 容器的基线高度 = 所有子节点中最高的那个基线位置
    var baselineOffset: CGFloat {
         return children.map { $0.baselineOffset }.max() ?? 0
     }
        
        init(children: [FormulaRenderNode]) {
            self.children = children
            
            // 简单计算总宽和总高
            // 注意：总高度 = (最高的基线 + 最深的底线)
            // 这里为了简化，我们暂时取最高的 height (虽然不完全严谨，但够用)
            // 严谨做法是：max(baseline) + max(height - baseline)
            
            let width = children.reduce(0) { $0 + $1.size.width }
            
            // 计算容器的“最高基线”
            let maxBaseline = children.map { $0.baselineOffset }.max() ?? 0
            
            // 计算容器的“最深底线” (基线以下的距离)
            let maxDescent = children.map { $0.size.height - $0.baselineOffset }.max() ?? 0
            
            let height = maxBaseline + maxDescent
            self.size = CGSize(width: width, height: height)
        }
        
        func layout() {
            // 如果你需要缓存子节点位置，可以在这里做
            // 但对于简单 parser，直接在 draw 里算也行
        }
        
        func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
            var currentX = point.x
            
            // 获取当前行的统一基线位置 (相对于 point.y 顶部)
            let rowBaselineOffset = self.baselineOffset
            
            for child in children {
                // 🌟 核心对齐逻辑 🌟
                // 子节点的 y 坐标 = (行的基线 - 子节点的基线)
                // 这样就把大家的基线都拽到了同一水平线上
                let childY = point.y + (rowBaselineOffset - child.baselineOffset)
                
                // 递归绘制子节点
                child.draw(
                    in: context,
                    at: CGPoint(x: currentX, y: childY),
                    foregroundColor: foregroundColor
                )
                
                // 移动 X 游标
                currentX += child.size.width
            }
        }
}

// 3.3 分数节点 (\frac)
class FractionNode: FormulaRenderNode {
    let numerator: FormulaRenderNode
    let denominator: FormulaRenderNode
    var size: CGSize = .zero
    let padding: CGFloat = 3.0
    var baselineOffset: CGFloat {
          // 分数线位置 = 分子高度 + padding
          let axisHeight = padding + 1
          return numerator.size.height + padding + axisHeight * 0.5
      }
    
    
    init(numerator: FormulaRenderNode, denominator: FormulaRenderNode) {
        self.numerator = numerator
        self.denominator = denominator
        layout()
    }
    
    func layout() {
        let width = max(numerator.size.width, denominator.size.width) + 4
        let height = numerator.size.height + denominator.size.height + padding * 2 + 1
        self.size = CGSize(width: width, height: height)
    }
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        // 分子
        let numX = point.x + (size.width - numerator.size.width) / 2
        numerator.draw(in: context, at: CGPoint(x: numX, y: point.y), foregroundColor: foregroundColor)
        
        // 分数线
        let lineY = point.y + numerator.size.height + padding
        context.setStrokeColor(foregroundColor.cgColor)
        context.setLineWidth(1.2)
        context.move(to: CGPoint(x: point.x, y: lineY))
        context.addLine(to: CGPoint(x: point.x + size.width, y: lineY))
        context.strokePath()
        
        // 分母
        let denX = point.x + (size.width - denominator.size.width) / 2
        let denY = lineY + 1 + padding
        denominator.draw(in: context, at: CGPoint(x: denX, y: denY), foregroundColor: foregroundColor)
    }
}

// 3.4 上下标节点 (^ 和 _)
class ScriptNode: FormulaRenderNode {
    let base: FormulaRenderNode
    let script: FormulaRenderNode
    let type: ScriptType
    var size: CGSize = .zero
    var baselineOffset: CGFloat {
        // base 在 ScriptNode 内部垂直居中
                  let baseTopOffset = (size.height - base.size.height) / 2
                  // ScriptNode 的基线 = base 顶部偏移 + base 内部的基线
                  return baseTopOffset + base.baselineOffset
    }

    enum ScriptType { case `super`, sub }
    
    init(base: FormulaRenderNode, script: FormulaRenderNode, type: ScriptType) {
        self.base = base
        self.script = script
        self.type = type
        layout()
    }
    
    func layout() {
        let width = base.size.width + script.size.width
        // 简单的高度估算
        let height = max(base.size.height, script.size.height + base.size.height * 0.4)
        self.size = CGSize(width: width, height: height)
    }
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        let baseY = point.y + (size.height - base.size.height) / 2
        base.draw(in: context, at: CGPoint(x: point.x, y: baseY), foregroundColor: foregroundColor)
        
        let scriptX = point.x + base.size.width
        var scriptY = baseY
        if type == .super {
            scriptY -= base.size.height * 0.35 // 上移
        } else {
            scriptY += base.size.height * 0.5  // 下移
        }
        script.draw(in: context, at: CGPoint(x: scriptX, y: scriptY), foregroundColor: foregroundColor)
    }
}

// 3.5 根号节点 (\sqrt)
class SqrtNode: FormulaRenderNode {
    let inner: FormulaRenderNode
    var size: CGSize = .zero
    // 🔥 添加这个
          var baselineOffset: CGFloat {
              // 根号的基线跟随内容
              return inner.baselineOffset + 3  // +3 是因为有 padding
          }
    init(inner: FormulaRenderNode) {
        self.inner = inner
        layout()
    }
    
    func layout() {
        self.size = CGSize(width: inner.size.width + 12, height: inner.size.height + 6)
    }
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        let innerPos = CGPoint(x: point.x + 10, y: point.y + 6)
        inner.draw(in: context, at: innerPos, foregroundColor: foregroundColor)
        
        context.setStrokeColor(foregroundColor.cgColor)
        context.setLineWidth(1.5)
        context.beginPath()
        context.move(to: CGPoint(x: point.x, y: point.y + size.height * 0.6))
        context.addLine(to: CGPoint(x: point.x + 4, y: point.y + size.height))
        context.addLine(to: CGPoint(x: point.x + 10, y: point.y))
        context.addLine(to: CGPoint(x: point.x + size.width, y: point.y))
        context.strokePath()
    }
}

// 3.6 矩阵节点 (Matrix - 新增!)
// 通常在 MatrixNode 类内部或外部定义
enum MatrixType {
    case plain   // matrix: 无边框
    case bracket // bmatrix: [ ]
    case paren   // pmatrix: ( )
    case cases   // cases:   {   (仅左侧)
    case abs     // vmatrix: | | (新增这个，用于行列式)
}



// 3.7 处理 \sum, \lim, \prod 等巨型算符，支持 Limits 垂直堆叠
class OperatorNode: FormulaRenderNode {
    let symbol: String
    let font: UIFont
    let upper: FormulaRenderNode? // 上限 (n)
    let lower: FormulaRenderNode? // 下限 (i=0)
    var size: CGSize = .zero
    // 🔥 添加这个属性
    var baselineOffset: CGFloat {
          // 大型运算符的基线对齐到数学轴（符号中心）
          let upperSize = upper?.size ?? .zero
          let spacing: CGFloat = 2.0
          let symNode = TextNode(text: symbol, font: font)

          // 基线 = 上限高度 + 间距 + 符号高度的一半
          return upperSize.height + (upperSize.height > 0 ? spacing : 0) + symNode.size.height * 0.5
      }
    init(symbol: String, font: UIFont, upper: FormulaRenderNode?, lower: FormulaRenderNode?) {
        self.symbol = symbol
        // 巨型算符通常比普通文本大一些，这里放大 1.2 倍
        self.font = font.withSize(font.pointSize * 1.5)
        self.upper = upper
        self.lower = lower
        layout()
    }
    
    func layout() {
        // 1. 计算符号大小
        let symNode = TextNode(text: symbol, font: font)
        
        // 2. 获取上下限大小 (如果有)
        let upperSize = upper?.size ?? .zero
        let lowerSize = lower?.size ?? .zero
        
        // 3. 整体宽度 = max(符号宽, 上限宽, 下限宽)
        let maxWidth = max(symNode.size.width, max(upperSize.width, lowerSize.width))
        
        // 4. 整体高度 = 符号高 + 上限高 + 下限高 + 间距
        let spacing: CGFloat = 2.0
        let totalHeight = symNode.size.height + upperSize.height + lowerSize.height + (spacing * 2)
        
        self.size = CGSize(width: maxWidth + 4, height: totalHeight)
    }
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        let centerX = point.x + size.width / 2
        
        var currentY = point.y
        
        // 1. 画上限 (Top)
        if let upper = upper {
            let upperX = centerX - upper.size.width / 2
            upper.draw(in: context, at: CGPoint(x: upperX, y: currentY), foregroundColor: foregroundColor)
            currentY += upper.size.height + 2
        } else {
            // 如果没有上限，留一点空或者直接画符号
            currentY += 2
        }
        
        // 2. 画中间的符号 (Middle)
        let symNode = TextNode(text: symbol, font: font)
        let symX = centerX - symNode.size.width / 2
        // 微调：让符号垂直居中看起来舒服点
        symNode.draw(in: context, at: CGPoint(x: symX, y: currentY), foregroundColor: foregroundColor)
        currentY += symNode.size.height + 2
        
        // 3. 画下限 (Bottom)
        if let lower = lower {
            let lowerX = centerX - lower.size.width / 2
            lower.draw(in: context, at: CGPoint(x: lowerX, y: currentY), foregroundColor: foregroundColor)
        }
    }
}

class DelimiterNode: FormulaRenderNode {
    let inner: FormulaRenderNode
    let type: DelimiterType
    var size: CGSize = .zero
    // 🔥 添加这个
          var baselineOffset: CGFloat {
              // 括号跟随内容的基线
              return inner.baselineOffset+10
          }
    enum DelimiterType { case paren, bracket, brace } // (), [], {}
    
    init(inner: FormulaRenderNode, type: DelimiterType) {
        self.inner = inner
        self.type = type
        layout()
    }
    
    func layout() {
        // 括号包裹内容，左右各加宽度
        let padding: CGFloat = 10.0
        self.size = CGSize(width: inner.size.width + padding * 2, height: inner.size.height)
    }
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        // 1. 绘制内部内容 (居中)
        let innerX = point.x + 10
        inner.draw(in: context, at: CGPoint(x: innerX, y: point.y), foregroundColor: foregroundColor)
        
        // 2. 绘制括号
        context.setStrokeColor(foregroundColor.cgColor)
        drawDelimiters(context: context, rect: CGRect(origin: point, size: size))
    }
    
    private func drawDelimiters(context: CGContext, rect: CGRect) {
        context.setLineWidth(1.2) // 稍微细一点更精致
        context.beginPath()
        
        let h = rect.height
        let w = rect.width
        let x = rect.minX
        let y = rect.minY
        
        // 简单的贝塞尔曲线模拟括号
        switch type {
        case .paren: // ( )
            // Left
            context.move(to: CGPoint(x: x + 6, y: y))
            context.addQuadCurve(to: CGPoint(x: x + 6, y: y + h), control: CGPoint(x: x, y: y + h / 2))
            // Right
            context.move(to: CGPoint(x: x + w - 6, y: y))
            context.addQuadCurve(to: CGPoint(x: x + w - 6, y: y + h), control: CGPoint(x: x + w, y: y + h / 2))
            
        case .bracket: // [ ]
            // Left
            context.move(to: CGPoint(x: x + 6, y: y)); context.addLine(to: CGPoint(x: x + 2, y: y)); context.addLine(to: CGPoint(x: x + 2, y: y + h)); context.addLine(to: CGPoint(x: x + 6, y: y + h))
            // Right
            context.move(to: CGPoint(x: x + w - 6, y: y)); context.addLine(to: CGPoint(x: x + w - 2, y: y)); context.addLine(to: CGPoint(x: x + w - 2, y: y + h)); context.addLine(to: CGPoint(x: x + w - 6, y: y + h))
            
        case .brace: // { }
            // 简单画法，略
            break
        }
        context.strokePath()
    }
}

class MatrixNode: FormulaRenderNode {
    let rows: [[FormulaRenderNode]]
    let type: MatrixType
    var size: CGSize = .zero
    // 🔥 添加这个
         var baselineOffset: CGFloat {
             // 矩阵的基线应该在垂直中心
             return size.height * 0.5
         }
    private var colWidths: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private let hSpacing: CGFloat = 8.0
    private let vSpacing: CGFloat = 6.0
    
    init(rows: [[FormulaRenderNode]], type: MatrixType) {
        self.rows = rows
        self.type = type
        layout()
    }
    
    func layout() {
        guard !rows.isEmpty else { return }
        
        let numCols = rows.map { $0.count }.max() ?? 0
        colWidths = Array(repeating: 0, count: numCols)
        rowHeights = Array(repeating: 0, count: rows.count)
        
        // 1. 计算每一列的最大宽度和每一行的最大高度
        for (i, row) in rows.enumerated() {
            for (j, node) in row.enumerated() {
                colWidths[j] = max(colWidths[j], node.size.width)
                rowHeights[i] = max(rowHeights[i], node.size.height)
            }
        }
        
        // 2. 计算总宽高
        let totalW = colWidths.reduce(0, +) + CGFloat(colWidths.count - 1) * hSpacing
        let totalH = rowHeights.reduce(0, +) + CGFloat(rowHeights.count - 1) * vSpacing
        
        // 留出括号的内边距
        let paddingX: CGFloat = type == .plain ? 0 : 10.0
        self.size = CGSize(width: totalW + paddingX * 2, height: totalH)
    }
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        let paddingX: CGFloat = type == .plain ? 0 : 10.0
        var currentY = point.y
        
        // 1. 绘制内容
        for (i, row) in rows.enumerated() {
            var currentX = point.x + paddingX
            let rowH = rowHeights[i]
            
            for (j, node) in row.enumerated() {
                let colW = colWidths[j]
                
                // 单元格内居中
                let cellX = currentX + (colW - node.size.width) / 2
                let cellY = currentY + (rowH - node.size.height) / 2
                
                node.draw(in: context, at: CGPoint(x: cellX, y: cellY), foregroundColor: foregroundColor)
                
                currentX += colW + hSpacing
            }
            currentY += rowH + vSpacing
        }
        
        // 2. 绘制定界符 (括号)
        context.setStrokeColor(foregroundColor.cgColor)
        drawDelimiters(in: context, at: point)
    }
    
    private func drawDelimiters(in context: CGContext, at point: CGPoint) {
        let w = size.width
        let h = size.height
        
        // 1. 设置通用样式（颜色继承当前公式绘制上下文）
        context.setLineWidth(1.5)
        context.beginPath() // 开始路径绘制

        // 2. 准备坐标
        // 注意：你之前的代码里重复定义了 width/height 和 x/y，这里统一一下
        let x = point.x
        let y = point.y
        
        // 3. 根据 type 绘制
        switch type {
        case .bracket: // [ ]
            // Left [
            context.move(to: CGPoint(x: x + 6, y: y))
            context.addLine(to: CGPoint(x: x + 1, y: y))
            context.addLine(to: CGPoint(x: x + 1, y: y + h))
            context.addLine(to: CGPoint(x: x + 6, y: y + h))
            // Right ]
            context.move(to: CGPoint(x: x + w - 6, y: y))
            context.addLine(to: CGPoint(x: x + w - 1, y: y))
            context.addLine(to: CGPoint(x: x + w - 1, y: y + h))
            context.addLine(to: CGPoint(x: x + w - 6, y: y + h))
            context.strokePath()
            
        case .paren: // ( ) - 简化为圆弧
            // Left (
            context.move(to: CGPoint(x: x + 6, y: y))
            context.addQuadCurve(to: CGPoint(x: x + 6, y: y + h), control: CGPoint(x: x - 2, y: y + h / 2))
            // Right )
            context.move(to: CGPoint(x: x + w - 6, y: y))
            context.addQuadCurve(to: CGPoint(x: x + w - 6, y: y + h), control: CGPoint(x: x + w + 2, y: y + h / 2))
            context.strokePath()
            
        case .cases: // { (分段函数)
            // 只画左边的花括号 {
            let braceX = x + 8
            
            context.move(to: CGPoint(x: braceX, y: y))
            // 上半部分 S 形
            context.addCurve(to: CGPoint(x: braceX - 6, y: y + h/2),
                             control1: CGPoint(x: braceX, y: y + h/4),
                             control2: CGPoint(x: braceX - 6, y: y + h/4))
            // 下半部分 S 形
            context.addCurve(to: CGPoint(x: braceX, y: y + h),
                             control1: CGPoint(x: braceX - 6, y: y + h*3/4),
                             control2: CGPoint(x: braceX, y: y + h*3/4))
            
            // 中间的小尖尖 (装饰)
            context.move(to: CGPoint(x: braceX - 4.5, y: y + h/2))
            context.addLine(to: CGPoint(x: braceX - 8, y: y + h/2))
            
            context.strokePath()

        case .abs: // | | (行列式)
            // 左竖线
            context.move(to: CGPoint(x: x + 1, y: y))
            context.addLine(to: CGPoint(x: x + 1, y: y + h))
            
            // 右竖线
            context.move(to: CGPoint(x: x + w - 1, y: y))
            context.addLine(to: CGPoint(x: x + w - 1, y: y + h))
            
            context.strokePath()

        case .plain:
            break
        }
    }
}

class AccentNode: FormulaRenderNode {
    let base: FormulaRenderNode
    let accentChar: String
    let font: UIFont
    var size: CGSize = .zero
    // AccentNode - 只加这个属性
    var baselineOffset: CGFloat {
        // 跟随基础元素的基线
        return base.baselineOffset
    }
    init(base: FormulaRenderNode, accentChar: String, font: UIFont) {
        self.base = base
        self.accentChar = accentChar
        self.font = font
        layout()
    }
    
    func layout() {
        // 装饰符的高度通常不计入主体高度，或者只加一点点
        // 这里简单处理：高度 = base + 顶部装饰的空间
        self.size = CGSize(width: base.size.width, height: base.size.height + 4)
    }
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        // 1. 先画底下的字母
                base.draw(in: context, at: point, foregroundColor: foregroundColor)
                
                // 2. 准备画上面的符号
                let accentSize = accentChar.size(withAttributes: [.font: font])
                
                // --- 🔧 核心修复开始 ---
                
                // 差异化计算偏移量 (yOffset)
                // 这里的 height 是 base 的高度 (通常是字体行高)
                // 我们要计算的是：从 base 的顶部开始，往上提多少？
                
                var yOffset: CGFloat = 0
                
                if accentChar == "→" || accentChar == "⃗" {
                     // 🚀 箭头：本身在中间，需要大幅提升 (比如高度的 60%~75%)
                     // 之前是 0.85 可能有点太高了，0.6~0.7 比较稳妥
                     yOffset = base.size.height * 0.65
                } else if accentChar == "^" {
                     // 🧢 帽子：本身就靠上，只需要轻轻提一点点，或者不提
                     // 这里给个负值或者极小值，视你的字体而定
                     // 如果觉得还是高，就减小这个值，甚至设为 0
                     yOffset = base.size.height * 0.1
                } else if accentChar == "˙" || accentChar == "¨" || accentChar == "ˉ" {
                     // 📍 点/横线：通常也靠上，微调即可
                     yOffset = base.size.height * 0.15
                } else {
                     // 默认情况
                     yOffset = base.size.height * 0.3
                }
                
                // 防止偏移过大导致重叠，加个保护 (可选)
                // yOffset = max(yOffset, 0)
                
                // --- 🔧 核心修复结束 ---
                
                // 水平居中
                let xOffset = (base.size.width - accentSize.width) / 2
                
                // 计算最终坐标 (注意 iOS 坐标系 y 越小越靠上，所以是 point.y - yOffset)
                let accentPoint = CGPoint(x: point.x + xOffset, y: point.y - yOffset)
                
                // 3. 绘制符号
                (accentChar as NSString).draw(at: accentPoint, withAttributes: [
                    .font: font,
                    .foregroundColor: foregroundColor
                ])
    }
}

class SpaceNode: FormulaRenderNode {
    var size: CGSize
    
    init(width: CGFloat) {
        self.size = CGSize(width: width, height: 0) // 高度为0，不影响垂直排版
    }
    
    func layout() {} // 也就是个占位符，不用计算
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        // 啥也不用画，留白即可
    }
}

class ColorNode: FormulaRenderNode {
    let child: FormulaRenderNode
    let color: UIColor
    var size: CGSize = .zero
    // 🔥 添加这个
    var baselineOffset: CGFloat {
        // ColorNode 是透明包装，基线跟随子节点
        return child.baselineOffset
    }
    
    init(child: FormulaRenderNode, color: UIColor) {
        self.child = child
        self.color = color
        layout()
    }
    
    func layout() {
        self.size = child.size
    }
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        child.draw(in: context, at: point, foregroundColor: color)
    }
}

// 处理 \overline{x}, \underline{x}, \boxed{x}
class EnclosureNode: FormulaRenderNode {
    let child: FormulaRenderNode
    let type: EnclosureType
    var size: CGSize = .zero
    var baselineOffset: CGFloat {
          switch type {
          case .boxed:
              // 方框：基线 = 内容基线 + 顶部padding
              return child.baselineOffset + 4  // 4 是顶部padding

          case .overline:
              // 上划线：基线 = 内容基线 + 上划线占据的空间
              return child.baselineOffset + 4  // 4 是上划线+间距

          case .underline:
              // 下划线：基线就是内容的基线（下划线在基线下方）
              return child.baselineOffset
          }
      }
    
    enum EnclosureType { case overline, underline, boxed }
    
    init(child: FormulaRenderNode, type: EnclosureType) {
        self.child = child
        self.type = type
        layout()
    }
    
    func layout() {
          switch type {
          case .boxed:
              // 方框：四周各留 4pt
              self.size = CGSize(width: child.size.width + 8, height: child.size.height + 8)
          case .overline:
              // 上划线：顶部多 4pt
              self.size = CGSize(width: child.size.width, height: child.size.height + 4)
          case .underline:
              // 下划线：底部多 4pt
              self.size = CGSize(width: child.size.width, height: child.size.height + 4)
          }
      }
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        context.setStrokeColor(foregroundColor.cgColor)
        context.setLineWidth(1.0)
        
        switch type {
        case .overline:
            // 内容下移，上面画线
            child.draw(in: context, at: CGPoint(x: point.x, y: point.y + 4), foregroundColor: foregroundColor)
            context.move(to: CGPoint(x: point.x, y: point.y + 1))
            context.addLine(to: CGPoint(x: point.x + size.width, y: point.y + 1))
            context.strokePath()
            
        case .underline:
            // 内容正常，下面画线
            child.draw(in: context, at: point, foregroundColor: foregroundColor)
            context.move(to: CGPoint(x: point.x, y: point.y + size.height - 1))
            context.addLine(to: CGPoint(x: point.x + size.width, y: point.y + size.height - 1))
            context.strokePath()
            
        case .boxed:
            // 绘制矩形框
            let rect = CGRect(origin: point, size: size)
            context.stroke(rect)
            // 居中绘制内容
            child.draw(in: context, at: CGPoint(x: point.x + 4, y: point.y + 4), foregroundColor: foregroundColor)
        }
    }
}

// 处理 \binom{n}{k}
class BinomNode: FormulaRenderNode {
    let numerator: FormulaRenderNode
    let denominator: FormulaRenderNode
    var size: CGSize = .zero
    
    init(numerator: FormulaRenderNode, denominator: FormulaRenderNode) {
        self.numerator = numerator
        self.denominator = denominator
        layout()
    }
    
    func layout() {
        // 类似于 Fraction，但没有横线，宽度包含括号
        let contentWidth = max(numerator.size.width, denominator.size.width)
        let contentHeight = numerator.size.height + denominator.size.height + 4
        // 加上括号的宽度 (左右各 8)
        self.size = CGSize(width: contentWidth + 16, height: contentHeight)
    }
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        let centerX = point.x + size.width / 2
        
        // 1. 画分子
        let numX = centerX - numerator.size.width / 2
        numerator.draw(in: context, at: CGPoint(x: numX, y: point.y + 2), foregroundColor: foregroundColor)
        
        // 2. 画分母
        let denX = centerX - denominator.size.width / 2
        // 分母在分子下面
        denominator.draw(
            in: context,
            at: CGPoint(x: denX, y: point.y + numerator.size.height + 4),
            foregroundColor: foregroundColor
        )
        
        // 3. 画两边的圆括号
        context.setStrokeColor(foregroundColor.cgColor)
        drawParens(context: context, rect: CGRect(origin: point, size: size))
    }
    
    private func drawParens(context: CGContext, rect: CGRect) {
        context.setLineWidth(1.0)
        context.beginPath()
        
        let h = rect.height
        let w = rect.width
        let x = rect.minX
        let y = rect.minY
        
        // 左括号 (
        context.move(to: CGPoint(x: x + 6, y: y))
        context.addQuadCurve(to: CGPoint(x: x + 6, y: y + h), control: CGPoint(x: x, y: y + h/2))
        
        // 右括号 )
        context.move(to: CGPoint(x: x + w - 6, y: y))
        context.addQuadCurve(to: CGPoint(x: x + w - 6, y: y + h), control: CGPoint(x: x + w, y: y + h/2))
        
        context.strokePath()
    }
}

class ArrowNode: FormulaRenderNode {
    let upper: FormulaRenderNode? // 箭头上面的字
    let lower: FormulaRenderNode? // 箭头下面的字
    let type: ArrowType
    var size: CGSize = .zero
    var baselineOffset: CGFloat {
          let upSize = upper?.size ?? .zero

          // 箭头的基线应该在箭头本身的中心线
          // 基线位置 = 上标高度 + (有上标的间距) + 箭头高度一半

          let spacing: CGFloat = 2.0
          let arrowHeight: CGFloat = 8.0  // 必须和 layout() 里的一致

          return upSize.height + (upSize.height > 0 ? spacing : 3*spacing) + arrowHeight * 0.5
      }
    enum ArrowType { case right, left, leftRight, equal } // ->, <-, <->, =
    
    init(upper: FormulaRenderNode?, lower: FormulaRenderNode?, type: ArrowType) {
        self.upper = upper
        self.lower = lower
        self.type = type
        layout()
    }
    
    func layout() {
        let upSize = upper?.size ?? .zero
        let lowSize = lower?.size ?? .zero
        
        // 1. 计算内容最大宽度
        let contentWidth = max(upSize.width, lowSize.width)
        // 2. 箭头至少要有 20pt 宽，或者比文字宽一点
        let arrowWidth = max(contentWidth + 10, 24.0)
        
        // 3. 计算高度 (上 + 箭头 + 下)
        let arrowHeight: CGFloat = 8.0 // 箭头本身占据的垂直空间
        let totalHeight = upSize.height + lowSize.height + arrowHeight + 4
        
        self.size = CGSize(width: arrowWidth, height: totalHeight)
    }
    
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
        let centerX = point.x + size.width / 2
        var currentY = point.y
        
        // 1. 画上标
        if let upper = upper {
            let upX = centerX - upper.size.width / 2
            upper.draw(in: context, at: CGPoint(x: upX, y: currentY), foregroundColor: foregroundColor)
            currentY += upper.size.height + 2
        } else {
            currentY += 2
        }
        
        // 2. 画箭头 (在 currentY 的位置)
        context.setStrokeColor(foregroundColor.cgColor)
        drawArrowLine(context: context, x: point.x, y: currentY + 4, w: size.width)
        
        // 3. 画下标
        if let lower = lower {
            let lowY = currentY + 10 // 箭头下方
            let lowX = centerX - lower.size.width / 2
            lower.draw(in: context, at: CGPoint(x: lowX, y: lowY), foregroundColor: foregroundColor)
        }
    }
    
    private func drawArrowLine(context: CGContext, x: CGFloat, y: CGFloat, w: CGFloat) {
        context.setLineWidth(1.0)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        
        let startX = x
        let endX = x + w
        let midY = y
        
        // 主线
        if type == .equal {
            // 等号是两条线
            context.move(to: CGPoint(x: startX, y: midY - 1.5)); context.addLine(to: CGPoint(x: endX, y: midY - 1.5))
            context.move(to: CGPoint(x: startX, y: midY + 1.5)); context.addLine(to: CGPoint(x: endX, y: midY + 1.5))
        } else {
            // 单线条
            context.move(to: CGPoint(x: startX, y: midY))
            context.addLine(to: CGPoint(x: endX, y: midY))
        }
        
        // 箭头头部 (简单的 V 字)
        let headSize: CGFloat = 4.0
        
        if type == .right || type == .leftRight {
            // 右箭头 >
            context.move(to: CGPoint(x: endX - headSize, y: midY - headSize))
            context.addLine(to: CGPoint(x: endX, y: midY))
            context.addLine(to: CGPoint(x: endX - headSize, y: midY + headSize))
        }
        
        if type == .left || type == .leftRight {
            // 左箭头 <
            context.move(to: CGPoint(x: startX + headSize, y: midY - headSize))
            context.addLine(to: CGPoint(x: startX, y: midY))
            context.addLine(to: CGPoint(x: startX + headSize, y: midY + headSize))
        }
        
        context.strokePath()
    }
}

class BenzeneNode: FormulaRenderNode {
    
    // MARK: - Protocol Requirements (必须严格对应协议)
    
    // 1. 尺寸 (协议要求)
    var size: CGSize
    
    // 2. 基线偏移 (协议要求)
    // ⚠️ 重点：这里定义为 var 存储属性，从而“覆盖”协议 extension 里的默认实现 (return 0)
    // 这样我们才能控制它垂直居中
    var baselineOffset: CGFloat {
              // 苯环的基线应该在垂直中心，这样能和字母对齐
              // 但要稍微偏上一点，对齐到字母的视觉中心
              return size.height * 0.55  // 0.55 比 0.5 稍高，更接近字母基线
          }
    
    // MARK: - Internal Properties (私有属性)
    private let font: UIFont
    private let structure: String  // 存储 "**6(...)"
    private let isAromatic: Bool
    
    private let sideLength: CGFloat
    private let padding: CGFloat = 4.0
    private let lineWidth: CGFloat = 1.5
    
    // 绘图辅助：六边形中心的偏移量
    private let hexCenterOffset: CGPoint
    
    // MARK: - Initialization
    
    init(font: UIFont, structure: String) {
            self.font = font
            self.structure = structure
            self.isAromatic = structure.contains("**")
            
            // 1. 基础尺寸
            let scaleFactor: CGFloat = 2.0
            self.sideLength = font.pointSize * scaleFactor * 0.5
            
            let hexWidth = sideLength * 1.732
            let hexHeight = sideLength * 2.0
            
            // 2. 智能 Margin 计算
            var marginTop: CGFloat = padding
            var marginBottom: CGFloat = padding
            var marginLeft: CGFloat = padding
            var marginRight: CGFloat = padding
            
            let extraSpace = font.pointSize * 1.8
            
            // ✅ 修复：同时也检查 CH3 (甲苯)
            if structure.contains("OH") || structure.contains("CH") {
                marginTop += extraSpace
            }
            
            // TNT 检查
            if structure.contains("NO_2") || structure.contains("NO2") {
                marginTop += extraSpace
                marginBottom += extraSpace
                marginLeft += extraSpace
                marginRight += extraSpace
            }
            
            // 3. 计算总 Size
            let totalWidth = hexWidth + marginLeft + marginRight
            let totalHeight = hexHeight + marginTop + marginBottom
            self.size = CGSize(width: totalWidth, height: totalHeight)
            
            // 4. 中心位置
            let cx = marginLeft + (hexWidth / 2.0)
            let cy = marginTop + (hexHeight / 2.0)
            self.hexCenterOffset = CGPoint(x: cx, y: cy)
            
            // 5. 基线
            let textMiddle = font.pointSize * 0.35
//            self.baselineOffset = cy - textMiddle
        }
    
    // MARK: - Protocol Methods Implementation
    
    // ✅ 3. 布局计算 (协议要求)
    func layout() {
        // 对于 BenzeneNode 这种“叶子节点”(Leaf Node)，
        // 所有的尺寸和位置在 init 里计算效率最高。
        // 所以这里留空即可，但必须存在以满足协议。
    }
    
    // ✅ 4. 绘制 (协议要求)
    // ✅ 替换 BenzeneNode.swift 中的 draw 方法
    func draw(in context: CGContext, at point: CGPoint, foregroundColor: UIColor) {
            context.saveGState()
            context.setStrokeColor(foregroundColor.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            
            let centerX = point.x + hexCenterOffset.x
            let centerY = point.y + hexCenterOffset.y
            
            var vertices: [CGPoint] = []
            let path = UIBezierPath()
            
            // 画六边形
            for i in 0..<6 {
                let angleDeg = -90.0 + Double(i) * 60.0
                let angleRad = angleDeg * .pi / 180.0
                let p = CGPoint(
                    x: centerX + sideLength * CGFloat(cos(angleRad)),
                    y: centerY + sideLength * CGFloat(sin(angleRad))
                )
                vertices.append(p)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.close()
            context.addPath(path.cgPath)
            context.strokePath()
            
            // 画圆圈
            if isAromatic {
                context.beginPath()
                context.addArc(center: CGPoint(x: centerX, y: centerY),
                               radius: sideLength * 0.65,
                               startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                context.strokePath()
            }
            
            // 解析取代基
            var cleanStr = structure
            if cleanStr.hasPrefix("chemfig") { cleanStr = String(cleanStr.dropFirst(7)) }
            if let range = cleanStr.range(of: "(") {
                let content = String(cleanStr[range.upperBound...].dropLast())
                
                // 🧪 逻辑分支
                if content.contains("NO_2") {
                    // TNT
                    let substituents: [Int: String] = [0: "CH3", 1: "NO2", 3: "NO2", 5: "NO2"]
                    for (idx, txt) in substituents {
                        drawSubstituent(
                            context: context,
                            vertex: vertices[idx],
                            text: txt,
                            angleIndex: idx,
                            foregroundColor: foregroundColor
                        )
                    }
                }
                else if content.contains("OH") {
                    // 苯酚
                    drawSubstituent(
                        context: context,
                        vertex: vertices[0],
                        text: "OH",
                        angleIndex: 0,
                        foregroundColor: foregroundColor
                    )
                }
                // ✅ 新增：甲苯 (Toluene)
                else if content.contains("CH_3") || content.contains("CH3") {
                    drawSubstituent(
                        context: context,
                        vertex: vertices[0],
                        text: "CH3",
                        angleIndex: 0,
                        foregroundColor: foregroundColor
                    )
                }
            }
            
            context.restoreGState()
        }
        
    // MARK: - Helper Methods
        
        // ✨ 新增辅助方法：把普通数字转成下标数字
        // 例如输入 "NO2"，输出 "NO₂"
        // 输入 "C6H12O6"，输出 "C₆H₁₂O₆"
        private func formatChemicalFormula(_ text: String) -> String {
            let subscriptMap: [String: String] = [
                "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
                "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
                "+": "⁺", "-": "⁻" // 顺便支持一下简单的电荷
            ]
            
            var result = text
            // 简单替换：只要是数字，就换成下标
            // 注意：这只是个简单的 Demo 优化，对于系数 (如 2H2O) 可能会误杀，
            // 但对于苯环取代基 (如 -NO2, -CH3) 这种写法通常是完美的。
            for (key, value) in subscriptMap {
                result = result.replacingOccurrences(of: key, with: value)
            }
            return result
        }

    // Helper method: Draw Bond and Text at a specific vertex
        private func drawSubstituent(
            context: CGContext,
            vertex: CGPoint,
            text: String,
            angleIndex: Int,
            foregroundColor: UIColor
        ) {
            
            // 1. Pre-process text (NO2 -> NO₂)
            let prettyText = formatChemicalFormula(text) as NSString
            
            // 2. Prepare Font & Attributes (Measure size first!)
            // Reduce font size to 0.65x for better proportion
            let smallFont = self.font.withSize(self.font.pointSize * 0.65)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: smallFont,
                .foregroundColor: foregroundColor
            ]
            let textSize = prettyText.size(withAttributes: attrs)
            
            // 3. Calculate geometry
            let angleDeg = -90.0 + Double(angleIndex) * 60.0
            let angleRad = angleDeg * .pi / 180.0
            let direction = CGPoint(x: cos(angleRad), y: sin(angleRad))
            
            // --- A. Calculate Line End (Fixed length relative to hexagon) ---
            // 0.45 * sideLength creates a neat, short bond
            let bondLength = sideLength * 0.45
            let lineEndPoint = CGPoint(
                x: vertex.x + direction.x * bondLength,
                y: vertex.y + direction.y * bondLength
            )
            
            // --- B. Calculate Text Center (Dynamic based on Text Size) ---
            // We calculate a "radius" for the text box to ensure it clears the line.
            // Simple approximation: use half the max dimension of the text.
            // This ensures whether the text is tall or wide, it gets pushed out enough.
            let textRadius = max(textSize.width, textSize.height) / 2.0
            
            // Add a small fixed padding (e.g., 2.0 points)
            let gapPadding: CGFloat = 3.0
            let totalOffset = textRadius + gapPadding
            
            // The text center is placed "offset" distance away from the line end
            let textCenterPoint = CGPoint(
                x: lineEndPoint.x + direction.x * totalOffset,
                y: lineEndPoint.y + direction.y * totalOffset
            )
            
            // 4. Draw Bond Line
            context.beginPath()
            context.move(to: vertex)
            context.addLine(to: lineEndPoint)
            context.strokePath()
            
            // 5. Draw Text centered at textCenterPoint
            let textRect = CGRect(
                x: textCenterPoint.x - textSize.width / 2,
                y: textCenterPoint.y - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            
            prettyText.draw(in: textRect, withAttributes: attrs)
        }
}
