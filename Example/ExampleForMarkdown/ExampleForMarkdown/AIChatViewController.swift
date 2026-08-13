//
//  AIChatViewController.swift
//  CocoapodsMDExample
//
//  Created by 朱继超 on 12/20/25.
//

import UIKit
import MarkdownDisplayView
import PhotosUI
import AVFoundation

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct AIChatToolContextMessage: Codable {
    let role: String
    var content: String?
    var reasoningContent: String?
    var toolCallID: String?
    var toolCalls: [AIChatToolCall]?

    struct AIChatToolCall: Codable {
        let id: String
        let type: String
        let name: String
        let arguments: String
    }

    fileprivate func toRequestMessage() -> OpenAIChatRequest.Message {
        OpenAIChatRequest.Message(
            role: role,
            content: content,
            reasoningContent: reasoningContent,
            toolCalls: toolCalls?.map {
                OpenAIChatRequest.Message.ToolCall(
                    id: $0.id,
                    type: $0.type,
                    function: OpenAIChatRequest.Message.ToolCall.FunctionCall(name: $0.name, arguments: $0.arguments)
                )
            },
            toolCallID: toolCallID
        )
    }
}

struct AIChatMessage: Codable {
    let id: UUID
    let role: ChatRole
    var content: String
    var isPlaceholder: Bool = false
    var isStreaming: Bool = false
    var attachments: [AIChatImageAttachment] = []
    var toolContext: [AIChatToolContextMessage]?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        isPlaceholder: Bool = false,
        isStreaming: Bool = false,
        attachments: [AIChatImageAttachment] = [],
        toolContext: [AIChatToolContextMessage]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.isPlaceholder = isPlaceholder
        self.isStreaming = isStreaming
        self.attachments = attachments
        self.toolContext = toolContext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(ChatRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        isPlaceholder = try container.decodeIfPresent(Bool.self, forKey: .isPlaceholder) ?? false
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        attachments = try container.decodeIfPresent([AIChatImageAttachment].self, forKey: .attachments) ?? []
        toolContext = try container.decodeIfPresent([AIChatToolContextMessage].self, forKey: .toolContext)
    }

    var renderedMarkdown: String {
        let attachmentSummary = attachments.isEmpty
            ? ""
            : "\n\n*已识别 \(attachments.count) 张图片中的文字*"
        return content + attachmentSummary
    }
}

/// 将 Markdown 粗略转为可朗读/可复制的纯文本。
private enum AIChatSpeechTextExtractor {
    static func plainText(from markdown: String) -> String {
        var text = markdown

        // 代码块围栏
        text = text.replacingOccurrences(of: "```[^\\n]*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "```", with: "")

        // 图片与链接
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)

        // LaTeX 分隔符
        text = text.replacingOccurrences(of: "\\${1,2}", with: "", options: .regularExpression)

        // 标题、引用、列表标记
        text = text.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*>+\\s?", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)

        // 表格分隔行与竖线
        text = text.replacingOccurrences(of: "(?m)^\\s*\\|?\\s*:?-+:?\\s*\\|.*$", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\|", with: " ")

        // 强调/加粗/删除线
        text = text.replacingOccurrences(of: "[*_~]{1,3}", with: "", options: .regularExpression)

        // 行内代码
        text = text.replacingOccurrences(of: "`+", with: "", options: .regularExpression)

        // 分隔线
        text = text.replacingOccurrences(of: "(?m)^\\s*[*_-]{3,}\\s*$", with: "", options: .regularExpression)

        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}

private final class AIChatPreparedContentBox {
    let markdown: String
    let widthBucket: Int
    let content: MarkdownPreparedContent

    init(markdown: String, widthBucket: Int, content: MarkdownPreparedContent) {
        self.markdown = markdown
        self.widthBucket = widthBucket
        self.content = content
    }
}

private struct AIChatPreparationKey: Hashable {
    let messageID: UUID
    let markdown: String
    let widthBucket: Int
}

private final class AIChatPreparationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private struct AIChatConfig: Decodable {
    struct Thinking: Decodable {
        let type: String
    }

    let host: String
    let path: String
    let apiKey: String
    let model: String
    let systemPrompt: String?
    let temperature: Double?
    let stream: Bool?
    let timeoutSeconds: TimeInterval?
    let thinking: Thinking?
    let reasoningEffort: String?
    let searchProvider: String?
    let searchAPIKey: String?

    enum CodingKeys: String, CodingKey {
        case host, path, apiKey, model, systemPrompt, temperature, stream, timeoutSeconds, thinking
        case reasoningEffort = "reasoning_effort"
        case searchProvider, searchAPIKey
    }

    var endpointURL: URL? {
        let trimmedHost = host.hasSuffix("/") ? String(host.dropLast()) : host
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        return URL(string: trimmedHost + normalizedPath)
    }
}

private enum AIChatConfigError: LocalizedError {
    case fileNotFound
    case invalidFormat
    case invalidURL
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "未找到 Config.local.json"
        case .invalidFormat:
            return "Config.local.json 格式错误"
        case .invalidURL:
            return "Config.local.json 中的 host/path 无效"
        case .invalidKey:
            return "Config.local.json 中的 apiKey 为空"
        }
    }
}

private enum AIChatConfigLoader {
    static func load() -> Result<AIChatConfig, AIChatConfigError> {
        guard let url = locateConfigURL() else {
            return .failure(.fileNotFound)
        }

        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(AIChatConfig.self, from: data)
            guard config.endpointURL != nil else {
                return .failure(.invalidURL)
            }
            guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.invalidKey)
            }
            return .success(config)
        } catch {
            return .failure(.invalidFormat)
        }
    }

    private static func locateConfigURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "Config.local", withExtension: "json") {
            return bundleURL
        }
//Config.local.json 结构如下
//{
//  "host": "https://api.deepseek.com",
//  "path": "/chat/completions",
//  "apiKey": "",
//  "model": "deepseek-chat",
//  "systemPrompt": "You are a helpful assistant.",
//  "temperature": 0.7,
//  "stream": true,
//  "timeoutSeconds": 30
//}
//
        let documentURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Config.local.json")

        if let documentURL, FileManager.default.fileExists(atPath: documentURL.path) {
            return documentURL
        }

        return nil
    }
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        struct ToolCall: Encodable {
            let id: String
            let type: String
            let function: FunctionCall

            struct FunctionCall: Encodable {
                let name: String
                let arguments: String
            }
        }

        let role: String
        let content: String?
        var reasoningContent: String?
        var toolCalls: [ToolCall]?
        var toolCallID: String?

        init(role: String, content: String?, reasoningContent: String? = nil, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
            self.role = role
            self.content = content
            self.reasoningContent = reasoningContent
            self.toolCalls = toolCalls
            self.toolCallID = toolCallID
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            if let content {
                try container.encode(content, forKey: .content)
            }
            try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
            try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
            try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        }

        private enum CodingKeys: String, CodingKey {
            case role
            case content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }
    }

    struct Tool: Encodable {
        let type: String
        let function: Function

        struct Function: Encodable {
            let name: String
            let description: String
            let parameters: Parameters
        }

        struct Parameters: Encodable {
            let type: String
            let properties: [String: Property]
            let required: [String]
            let additionalProperties: Bool
        }

        struct Property: Encodable {
            let type: String
            let description: String
        }
    }

    struct Thinking: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
    let stream: Bool?
    let tools: [Tool]?
    let toolChoice: String?
    let thinking: Thinking?
    let reasoningEffort: String?

    init(
        model: String,
        messages: [Message],
        temperature: Double?,
        stream: Bool?,
        tools: [Tool]? = nil,
        toolChoice: String? = nil,
        thinking: Thinking? = nil,
        reasoningEffort: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.stream = stream
        self.tools = tools
        self.toolChoice = toolChoice
        self.thinking = thinking
        self.reasoningEffort = reasoningEffort
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(stream, forKey: .stream)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case stream
        case tools
        case toolChoice = "tool_choice"
        case thinking
        case reasoningEffort = "reasoning_effort"
    }
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            struct ToolCall: Decodable {
                let id: String?
                let type: String?
                let function: FunctionCall?

                struct FunctionCall: Decodable {
                    let name: String?
                    let arguments: String?
                }
            }

            let role: String?
            let content: String?
            let reasoningContent: String?
            let toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case role
                case content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }
        let message: Message?
    }

    struct ErrorInfo: Decodable {
        let message: String?
    }

    let choices: [Choice]?
    let error: ErrorInfo?
}

private struct OpenAIStreamResponse: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoningContent: String?
            let toolCalls: [ToolCallDelta]?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        struct ToolCallDelta: Decodable {
            let index: Int?
            let id: String?
            let type: String?
            let function: FunctionDelta?

            struct FunctionDelta: Decodable {
                let name: String?
                let arguments: String?
            }
        }

        let delta: Delta?
        let finish_reason: String?
    }

    let choices: [Choice]?
}

private struct WebSearchToolCall {
    let id: String
    let name: String
    let arguments: String
}

