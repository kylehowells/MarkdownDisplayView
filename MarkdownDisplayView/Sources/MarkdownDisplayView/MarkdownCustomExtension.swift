//
//  MarkdownCustomExtension.swift
//  MarkdownDisplayView
//
//  Created by Claude on 12/30/25.
//

import UIKit

// MARK: - Custom Element Data

/// 自定义元素数据（解析结果）
public struct CustomElementData: Equatable {
    public let type: String           // 类型标识
    public let rawText: String        // 原始文本
    public let payload: [String: String] // 自定义数据

    public init(type: String, rawText: String, payload: [String: String] = [:]) {
        self.type = type
        self.rawText = rawText
        self.payload = payload
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.type == rhs.type && lhs.rawText == rhs.rawText && lhs.payload == rhs.payload
    }
}

// MARK: - Custom Parser Protocol

/// 自定义 Markdown 语法解析器协议
public protocol MarkdownCustomParser: AnyObject {
    /// 解析器的唯一标识符
    var identifier: String { get }

    /// 正则匹配模式
    var pattern: String { get }

    /// 将匹配到的文本转换为自定义数据
    func parse(match: NSTextCheckingResult, in text: String) -> CustomElementData?
}

// MARK: - Custom View Provider Protocol

/// 自定义元素的视图提供者协议
public protocol MarkdownCustomViewProvider: AnyObject {
    /// 支持的元素类型
    var supportedType: String { get }

    /// 创建视图
    func createView(
        for data: CustomElementData,
        configuration: MarkdownConfiguration,
        containerWidth: CGFloat
    ) -> UIView

    /// 计算视图尺寸
    func calculateSize(
        for data: CustomElementData,
        configuration: MarkdownConfiguration,
        containerWidth: CGFloat
    ) -> CGSize
}

// MARK: - Custom Action Handler Protocol

/// 自定义元素的交互处理器协议
public protocol MarkdownCustomActionHandler: AnyObject {
    /// 支持的元素类型
    var supportedType: String { get }

    /// 处理点击事件
    func handleTap(data: CustomElementData, sourceView: UIView, presentingViewController: UIViewController?)

    /// 处理长按事件（可选）
    func handleLongPress(data: CustomElementData, sourceView: UIView, presentingViewController: UIViewController?)
}

// 默认实现
public extension MarkdownCustomActionHandler {
    func handleLongPress(data: CustomElementData, sourceView: UIView, presentingViewController: UIViewController?) {}
}

// MARK: - Code Block Renderer Protocol

/// 代码块自定义渲染器协议
/// 用于渲染特殊语言的代码块（如 mermaid、plantuml、mindmap 等）
public protocol MarkdownCodeBlockRenderer: AnyObject {
    /// 支持的语言标识（如 "mermaid", "plantuml", "mindmap"）
    var supportedLanguage: String { get }

    /// 渲染代码块内容
    /// - Parameters:
    ///   - code: 原始代码文本
    ///   - configuration: Markdown 配置
    ///   - containerWidth: 容器宽度
    /// - Returns: 渲染后的视图
    func renderCodeBlock(
        code: String,
        configuration: MarkdownConfiguration,
        containerWidth: CGFloat
    ) -> UIView

    /// 计算视图尺寸
    /// - Parameters:
    ///   - code: 原始代码文本
    ///   - configuration: Markdown 配置
    ///   - containerWidth: 容器宽度
    /// - Returns: 视图尺寸
    func calculateSize(
        code: String,
        configuration: MarkdownConfiguration,
        containerWidth: CGFloat
    ) -> CGSize
}

// MARK: - Custom Extension Manager

/// 自定义扩展管理器
public final class MarkdownCustomExtensionManager {

    public static let shared = MarkdownCustomExtensionManager()

    /// 保护扩展注册表的并发读写。
    ///
    /// Markdown 解析会在各 MarkdownView 的后台 renderQueue 上执行，而业务方可能在
    /// 运行期间注册扩展；Swift Dictionary 不支持这种并发读写。这里只保护注册表本身，
    /// 不在锁内调用第三方 parser/provider，避免长时间占锁或回调 manager 时死锁。
    private let registryLock = NSLock()
    private var parsers: [String: MarkdownCustomParser] = [:]
    private var viewProviders: [String: MarkdownCustomViewProvider] = [:]
    private var actionHandlers: [String: MarkdownCustomActionHandler] = [:]
    private var codeBlockRenderers: [String: MarkdownCodeBlockRenderer] = [:]  // 代码块渲染器

    private init() {}

    private func withRegistryLock<T>(_ body: () throws -> T) rethrows -> T {
        registryLock.lock()
        defer { registryLock.unlock() }
        return try body()
    }

    // MARK: - Registration

    /// 注册自定义解析器
    public func register(parser: MarkdownCustomParser) {
        withRegistryLock {
            parsers[parser.identifier] = parser
        }
    }

    /// 注册自定义视图提供者
    public func register(viewProvider: MarkdownCustomViewProvider) {
        withRegistryLock {
            viewProviders[viewProvider.supportedType] = viewProvider
        }
    }

    /// 注册自定义事件处理器
    public func register(actionHandler: MarkdownCustomActionHandler) {
        withRegistryLock {
            actionHandlers[actionHandler.supportedType] = actionHandler
        }
    }

    /// 注册代码块渲染器
    public func register(codeBlockRenderer: MarkdownCodeBlockRenderer) {
        withRegistryLock {
            codeBlockRenderers[codeBlockRenderer.supportedLanguage.lowercased()] = codeBlockRenderer
        }
    }

    // MARK: - Access

    /// 获取所有解析器
    public var allParsers: [MarkdownCustomParser] {
        withRegistryLock {
            Array(parsers.values)
        }
    }

    /// 获取视图提供者
    public func viewProvider(for type: String) -> MarkdownCustomViewProvider? {
        withRegistryLock {
            viewProviders[type]
        }
    }

    /// 获取事件处理器
    public func actionHandler(for type: String) -> MarkdownCustomActionHandler? {
        withRegistryLock {
            actionHandlers[type]
        }
    }

    /// 获取代码块渲染器
    public func codeBlockRenderer(for language: String) -> MarkdownCodeBlockRenderer? {
        withRegistryLock {
            codeBlockRenderers[language.lowercased()]
        }
    }

    // MARK: - Parsing

    /// 预处理文本，提取自定义元素
    public func preprocessCustomElements(
        in text: String
    ) -> [(range: NSRange, data: CustomElementData)] {
        var results: [(range: NSRange, data: CustomElementData)] = []
        let nsText = text as NSString
        // 只在锁内复制快照。parser.parse 是第三方代码，必须在解锁后调用。
        let parserSnapshot = allParsers

        for parser in parserSnapshot {
            guard let regex = try? NSRegularExpression(pattern: parser.pattern, options: []) else {
                continue
            }

            let matches = regex.matches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: nsText.length)
            )

            for match in matches {
                if let data = parser.parse(match: match, in: text) {
                    results.append((range: match.range, data: data))
                }
            }
        }

        // 按位置排序
        results.sort { $0.range.location < $1.range.location }

        return results
    }
}
