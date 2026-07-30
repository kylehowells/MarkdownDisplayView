//
//  LateXParser.swift
//  LateXDemo
//
//  Created by 朱继超 on 12/18/25.
//


import UIKit
import CoreText

// ==========================================
// MARK: - 1. 配置与符号表
// ==========================================

struct LatexSymbols {
    static let map: [String: String] = [
        // --- 1. 希腊字母 (Greek) ---
        "alpha": "α", "beta": "β", "gamma": "γ", "Gamma": "Γ",
        "delta": "δ", "Delta": "Δ",
        "epsilon": "ε", "varepsilon": "ε", // 兼容写法
        "zeta": "ζ",
        "eta": "η",
        "theta": "θ", "Theta": "Θ", "vartheta": "ϑ",
        "iota": "ι",
        "kappa": "κ",
        "lambda": "λ", "Lambda": "Λ",
        "mu": "μ",
        "nu": "ν",
        "xi": "ξ", "Xi": "Ξ",
        "pi": "π", "Pi": "Π", "varpi": "ϖ",
        "rho": "ρ",
        "sigma": "σ", "Sigma": "Σ",
        "tau": "τ",
        "upsilon": "υ", "Upsilon": "Υ",
        "phi": "φ", "Phi": "Φ", "varphi": "ϕ",
        "chi": "χ",
        "psi": "ψ", "Psi": "Ψ",
        "omega": "ω", "Omega": "Ω",
        
        // --- 2. 巨型算符 (Big Operators) ---
        "sum": "∑", "prod": "∏", "coprod": "∐",
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        
        // --- 3. 关系运算符 (Relations) ---
        "approx": "≈", "neq": "≠", "leq": "≤", "geq": "≥",
        "equiv": "≡", "sim": "∼", "cong": "≅", "propto": "∝",
        "in": "∈", "notin": "∉", "ni": "∋",
        "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "perp": "⊥", "parallel": "∥", "mid": "|", // 垂直、平行、整除
        
        // --- 4. 逻辑与箭头 (Arrows & Logic) ---
        "rightarrow": "→", "to": "→", "leftarrow": "←",
        "longrightarrow": "⟶", "longleftarrow": "⟵", // 化学常用长箭头
        "rightleftharpoons": "⇌", // [关键] 化学平衡
        "Rightarrow": "⇒", "Leftarrow": "⇐", "iff": "⇔",
        "uparrow": "↑", "downarrow": "↓",
        
        "infty": "∞", "forall": "∀", "exists": "∃", "empty": "∅", "emptyset": "∅",
        "therefore": "∴", "because": "∵",
        "partial": "∂", "nabla": "∇",
        
        // --- 5. 物理与高数特殊符号 ---
        "hbar": "ℏ",   // 约化普朗克常数
        "ell": "ℓ",    // 手写 l
        "Re": "ℜ",     // 实部
        "Im": "ℑ",     // 虚部
        "aleph": "ℵ",  // 阿列夫数
        "wp": "℘",     // 魏尔斯特拉斯函数
        
        // --- 6. 几何与标点 ---
        "angle": "∠", "degree": "°", "triangle": "△",
        "cdot": "·", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        
        // --- 7. 二元运算符 ---
        "times": "×", "div": "÷", "pm": "±", "mp": "∓",
        "ast": "*", "star": "⋆", "circ": "∘", "bullet": "•",
        "cup": "∪", "cap": "∩", "vee": "∨", "wedge": "∧", "oplus": "⊕", "otimes": "⊗"
    ]
    
    // 垂直堆叠的算符 (上下标在正上方/正下方)
    static let verticalLimits: Set<String> = ["sum", "prod", "coprod", "lim", "max", "min", "sup", "inf"]
    
    // 装饰符
    static let accentMap: [String: String] = [
        "vec": "→", "bar": "ˉ", "hat": "^", "dot": "˙", "ddot": "¨",
        "tilde": "˜", "check": "ˇ", "breve": "˘"
    ]

    // 颜色
    static let colorMap: [String: UIColor] = [
        "red": .red, "blue": .blue, "green": .green, "black": .black,
        "white": .white, "gray": .gray, "cyan": .cyan, "magenta": .magenta,
        "yellow": .yellow, "orange": .orange, "purple": .purple, "brown": .brown
    ]
}


// ==========================================
// MARK: - 4. 词法分析 (Lexer)
// ==========================================