private enum WebSearchService {
    enum SearchError: LocalizedError {
        case invalidQuery
        case emptyResponse
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .invalidQuery: return "搜索关键词无效"
            case .emptyResponse: return "搜索响应为空"
            case .missingAPIKey: return "缺少搜索 API Key"
            }
        }
    }

    /// 搜索不可用时的兑底提示：让模型停止重试、直接基于已有知识回答。
    static let unavailableMessage = "联网搜索服务暂时不可用。请不要再调用搜索工具，直接基于你已有的知识回答，并说明无法获取最新信息。"

    static func search(
        query: String,
        provider: String?,
        apiKey: String?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let resolved = (provider ?? "bing").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        print("[AIChat][WebSearch] provider=\(resolved) query=\"\(query)\"")
        switch resolved {
        case "tavily":
            searchTavily(query: query, apiKey: apiKey, completion: completion)
        case "bocha", "bochaai":
            searchBocha(query: query, apiKey: apiKey, completion: completion)
        case "duckduckgo", "ddg":
            searchDuckDuckGo(query: query, completion: completion)
        default:
            searchBing(query: query, completion: completion)
        }
    }

    // MARK: - DuckDuckGo（无需 key）

    private static func searchDuckDuckGo(query: String, completion: @escaping (Result<String, Error>) -> Void) {
        var components = URLComponents(string: "https://api.duckduckgo.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]
        guard let url = components?.url else {
            completion(.failure(SearchError.invalidQuery))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(SearchError.emptyResponse))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(DuckDuckGoResponse.self, from: data)
                completion(.success(decoded.formattedText))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Tavily（需要 API Key）

    private static func searchTavily(query: String, apiKey: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            completion(.failure(SearchError.missingAPIKey))
            return
        }

        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": 5,
            "search_depth": "basic"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(SearchError.emptyResponse))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(TavilyResponse.self, from: data)
                completion(.success(decoded.formattedText))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Bocha（博查，需要 API Key，国内可访问）

    private static func searchBocha(query: String, apiKey: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            completion(.failure(SearchError.missingAPIKey))
            return
        }

        var request = URLRequest(url: URL(string: "https://api.bochaai.com/v1/web-search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "query": query,
            "freshness": "noLimit",
            "summary": true,
            "count": 8
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(SearchError.emptyResponse))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(BochaResponse.self, from: data)
                completion(.success(decoded.formattedText))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Bing（无需 key，HTML 解析）

    private static func searchBing(query: String, completion: @escaping (Result<String, Error>) -> Void) {
        var components = URLComponents(string: "https://www.bing.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "setlang", value: "zh-hans")
        ]
        guard let url = components?.url else {
            completion(.failure(SearchError.invalidQuery))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.addValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.addValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(SearchError.emptyResponse))
                return
            }
            let results = Self.parseBingHTML(html)
            completion(.success(results.isEmpty ? "未找到相关搜索结果。" : results.joined(separator: "\n")))
        }.resume()
    }

    private static func parseBingHTML(_ html: String) -> [String] {
        var results: [String] = []
        let blocks = html.components(separatedBy: "b_algo")
        for block in blocks.dropFirst() {
            guard let title = extractFirst(in: block, tag: "h2"),
                  let snippet = extractFirst(in: block, tag: "p") else { continue }
            let titleText = stripHTML(title).trimmingCharacters(in: .whitespacesAndNewlines)
            let snippetText = stripHTML(snippet).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !titleText.isEmpty else { continue }
            var line = titleText
            if !snippetText.isEmpty {
                line += "\n" + snippetText
            }
            if results.count < 6 {
                results.append(line)
            }
        }
        return results
    }

    private static func extractFirst(in text: String, tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(tag)[^>]*>(.*?)</\(tag)>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    private static func stripHTML(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}

private struct TavilyResponse: Decodable {
    let answer: String?
    let results: [Result]?

    struct Result: Decodable {
        let title: String?
        let url: String?
        let content: String?
    }

    var formattedText: String {
        var lines: [String] = []
        if let answer, !answer.isEmpty {
            lines.append(answer)
        }
        for result in results ?? [] {
            var parts: [String] = []
            if let title = result.title, !title.isEmpty { parts.append(title) }
            if let content = result.content, !content.isEmpty { parts.append(content) }
            if let url = result.url, !url.isEmpty { parts.append("来源：\(url)") }
            let line = parts.joined(separator: "\n")
            if !line.isEmpty { lines.append(line) }
        }
        if lines.isEmpty { return "未找到相关搜索结果。" }
        return lines.joined(separator: "\n\n")
    }
}

private struct BochaResponse: Decodable {
    let code: Int?
    let message: String?
    let data: Data?

    struct Data: Decodable {
        let webPages: WebPages?

        struct WebPages: Decodable {
            let value: [Item]?

            struct Item: Decodable {
                let name: String?
                let url: String?
                let snippet: String?
                let summary: String?
                let siteName: String?
            }
        }
    }

    var formattedText: String {
        let items = data?.webPages?.value ?? []
        var lines: [String] = []
        for item in items {
            var parts: [String] = []
            if let name = item.name, !name.isEmpty { parts.append(name) }
            let text = item.summary ?? item.snippet ?? ""
            if !text.isEmpty { parts.append(text) }
            if let siteName = item.siteName, !siteName.isEmpty { parts.append("来源：\(siteName)") }
            let line = parts.joined(separator: "\n")
            if !line.isEmpty { lines.append(line) }
        }
        if lines.isEmpty {
            if let message, !message.isEmpty { return message }
            return "未找到相关搜索结果。"
        }
        return lines.joined(separator: "\n\n")
    }
}

private struct DuckDuckGoResponse: Decodable {
    let heading: String?
    let abstractText: String?
    let abstractURL: String?
    let relatedTopics: [Topic]?

    struct Topic: Decodable {
        let text: String?
        let firstURL: String?
        let topics: [Topic]?

        enum CodingKeys: String, CodingKey {
            case text = "Text"
            case firstURL = "FirstURL"
            case topics = "Topics"
        }
    }

    enum CodingKeys: String, CodingKey {
        case heading = "Heading"
        case abstractText = "AbstractText"
        case abstractURL = "AbstractURL"
        case relatedTopics = "RelatedTopics"
    }

    var formattedText: String {
        var lines: [String] = []
        if let heading, !heading.isEmpty {
            lines.append("主题：\(heading)")
        }
        if let abstractText, !abstractText.isEmpty {
            lines.append(abstractText)
            if let abstractURL, !abstractURL.isEmpty {
                lines.append("来源：\(abstractURL)")
            }
        }
        for topic in relatedTopics ?? [] {
            append(topic, into: &lines)
        }
        if lines.isEmpty {
            return "未找到相关搜索结果。"
        }
        return lines.joined(separator: "\n")
    }

    private func append(_ topic: Topic, into lines: inout [String]) {
        if let children = topic.topics, !children.isEmpty {
            for child in children {
                append(child, into: &lines)
            }
        } else if let text = topic.text, !text.isEmpty {
            let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            if let url = topic.firstURL, !url.isEmpty {
                lines.append("\(cleaned)\n来源：\(url)")
            } else {
                lines.append(cleaned)
            }
        }
    }
}

private final class StreamMarkdownNormalizer {
    private var pendingBackslash = false
    private var pendingBackticks = 0
    private var pendingDollars = 0
    private var inCodeFence = false
    private var inlineCodeDelimiterCount: Int?

    func reset() {
        pendingBackslash = false
        pendingBackticks = 0
        pendingDollars = 0
        inCodeFence = false
        inlineCodeDelimiterCount = nil
    }

    func normalizeDelta(_ delta: String) -> String {
        process(delta, flushPending: false)
    }

    func normalizeFullText(_ text: String) -> String {
        reset()
        return process(text, flushPending: true)
    }

    func flush() -> String {
        process("", flushPending: true)
    }

    private var isInCodeRegion: Bool {
        inCodeFence || inlineCodeDelimiterCount != nil
    }

    private func process(_ input: String, flushPending: Bool) -> String {
        var output = ""
        var index = input.startIndex

        if pendingBackslash {
            if index < input.endIndex {
                let first = input[index]
                if !isInCodeRegion, isLatexDelimiter(first) {
                    output += latexReplacement(for: first)
                    index = input.index(after: index)
                } else {
                    output += "\\"
                }
                pendingBackslash = false
            } else if flushPending {
                output += "\\"
                pendingBackslash = false
            } else {
                return ""
            }
        }

        let prefix = String(repeating: "`", count: pendingBackticks)
            + String(repeating: "$", count: pendingDollars)
        pendingBackticks = 0
        pendingDollars = 0

        let remaining = input[index...]
        let text = prefix + remaining

        var cursor = text.startIndex
        while cursor < text.endIndex {
            let current = text[cursor]

            if current == "`" {
                var end = cursor
                while end < text.endIndex, text[end] == "`" {
                    end = text.index(after: end)
                }
                let count = text.distance(from: cursor, to: end)

                if end == text.endIndex, !flushPending {
                    pendingBackticks = count
                    break
                }

                handleBackticks(count, output: &output)
                cursor = end
                continue
            }

            if current == "$" {
                var end = cursor
                while end < text.endIndex, text[end] == "$" {
                    end = text.index(after: end)
                }
                let count = text.distance(from: cursor, to: end)

                if end == text.endIndex, !flushPending {
                    pendingDollars = count
                    break
                }

                output += String(repeating: "$", count: count)
                cursor = end
                continue
            }

            if current == "\\" {
                let nextIndex = text.index(after: cursor)
                if nextIndex == text.endIndex {
                    if flushPending {
                        output += "\\"
                    } else {
                        pendingBackslash = true
                    }
                    break
                }

                let nextChar = text[nextIndex]
                if !isInCodeRegion, isLatexDelimiter(nextChar) {
                    output += latexReplacement(for: nextChar)
                    cursor = text.index(after: nextIndex)
                } else {
                    output += "\\"
                    cursor = nextIndex
                }
                continue
            }

            output.append(current)
            cursor = text.index(after: cursor)
        }

        if flushPending {
            if pendingBackticks > 0 {
                output += String(repeating: "`", count: pendingBackticks)
                pendingBackticks = 0
            }
            if pendingDollars > 0 {
                output += String(repeating: "$", count: pendingDollars)
                pendingDollars = 0
            }
            if pendingBackslash {
                output += "\\"
                pendingBackslash = false
            }
        }

        return output
    }

    private func handleBackticks(_ count: Int, output: inout String) {
        if inCodeFence {
            if count >= 3 {
                inCodeFence = false
            }
            output += String(repeating: "`", count: count)
            return
        }

        if let inlineCount = inlineCodeDelimiterCount {
            if count == inlineCount {
                inlineCodeDelimiterCount = nil
            }
            output += String(repeating: "`", count: count)
            return
        }

        if count >= 3 {
            inCodeFence = true
        } else {
            inlineCodeDelimiterCount = count
        }
        output += String(repeating: "`", count: count)
    }

    private func isLatexDelimiter(_ char: Character) -> Bool {
        char == "(" || char == ")" || char == "[" || char == "]"
    }

    private func latexReplacement(for delimiter: Character) -> String {
        switch delimiter {
        case "(", ")":
            return "$"
        case "[", "]":
            return "$$"
        default:
            return "\\"
        }
    }
}

private struct StreamedToolCall {
    let id: String
    let name: String
    let arguments: String
}

private final class AIChatStreamSession: NSObject, URLSessionDataDelegate {
    private struct ToolCallBuilder {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private let request: URLRequest
    private let onDelta: (String) -> Void
    private let onToolCalls: ([StreamedToolCall], String) -> Void
    private let onComplete: () -> Void
    private let onError: (String) -> Void
    private var buffer = ""
    private var isFinished = false
    private var dataTask: URLSessionDataTask?
    private var toolCallBuilders: [Int: ToolCallBuilder] = [:]
    private var reasoningContent = ""

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(
        request: URLRequest,
        onDelta: @escaping (String) -> Void,
        onToolCalls: @escaping ([StreamedToolCall], String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.request = request
        self.onDelta = onDelta
        self.onToolCalls = onToolCalls
        self.onComplete = onComplete
        self.onError = onError
        super.init()
    }

    func start() {
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }

    func cancel() {
        isFinished = true
        dataTask?.cancel()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            finishWithError("服务返回状态码 \(http.statusCode)")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isFinished else { return }
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        buffer.append(chunk)
        parseBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isFinished else { return }
        if let error = error {
            finishWithError(error.localizedDescription)
        } else {
            finishSuccessfully()
        }
    }

    private func parseBuffer() {
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.hasPrefix("data:") else { return }

        let payload = trimmed.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            finishSuccessfully()
            return
        }

        guard let data = payload.data(using: .utf8) else { return }
        guard let decoded = try? JSONDecoder().decode(OpenAIStreamResponse.self, from: data) else { return }
        if let content = decoded.choices?.first?.delta?.content, !content.isEmpty {
            onDelta(content)
        }
        if let reasoning = decoded.choices?.first?.delta?.reasoningContent, !reasoning.isEmpty {
            reasoningContent += reasoning
        }
        for toolCall in decoded.choices?.first?.delta?.toolCalls ?? [] {
            accumulate(toolCall)
        }
    }

    private func accumulate(_ delta: OpenAIStreamResponse.Choice.ToolCallDelta) {
        let index = delta.index ?? 0
        var builder = toolCallBuilders[index] ?? ToolCallBuilder()
        if let id = delta.id { builder.id = id }
        if let name = delta.function?.name { builder.name += name }
        if let arguments = delta.function?.arguments { builder.arguments += arguments }
        toolCallBuilders[index] = builder
    }

    private func finishSuccessfully() {
        guard !isFinished else { return }
        isFinished = true
        let calls = toolCallBuilders.keys.sorted().compactMap { index -> StreamedToolCall? in
            let builder = toolCallBuilders[index]!
            guard !builder.name.isEmpty else { return nil }
            return StreamedToolCall(id: builder.id, name: builder.name, arguments: builder.arguments)
        }
        if !calls.isEmpty {
            onToolCalls(calls, reasoningContent)
        }
        onComplete()
    }

    private func finishWithError(_ message: String) {
        guard !isFinished else { return }
        isFinished = true
        onError(message)
    }
}

final class AIChatViewController: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let selectedTheme = MarkdownDemoThemeStore.selectedTheme
    private var messages: [AIChatMessage] = []
    private var isRequesting = false
    private var pendingAssistantIndex: Int?
    private var streamingAssistantIndex: Int?
    private var config: AIChatConfig?
    private var streamSession: AIChatStreamSession?
    private var activeTask: URLSessionDataTask?
    private let responseLogLimit = 400
    private let streamNormalizer = StreamMarkdownNormalizer()
    private var receivedText = ""
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var speakingMessageID: UUID?
    private var activeRequestMessages: [OpenAIChatRequest.Message] = []
    private var activeToolExchange: [AIChatToolContextMessage] = []
    private var toolCallRounds = 0
    private let maxToolCallRounds = 36
    private var isHandlingToolCalls = false
    private var chatTurnGeneration = 0

    private static let webSearchTool = OpenAIChatRequest.Tool(
        type: "function",
        function: OpenAIChatRequest.Tool.Function(
            name: "web_search",
            description: "搜索互联网以获取最新信息或模型训练数据之外的内容。当用户询问近期事件、实时数据、商品价格/参数/评测/对比、新闻等内容时使用。",
            parameters: OpenAIChatRequest.Tool.Parameters(
                type: "object",
                properties: [
                    "query": OpenAIChatRequest.Tool.Property(
                        type: "string",
                        description: "要搜索的关键词或问题"
                    )
                ],
                required: ["query"],
                additionalProperties: false
            )
        )
    )

    private let conversationStore = AIChatConversationStore.shared
    private var currentConversation = AIChatConversation(title: "新对话")
    private var selectedHistoryConversationIDs = Set<UUID>()
    private let preparedContentCache: NSCache<NSUUID, AIChatPreparedContentBox> = {
        let cache = NSCache<NSUUID, AIChatPreparedContentBox>()
        cache.countLimit = 100
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private let markdownPreparationQueue = DispatchQueue(
        label: "com.markdown.aichat.prepare",
        qos: .userInitiated
    )
    private var pendingPreparationKeys = Set<AIChatPreparationKey>()
    private var pendingPreparationTokens: [AIChatPreparationKey: AIChatPreparationToken] = [:]
    private var lastMarkdownWidthBucket: Int?
    private let ocrService = AIChatOCRService()
    private var selectedImages: [AIChatSelectedImage] = []
    /// 清空选图后自增，用于丢弃已在执行中的 OCR 回调
    private var ocrGeneration = 0

    /// 用户是否正在交互（拖拽滚动），用于暂停自动滚动
    private var isUserInteracting = false
    private var pendingRowHeightUpdate = false
    private var pendingStreamingFollow = false
    /// 防止 performBatchUpdates 触发的布局回调再次排队，形成行高更新反馈环。
    private var isApplyingRowHeightUpdate = false
    /// 首轮 batch 中可能才得到最终有效高度；允许 completion 后补一次，但禁止继续递归。
    private var needsPostBatchRowHeightUpdate = false
    private var isPostBatchRowHeightUpdate = false
    /// 拖拽或减速期间只记录一次行高变化，手势结束后合并刷新。
    private var hasDeferredRowHeightUpdate = false
    private var isTableViewGestureActive = false
    /// 每次开始/结束流式时递增，使已经排队的自动滚动任务立即失效。
    private var autoScrollGeneration = 0

    private let inputContainer = UIView()
    private let inputTextView = UITextView()
    private let sendButton = UIButton(type: .system)
    private let imageButton = UIButton(type: .system)
    private let imageStripView = AIChatImageStripView()
    private var imageStripHeightConstraint: NSLayoutConstraint?
    private var inputBottomConstraint: NSLayoutConstraint?

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("关闭", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var historyButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "clock.arrow.circlepath"), for: .normal)
        button.accessibilityLabel = "历史会话"
        button.addTarget(self, action: #selector(historyTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var stopButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("停止", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.text = "AI 对话"
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.backgroundColor = .systemBackground
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        if let selectedTheme {
            overrideUserInterfaceStyle = selectedTheme.interfaceStyle
        }
        view.backgroundColor = .systemBackground
        setupHeader()
        setupTableView()
        setupInputArea()
        applySelectedTheme()
        loadConfig()
        loadConversationHistory()
        registerKeyboardNotifications()
        speechSynthesizer.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if config == nil,
           !ProcessInfo.processInfo.arguments.contains("-SuppressAIConfigAlert") {
            showConfigAlert()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let width = markdownContentWidth()
        guard width > 1 else { return }
        let widthBucket = Self.widthBucket(for: width)
        guard lastMarkdownWidthBucket != widthBucket else { return }
        let hadPreviousWidth = lastMarkdownWidthBucket != nil
        cancelPendingMarkdownPreparation()
        lastMarkdownWidthBucket = widthBucket
        if hadPreviousWidth {
            preparedContentCache.removeAllObjects()
            prepareVisibleMarkdown(width: width)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        cancelPendingMarkdownPreparation()
        preparedContentCache.removeAllObjects()
        prepareVisibleMarkdown(width: markdownContentWidth())
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSpeech()
        persistCurrentConversation()
        streamSession?.cancel()
        streamSession = nil
    }

    deinit {
        pendingPreparationTokens.values.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    private func setupHeader() {
        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        view.addSubview(stopButton)
        view.addSubview(historyButton)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.heightAnchor.constraint(equalToConstant: 44),

            stopButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stopButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stopButton.heightAnchor.constraint(equalToConstant: 44),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            historyButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            historyButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            historyButton.widthAnchor.constraint(equalToConstant: 40),
            historyButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func setupTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 140
        tableView.rowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .interactive
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(AIChatMessageCell.self, forCellReuseIdentifier: AIChatMessageCell.reuseIdentifier)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupInputArea() {
        inputContainer.backgroundColor = .systemGray6
        inputContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputContainer)

        inputTextView.font = .systemFont(ofSize: 16)
        inputTextView.layer.cornerRadius = 8
        inputTextView.layer.borderWidth = 1
        inputTextView.layer.borderColor = UIColor.systemGray4.cgColor
        inputTextView.backgroundColor = .systemBackground
        inputTextView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        inputTextView.delegate = self
        inputTextView.translatesAutoresizingMaskIntoConstraints = false

        imageButton.setImage(UIImage(systemName: "photo.on.rectangle.angled"), for: .normal)
        imageButton.accessibilityLabel = "选择图片"
        imageButton.addTarget(self, action: #selector(selectImagesTapped), for: .touchUpInside)
        imageButton.translatesAutoresizingMaskIntoConstraints = false

        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        imageStripView.translatesAutoresizingMaskIntoConstraints = false
        imageStripView.onRemove = { [weak self] id in
            self?.removeSelectedImage(id: id)
        }

        inputContainer.addSubview(imageStripView)
        inputContainer.addSubview(imageButton)
        inputContainer.addSubview(inputTextView)
        inputContainer.addSubview(sendButton)

        inputBottomConstraint = inputContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)

        imageStripHeightConstraint = imageStripView.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            inputContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBottomConstraint!,

            imageStripView.topAnchor.constraint(equalTo: inputContainer.topAnchor),
            imageStripView.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 12),
            imageStripView.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -12),
            imageStripHeightConstraint!,

            imageButton.topAnchor.constraint(equalTo: imageStripView.bottomAnchor, constant: 8),
            imageButton.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 8),
            imageButton.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: -8),
            imageButton.widthAnchor.constraint(equalToConstant: 40),

            inputTextView.topAnchor.constraint(equalTo: imageStripView.bottomAnchor, constant: 8),
            inputTextView.leadingAnchor.constraint(equalTo: imageButton.trailingAnchor, constant: 4),
            inputTextView.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: -8),
            inputTextView.heightAnchor.constraint(equalToConstant: 40),

            sendButton.leadingAnchor.constraint(equalTo: inputTextView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: inputTextView.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 52)
        ])

        tableView.bottomAnchor.constraint(equalTo: inputContainer.topAnchor).isActive = true
        updateComposerState(animated: false)
    }

    private func applySelectedTheme() {
        guard let theme = selectedTheme else { return }

        view.backgroundColor = theme.canvasColor
        tableView.backgroundColor = theme.canvasColor
        tableView.indicatorStyle = theme.interfaceStyle == .dark ? .white : .black
        titleLabel.backgroundColor = theme.canvasColor
        titleLabel.textColor = theme.primaryTextColor

        [closeButton, stopButton, historyButton, imageButton, sendButton].forEach {
            $0.tintColor = theme.accentColor
        }

        inputContainer.backgroundColor = theme.panelColor
        inputTextView.backgroundColor = theme.blockColor
        inputTextView.textColor = theme.primaryTextColor
        inputTextView.tintColor = theme.accentColor
        inputTextView.layer.borderColor = theme.borderColor.cgColor
    }

    private func loadConversationHistory() {
        do {
            _ = try conversationStore.load()
        } catch {
            showTransientAlert(title: "历史记录读取失败", message: error.localizedDescription)
        }
    }

    @objc private func historyTapped() {
        guard !isRequesting, streamingAssistantIndex == nil else {
            showTransientAlert(title: "正在回复", message: "请先停止或等待当前回复完成后再切换会话。")
            return
        }
        persistCurrentConversation()
        let historyConversations = conversationStore.conversations.filter { $0.id != currentConversation.id }
        let availableIDs = Set(historyConversations.map(\.id))
        selectedHistoryConversationIDs.formIntersection(availableIDs)
        let history = AIChatHistoryViewController(
            conversations: historyConversations,
            selectedIDs: selectedHistoryConversationIDs
        )
        history.onReferenceSelection = { [weak self] ids in
            self?.selectedHistoryConversationIDs = ids
            self?.updateHistoryButtonState()
        }
        history.onOpenConversation = { [weak self] conversation in
            self?.openConversation(conversation)
        }
        history.onDeleteConversation = { [weak self] id in
            guard let self else { return }
            do {
                try self.conversationStore.delete(id: id)
                self.selectedHistoryConversationIDs.remove(id)
                if self.currentConversation.id == id {
                    self.startNewConversation()
                }
                self.updateHistoryButtonState()
            } catch {
                self.showTransientAlert(title: "删除失败", message: error.localizedDescription)
            }
        }
        history.onCreateConversation = { [weak self] in
            self?.startNewConversation()
        }
        present(UINavigationController(rootViewController: history), animated: true)
    }

    private func openConversation(_ conversation: AIChatConversation) {
        cancelPendingMarkdownPreparation()
        stopSpeech()
        currentConversation = conversation
        messages = conversation.messages.map {
            var message = $0
            message.isPlaceholder = false
            message.isStreaming = false
            return message
        }
        pendingAssistantIndex = nil
        streamingAssistantIndex = nil
        clearSelectedImages()
        tableView.reloadData()
        tableView.layoutIfNeeded()
        scrollToBottom(animated: false)
        titleLabel.text = "AI 对话"
    }

    private func startNewConversation() {
        cancelPendingMarkdownPreparation()
        stopSpeech()
        currentConversation = AIChatConversation(title: "新对话")
        messages = []
        pendingAssistantIndex = nil
        streamingAssistantIndex = nil
        selectedHistoryConversationIDs.removeAll()
        clearSelectedImages()
        tableView.reloadData()
        titleLabel.text = "AI 对话"
        updateHistoryButtonState()
    }

    private static func widthBucket(for width: CGFloat) -> Int {
        Int(width.rounded())
    }

    private func markdownContentWidth() -> CGFloat {
        let tableWidth = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
        return max(1, tableWidth * 0.78 - 36)
    }

    private func cachedPreparedContent(
        for message: AIChatMessage,
        width: CGFloat
    ) -> MarkdownPreparedContent? {
        let markdown = message.renderedMarkdown
        let widthBucket = Self.widthBucket(for: width)
        guard let cached = preparedContentCache.object(forKey: message.id as NSUUID),
              cached.widthBucket == widthBucket,
              cached.markdown == markdown else {
            return nil
        }
        return cached.content
    }

    private func shouldPrepareMarkdown(for message: AIChatMessage) -> Bool {
        !message.isStreaming
            && !message.isPlaceholder
            && message.renderedMarkdown.utf8.count >= 1_200
    }

    private func prepareVisibleMarkdown(width: CGFloat) {
        guard width > 1 else { return }
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard messages.indices.contains(indexPath.row) else { continue }
            prepareMarkdownIfNeeded(for: messages[indexPath.row], width: width)
        }
    }

    private func prepareMarkdownIfNeeded(
        for message: AIChatMessage,
        width: CGFloat
    ) {
        guard width > 1, shouldPrepareMarkdown(for: message) else { return }
        guard cachedPreparedContent(for: message, width: width) == nil else { return }

        let markdown = message.renderedMarkdown
        let widthBucket = Self.widthBucket(for: width)
        let key = AIChatPreparationKey(
            messageID: message.id,
            markdown: markdown,
            widthBucket: widthBucket
        )
        guard pendingPreparationKeys.insert(key).inserted else { return }

        let obsoleteKeys = pendingPreparationKeys.filter {
            $0.messageID == message.id && $0 != key
        }
        for obsoleteKey in obsoleteKeys {
            pendingPreparationTokens[obsoleteKey]?.cancel()
            pendingPreparationTokens.removeValue(forKey: obsoleteKey)
            pendingPreparationKeys.remove(obsoleteKey)
        }

        let token = AIChatPreparationToken()
        pendingPreparationTokens[key] = token

        let configuration = AIChatMessageCell.markdownConfiguration(theme: selectedTheme)
        markdownPreparationQueue.async { [weak self] in
            guard !token.isCancelled else { return }
            let renderer = MarkdownRenderer(configuration: configuration, containerWidth: width)
            let prepared = renderer.prepare(markdown)
            guard !token.isCancelled else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.pendingPreparationTokens[key] === token else { return }
                self.pendingPreparationTokens.removeValue(forKey: key)
                self.pendingPreparationKeys.remove(key)
                guard Self.widthBucket(for: self.markdownContentWidth()) == widthBucket else { return }
                guard let row = self.messages.firstIndex(where: { $0.id == message.id }),
                      self.messages[row].renderedMarkdown == markdown,
                      !self.messages[row].isStreaming else {
                    return
                }

                self.preparedContentCache.setObject(
                    AIChatPreparedContentBox(
                        markdown: markdown,
                        widthBucket: widthBucket,
                        content: prepared
                    ),
                    forKey: message.id as NSUUID,
                    cost: max(
                        1,
                        markdown.utf8.count * 4
                            + prepared.elements.count * 512
                            + prepared.imageAttachments.count * 64 * 1024
                    )
                )

                let indexPath = IndexPath(row: row, section: 0)
                guard let cell = self.tableView.cellForRow(at: indexPath) as? AIChatMessageCell,
                      cell.representedMessageID == message.id else {
                    return
                }
                print("[AIChat][Prepare] completion row=\(row)")
                cell.configure(
                    with: self.messages[row],
                    preparedContent: prepared,
                    theme: self.selectedTheme
                )
                self.scheduleRowHeightUpdate(followStreaming: false)
            }
        }
    }

    private func cancelPendingMarkdownPreparation() {
        pendingPreparationTokens.values.forEach { $0.cancel() }
        pendingPreparationTokens.removeAll()
        pendingPreparationKeys.removeAll()
    }

    private func cancelMarkdownPreparation(for messageIDs: Set<UUID>) {
        let keys = pendingPreparationKeys.filter { messageIDs.contains($0.messageID) }
        for key in keys {
            pendingPreparationTokens[key]?.cancel()
            pendingPreparationTokens.removeValue(forKey: key)
            pendingPreparationKeys.remove(key)
        }
    }

    private func persistCurrentConversation() {
        let stableMessages = messages.filter {
            !$0.isPlaceholder && !$0.isStreaming && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard stableMessages.contains(where: { $0.role == .user }) else { return }
        currentConversation.messages = stableMessages
        if currentConversation.title == "新对话",
           let firstQuestion = stableMessages.first(where: { $0.role == .user })?.content {
            let title = firstQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            currentConversation.title = title.isEmpty ? "新对话" : String(title.prefix(30))
        }
        currentConversation.updatedAt = Date()
        do {
            try conversationStore.save(currentConversation)
        } catch {
            print("[AIChat][History] 保存失败: \(error.localizedDescription)")
        }
    }

    private func updateHistoryButtonState() {
        if let selectedTheme {
            historyButton.tintColor = selectedHistoryConversationIDs.isEmpty
                ? selectedTheme.secondaryTextColor
                : selectedTheme.accentColor
        } else {
            historyButton.tintColor = selectedHistoryConversationIDs.isEmpty ? .systemBlue : .systemOrange
        }
        historyButton.accessibilityValue = selectedHistoryConversationIDs.isEmpty
            ? "未引用历史会话"
            : "已引用 \(selectedHistoryConversationIDs.count) 个历史会话"
    }

    @objc private func selectImagesTapped() {
        guard !isRequesting else { return }
        let remaining = 9 - selectedImages.count
        guard remaining > 0 else {
            showTransientAlert(title: "最多选择 9 张图片", message: "请先移除部分图片后再添加。")
            return
        }
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = remaining
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func addSelectedImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        var newItems: [AIChatSelectedImage] = []
        for image in images {
            newItems.append(AIChatSelectedImage(image: image))
        }
        selectedImages.append(contentsOf: newItems)
        updateComposerState(animated: true)
        let items = newItems.map { AIChatOCRRequestItem(id: $0.id, image: $0.image) }
        let generation = ocrGeneration
        ocrService.recognize(items: items, generation: generation) { [weak self] resultGeneration, results in
            guard let self, resultGeneration == self.ocrGeneration else { return }
            for result in results {
                guard let itemIndex = self.selectedImages.firstIndex(where: { $0.id == result.id }) else { continue }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.selectedImages[itemIndex].recognizedText = text
                if let error = result.error {
                    self.selectedImages[itemIndex].state = .failed
                    self.selectedImages[itemIndex].errorDescription = error.localizedDescription
                } else if text.isEmpty {
                    self.selectedImages[itemIndex].state = .failed
                    self.selectedImages[itemIndex].errorDescription = "未识别到文字"
                } else {
                    self.selectedImages[itemIndex].state = .ready
                    self.selectedImages[itemIndex].errorDescription = nil
                }
            }
            self.updateComposerState(animated: false)
        }
    }

    private func removeSelectedImage(id: UUID) {
        selectedImages.removeAll { $0.id == id }
        updateComposerState(animated: true)
    }

    private func clearSelectedImages() {
        ocrGeneration &+= 1
        ocrService.cancelAll()
        selectedImages.removeAll()
        updateComposerState(animated: false)
    }

    private var recognizedAttachments: [AIChatImageAttachment] {
        selectedImages.enumerated().map { index, item in
            let state: AIChatImageAttachment.RecognitionState
            switch item.state {
            case .processing: state = .recognizing
            case .ready: state = .completed
            case .failed: state = .failed
            }
            return AIChatImageAttachment(
                id: item.id,
                displayName: "图片 \(index + 1)",
                ocrText: item.recognizedText,
                recognitionState: state,
                errorDescription: item.errorDescription
            )
        }
    }

    private func updateComposerState(animated: Bool) {
        imageStripView.update(items: selectedImages)
        imageStripHeightConstraint?.constant = selectedImages.isEmpty ? 0 : 76
        let isRecognizing = selectedImages.contains { $0.state == .processing }
        let hasImageText = selectedImages.contains {
            $0.state == .ready && !$0.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasInputText = !inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isBusy = isRequesting || streamingAssistantIndex != nil
        sendButton.isEnabled = !isBusy && !isRecognizing && (hasInputText || hasImageText)
        imageButton.isEnabled = !isBusy
        let updates = { self.view.layoutIfNeeded() }
        if animated {
            UIView.animate(withDuration: 0.2, animations: updates)
        } else {
            updates()
        }
    }

    private func showTransientAlert(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    // MARK: - 复制 / 朗读

    private func copyText(for message: AIChatMessage) -> String {
        message.renderedMarkdown
    }

    private func copyMessage(_ message: AIChatMessage) {
        let text = copyText(for: message)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UIPasteboard.general.string = text
        guard let row = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? AIChatMessageCell
        cell?.showCopyConfirmation()
    }

    private func toggleSpeech(for message: AIChatMessage) {
        if speakingMessageID == message.id {
            stopSpeech()
        } else {
            startSpeech(for: message)
        }
    }

    private func startSpeech(for message: AIChatMessage) {
        stopSpeech()
        let text = AIChatSpeechTextExtractor.plainText(from: copyText(for: message))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showTransientAlert(title: "无法朗读", message: "没有可朗读的文字内容。")
            return
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingMessageID = message.id
        refreshSpeechButtons()
        speechSynthesizer.speak(utterance)
    }

    private func stopSpeech() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        speakingMessageID = nil
        refreshSpeechButtons()
    }

    private func refreshSpeechButtons() {
        for cell in tableView.visibleCells.compactMap({ $0 as? AIChatMessageCell }) {
            cell.setSpeaking(cell.representedMessageID == speakingMessageID)
        }
    }

    private func loadConfig() {
        switch AIChatConfigLoader.load() {
        case .success(let config):
            self.config = config
        case .failure:
            self.config = nil
        }
    }

    private func registerKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func handleKeyboardChange(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let endFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
            let curveRaw = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }

        let endFrameInView = view.convert(endFrame, from: view.window)
        let overlap = max(0, view.bounds.maxY - endFrameInView.origin.y)
        let bottomInset = max(0, overlap - view.safeAreaInsets.bottom)

        inputBottomConstraint?.constant = -bottomInset

        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
            self.scrollToBottom(animated: false)
        }
    }

    @objc private func closeTapped() {
        cancelActiveRequest(showMessage: false)
        streamSession?.cancel()
        streamSession = nil
        dismiss(animated: true)
    }

    @objc private func stopTapped() {
        cancelActiveRequest(showMessage: true)
    }

    @objc private func sendTapped() {
        let text = inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = recognizedAttachments.filter { $0.recognitionState == .completed && !$0.ocrText.isEmpty }
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard !isRequesting else { return }

        view.endEditing(true)

        let willStream = config?.stream ?? false
        if willStream {
            streamNormalizer.reset()
        }
        let visibleQuestion = text.isEmpty ? "请根据图片中识别到的文字回答。" : text
        appendMessage(role: .user, content: visibleQuestion, attachments: attachments)
        inputTextView.text = ""
        clearSelectedImages()

        let placeholderIndex = appendMessage(
            role: .assistant,
            content: willStream ? "" : "…",
            isPlaceholder: !willStream,
            isStreaming: willStream
        )
        pendingAssistantIndex = placeholderIndex
        streamingAssistantIndex = willStream ? placeholderIndex : nil
        autoScrollGeneration += 1
        prepareStreamingCellIfNeeded()
        persistCurrentConversation()
        requestAssistantReply()
    }

    private func requestAssistantReply() {
        receivedText = ""
        guard let config else {
            updatePendingMessage(with: "未找到本地配置，请先创建 Config.local.json。")
            return
        }

        guard config.endpointURL != nil else {
            updatePendingMessage(with: "配置中的 host/path 无效。")
            return
        }

        activeRequestMessages = buildRequestMessages(config: config)
        activeToolExchange = []
        toolCallRounds = 0
        isHandlingToolCalls = false
        chatTurnGeneration += 1
        performChatTurn()
    }

    private func buildRequestMessages(config: AIChatConfig) -> [OpenAIChatRequest.Message] {
        var requestMessages: [OpenAIChatRequest.Message] = []
        for message in messages where !message.isPlaceholder && !message.isStreaming {
            if message.role == .user {
                let content = AIChatRequestContextBuilder.combinedQuestion(
                    userText: message.content,
                    attachments: message.attachments
                )
                requestMessages.append(OpenAIChatRequest.Message(role: "user", content: content))
            } else {
                if let toolContext = message.toolContext, !toolContext.isEmpty {
                    requestMessages.append(contentsOf: toolContext.map { $0.toRequestMessage() })
                }
                requestMessages.append(OpenAIChatRequest.Message(role: "assistant", content: message.content))
            }
        }

        if let latestUser = messages.last(where: { $0.role == .user }) {
            let query = AIChatRequestContextBuilder.combinedQuestion(
                userText: latestUser.content,
                attachments: latestUser.attachments
            )
            let selectedConversations = conversationStore.conversations.filter {
                selectedHistoryConversationIDs.contains($0.id) && $0.id != currentConversation.id
            }
            let relevantPairs = AIChatHistoryRetriever.relevantPairs(for: query, in: selectedConversations)
            if let historyContext = AIChatRequestContextBuilder.historyContext(from: relevantPairs) {
                requestMessages.insert(OpenAIChatRequest.Message(role: "system", content: historyContext), at: 0)
            }
        }

        if let systemPrompt = config.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty {
            requestMessages.insert(OpenAIChatRequest.Message(role: "system", content: systemPrompt), at: 0)
        }

        return requestMessages
    }

    private func performChatTurn(forceNoTools: Bool = false) {
        guard let config else {
            updatePendingMessage(with: "未找到本地配置，请先创建 Config.local.json。")
            return
        }
        guard let url = config.endpointURL else {
            updatePendingMessage(with: "配置中的 host/path 无效。")
            return
        }

        isHandlingToolCalls = false
        let shouldStream = config.stream ?? false
        let payload = OpenAIChatRequest(
            model: config.model,
            messages: activeRequestMessages,
            temperature: config.temperature,
            stream: shouldStream,
            tools: forceNoTools ? nil : [Self.webSearchTool],
            thinking: config.thinking.map { OpenAIChatRequest.Thinking(type: $0.type) },
            reasoningEffort: config.reasoningEffort
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutSeconds ?? 30
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        if shouldStream {
            request.addValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            updatePendingMessage(with: "请求构建失败：无法编码请求体。")
            return
        }

        isRequesting = true
        updateComposerState(animated: false)

        if shouldStream {
            startStreamRequest(request)
        } else {
            startNonStreamRequest(request)
        }
    }

    private func startNonStreamRequest(_ request: URLRequest) {
        var taskIdentifier = 0
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.activeTask?.taskIdentifier == taskIdentifier else { return }
                self.activeTask = nil
                self.handleResponse(data: data, response: response, error: error)
            }
        }
        taskIdentifier = task.taskIdentifier
        activeTask = task
        task.resume()
    }

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?) {
        if let error = error {
            isRequesting = false
            updateComposerState(animated: false)
            updatePendingMessage(with: "请求失败：\(error.localizedDescription)")
            return
        }

        guard let data = data else {
            isRequesting = false
            updateComposerState(animated: false)
            updatePendingMessage(with: "请求失败：响应为空。")
            return
        }

        do {
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)

            if let toolCalls = decoded.choices?.first?.message?.toolCalls, !toolCalls.isEmpty {
                isRequesting = true
                updateComposerState(animated: false)
                let reasoningContent = decoded.choices?.first?.message?.reasoningContent ?? ""
                handleToolCalls(
                    toolCalls.map {
                        WebSearchToolCall(
                            id: $0.id ?? "",
                            name: $0.function?.name ?? "",
                            arguments: $0.function?.arguments ?? "{}"
                        )
                    },
                    reasoningContent: reasoningContent
                )
                return
            }

            if let message = decoded.choices?.first?.message?.content, !message.isEmpty {
                logServerText(message, category: "response", limit: responseLogLimit)
                let normalized = StreamMarkdownNormalizer().normalizeFullText(message)
                isRequesting = false
                updateComposerState(animated: false)
                updatePendingMessage(with: normalized, toolContext: activeToolExchange)
                return
            }

            if let errorMessage = decoded.error?.message {
                isRequesting = false
                updateComposerState(animated: false)
                updatePendingMessage(with: "服务错误：\(errorMessage)")
                return
            }

            isRequesting = false
            updateComposerState(animated: false)
            updatePendingMessage(with: "响应解析失败：内容为空。")
        } catch {
            isRequesting = false
            updateComposerState(animated: false)
            updatePendingMessage(with: "响应解析失败：\(error.localizedDescription)")
        }
    }

    private func handleToolCalls(_ calls: [WebSearchToolCall], reasoningContent: String = "") {
        guard toolCallRounds < maxToolCallRounds else {
            print("[AIChat][ToolCalls] max rounds reached, forcing final answer")
            // 搜索预算用尽：追加指令，强制模型基于已收集的信息直接作答
            activeRequestMessages.append(OpenAIChatRequest.Message(
                role: "user",
                content: "请基于上面的搜索结果和你的已有知识，直接给出最终、完整的回答，不要再调用搜索工具。"
            ))
            DispatchQueue.main.async { [weak self] in
                self?.performChatTurn(forceNoTools: true)
            }
            return
        }
        toolCallRounds += 1
        print("[AIChat][ToolCalls] round=\(toolCallRounds)/\(maxToolCallRounds) calls=\(calls.count)")
        for call in calls {
            print("[AIChat][ToolCalls]   name=\(call.name) args=\(call.arguments)")
        }

        // 1. 把模型请求的 tool_calls 追加到上下文
        activeRequestMessages.append(OpenAIChatRequest.Message(
            role: "assistant",
            content: nil,
            reasoningContent: reasoningContent.isEmpty ? nil : reasoningContent,
            toolCalls: calls.map {
                OpenAIChatRequest.Message.ToolCall(
                    id: $0.id,
                    type: "function",
                    function: OpenAIChatRequest.Message.ToolCall.FunctionCall(name: $0.name, arguments: $0.arguments)
                )
            }
        ))
        activeToolExchange.append(AIChatToolContextMessage(
            role: "assistant",
            content: nil,
            reasoningContent: reasoningContent.isEmpty ? nil : reasoningContent,
            toolCallID: nil,
            toolCalls: calls.map {
                AIChatToolContextMessage.AIChatToolCall(id: $0.id, type: "function", name: $0.name, arguments: $0.arguments)
            }
        ))

        // 2. 真正执行 web_search
        let generation = chatTurnGeneration
        let provider = config?.searchProvider
        let apiKey = config?.searchAPIKey
        let searches = calls.map { call -> (call: WebSearchToolCall, query: String) in
            (call, parseSearchQuery(from: call.arguments))
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [String: String] = [:] // tool_call_id -> 结果文本
        for item in searches {
            group.enter()
            WebSearchService.search(query: item.query, provider: provider, apiKey: apiKey) { result in
                let text: String
                switch result {
                case .success(let value):
                    print("[AIChat][WebSearch] success query=\"\(item.query)\" chars=\(value.count)")
                    text = value.isEmpty ? WebSearchService.unavailableMessage : value
                case .failure(let error):
                    print("[AIChat][WebSearch] failed query=\"\(item.query)\" error=\(error.localizedDescription)")
                    text = WebSearchService.unavailableMessage
                }
                lock.lock()
                results[item.call.id] = text
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, self.chatTurnGeneration == generation else { return }
            print("[AIChat][ToolCalls] searches finished, continue turn")

            // 3. 把搜索结果以 role=tool 形式回传
            for call in calls {
                let content: String
                if call.name == "web_search" {
                    content = results[call.id] ?? WebSearchService.unavailableMessage
                } else {
                    content = "不支持的函数调用：\(call.name)"
                }
                self.activeRequestMessages.append(OpenAIChatRequest.Message(
                    role: "tool",
                    content: content,
                    toolCallID: call.id
                ))
                self.activeToolExchange.append(AIChatToolContextMessage(
                    role: "tool",
                    content: content,
                    reasoningContent: nil,
                    toolCallID: call.id,
                    toolCalls: nil
                ))
            }

            // 4. 继续请求模型生成最终答案
            self.performChatTurn()
        }
    }

    private func parseSearchQuery(from argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return argumentsJSON
        }
        return (object["query"] as? String) ?? argumentsJSON
    }

    private func startStreamRequest(_ request: URLRequest) {
        streamNormalizer.reset()
        streamSession?.cancel()
        streamSession = AIChatStreamSession(
            request: request,
            onDelta: { [weak self] delta in
                DispatchQueue.main.async {
                    self?.handleStreamDelta(delta)
                }
            },
            onToolCalls: { [weak self] calls, reasoningContent in
                DispatchQueue.main.async {
                    self?.handleStreamToolCalls(calls, reasoningContent: reasoningContent)
                }
            },
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    self?.finishStream()
                }
            },
            onError: { [weak self] message in
                DispatchQueue.main.async {
                    self?.failStream(message: message)
                }
            }
        )
        streamSession?.start()
    }

    private func handleStreamDelta(_ delta: String) {
        guard let index = streamingAssistantIndex, messages.indices.contains(index) else { return }
        let normalizedDelta = streamNormalizer.normalizeDelta(delta)
        messages[index].content.append(normalizedDelta)
        logStreamDelta(delta)

        if let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? AIChatMessageCell {
            if cell.isStreamingActive {
                cell.appendStreamData(normalizedDelta)
            } else {
                cell.startStreaming(withInitial: messages[index].content)
            }
        } else {
            // 离屏时只更新数据源。Cell 再次出现时由 cellForRowAt 使用累计内容
            // 恢复真流式，避免每个 delta 都触发复用和一次普通全文渲染。
        }
    }

    private func handleStreamToolCalls(_ calls: [StreamedToolCall], reasoningContent: String) {
        isHandlingToolCalls = true
        handleToolCalls(
            calls.map {
                WebSearchToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
            },
            reasoningContent: reasoningContent
        )
    }

    private func finishStream() {
        if isHandlingToolCalls { return }
        print("[AIChat][Stream][Complete] Total received chars: \(receivedText.count)")
        isRequesting = false
        updateComposerState(animated: false)

        guard let index = streamingAssistantIndex, messages.indices.contains(index) else { return }
        let remaining = streamNormalizer.flush()
        if !remaining.isEmpty {
            messages[index].content.append(remaining)
        }
        messages[index].content = StreamMarkdownNormalizer().normalizeFullText(messages[index].content)
        let indexPath = IndexPath(row: index, section: 0)
        if let cell = tableView.cellForRow(at: indexPath) as? AIChatMessageCell {
            // Normalizer 可能还缓存了尾部字符，必须先交给 StreamBuffer，再结束网络输入。
            if !remaining.isEmpty {
                cell.appendStreamData(remaining)
            }
            // 网络接收完成不等于打字机播放完成。保持页面流式状态和自动跟随，
            // 直到 MarkdownView 的 TypewriterEngine 队列真正播放完毕。
            cell.endStreaming { [weak self, weak cell] in
                guard let self,
                      self.messages.indices.contains(index),
                      self.streamingAssistantIndex == index else { return }
                self.messages[index].isStreaming = false
                if !self.activeToolExchange.isEmpty {
                    self.messages[index].toolContext = self.activeToolExchange
                }
                cell?.setStreamingAppearanceEnabled(false)
                self.streamingAssistantIndex = nil
                self.autoScrollGeneration += 1
                self.scheduleRowHeightUpdate(followStreaming: false)
                self.persistCurrentConversation()
                self.updateComposerState(animated: false)
            }
        } else {
            messages[index].isStreaming = false
            if !activeToolExchange.isEmpty {
                messages[index].toolContext = activeToolExchange
            }
            tableView.reloadRows(at: [indexPath], with: .fade)
            streamingAssistantIndex = nil
            autoScrollGeneration += 1
            persistCurrentConversation()
            updateComposerState(animated: false)
        }
    }

    private func failStream(message: String) {
        isHandlingToolCalls = false
        activeToolExchange = []
        isRequesting = false
        updateComposerState(animated: false)
        streamNormalizer.reset()
        if let index = streamingAssistantIndex,
           let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? AIChatMessageCell {
            cell.endStreaming()
        }
        updatePendingMessage(with: "流式请求失败：\(message)")
        streamingAssistantIndex = nil
        persistCurrentConversation()
        updateComposerState(animated: false)
    }

    private func cancelActiveRequest(showMessage: Bool) {
        isHandlingToolCalls = false
        activeToolExchange = []
        chatTurnGeneration += 1
        streamSession?.cancel()
        streamSession = nil
        streamNormalizer.reset()

        if let task = activeTask {
            task.cancel()
            activeTask = nil
        }

        if let index = streamingAssistantIndex,
           let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? AIChatMessageCell {
            cell.endStreaming()
        }

        if showMessage {
            updatePendingMessage(with: "请求已取消。")
        }

        isRequesting = false
        updateComposerState(animated: false)
        pendingAssistantIndex = nil
        streamingAssistantIndex = nil
        persistCurrentConversation()
        updateComposerState(animated: false)
    }

    private func logServerText(_ text: String, category: String, limit: Int?) {
        let normalized = text.replacingOccurrences(of: "\n", with: "\\n")
        let prefix = "[AIChat][Server][\(category)]"
        if let limit, normalized.count > limit {
            let snippet = String(normalized.prefix(limit))
            print("\(prefix) \(snippet) ...(total \(normalized.count) chars)")
        } else {
            print("\(prefix) \(normalized)")
        }
    }

    private func logStreamDelta(_ delta: String) {
        self.receivedText.append(delta)
        logServerText(delta, category: "stream", limit: nil)
    }

    @discardableResult
    private func appendMessage(
        role: ChatRole,
        content: String,
        isPlaceholder: Bool = false,
        isStreaming: Bool = false,
        attachments: [AIChatImageAttachment] = []
    ) -> Int {
        let message = AIChatMessage(
            role: role,
            content: content,
            isPlaceholder: isPlaceholder,
            isStreaming: isStreaming,
            attachments: attachments
        )
        messages.append(message)
        let indexPath = IndexPath(row: messages.count - 1, section: 0)
        tableView.insertRows(at: [indexPath], with: .fade)
        scrollToBottom(animated: true)
        return indexPath.row
    }

    private func updatePendingMessage(with content: String, toolContext: [AIChatToolContextMessage]? = nil) {
        guard let index = pendingAssistantIndex, messages.indices.contains(index) else { return }
        messages[index].content = content
        messages[index].isPlaceholder = false
        messages[index].isStreaming = false
        if let toolContext, !toolContext.isEmpty {
            messages[index].toolContext = toolContext
        }
        let indexPath = IndexPath(row: index, section: 0)
        tableView.reloadRows(at: [indexPath], with: .fade)
        scrollToBottom(animated: true)
        persistCurrentConversation()
    }

    private func scrollToBottom(animated: Bool) {
        // 用户正在交互时不自动滚动，避免打断用户浏览
        guard !isUserInteracting else { return }
        guard messages.count > 0 else { return }
        let indexPath = IndexPath(row: messages.count - 1, section: 0)
        tableView.scrollToRow(at: indexPath, at: .bottom, animated: animated)
    }

    private func prepareStreamingCellIfNeeded() {
        guard let index = streamingAssistantIndex else { return }
        tableView.layoutIfNeeded()
        if let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? AIChatMessageCell {
            cell.startStreaming(withInitial: messages[index].content)
        }
    }

    private func showConfigAlert() {
        let message = """
        未找到 Config.local.json。

        请在本地创建该文件并加入 Xcode Target（不提交到仓库），
        或复制到 App Documents 目录。
        参考：CocoapodsMDExample/CocoapodsMDExample/Config.local.json.example
        """
        let alert = UIAlertController(title: "配置缺失", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }
}

