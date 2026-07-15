//
//  AIChatViewController.swift
//  CocoapodsMDExample
//
//  Created by 朱继超 on 12/20/25.
//

import UIKit
import MarkdownDisplayView

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct AIChatMessage: Codable {
    let role: ChatRole
    var content: String
    var isPlaceholder: Bool = false
    var isStreaming: Bool = false
}

private struct AIChatConfig: Decodable {
    let host: String
    let path: String
    let apiKey: String
    let model: String
    let systemPrompt: String?
    let temperature: Double?
    let stream: Bool?
    let timeoutSeconds: TimeInterval?

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
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
    let stream: Bool?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(stream, forKey: .stream)
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case stream
    }
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String?
            let content: String?
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
        }
        let delta: Delta?
        let finish_reason: String?
    }

    let choices: [Choice]?
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

private final class AIChatStreamSession: NSObject, URLSessionDataDelegate {
    private let request: URLRequest
    private let onDelta: (String) -> Void
    private let onComplete: () -> Void
    private let onError: (String) -> Void
    private var buffer = ""
    private var isFinished = false
    private var dataTask: URLSessionDataTask?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(request: URLRequest, onDelta: @escaping (String) -> Void, onComplete: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.request = request
        self.onDelta = onDelta
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
        if let decoded = try? JSONDecoder().decode(OpenAIStreamResponse.self, from: data),
           let content = decoded.choices?.first?.delta?.content,
           !content.isEmpty {
            onDelta(content)
        }
    }

    private func finishSuccessfully() {
        guard !isFinished else { return }
        isFinished = true
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

    /// 用户是否正在交互（拖拽滚动），用于暂停自动滚动
    private var isUserInteracting = false
    private var pendingRowHeightUpdate = false
    private var pendingStreamingFollow = false
    /// 每次开始/结束流式时递增，使已经排队的自动滚动任务立即失效。
    private var autoScrollGeneration = 0

    private let inputContainer = UIView()
    private let inputTextView = UITextView()
    private let sendButton = UIButton(type: .system)
    private var inputBottomConstraint: NSLayoutConstraint?

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("关闭", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
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
        view.backgroundColor = .systemBackground
        setupHeader()
        setupTableView()
        setupInputArea()
        loadConfig()
        registerKeyboardNotifications()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if config == nil {
            showConfigAlert()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        streamSession?.cancel()
        streamSession = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupHeader() {
        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        view.addSubview(stopButton)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.heightAnchor.constraint(equalToConstant: 44),

            stopButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stopButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stopButton.heightAnchor.constraint(equalToConstant: 44),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func setupTableView() {
        tableView.dataSource = self
        tableView.delegate = self
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
        inputTextView.translatesAutoresizingMaskIntoConstraints = false

        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        inputContainer.addSubview(inputTextView)
        inputContainer.addSubview(sendButton)

        inputBottomConstraint = inputContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)

        NSLayoutConstraint.activate([
            inputContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBottomConstraint!,

            inputTextView.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 8),
            inputTextView.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 12),
            inputTextView.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: -8),
            inputTextView.heightAnchor.constraint(equalToConstant: 40),

            sendButton.leadingAnchor.constraint(equalTo: inputTextView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: inputTextView.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 52)
        ])

        tableView.bottomAnchor.constraint(equalTo: inputContainer.topAnchor).isActive = true
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
        guard !text.isEmpty else { return }
        guard !isRequesting else { return }

        view.endEditing(true)

        let willStream = config?.stream ?? false
        if willStream {
            streamNormalizer.reset()
        }
        appendMessage(role: .user, content: text)
        inputTextView.text = ""

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
        requestAssistantReply()
    }

