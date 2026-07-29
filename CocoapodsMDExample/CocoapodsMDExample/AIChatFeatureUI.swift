import UIKit

struct AIChatSelectedImage: Identifiable {
    enum OCRState: String {
        case processing
        case ready
        case failed
    }

    let id: UUID
    let image: UIImage
    var recognizedText: String
    var state: OCRState
    var errorDescription: String?

    init(image: UIImage) {
        id = UUID()
        self.image = image
        recognizedText = ""
        state = .processing
        errorDescription = nil
    }
}

final class AIChatImageStripView: UIView {
    var onRemove: ((UUID) -> Void)?

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    /// 只有 id 或识别状态变化才重建子视图：update 会随每次输入框改动被调用。
    private var renderedSignature: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(items: [AIChatSelectedImage]) {
        let signature = items.map { "\($0.id.uuidString)-\($0.state.rawValue)" }
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }
        items.forEach { stackView.addArrangedSubview(makeItemView($0)) }
        accessibilityLabel = items.isEmpty ? "未选择图片" : "已选择 \(items.count) 张图片"
    }

    private func makeItemView(_ item: AIChatSelectedImage) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 10
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.separator.cgColor
        container.clipsToBounds = false
        container.translatesAutoresizingMaskIntoConstraints = false
        let imageView = UIImageView(image: item.image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 9
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isAccessibilityElement = false
        container.addSubview(imageView)
        let statusView: UIView
        switch item.state {
        case .processing:
            let spinner = UIActivityIndicatorView(style: .medium); spinner.color = .white; spinner.startAnimating(); statusView = spinner
            container.accessibilityLabel = "图片，正在识别文字"
        case .ready:
            let image = UIImageView(image: UIImage(systemName: "checkmark.circle.fill")); image.tintColor = .systemGreen; statusView = image
            container.accessibilityLabel = "图片，文字识别完成"
        case .failed:
            let image = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill")); image.tintColor = .systemOrange; statusView = image
            container.accessibilityLabel = "图片，文字识别失败"
        }
        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.contentMode = .scaleAspectFit
        let statusBackground = UIView()
        statusBackground.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        statusBackground.layer.cornerRadius = 12
        statusBackground.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBackground); container.addSubview(statusView)
        let removeButton = UIButton(type: .system)
        removeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        removeButton.tintColor = .secondaryLabel; removeButton.backgroundColor = .systemBackground; removeButton.layer.cornerRadius = 11
        removeButton.translatesAutoresizingMaskIntoConstraints = false; removeButton.accessibilityLabel = "移除图片"
        removeButton.addAction(UIAction { [weak self] _ in self?.onRemove?(item.id) }, for: .touchUpInside)
        container.addSubview(removeButton)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 68), container.heightAnchor.constraint(equalToConstant: 68),
            imageView.topAnchor.constraint(equalTo: container.topAnchor), imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor), imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBackground.centerXAnchor.constraint(equalTo: container.centerXAnchor), statusBackground.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusBackground.widthAnchor.constraint(equalToConstant: 28), statusBackground.heightAnchor.constraint(equalToConstant: 28),
            statusView.centerXAnchor.constraint(equalTo: statusBackground.centerXAnchor), statusView.centerYAnchor.constraint(equalTo: statusBackground.centerYAnchor),
            statusView.widthAnchor.constraint(equalToConstant: 20), statusView.heightAnchor.constraint(equalToConstant: 20),
            removeButton.centerXAnchor.constraint(equalTo: container.trailingAnchor, constant: -2), removeButton.centerYAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            removeButton.widthAnchor.constraint(equalToConstant: 22), removeButton.heightAnchor.constraint(equalToConstant: 22)
        ])
        return container
    }
}

final class AIChatHistoryViewController: UIViewController {
    var onOpenConversation: ((AIChatConversation) -> Void)?
    var onReferenceSelection: ((Set<UUID>) -> Void)?
    var onDeleteConversation: ((UUID) -> Void)?
    var onCreateConversation: (() -> Void)?
    private var conversations: [AIChatConversation]
    private var selectedIDs: Set<UUID>
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private lazy var applyButton = UIBarButtonItem(title: "引用", style: .done, target: self, action: #selector(applySelection))

    init(conversations: [AIChatConversation], selectedIDs: Set<UUID>) {
        self.conversations = conversations.sorted { $0.updatedAt > $1.updatedAt }; self.selectedIDs = selectedIDs
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad(); title = "历史会话"; view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = applyButton
        tableView.dataSource = self; tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(tableView)
        let newButton = UIButton(type: .system); var config = UIButton.Configuration.filled(); config.title = "新建会话"
        config.image = UIImage(systemName: "square.and.pencil"); config.imagePadding = 8; newButton.configuration = config
        newButton.addTarget(self, action: #selector(createConversation), for: .touchUpInside); newButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newButton)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor), tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor), tableView.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -8),
            newButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            newButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            newButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12), newButton.heightAnchor.constraint(equalToConstant: 48)
        ]); updateApplyButton()
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func applySelection() { onReferenceSelection?(selectedIDs); dismiss(animated: true) }
    @objc private func createConversation() { onCreateConversation?(); dismiss(animated: true) }
    private func updateApplyButton() {
        applyButton.title = selectedIDs.isEmpty ? "清除引用" : "引用(\(selectedIDs.count))"
        applyButton.accessibilityLabel = selectedIDs.isEmpty ? "清除历史会话引用" : "引用 \(selectedIDs.count) 个历史会话"
    }
    private static let dateFormatter: DateFormatter = { let f = DateFormatter(); f.locale = .current; f.dateStyle = .medium; f.timeStyle = .short; return f }()
}

extension AIChatHistoryViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { conversations.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "AIChatHistoryCell"; let cell = tableView.dequeueReusableCell(withIdentifier: id) ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)
        let item = conversations[indexPath.row]; cell.textLabel?.text = item.title; cell.textLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        let question = item.messages.last(where: { $0.role == .user })?.content ?? "暂无问题"
        cell.detailTextLabel?.text = "\(Self.dateFormatter.string(from: item.updatedAt)) · \(question.prefix(48))"
        cell.detailTextLabel?.textColor = .secondaryLabel; cell.detailTextLabel?.numberOfLines = 2
        cell.accessibilityHint = "轻点切换引用状态，轻点信息按钮打开会话"
        cell.accessoryType = .detailButton
        // selectedIDs 是唯一数据源；不再调用 tableView.selectRow，避免与 reloadRows 互相覆盖。
        let isSelected = selectedIDs.contains(item.id)
        cell.imageView?.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        cell.imageView?.tintColor = isSelected ? .systemBlue : .tertiaryLabel
        cell.accessibilityValue = isSelected ? "已引用" : "未引用"
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let id = conversations[indexPath.row].id
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        tableView.reloadRows(at: [indexPath], with: .none); updateApplyButton()
    }
    func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        onOpenConversation?(conversations[indexPath.row]); dismiss(animated: true)
    }
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }; let item = conversations.remove(at: indexPath.row); selectedIDs.remove(item.id)
        onDeleteConversation?(item.id); tableView.deleteRows(at: [indexPath], with: .automatic); updateApplyButton()
    }
}