extension AIChatViewController: UITableViewDataSource, UITableViewDelegate, UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: AIChatMessageCell.reuseIdentifier,
            for: indexPath
        ) as? AIChatMessageCell else {
            return UITableViewCell(style: .default, reuseIdentifier: "fallback")
        }
        let message = messages[indexPath.row]
        cell.onHeightChange = { [weak self] in
            self?.scheduleRowHeightUpdate(followStreaming: message.isStreaming)
        }
        let messageID = message.id
        cell.onCopyTapped = { [weak self] in
            guard let self,
                  let row = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
            self.copyMessage(self.messages[row])
        }
        cell.onSpeakTapped = { [weak self] in
            guard let self,
                  let row = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
            self.toggleSpeech(for: self.messages[row])
        }
        cell.setSpeaking(speakingMessageID == messageID)
        let preparedContent = cachedPreparedContent(
            for: message,
            width: markdownContentWidth()
        )
        let needsPreparation = preparedContent == nil && shouldPrepareMarkdown(for: message)
        print("[AIChat][Cell] row=\(indexPath.row) role=\(message.role.rawValue) len=\(message.renderedMarkdown.utf8.count) prepared=\(preparedContent != nil) streaming=\(message.isStreaming)")
        cell.configure(
            with: message,
            preparedContent: preparedContent,
            showsPreparationPlaceholder: needsPreparation,
            theme: selectedTheme
        )
        if needsPreparation {
            prepareMarkdownIfNeeded(for: message, width: markdownContentWidth())
        }
        if message.isStreaming {
            cell.startStreaming(withInitial: message.content)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        let width = markdownContentWidth()
        guard width > 1 else { return }
        for indexPath in indexPaths {
            guard messages.indices.contains(indexPath.row) else { continue }
            prepareMarkdownIfNeeded(for: messages[indexPath.row], width: width)
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        let messageIDs = Set(indexPaths.compactMap { indexPath -> UUID? in
            guard tableView.cellForRow(at: indexPath) == nil,
                  messages.indices.contains(indexPath.row) else {
                return nil
            }
            return messages[indexPath.row].id
        })
        cancelMarkdownPreparation(for: messageIDs)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard messages.indices.contains(indexPath.row),
              tableView.indexPathsForVisibleRows?.contains(indexPath) != true else {
            return
        }
        cancelMarkdownPreparation(for: [messages[indexPath.row].id])
    }

    /// 合并同一主循环的高度变化，避免从 MarkdownView.layoutSubviews 同步重入 TableView 布局。
    private func scheduleRowHeightUpdate(followStreaming: Bool = true) {
        pendingStreamingFollow = pendingStreamingFollow || followStreaming

        if isApplyingRowHeightUpdate {
            // 首轮 batch 可能修正 TextKit 的实际宽度并产生一个新的有效高度，因此保留一次补刷。
            // 补刷自身引起的回调直接丢弃，把反馈链限制为最多两轮。
            if !isPostBatchRowHeightUpdate {
                needsPostBatchRowHeightUpdate = true
            }
            return
        }

        // 手指拖拽或 TableView 正在减速时不改变 contentSize，避免滚动条和手势争抢。
        // 高度本身已经写入 MarkdownView，手势结束后合并刷新一次即可。
        if isTableViewGestureActive {
            hasDeferredRowHeightUpdate = true
            return
        }

        guard !pendingRowHeightUpdate else { return }
        pendingRowHeightUpdate = true
        let generation = autoScrollGeneration

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if self.isTableViewGestureActive {
                self.pendingRowHeightUpdate = false
                self.hasDeferredRowHeightUpdate = true
                return
            }

            let shouldFollowStreaming = self.pendingStreamingFollow
            self.pendingStreamingFollow = false
            self.isApplyingRowHeightUpdate = true
            UIView.performWithoutAnimation {
                self.tableView.performBatchUpdates(nil) { [weak self] _ in
                    guard let self else { return }
                    self.isApplyingRowHeightUpdate = false
                    self.pendingRowHeightUpdate = false

                    if shouldFollowStreaming,
                       generation == self.autoScrollGeneration,
                       !self.isUserInteracting,
                       self.streamingAssistantIndex != nil {
                        self.scrollToBottom(animated: false)
                    }

                    if self.needsPostBatchRowHeightUpdate,
                       !self.isPostBatchRowHeightUpdate {
                        self.needsPostBatchRowHeightUpdate = false
                        self.isPostBatchRowHeightUpdate = true
                        self.scheduleRowHeightUpdate(followStreaming: false)
                    } else {
                        self.needsPostBatchRowHeightUpdate = false
                        self.isPostBatchRowHeightUpdate = false
                    }
                }
            }
        }
    }

    // MARK: - UIScrollViewDelegate（用户交互检测）

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // 用户开始拖拽，暂停自动滚动
        isTableViewGestureActive = true
        isUserInteracting = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            isTableViewGestureActive = false
            // 拖拽结束且没有惯性滚动，检查是否在底部
            checkIfAtBottomAndResumeAutoScroll(scrollView)
            flushDeferredRowHeightUpdateIfNeeded()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isTableViewGestureActive = false
        // 惯性滚动结束，检查是否在底部
        checkIfAtBottomAndResumeAutoScroll(scrollView)
        flushDeferredRowHeightUpdateIfNeeded()
    }

    private func flushDeferredRowHeightUpdateIfNeeded() {
        guard hasDeferredRowHeightUpdate else { return }
        hasDeferredRowHeightUpdate = false
        // pendingStreamingFollow 已保存拖动期间是否需要继续跟随；这里仅触发合并刷新。
        scheduleRowHeightUpdate(followStreaming: false)
    }

    private func checkIfAtBottomAndResumeAutoScroll(_ scrollView: UIScrollView) {
        // 判断是否滚动到底部（允许 20pt 误差）
        let offsetY = scrollView.contentOffset.y
        let contentHeight = scrollView.contentSize.height
        let frameHeight = scrollView.frame.height
        let bottomInset = scrollView.contentInset.bottom

        let isAtBottom = offsetY >= (contentHeight - frameHeight - bottomInset - 20)

        if isAtBottom {
            // 用户滚动到底部，恢复自动滚动
            isUserInteracting = false
        }
        // 如果用户没有滚动到底部，保持 isUserInteracting = true，不自动滚动
    }
}

