//
//  StreamingMarkdownController.swift
//  ExampleForMarkdown
//
//  Created by 朱继超 on 12/16/25.
//

import UIKit
import MarkdownDisplayKit

class StreamingMarkdownController: UIViewController {

    private let scrollableMarkdownView = ScrollableMarkdownViewTextKit()
    private var streamingTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadSampleMarkdown()
    }
    
    private func setupUI() {
        self.view.backgroundColor = .white
        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.text = "Streaming Markdown"
        titleLabel.backgroundColor = .systemBackground
        titleLabel.textColor = .systemBlue
        view.addSubview(titleLabel)
        // 关闭按钮
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("关闭", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        closeButton.addTarget(self, action: #selector(dismissSelf), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        view.addSubview(scrollableMarkdownView)

        scrollableMarkdownView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.heightAnchor.constraint(equalToConstant: 44),
            closeButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            scrollableMarkdownView.topAnchor.constraint(
                equalTo: closeButton.bottomAnchor, constant: 8),
            scrollableMarkdownView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollableMarkdownView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollableMarkdownView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // 设置链接点击回调
        scrollableMarkdownView.onLinkTap = { [weak self] url in
            self?.handleLinkTap(url)
        }
    }
    
    private func handleLinkTap(_ url: URL) {
        // 处理链接点击
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    @objc private func dismissSelf() {
        streamingTask?.cancel()
        dismiss(animated: true, completion: nil)
    }

    private func loadSampleMarkdown() {
        // Demo 使用本地分片模拟 AI/SSE 网络回调；实际项目应在收到每个字符串分片时直接追加。
        let chunks = makeNetworkChunks(from: sampleMarkdown)
        scrollableMarkdownView.markdownView.beginRealStreaming()

        streamingTask = Task { @MainActor [weak self] in
            for chunk in chunks {
                guard !Task.isCancelled else { return }
                self?.scrollableMarkdownView.markdownView.appendStreamData(chunk)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }

            guard !Task.isCancelled else { return }
            self?.scrollableMarkdownView.markdownView.endRealStreaming()
            self?.streamingTask = nil
        }
    }

    private func makeNetworkChunks(from text: String, maximumLength: Int = 48) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let end = text.index(
                start,
                offsetBy: maximumLength,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }

        return chunks
    }
}