enum TokenType: Equatable {
    case command(String) // \frac, \begin
    case text(String)    // a, 1, +
    case lBrace, rBrace  // { }
    case hat, underscore // ^ _
    case ampersand       // & (矩阵分列)
    case newLine         // \\ (矩阵换行)
    case unknown
}

struct Token {
    let type: TokenType
    let content: String
}

class LatexLexer {
    private let input: [Character]
    private var index = 0
    
    init(_ input: String) { self.input = Array(input) }
    
    func tokenize() -> [Token] {
        var tokens: [Token] = []
        while index < input.count {
            let char = input[index]
            switch char {
            case "\\":
                // 检查是否是 \\ (换行)
                if index + 1 < input.count && input[index+1] == "\\" {
                    tokens.append(Token(type: .newLine, content: "\\\\"))
                    index += 2
                } else {
                    tokens.append(readCommand())
                }
            case "{":  add(&tokens, .lBrace, "{")
            case "}":  add(&tokens, .rBrace, "}")
            case "^":  add(&tokens, .hat, "^")
            case "_":  add(&tokens, .underscore, "_")
            case "&":  add(&tokens, .ampersand, "&")
            case " ", "\t", "\n": index += 1
            case "[": add(&tokens, .text("["), "[") // 临时当做 text 处理，但在 Parser 里要专门判断 content == "["
            case "]": add(&tokens, .text("]"), "]")
            default:   add(&tokens, .text(String(char)), String(char))
            }
        }
        return tokens
    }
    
    private func add(_ list: inout [Token], _ type: TokenType, _ str: String) {
        list.append(Token(type: type, content: str))
        index += 1
    }
    
    private func readCommand() -> Token {
        index += 1 // skip \
        var cmd = ""
        while index < input.count {
            let c = input[index]
            if c.isLetter { cmd.append(c); index += 1 } else { break }
        }
        return Token(type: .command(cmd), content: cmd)
    }
}

// ==========================================
// MARK: - 5. 语法分析 (Parser)
// ==========================================

class LatexParser {
    private let tokens: [Token]
    private var index = 0
    private let rootFont: UIFont
    
    init(latex: String, font: UIFont) {
        let lexer = LatexLexer(latex)
        self.tokens = lexer.tokenize()
        self.rootFont = font
    }
    
    func parse() -> FormulaRenderNode {
        return parseNodes(font: rootFont, terminationCondition: { _ in false })
    }
    
    // 核心递归函数
    // terminationCondition: 闭包，用于告诉解析器何时停止当前层级的解析 (例如遇到 }, &, \\, \end)
    private func parseNodes(font: UIFont, terminationCondition: (Token) -> Bool) -> FormulaRenderNode {
            var nodes: [FormulaRenderNode] = []
            
            while index < tokens.count {
                if terminationCondition(tokens[index]) { break }
                if tokens[index].type == .rBrace { break } // 安全检查
                
                // 记录当前 Token，用于预判是否是 "巨型算符" (Big Operator)
                let startToken = tokens[index]
                
                // 1. 尝试解析基础原子
                // 注意：这里我们还没有消耗 index，parseAtom 会消耗
                // 但对于 Big Operator，我们需要特殊处理，不让 parseAtom 把它当普通符号处理完就结束了
                
                var base: FormulaRenderNode
                var isBigOp = false
                var opSymbol = ""
                
                // 检查是否是需要垂直堆叠的算符 (如 \sum, \prod, \lim)
                // 在 parseNodes 方法的 while 循环内部：

                // 检查是否是巨型算符 (需要垂直堆叠上下标的)
                // 使用 LatexSymbols.verticalLimits 集合来判断
                if case .command(let cmd) = startToken.type, LatexSymbols.verticalLimits.contains(cmd) {
                    isBigOp = true
                    // 从 map 里取符号 (如 "sum" -> "∑")，取不到就用原名
                    opSymbol = LatexSymbols.map[cmd] ?? cmd
                    index += 1 // 消耗该 token
                }
                // 之前的 lim 逻辑可以合并进去了，因为 lim 也在 verticalLimits 里
                
                if isBigOp {
                    // --- 🅰️ 巨型算符处理逻辑 (\sum, \lim) ---
                    var upper: FormulaRenderNode? = nil
                    var lower: FormulaRenderNode? = nil
                    
                    // 贪婪匹配后面紧跟的 ^ 和 _
                    // 注意：对于 OperatorNode，我们需要把上下标在初始化时就传进去
                    while index < tokens.count {
                        if tokens[index].type == .hat { // ^
                            index += 1
                            upper = parseNextItem(font: font.withSize(font.pointSize * 0.6))
                        } else if tokens[index].type == .underscore { // _
                            index += 1
                            lower = parseNextItem(font: font.withSize(font.pointSize * 0.6))
                        } else {
                            break
                        }
                    }
                    // 创建 OperatorNode (支持垂直堆叠)
                    base = OperatorNode(symbol: opSymbol, font: font, upper: upper, lower: lower)
                    
                } else {
                    // --- 🅱️ 普通原子处理逻辑 ---
                    guard let atom = parseAtom(font: font) else { break }
                    base = atom
                    
                    // 处理普通的后缀 (右上角/右下角)
                    while index < tokens.count {
                        if tokens[index].type == .hat {
                            index += 1
                            let scriptFont = font.withSize(font.pointSize * 0.6)
                            let script = parseNextItem(font: scriptFont)
                            base = ScriptNode(base: base, script: script, type: .super)
                        } else if tokens[index].type == .underscore {
                            index += 1
                            let scriptFont = font.withSize(font.pointSize * 0.6)
                            let script = parseNextItem(font: scriptFont)
                            base = ScriptNode(base: base, script: script, type: .sub)
                        } else {
                            break
                        }
                    }
                }
                
                nodes.append(base)
            }
            
            if nodes.isEmpty { return TextNode(text: "", font: font) }
            if nodes.count == 1 { return nodes[0] }
            return HorizontalNode(children: nodes)
        }
    