extension AIChatViewController: UITextViewDelegate, PHPickerViewControllerDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updateComposerState(animated: false)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }

        let group = DispatchGroup()
        let lock = NSLock()
        var loadedImages: [Int: UIImage] = [:]
        for (index, result) in results.enumerated() {
            guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else { continue }
            group.enter()
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                if let image = object as? UIImage {
                    lock.lock()
                    loadedImages[index] = image
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let images = loadedImages.keys.sorted().compactMap { loadedImages[$0] }
            self?.addSelectedImages(images)
        }
    }
}

final class AIChatMessageCell: UITableViewCell {
    static let reuseIdentifier = "AIChatMessageCell"

    private let bubbleView = UIView()
    private let markdownView = MarkdownViewTextKit()
    private let preparationIndicator = UIActivityIndicatorView(style: .medium)
    private var alignConstraints: [NSLayoutConstraint] = []
    private var appliedThemeRawValue: Int?
    private var hasStartedStreaming = false
    private let typewriterCharsPerStep = 1

    private let footerView = UIView()
    private let copyButton = UIButton(type: .system)
    private let speakButton = UIButton(type: .system)
    private let footerStackView = UIStackView()
    private var footerTintColor: UIColor = .systemBlue
    private var isSpeaking = false

    static func markdownConfiguration(theme: MarkdownDemoTheme?) -> MarkdownConfiguration {
        var configuration = theme?.makeConfiguration() ?? MarkdownConfiguration.default
        configuration.typewriterTextMode = .append
        configuration.typewriterHeightUpdateInterval = 20
        configuration.streamMinModuleLength = 10
        configuration.streamingHapticFeedbackStyle = .medium
        configuration.latexAlignment = .left
        if theme == nil {
            configuration.latexBackgroundColor = .systemBlue.withAlphaComponent(0.1)
        }
        configuration.latexPadding = 16
        return configuration
    }

