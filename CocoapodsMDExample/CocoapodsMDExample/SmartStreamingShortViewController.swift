//
//  SmartStreamingShortViewController.swift
//  CocoapodsMDExample
//
//  Created by 朱继超 on 12/20/25.
//

import UIKit
import MarkdownDisplayKit

final class SmartStreamingShortViewController: UIViewController {

    private let scrollableMarkdownView = ScrollableMarkdownViewTextKit()
    private var streamTimer: Timer?
    private var hasStarted = false
    private var currentChunkIndex = 0

    private let streamChunks: [String] = [
        """
        好嘞！下面用 4 个表格快速验证对齐能力👇

        **主题：左对齐 / 居中 / 右对齐 / 混合对齐**

        ---

        **1）左对齐（`:---`）**

        | 字段 | 对齐验证说明（这一列故意很长，用于拉宽列宽） | 数值 |
        | :--- | :--- | :--- |
        | A | 短词 | 1 |
        | B | 中等长度文本 | 20 |
        | C | x | 300 |

        """,
        """
        ---

        **2）居中（`:--:`）**

        | 字段 | 对齐验证说明（这一列故意很长，用于拉宽列宽） | 数值 |
        | :--: | :--: | :--: |
        | A | 短词 | 1 |
        | B | 中等长度文本 | 20 |
        | C | x | 300 |

        """,
        """
        ---

        **3）右对齐（`---:`）**

        | 字段 | 对齐验证说明（这一列故意很长，用于拉宽列宽） | 数值 |
        | ---: | ---: | ---: |
        | A | 短词 | 1 |
        | B | 中等长度文本 | 20 |
        | C | x | 300 |

        """,
        """
        ---

        **4）混合对齐（第一列左、第二列中、第三列右）**

        | 名称 | 状态 | 分数 |
        | :--- | :--: | ---: |
        | ultra-long-metric-name-demo | OK | 7 |
        | m | HOLD | 88 |
        | s | FAIL | 1000 |

        提示：如果你看到 4 个表格的文本对齐不同，说明列对齐语法已生效。
        """
    ]

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("关闭", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.text = "智能流式短文本"
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.backgroundColor = .systemBackground
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startStreamingIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopStreaming()
    }

    private func setupUI() {
        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        view.addSubview(scrollableMarkdownView)

        scrollableMarkdownView.translatesAutoresizingMaskIntoConstraints = false
        scrollableMarkdownView.alwaysBounceVertical = true
        scrollableMarkdownView.onLinkTap = { [weak self] url in
            self?.handleLinkTap(url)
        }

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.heightAnchor.constraint(equalToConstant: 44),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            scrollableMarkdownView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            scrollableMarkdownView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollableMarkdownView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollableMarkdownView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func startStreamingIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true

        currentChunkIndex = 0
        scrollableMarkdownView.markdownView.beginRealStreaming(
            autoScrollBottom: true
        )

        streamTimer?.invalidate()
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            if self.currentChunkIndex < self.streamChunks.count {
                let chunk = self.streamChunks[self.currentChunkIndex]
                self.scrollableMarkdownView.markdownView.appendStreamData(chunk)
                self.currentChunkIndex += 1
            } else {
                timer.invalidate()
                self.streamTimer = nil
                self.scrollableMarkdownView.markdownView.endRealStreaming()
            }
        }
    }

    private func stopStreaming() {
        streamTimer?.invalidate()
        streamTimer = nil
    }

    private func handleLinkTap(_ url: URL) {
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    @objc private func closeTapped() {
        stopStreaming()
        dismiss(animated: true)
    }
}