    // 解析单个原子
    // MARK: - 辅助方法：根据内容智能选择字体
        // 如果是 x, y 使用斜体；如果是 1, 2, +, sin 使用正体
    // 在 LatexParser 类中

        // 辅助方法：根据内容智能选择字体
        private func getKaTeXFont(text: String, size: CGFloat) -> UIFont {
            // 1. 数字、标点、运算符 -> KaTeX_Main-Regular (注意下划线!)
            if text.first?.isNumber == true || "+-=()[].,/!|<>".contains(text.first ?? " ") {
                return UIFont(name: "KaTeX_Main-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
            }
            
            // 2. 单个字母 (x, y, a, b) -> KaTeX_Math-Italic (注意下划线!)
            if text.count == 1 && text.first?.isLetter == true {
                 return UIFont(name: "KaTeX_Math-Italic", size: size) ?? UIFont.italicSystemFont(ofSize: size)
            }
            
            // 3. 默认回退 -> KaTeX_Main-Regular
            return UIFont(name: "KaTeX_Main-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
        }

       

        // MARK: - 核心解析方法
    // 解析单个原子
    private func parseAtom(font: UIFont) -> FormulaRenderNode? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        let currentSize = font.pointSize
        
        switch token.type {
        case .text(let str):
                    index += 1
                    
                    // [修复] 检查当前字体是否已经是特殊字体 (花体、黑板粗体等)
                    // 如果是特殊字体，直接使用，不要被 getKaTeXFont 覆盖
                    let fontName = font.fontName
                    if fontName.contains("Caligraphic") ||
                       fontName.contains("AMS") ||
                       fontName.contains("Fraktur") ||
                       fontName.contains("Typewriter") ||
                       fontName.contains("SansSerif") ||
                       fontName.contains("Script") {
                        return TextNode(text: str, font: font)
                    }
                    
                    // 只有普通情况才走智能选择 (斜体/正体)
                    let correctFont = getKaTeXFont(text: str, size: currentSize)
                    return TextNode(text: str, font: correctFont)
            
        case .command(let cmd):
            index += 1
            switch cmd {
            case "chemfig":
                // 1. 尝试读取花括号里的原始文本 (例如 "**6(------)")
                    if let structureCode = parseRawGroup() {
                        
                        // 2. 分析结构代码
                        // 如果包含 "**"，我们就认为是芳香环 (isAromatic = true)
                        let isAromatic = structureCode.contains("**")
                        
                        // 3. 返回你的 BenzeneNode
                        return BenzeneNode(font: font, structure: structureCode)
                    } else {
                        // 如果解析失败（比如没写花括号），返回一个空节点或错误提示
                        return TextNode(text: token.content, font: font)
                    }
            case "benzene":
                // 实例化 BenzeneNode
                // 手动传入标准苯环的 chemfig 代码 "**6(------)"
                // 这样 Node 内部会自动识别 "**" 并把 isAromatic 设为 true
                let node = BenzeneNode(font: font, structure: "**6(------)")
                return node

            case "cyclohexane":
                // 实例化环己烷
                // 手动传入标准环己烷代码 "6(------)" (或者 *6)
                // 只要不带 "**"，Node 内部就会把 isAromatic 设为 false
                let node = BenzeneNode(font: font, structure: "6(------)")
                return node
                // 这是一个简化的 text 模式处理，在 parseAtom 的 switch cmd 里：

                case "text", "mathrm", "textbf":
                    // 1. 计算字体
                    var subFont = font
                    if cmd == "textbf" {
                        subFont = UIFont(name: "KaTeX_Main-Bold", size: currentSize) ?? font
                    } else {
                        subFont = UIFont(name: "KaTeX_Main-Regular", size: currentSize) ?? font
                    }
                    
                    // 2. 解析内容
                    // 注意：这里继续调用 parseNextItem，它会递归调用 parseNodes
                    // 如果想要支持空格，你可以在 parseNodes 里判断：
                    // 只要是 text 模式，遇到 text token 就在后面追加一个微小的 SpaceNode?
                    // 或者目前先保持现状，依靠 \text{high~T} 来手动控制空格是最稳妥的。
                    return parseNextItem(font: subFont)
                // --- 结构类 ---
            case "frac":
                let smallFont = font.withSize(currentSize * 0.9)
                let num = parseNextItem(font: smallFont)
                let den = parseNextItem(font: smallFont)
                return FractionNode(numerator: num, denominator: den)
                
            case "sqrt":
                let inner = parseNextItem(font: font)
                return SqrtNode(inner: inner)
                
            case "begin":
                return parseMatrix(font: font)
            case "ce":
                return parseChemistry(font: font)
            case "left":
                // 格式: \left( ... \right)
                guard index < tokens.count else { return nil }
                let lDelim = tokens[index].content // "(" or "["
                index += 1
                
                // 解析内部内容，直到遇到 \right
                let contentNode = parseNodes(font: font, terminationCondition: { $0.type == .command("right") })
                
                // 吃掉 \right 和 它的右括号
                if index < tokens.count, case .command("right") = tokens[index].type {
                    index += 1 // eat \right
                    if index < tokens.count { index += 1 } // eat ) or ]
                }
                
                if lDelim == "(" { return DelimiterNode(inner: contentNode, type: .paren) }
                if lDelim == "[" { return DelimiterNode(inner: contentNode, type: .bracket) }
                return DelimiterNode(inner: contentNode, type: .paren)
                
                // --- 样式控制 ---
            case "mathbf", "textbf": // 粗体
                let boldName = "KaTeX_Main-Bold" // 确保名字与 Info.plist 一致
                let boldFont = UIFont(name: boldName, size: currentSize) ?? UIFont.boldSystemFont(ofSize: currentSize)
                return parseNextItem(font: boldFont)
                // --- 高级数学字体 ---
                            case "mathcal": // 花体 (Fourier F, Normal N)
                                // 对应字体文件: KaTeX_Caligraphic-Regular.ttf
                                let calFont = UIFont(name: "KaTeX_Caligraphic-Regular", size: currentSize) ?? font
                                return parseNextItem(font: calFont)
                                
                            case "mathbb": // 黑板粗体 (Real R, Complex C)
                                // 对应字体文件: KaTeX_AMS-Regular.ttf
                                let amsFont = UIFont(name: "KaTeX_AMS-Regular", size: currentSize) ?? font
                                return parseNextItem(font: amsFont)
                
            case "mathrm", "text": // 正体
                let romanName = "KaTeX_Main-Regular"
                let romanFont = UIFont(name: romanName, size: currentSize) ?? UIFont.systemFont(ofSize: currentSize)
                return parseNextItem(font: romanFont)
                
            case "mathit": // 斜体
                let italicName = "KaTeX_Main-Italic" // 注意：这是 Main 的 Italic，不是 Math-Italic
                let italicFont = UIFont(name: italicName, size: currentSize) ?? UIFont.italicSystemFont(ofSize: currentSize)
                return parseNextItem(font: italicFont)
                
                // --- 装饰符 (Accents) ---
            case "vec", "bar", "hat", "dot":
                // 需要在 LatexSymbols 或 LatexParser 顶部定义 accentMap
                let accentMap = ["vec": "→", "bar": "ˉ", "hat": "^", "dot": "˙"]
                if let char = accentMap[cmd] {
                    let base = parseNextItem(font: font)
                    let accentFont = UIFont(name: "KaTeX_Main-Regular", size: currentSize) ?? font
                    return AccentNode(base: base, accentChar: char, font: accentFont)
                }
                return TextNode(text: cmd, font: font)
                // --- 伸缩箭头 ---
                case "xrightarrow", "xleftarrow", "xlongequal":
                    // 格式: \xrightarrow[下方]{上方}
                    // 1. 解析可选参数 [下方]
                    var lower: FormulaRenderNode? = nil
                    if index < tokens.count && tokens[index].content == "[" {
                        index += 1 // eat [
                        // 注意：这里需要 parseNodes 直到遇到 ]
                        // 为了简化 Demo，我们假设可选参数里没有嵌套 ]，使用 terminationCondition
                        lower = parseNodes(font: font.withSize(font.pointSize * 0.7), terminationCondition: { $0.content == "]" })
                        if index < tokens.count { index += 1 } // eat ]
                    }
                    
                    // 2. 解析必选参数 {上方}
                    let upper = parseNextItem(font: font.withSize(font.pointSize * 0.7))
                    
                    let type: ArrowNode.ArrowType
                    if cmd == "xleftarrow" { type = .left }
                    else if cmd == "xlongequal" { type = .equal }
                    else { type = .right }
                    
                    return ArrowNode(upper: upper, lower: lower, type: type)
                // --- 间距 (Spacing) ---
            case "quad": return SpaceNode(width: currentSize)
            case "qquad": return SpaceNode(width: currentSize * 2)
            case ",", " ": return SpaceNode(width: currentSize * 0.3)
            case "!": return SpaceNode(width: -currentSize * 0.15)
                
                // --- 颜色 (Color) ---
                // [修改版] parseAtom 中的 color 分支
            case "color":
                  let colorName = parseStringContent()

                  // 🔥 必须解析整个 group，而不是单个 item
                  guard tokens[index].type == .lBrace else {
                      return TextNode(text: "", font: font)
                  }
                  index += 1  // 跳过 {
                  let content = parseNodes(font: font, terminationCondition: { $0.type == .rBrace })
                  guard index < tokens.count, tokens[index].type == .rBrace else {
                      return content
                  }
                  index += 1  // 跳过 }

                  if let color = LatexSymbols.colorMap[colorName] {
                      return ColorNode(child: content, color: color)
                  }
                  return content
                
                
                // --- 函数名 (正体) ---
            case "sin", "cos", "tan", "log", "ln", "lim":
                // 函数名强制使用 Main-Regular (正体)
                let funcFont = UIFont(name: "KaTeX_Main-Regular", size: currentSize) ?? font
                return TextNode(text: cmd, font: funcFont)
                // --- 1. 线框与修饰 ---
            case "overline":
                let content = parseNextItem(font: font)
                return EnclosureNode(child: content, type: .overline)
                
            case "underline":
                let content = parseNextItem(font: font)
                return EnclosureNode(child: content, type: .underline)
                
            case "boxed":
                let content = parseNextItem(font: font)
                return EnclosureNode(child: content, type: .boxed)
                
                // --- 2. 组合数 ---
            case "binom":
                // \binom{n}{k}
                let num = parseNextItem(font: font) // 上面的 n
                let den = parseNextItem(font: font) // 下面的 k
                return BinomNode(numerator: num, denominator: den)
                
                // --- 3. 升级 parseMatrix 支持 cases ---
                // 找到之前的 parseMatrix 方法，修改类型判断逻辑：
                /* 在 parseMatrix 方法内部：
                 if envName == "bmatrix" { type = .bracket }
                 else if envName == "pmatrix" { type = .paren }
                 else if envName == "cases" { type = .cases } // <--- 新增这行
                 else { type = .plain }
                 */
                // --- 默认符号查找 ---
                // 在 parseAtom 方法的 switch cmd 结束的 default 分支里：

                default:
                    // 1. 【关键】优先查表！支持希腊字母、特殊符号、箭头
                    if let sym = LatexSymbols.map[cmd] {
                        // 符号通常使用 Main-Regular 字体
                        let symFont = UIFont(name: "KaTeX_Main-Regular", size: currentSize) ?? font
                        return TextNode(text: sym, font: symFont)
                    }
                    
                    // 2. 检查是否是“装饰符” (如 \vec{a}, \bar{x})
                    if let accentChar = LatexSymbols.accentMap[cmd] {
                        let base = parseNextItem(font: font)
                        // 装饰符本身用常规字体
                        let accentFont = UIFont(name: "KaTeX_Main-Regular", size: currentSize) ?? font
                        return AccentNode(base: base, accentChar: accentChar, font: accentFont)
                    }

                    // 3. 未知命令，直接显示文本 (作为容错)
                    let textFont = UIFont(name: "KaTeX_Main-Regular", size: currentSize) ?? font
                    return TextNode(text: cmd, font: textFont)
            }
            
        case .lBrace:
            index += 1
            // 递归解析 Group
            let node = parseNodes(font: font, terminationCondition: { $0.type == .rBrace })
            if index < tokens.count && tokens[index].type == .rBrace { index += 1 }
            return node
            
        case .ampersand, .newLine, .rBrace:
            return nil
            
        default:
            index += 1
            return nil
        }
    }
    
    // 读取花括号内的原始字符串，不进行数学解析
    // 例如输入 \chemfig{**6}，这个方法返回 "**6"
    // 📖 读取花括号 {} 内部的原始文本 (Token 版)
        // 专门用于 chemfig 这种需要获取原始结构字符串的命令
        private func parseRawGroup() -> String? {
            // 1. 边界检查
            guard index < tokens.count else { return nil }
            
            // 2. 检查当前是否是 '{'
            // 注意：在你的 Lexer 里，'{' 对应的 type 是 .lBrace
            guard tokens[index].type == .lBrace else {
                return nil
            }
            
            index += 1 // 消耗掉开头的 '{'
            
            var rawContent = ""
            var braceDepth = 1 // 记录嵌套深度
            
            // 3. 循环遍历后续 Token
            while index < tokens.count {
                let token = tokens[index]
                index += 1 // 移动指针
                
                switch token.type {
                case .lBrace:
                    braceDepth += 1
                    rawContent.append(token.content) // 内部的括号也要保留
                    
                case .rBrace:
                    braceDepth -= 1
                    if braceDepth == 0 {
                        return rawContent // ✅ 成功闭合，返回内容 (不包含最外层的括号)
                    }
                    rawContent.append(token.content)
                    
                case .command(let cmd):
                    // 如果遇到命令，token.content 通常只包含命令名（如 "frac"），
                    // 我们需要补上反斜杠
                    rawContent.append("\\" + cmd)
                    
                case .newLine:
                    rawContent.append("\\\\")
                    
                default:
                    // 对于 text, hat, underscore 等，直接追加原始内容
                    rawContent.append(token.content)
                }
            }
            
            return nil // 括号不匹配 (没找到结尾的 '}')
        }
    // 🧪 简单的化学公式解析器
    // MARK: - 化学公式解析 (\ce)
        private func parseChemistry(font: UIFont) -> FormulaRenderNode {
            // 1. 准备工作
            // 必须以 { 开始 (由 parseAtom 调用时已经保证了，但为了安全还是检查一下)
            if index < tokens.count && tokens[index].type == .lBrace {
                index += 1 // eat {
            }
            
            var nodes: [FormulaRenderNode] = []
            // 化学式通常使用正体 (Main-Regular)，而不是斜体
            let chemFontName = "KaTeX_Main-Regular"
            let chemFont = UIFont(name: chemFontName, size: font.pointSize) ?? font
            
            // 2. 循环解析直到遇到的 }
            while index < tokens.count {
                // 结束条件
                if tokens[index].type == .rBrace {
                    index += 1 // eat }
                    break
                }
                
                let token = tokens[index]
                
                // ============================================================
                // 规则 1: 自动下标 (数字)
                // 触发条件：当前是数字，且前一个 Token 是字母或右括号
                // ============================================================
                if case .text(let str) = token.type, str.first?.isNumber == true {
                    // 检查前一个 Token 是否允许加下标
                    var shouldSubscript = false
                    let prevIndex = index - 1
                    
                    if prevIndex >= 0 {
                        let prevToken = tokens[prevIndex]
                        // 判断前一个是不是字母 (如 H2)
                        let isPrevLetter = (try? prevToken.content.first?.isLetter) ?? false
                        // 判断前一个是不是右括号 (如 )2 或 ]2)
                        let isPrevCloser = prevToken.type == .rBrace || prevToken.content == ")" || prevToken.content == "]"
                        
                        if isPrevLetter || isPrevCloser {
                            shouldSubscript = true
                        }
                    }
                    
                    if shouldSubscript, let last = nodes.popLast() {
                        index += 1
                        let subFont = chemFont.withSize(chemFont.pointSize * 0.7)
                        let subNode = TextNode(text: str, font: subFont)
                        nodes.append(ScriptNode(base: last, script: subNode, type: .sub))
                        continue // 处理完毕，进入下一次循环
                    }
                }
                
                // ============================================================
                // 规则 2: 处理减号 (可能是箭头 ->，可能是电荷 -，可能是单键 -)
                // ============================================================
                if case .text("-") = token.type {
                    
                    // A. 检查是不是箭头 ->
                    if index + 1 < tokens.count, tokens[index+1].content == ">" {
                        index += 2 // eat - and >
                        // 插入一个向右的箭头
                        let arrow = ArrowNode(upper: nil, lower: nil, type: .right)
                        nodes.append(arrow)
                        continue
                    }
                    
                    // B. 检查是不是电荷 (Charge) [例如 OH-]
                    // 逻辑：如果前面有原子，且不被视为单键
                    // 简单判断：如果前面不是空格，且后面没有东西了，或者是另一个电荷符号
                    var isCharge = false
                    if let last = nodes.last, !(last is SpaceNode) {
                        isCharge = true // 默认倾向于电荷，除非后面跟着明显的“连接对象”
                        // 如果后面跟着字母，那就是单键 (如 C-C)，不是电荷
                        if index + 1 < tokens.count, case .text(let nextStr) = tokens[index+1].type, nextStr.first?.isLetter == true {
                            isCharge = false
                        }
                    }
                    
                    if isCharge, let last = nodes.popLast() {
                        index += 1
                        let chargeFont = chemFont.withSize(chemFont.pointSize * 0.7)
                        let chargeNode = TextNode(text: "−", font: chargeFont) // 使用数学减号
                        nodes.append(ScriptNode(base: last, script: chargeNode, type: .super))
                        continue
                    }
                    
                    // C. 否则是单键 (Bond)
                    index += 1
                    nodes.append(TextNode(text: "−", font: chemFont))
                    continue
                }
                
                // ============================================================
                // 规则 3: 处理加号 (可能是电荷 +，可能是反应连接符 +)
                // ============================================================
                else if case .text("+") = token.type {
                    var isCharge = false
                    
                    // 只有当前面紧挨着原子或下标时，才可能是电荷
                    if let last = nodes.last, !(last is SpaceNode) {
                        // 向前看 (Lookahead) 策略
                        if index + 1 >= tokens.count {
                            isCharge = true // 结尾 (Na+)
                        } else {
                            let nextToken = tokens[index+1]
                            // 如果后面紧跟另一个 + (H+ + ...)
                            if case .text("+") = nextToken.type { isCharge = true }
                            // 如果后面紧跟箭头或减号 (Na+ -> ...)
                            else if case .text("-") = nextToken.type { isCharge = true }
                            // 如果后面是右括号 ([...]^2+)
                            else if case .rBrace = nextToken.type { isCharge = true }
                            else if nextToken.content == ")" || nextToken.content == "]" { isCharge = true }
                        }
                    }
                    
                    if isCharge, let last = nodes.popLast() {
                        // ⚡️ 渲染为上标电荷
                        index += 1
                        let chargeFont = chemFont.withSize(chemFont.pointSize * 0.7)
                        let chargeNode = TextNode(text: "+", font: chargeFont)
                        nodes.append(ScriptNode(base: last, script: chargeNode, type: .super))
                    } else {
                        // ➕ 渲染为反应连接符 (大加号，带空格)
                        index += 1
                        nodes.append(SpaceNode(width: chemFont.pointSize * 0.5))
                        nodes.append(TextNode(text: "+", font: chemFont))
                        nodes.append(SpaceNode(width: chemFont.pointSize * 0.5))
                    }
                    continue
                }
                
                // ============================================================
                // 规则 4: 其他情况 (显式上下标 ^ _, 或者普通文本)
                // ============================================================
                
                // 处理显式上标 (如 ^2+)
                if token.type == .hat {
                    index += 1
                    if let last = nodes.popLast() {
                        // 递归解析上标内容 (字号缩小)
                        let script = parseNextItem(font: chemFont.withSize(chemFont.pointSize * 0.7))
                        nodes.append(ScriptNode(base: last, script: script, type: .super))
                    }
                    continue
                }
                
                // 处理显式下标
                if token.type == .underscore {
                    index += 1
                    if let last = nodes.popLast() {
                        let script = parseNextItem(font: chemFont.withSize(chemFont.pointSize * 0.7))
                        nodes.append(ScriptNode(base: last, script: script, type: .sub))
                    }
                    continue
                }
                
                // 普通文本 (原子、括号等)
                if case .text(let str) = token.type {
                    index += 1
                    nodes.append(TextNode(text: str, font: chemFont))
                } else {
                    // 如果遇到其他无法识别的 token (如 \frac 在 \ce 里)，尝试回退到标准解析
                    // 但通常 \ce 内部不应该出现复杂 LaTeX 命令，除非嵌套
                    if let node = parseAtom(font: chemFont) {
                        nodes.append(node)
                    } else {
                        index += 1 // 避免死循环
                    }
                }
            }
            
            if nodes.isEmpty { return TextNode(text: "", font: font) }
            return HorizontalNode(children: nodes)
        }
    // 辅助：读取花括号内的完整字符串 (例如 "matrix", "blue", "cases")
        private func parseStringContent() -> String {
            var content = ""
            // 1. 必须以 { 开始
            guard index < tokens.count && tokens[index].type == .lBrace else { return "" }
            index += 1 // eat {
            
            // 2. 循环读取直到 }
            while index < tokens.count {
                if tokens[index].type == .rBrace {
                    index += 1 // eat }
                    break
                }
                // 拼接内容
                content += tokens[index].content
                index += 1
            }
            return content
        }
    // 解析单个参数 (处理 { } 或 单个字符)
    private func parseNextItem(font: UIFont) -> FormulaRenderNode {
        if index < tokens.count && tokens[index].type == .lBrace {
            index += 1
            let node = parseNodes(font: font, terminationCondition: { $0.type == .rBrace })
            if index < tokens.count && tokens[index].type == .rBrace { index += 1 }
            return node
        } else {
            return parseAtom(font: font) ?? TextNode(text: "", font: font)
        }
    }
    // 解析矩阵
    // 替换原有的 parseMatrix 方法
        private func parseMatrix(font: UIFont) -> FormulaRenderNode {
            // 1. 读取环境名称 (使用新方法读取完整字符串!)
                    // 之前是: guard ..., case .text(let envName) ... 导致只读了一个字母
                    let envName = parseStringContent()
                    
            // LatexParser.swift -> parseMatrix 方法内
            let type: MatrixType
            switch envName {
            case "bmatrix": type = .bracket
            case "pmatrix": type = .paren
            case "vmatrix": type = .abs    // ✅ 这里关联上
            case "cases":   type = .cases
            default:        type = .plain
            }
            
            // 2. 解析行和列
            var rows: [[FormulaRenderNode]] = []
            var currentRow: [FormulaRenderNode] = []
            
            // 循环直到遇到 \end
            while index < tokens.count {
                // 记录其实位置，防止死循环
                let loopStartIndex = index
                
                // 检查是否是 \end
                if case .command(let cmd) = tokens[index].type, cmd == "end" {
                    // 吃掉 \end {name}
                    index += 1
                    if index < tokens.count && tokens[index].type == .lBrace { index += 1 } // {
                    // 这里可以严谨点检查 name 是否匹配，暂略
                    if index < tokens.count, case .text = tokens[index].type { index += 1 } // name
                    if index < tokens.count && tokens[index].type == .rBrace { index += 1 } // }
                    break
                }
                
                // 解析单元格内容
                // 停止条件：遇到 & 或 \\ 或 \end
                let cellNode = parseNodes(font: font, terminationCondition: { t in
                    return t.type == .ampersand || t.type == .newLine || (t.type == .command("end"))
                })
                
                currentRow.append(cellNode)
                
                // 检查分隔符
                if index < tokens.count {
                    if tokens[index].type == .ampersand {
                        index += 1 // Next cell
                    } else if tokens[index].type == .newLine {
                        index += 1 // Next row
                        rows.append(currentRow)
                        currentRow = []
                    }
                }
                
                // [关键修复] 死循环熔断机制
                // 如果 parseNodes 没有消耗 token，且我们也没遇到 & 或 \\ 或 \end，说明遇到了无法解析的垃圾 Token
                if index == loopStartIndex {
                    // 强制跳过一个 token，防止死循环
                    // mdLog("⚠️ Warning: Skipping unexpected token in matrix: \(tokens[index].content)")
                    index += 1
                }
            }
            
            // 追加最后一行
            if !currentRow.isEmpty {
                rows.append(currentRow)
            }
            
            return MatrixNode(rows: rows, type: type)
        }
}