    var onHeightChange: (() -> Void)?
    var onCopyTapped: (() -> Void)?
    var onSpeakTapped: (() -> Void)?
    private(set) var representedMessageID: UUID?

    var isStreamingActive: Bool {
        hasStartedStreaming
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentView.backgroundColor = .clear

        bubbleView.layer.cornerRadius = 12
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubbleView)
        markdownView.configuration = Self.markdownConfiguration(theme: nil)
        markdownView.enableTypewriterEffect = false
        markdownView.translatesAutoresizingMaskIntoConstraints = false
        markdownView.onHeightChange = { [weak self] _ in
            self?.onHeightChange?()
        }
        bubbleView.addSubview(markdownView)

        footerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(footerView)

        footerStackView.axis = .horizontal
        footerStackView.alignment = .center
        footerStackView.spacing = 12
        footerStackView.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(footerStackView)
        footerStackView.addArrangedSubview(copyButton)
        footerStackView.addArrangedSubview(speakButton)
        configureCopyButton()
        configureSpeakButton()

        preparationIndicator.hidesWhenStopped = true
        preparationIndicator.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(preparationIndicator)

        let bubbleBottomConstraint = bubbleView.bottomAnchor.constraint(equalTo: footerView.topAnchor, constant: -4)

        let footerBottomConstraint = footerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        footerBottomConstraint.priority = .defaultHigh