    private func requestAssistantReply() {
        guard let config else {
            updatePendingMessage(with: "未找到本地配置，请先创建 Config.local.json。")
            return
        }

        guard let url = config.endpointURL else {
            updatePendingMessage(with: "配置中的 host/path 无效。")
            return
        }

        var requestMessages = messages
            .filter { !$0.isPlaceholder }
            .map { OpenAIChatRequest.Message(role: $0.role.rawValue, content: $0.content) }

        if let systemPrompt = config.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty {
            requestMessages.insert(OpenAIChatRequest.Message(role: "system", content: systemPrompt), at: 0)
        }

        let shouldStream = config.stream ?? false
        let payload = OpenAIChatRequest(
            model: config.model,
            messages: requestMessages,
            temperature: config.temperature,
            stream: shouldStream
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
        sendButton.isEnabled = false

        if shouldStream {
            startStreamRequest(request)
        } else {
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
    }

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?) {
        defer {
            isRequesting = false
            sendButton.isEnabled = true
        }

        if let error = error {
            updatePendingMessage(with: "请求失败：\(error.localizedDescription)")
            return
        }

        guard let data = data else {
            updatePendingMessage(with: "请求失败：响应为空。")
            return
        }

        do {
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            if let message = decoded.choices?.first?.message?.content, !message.isEmpty {
                logServerText(message, category: "response", limit: responseLogLimit)
                let normalized = StreamMarkdownNormalizer().normalizeFullText(message)
                updatePendingMessage(with: normalized)
                return
            }

            if let errorMessage = decoded.error?.message {
                updatePendingMessage(with: "服务错误：\(errorMessage)")
                return
            }

            updatePendingMessage(with: "响应解析失败：内容为空。")
        } catch {
            updatePendingMessage(with: "响应解析失败：\(error.localizedDescription)")
        }
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

    private func finishStream() {
        print("[AIChat][Stream][Complete] Total received chars: \(receivedText)")
        isRequesting = false
        sendButton.isEnabled = true

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
                cell?.setStreamingAppearanceEnabled(false)
                self.streamingAssistantIndex = nil
                self.autoScrollGeneration += 1
                self.scheduleRowHeightUpdate(followStreaming: false)
            }
        } else {
            messages[index].isStreaming = false
            tableView.reloadRows(at: [indexPath], with: .fade)
            streamingAssistantIndex = nil
            autoScrollGeneration += 1
        }
    }

    private func failStream(message: String) {
        isRequesting = false
        sendButton.isEnabled = true
        streamNormalizer.reset()
        if let index = streamingAssistantIndex,
           let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? AIChatMessageCell {
            cell.endStreaming()
        }
        updatePendingMessage(with: "流式请求失败：\(message)")
        streamingAssistantIndex = nil
    }

