//
//  SmartStreamingCellDemoViewController.swift
//  CocoapodsMDExample
//
//  Created by 朱继超 on 12/20/25.
//

import UIKit
import MarkdownDisplayView

final class SmartStreamingCellDemoViewController: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let selectedTheme = MarkdownDemoThemeStore.selectedTheme
    private var isHeightUpdateScheduled = false

    private let demoChunks: [String] = [
        "# 智能流式（Cell 内）\n",
        "这是一个**短文本**演示，放在 UITableViewCell 中渲染。\n\n",
        "## 触发方式\n点击按钮后延时开始流式追加。\n\n",
        "```swift\nlet message = \"Hello from cell\"\nprint(message)\n```\n\n",
        "> 结束：Cell 内展示完成。\n"
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
        label.text = "智能流式 Cell 演示"
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
        setupTableView()
        setupUI()
        applySelectedTheme()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopVisibleCellStreams()
    }

    private func setupTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 220
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(SmartStreamingDemoCell.self, forCellReuseIdentifier: SmartStreamingDemoCell.reuseIdentifier)
        tableView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupUI() {
        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.heightAnchor.constraint(equalToConstant: 44),

            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            tableView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func applySelectedTheme() {
        guard let theme = selectedTheme else { return }
        view.backgroundColor = theme.canvasColor
        titleLabel.backgroundColor = theme.canvasColor
        titleLabel.textColor = theme.primaryTextColor
        closeButton.tintColor = theme.accentColor
        tableView.backgroundColor = theme.canvasColor
        tableView.indicatorStyle = theme.interfaceStyle == .dark ? .white : .black
    }

    private func scheduleHeightUpdate() {
        guard !isHeightUpdateScheduled else { return }
        isHeightUpdateScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isHeightUpdateScheduled = false
            UIView.performWithoutAnimation {
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
            }
        }
    }

    private func stopVisibleCellStreams() {
        tableView.visibleCells
            .compactMap { $0 as? SmartStreamingDemoCell }
            .forEach { $0.stopStreaming() }
    }

    @objc private func closeTapped() {
        stopVisibleCellStreams()
        dismiss(animated: true)
    }
}

extension SmartStreamingCellDemoViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: SmartStreamingDemoCell.reuseIdentifier,
            for: indexPath
        ) as? SmartStreamingDemoCell else {
            return UITableViewCell(style: .default, reuseIdentifier: "fallback")
        }
        cell.configure(chunks: demoChunks, theme: selectedTheme)
        cell.onContentHeightChange = { [weak self] in
            self?.scheduleHeightUpdate()
        }
        return cell
    }
}

final class SmartStreamingDemoCell: UITableViewCell {
    static let reuseIdentifier = "SmartStreamingDemoCell"

    private let markdownView = MarkdownViewTextKit()
    private var streamTimer: Timer?
    private var startDelayWorkItem: DispatchWorkItem?
    private var hasStarted = false
    private var currentChunkIndex = 0
    private var streamChunks: [String] = []
    private var appliedThemeRawValue: Int?

    var onContentHeightChange: (() -> Void)?

    private lazy var startButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("开始流式（延时）", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.addTarget(self, action: #selector(startButtonTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentView.clipsToBounds = true

        markdownView.translatesAutoresizingMaskIntoConstraints = false
        markdownView.onHeightChange = { [weak self] _ in
            self?.onContentHeightChange?()
        }

        contentView.addSubview(startButton)
        contentView.addSubview(markdownView)

        let bottomConstraint = markdownView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        bottomConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            startButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            startButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            startButton.heightAnchor.constraint(equalToConstant: 32),

            markdownView.topAnchor.constraint(equalTo: startButton.bottomAnchor, constant: 8),
            markdownView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            markdownView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bottomConstraint
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopStreaming()
        markdownView.resetForReuse()
        startButton.isEnabled = true
        startButton.setTitle("开始流式（延时）", for: .normal)
        hasStarted = false
        currentChunkIndex = 0
        streamChunks = []
        onContentHeightChange = nil
    }

    func configure(chunks: [String], theme: MarkdownDemoTheme?) {
        streamChunks = chunks
        guard let theme else { return }

        backgroundColor = .clear
        contentView.backgroundColor = theme.canvasColor
        markdownView.backgroundColor = theme.panelColor
        if appliedThemeRawValue != theme.rawValue {
            markdownView.configuration = theme.makeConfiguration()
            appliedThemeRawValue = theme.rawValue
        }
        markdownView.layer.cornerRadius = 12
        markdownView.layer.borderWidth = 1
        markdownView.layer.borderColor = theme.borderColor.cgColor
        markdownView.clipsToBounds = true
        startButton.tintColor = theme.accentColor
    }

    func stopStreaming() {
        startDelayWorkItem?.cancel()
        startDelayWorkItem = nil
        streamTimer?.invalidate()
        streamTimer = nil
    }

    @objc private func startButtonTapped() {
        guard !hasStarted else { return }
        hasStarted = true
        startButton.isEnabled = false
        startButton.setTitle("准备中…", for: .normal)

        let workItem = DispatchWorkItem { [weak self] in
            self?.startStreaming()
        }
        startDelayWorkItem?.cancel()
        startDelayWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    private func startStreaming() {
        currentChunkIndex = 0
        markdownView.beginRealStreaming(autoScrollBottom: false)

        streamTimer?.invalidate()
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if self.currentChunkIndex < self.streamChunks.count {
                let chunk = self.streamChunks[self.currentChunkIndex]
                self.markdownView.appendStreamData(chunk)
                self.currentChunkIndex += 1
            } else {
                timer.invalidate()
                self.streamTimer = nil
                self.markdownView.endRealStreaming()
            }
        }
    }
}