        let aiLeading = bubbleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        let aiWidth = bubbleView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.78, constant: -16)
        aiWidth.priority = .required

        let userTrailing = bubbleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        let userWidth = bubbleView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.78, constant: -16)
        userWidth.priority = .required

        alignConstraints = [aiLeading, aiWidth, userTrailing, userWidth]

        NSLayoutConstraint.activate([
            bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            bubbleBottomConstraint,

            markdownView.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 10),
            markdownView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
            markdownView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -10),
            markdownView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -10),
            bubbleView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            preparationIndicator.centerXAnchor.constraint(equalTo: bubbleView.centerXAnchor),
            preparationIndicator.centerYAnchor.constraint(equalTo: bubbleView.centerYAnchor),

            footerView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor),
            footerBottomConstraint,
            footerView.heightAnchor.constraint(equalToConstant: 28),

            footerStackView.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
            footerStackView.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            footerStackView.leadingAnchor.constraint(greaterThanOrEqualTo: footerView.leadingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        print("[AIChat][Cell] prepareForReuse")
        hasStartedStreaming = false
        representedMessageID = nil
        preparationIndicator.stopAnimating()
        markdownView.isHidden = false
        onHeightChange = nil
        onCopyTapped = nil
        onSpeakTapped = nil
        isSpeaking = false
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        applyCopyButtonStyle()
        applySpeakButtonStyle()
        markdownView.resetForReuse()
    }

    func configure(
        with message: AIChatMessage,
        preparedContent: MarkdownPreparedContent? = nil,
        showsPreparationPlaceholder: Bool = false,
        theme: MarkdownDemoTheme? = nil
    ) {
        let isUser = message.role == .user
        if let theme, appliedThemeRawValue != theme.rawValue {
            markdownView.configuration = Self.markdownConfiguration(theme: theme)
            appliedThemeRawValue = theme.rawValue
        }
        apply(theme: theme, isUser: isUser)
        representedMessageID = message.id
        setFooterTintColor(theme?.accentColor ?? .systemBlue)
        markdownView.enableTypewriterEffect = message.isStreaming
        if !message.isStreaming {
            if let preparedContent {
                preparationIndicator.stopAnimating()
                markdownView.isHidden = false
                markdownView.setPreparedContent(preparedContent)
            } else if showsPreparationPlaceholder {
                markdownView.resetForReuse()
                markdownView.isHidden = true
                preparationIndicator.startAnimating()
            } else {
                preparationIndicator.stopAnimating()
                markdownView.isHidden = false
                markdownView.markdown = message.renderedMarkdown
            }
        } else {
            preparationIndicator.stopAnimating()
            markdownView.isHidden = false
        }

        if isUser {
            NSLayoutConstraint.deactivate([alignConstraints[0], alignConstraints[1]])
            NSLayoutConstraint.activate([alignConstraints[2], alignConstraints[3]])
        } else {
            NSLayoutConstraint.deactivate([alignConstraints[2], alignConstraints[3]])
            NSLayoutConstraint.activate([alignConstraints[0], alignConstraints[1]])
        }

        if isUser {
            bubbleView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner]
        } else {
            bubbleView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
    }

    private func apply(theme: MarkdownDemoTheme?, isUser: Bool) {
        guard let theme else {
            bubbleView.backgroundColor = isUser ? .systemGray5 : .systemGray6
            bubbleView.layer.borderWidth = 0
            return
        }

        backgroundColor = .clear
        contentView.backgroundColor = .clear
        markdownView.backgroundColor = .clear
        bubbleView.backgroundColor = isUser
            ? theme.accentColor.withAlphaComponent(theme.interfaceStyle == .dark ? 0.26 : 0.14)
            : theme.panelColor
        bubbleView.layer.borderWidth = 1
        bubbleView.layer.borderColor = (isUser ? theme.accentColor : theme.borderColor).cgColor
        preparationIndicator.color = theme.accentColor
    }

    // MARK: - Footer 操作按钮

    private func configureCopyButton() {
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        applyCopyButtonStyle()
    }

    private func configureSpeakButton() {
        speakButton.addTarget(self, action: #selector(speakTapped), for: .touchUpInside)
        applySpeakButtonStyle()
    }

    private func applyCopyButtonStyle() {
        var configuration = UIButton.Configuration.plain()
        configuration.title = "复制"
        configuration.image = UIImage(systemName: "doc.on.doc")
        configuration.imagePadding = 4
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        configuration.baseForegroundColor = footerTintColor
        copyButton.configuration = configuration
    }

    private func applySpeakButtonStyle() {
        var configuration = UIButton.Configuration.plain()
        configuration.title = isSpeaking ? "停止" : "朗读"
        configuration.image = UIImage(systemName: isSpeaking ? "stop.circle" : "speaker.wave.2")
        configuration.imagePadding = 4
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        configuration.baseForegroundColor = footerTintColor
        speakButton.configuration = configuration
    }

    func setFooterTintColor(_ color: UIColor) {
        guard footerTintColor != color else { return }
        footerTintColor = color
        applyCopyButtonStyle()
        applySpeakButtonStyle()
    }

    func setSpeaking(_ speaking: Bool) {
        guard isSpeaking != speaking else { return }
        isSpeaking = speaking
        applySpeakButtonStyle()
    }

    func showCopyConfirmation() {
        var configuration = copyButton.configuration ?? UIButton.Configuration.plain()
        configuration.title = "已复制"
        configuration.image = UIImage(systemName: "checkmark")
        copyButton.configuration = configuration
        perform(#selector(resetCopyButtonStyle), with: nil, afterDelay: 1.5)
    }

    @objc private func resetCopyButtonStyle() {
        applyCopyButtonStyle()
    }

    @objc private func copyTapped() {
        onCopyTapped?()
    }

    @objc private func speakTapped() {
        onSpeakTapped?()
    }

    func startStreaming(withInitial text: String) {
        guard !hasStartedStreaming else { return }
        hasStartedStreaming = true
        markdownView.enableTypewriterEffect = true
        markdownView.updateTypewriterSpeed(charsPerStep: typewriterCharsPerStep)
        markdownView.beginRealStreaming(autoScrollBottom: false)
        if !text.isEmpty {
            markdownView.appendStreamData(text)
        }
    }

    func appendStreamData(_ data: String) {
        if !hasStartedStreaming {
            startStreaming(withInitial: data)
            return
        }
        markdownView.appendStreamData(data)
    }

    func endStreaming(completion: (() -> Void)? = nil) {
        guard hasStartedStreaming else {
            completion?()
            return
        }
        markdownView.endRealStreaming { [weak self] in
            self?.hasStartedStreaming = false
            completion?()
        }
    }

    func setStreamingAppearanceEnabled(_ enabled: Bool) {
        markdownView.enableTypewriterEffect = enabled
    }
}

extension AIChatViewController: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.speakingMessageID = nil
            self?.refreshSpeechButtons()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.speakingMessageID = nil
            self?.refreshSpeechButtons()
        }
    }
}