    private func cancelActiveRequest(showMessage: Bool) {
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
        sendButton.isEnabled = true
        pendingAssistantIndex = nil
        streamingAssistantIndex = nil
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
    private func appendMessage(role: ChatRole, content: String, isPlaceholder: Bool = false, isStreaming: Bool = false) -> Int {
        let message = AIChatMessage(role: role, content: content, isPlaceholder: isPlaceholder, isStreaming: isStreaming)
        messages.append(message)
        let indexPath = IndexPath(row: messages.count - 1, section: 0)
        tableView.insertRows(at: [indexPath], with: .fade)
        scrollToBottom(animated: true)
        return indexPath.row
    }

    private func updatePendingMessage(with content: String) {
        guard let index = pendingAssistantIndex, messages.indices.contains(index) else { return }
        messages[index].content = content
        messages[index].isPlaceholder = false
        messages[index].isStreaming = false
        let indexPath = IndexPath(row: index, section: 0)
        tableView.reloadRows(at: [indexPath], with: .fade)
        scrollToBottom(animated: true)
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

extension AIChatViewController: UITableViewDataSource, UITableViewDelegate {
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
        cell.configure(with: message)
        if message.isStreaming {
            cell.startStreaming(withInitial: message.content)
        }
        return cell
    }

    /// 合并同一主循环的高度变化，避免从 MarkdownView.layoutSubviews 同步重入 TableView 布局。
    private func scheduleRowHeightUpdate(followStreaming: Bool = true) {
        pendingStreamingFollow = pendingStreamingFollow || followStreaming
        guard !pendingRowHeightUpdate else { return }
        pendingRowHeightUpdate = true
        let generation = autoScrollGeneration

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRowHeightUpdate = false
            let shouldFollowStreaming = self.pendingStreamingFollow
            self.pendingStreamingFollow = false
            UIView.performWithoutAnimation {
                self.tableView.performBatchUpdates(nil) { [weak self] _ in
                    guard let self,
                          shouldFollowStreaming,
                          generation == self.autoScrollGeneration,
                          !self.isUserInteracting,
                          self.streamingAssistantIndex != nil else { return }
                    self.scrollToBottom(animated: false)
                }
            }
        }
    }

    // MARK: - UIScrollViewDelegate（用户交互检测）

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // 用户开始拖拽，暂停自动滚动
        isUserInteracting = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            // 拖拽结束且没有惯性滚动，检查是否在底部
            checkIfAtBottomAndResumeAutoScroll(scrollView)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // 惯性滚动结束，检查是否在底部
        checkIfAtBottomAndResumeAutoScroll(scrollView)
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

final class AIChatMessageCell: UITableViewCell {
    static let reuseIdentifier = "AIChatMessageCell"

    private let bubbleView = UIView()
    private let markdownView = MarkdownViewTextKit()
    private var alignConstraints: [NSLayoutConstraint] = []
    private var hasStartedStreaming = false
    private let typewriterCharsPerStep = 1

    var onHeightChange: (() -> Void)?

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
        var config = MarkdownConfiguration.default
        
        config.typewriterTextMode = .append
        config.typewriterHeightUpdateInterval = 20
        config.streamMinModuleLength = 10
        config.streamingHapticFeedbackStyle = .medium
        config.latexAlignment = .left                // 设置为居左对齐
        config.latexBackgroundColor = .systemBlue.withAlphaComponent(0.1)  // 设置背景颜色
        config.latexPadding = 16
        markdownView.configuration = config
        markdownView.enableTypewriterEffect = false
        markdownView.translatesAutoresizingMaskIntoConstraints = false
        markdownView.onHeightChange = { [weak self] _ in
            self?.onHeightChange?()
        }
        bubbleView.addSubview(markdownView)

        let bottomConstraint = bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        bottomConstraint.priority = .defaultHigh

        let aiLeading = bubbleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        let aiWidth = bubbleView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.78, constant: -16)
        aiWidth.priority = .required

        let userTrailing = bubbleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        let userWidth = bubbleView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.78, constant: -16)
        userWidth.priority = .required

        alignConstraints = [aiLeading, aiWidth, userTrailing, userWidth]

        NSLayoutConstraint.activate([
            bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            bottomConstraint,

            markdownView.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 10),
            markdownView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
            markdownView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -10),
            markdownView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hasStartedStreaming = false
        onHeightChange = nil
        markdownView.resetForReuse()
    }

    func configure(with message: AIChatMessage) {
        markdownView.enableTypewriterEffect = message.isStreaming
        if !message.isStreaming {
            markdownView.markdown = message.content
        }

        let isUser = message.role == .user
        if isUser {
            NSLayoutConstraint.deactivate([alignConstraints[0], alignConstraints[1]])
            NSLayoutConstraint.activate([alignConstraints[2], alignConstraints[3]])
        } else {
            NSLayoutConstraint.deactivate([alignConstraints[2], alignConstraints[3]])
            NSLayoutConstraint.activate([alignConstraints[0], alignConstraints[1]])
        }

        bubbleView.backgroundColor = isUser ? UIColor.systemGray5 : UIColor.systemGray6
        if isUser {
            bubbleView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner]
        } else {
            bubbleView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
    }

    func startStreaming(withInitial text: String) {
        guard !hasStartedStreaming else { return }
        hasStartedStreaming = true
        markdownView.enableTypewriterEffect = true
        markdownView.updateTypewriterSpeed(charsPerStep: typewriterCharsPerStep)
        markdownView.beginRealStreaming(autoScrollBottom: false, useSmartBuffer: true)
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
