//
//  MarkdownThemeGalleryViewController.swift
//  ExampleForMarkdown
//
//  Demonstrates visual-only MarkdownConfiguration themes.
//

import UIKit
import MarkdownDisplayView

enum MarkdownDemoTheme: Int, CaseIterable {
    case parchment
    case sage
    case midnight
    case plum

    var name: String {
        switch self {
        case .parchment: return "暖纸张"
        case .sage: return "鼠尾草"
        case .midnight: return "深海代码"
        case .plum: return "暮紫夜色"
        }
    }

    var caption: String {
        switch self {
        case .parchment: return "Editorial"
        case .sage: return "Calm"
        case .midnight: return "Code"
        case .plum: return "Art"
        }
    }

    var symbolName: String {
        switch self {
        case .parchment: return "doc.text"
        case .sage: return "leaf"
        case .midnight: return "terminal"
        case .plum: return "sparkles"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .parchment, .sage: return .light
        case .midnight, .plum: return .dark
        }
    }

    var canvasColor: UIColor {
        switch self {
        case .parchment: return UIColor(hex: 0xF4EFE5)
        case .sage: return UIColor(hex: 0xEEF5F1)
        case .midnight: return UIColor(hex: 0x08111F)
        case .plum: return UIColor(hex: 0x17121D)
        }
    }

    var panelColor: UIColor {
        switch self {
        case .parchment: return UIColor(hex: 0xFFFCF6)
        case .sage: return UIColor(hex: 0xFBFEFC)
        case .midnight: return UIColor(hex: 0x0D192A)
        case .plum: return UIColor(hex: 0x211827)
        }
    }

    var primaryTextColor: UIColor {
        switch self {
        case .parchment: return UIColor(hex: 0x29231E)
        case .sage: return UIColor(hex: 0x193229)
        case .midnight: return UIColor(hex: 0xEDF4FF)
        case .plum: return UIColor(hex: 0xF7EFF9)
        }
    }

    var secondaryTextColor: UIColor {
        switch self {
        case .parchment: return UIColor(hex: 0x71665C)
        case .sage: return UIColor(hex: 0x536A62)
        case .midnight: return UIColor(hex: 0xA7B6CB)
        case .plum: return UIColor(hex: 0xC7B5CB)
        }
    }

    var accentColor: UIColor {
        switch self {
        case .parchment: return UIColor(hex: 0xA44F35)
        case .sage: return UIColor(hex: 0x24705D)
        case .midnight: return UIColor(hex: 0x53A8FF)
        case .plum: return UIColor(hex: 0xC990F2)
        }
    }

    var borderColor: UIColor {
        switch self {
        case .parchment: return UIColor(hex: 0xD8CABA)
        case .sage: return UIColor(hex: 0xC5DAD1)
        case .midnight: return UIColor(hex: 0x28405D)
        case .plum: return UIColor(hex: 0x493455)
        }
    }

    var blockColor: UIColor {
        switch self {
        case .parchment: return UIColor(hex: 0xEEE4D6)
        case .sage: return UIColor(hex: 0xE2EEE8)
        case .midnight: return UIColor(hex: 0x111F33)
        case .plum: return UIColor(hex: 0x2B2032)
        }
    }

    var swatches: [UIColor] {
        [canvasColor, panelColor, accentColor, blockColor]
    }

    func makeConfiguration() -> MarkdownConfiguration {
        var configuration = interfaceStyle == .dark
            ? MarkdownConfiguration.dark
            : MarkdownConfiguration.default

        configuration.textColor = primaryTextColor
        configuration.headingColor = primaryTextColor
        configuration.linkColor = accentColor
        configuration.linkUnderlineEnabled = true
        configuration.codeTextColor = primaryTextColor
        configuration.codeBackgroundColor = blockColor
        configuration.blockquoteTextColor = primaryTextColor
        configuration.blockquoteBarColor = accentColor
        configuration.blockquoteBackgroundColor = blockColor.withAlphaComponent(interfaceStyle == .dark ? 0.82 : 0.72)
        configuration.tableBorderColor = borderColor
        configuration.tableHeaderBackgroundColor = accentColor.withAlphaComponent(interfaceStyle == .dark ? 0.22 : 0.14)
        configuration.tableRowBackgroundColor = panelColor
        configuration.tableAlternateRowBackgroundColor = blockColor.withAlphaComponent(interfaceStyle == .dark ? 0.55 : 0.45)
        configuration.horizontalRuleColor = borderColor
        configuration.imagePlaceholderColor = blockColor
        configuration.footnoteColor = secondaryTextColor
        configuration.tocTextColor = accentColor
        configuration.latexTextColor = primaryTextColor
        configuration.latexBackgroundColor = blockColor
        configuration.detailsSummaryTextColor = accentColor

        configuration.codeBlockAppearance = MarkdownBlockAppearance(
            cornerRadius: 14,
            borderWidth: 1,
            borderColor: borderColor
        )
        configuration.blockquoteAppearance = MarkdownBlockAppearance(
            cornerRadius: 12,
            borderWidth: 1,
            borderColor: borderColor.withAlphaComponent(0.75)
        )
        configuration.tableAppearance = MarkdownBlockAppearance(
            cornerRadius: 12,
            borderWidth: 1,
            borderColor: borderColor
        )
        configuration.imageAppearance = MarkdownBlockAppearance(
            cornerRadius: 14
        )
        configuration.latexAppearance = MarkdownBlockAppearance(
            cornerRadius: 12,
            borderWidth: 1,
            borderColor: borderColor
        )
        configuration.detailsAppearance = MarkdownBlockAppearance(
            cornerRadius: 12,
            borderWidth: 1,
            borderColor: borderColor
        )

        configuration.syntaxColors = interfaceStyle == .dark ? .xcodeDark : .xcode
        configuration.syntaxColorsDark = .xcodeDark
        return configuration
    }
}

enum MarkdownDemoThemeStore {
    private static let selectedThemeKey = "MarkdownDisplayView.demo.selectedTheme"

    static var selectedTheme: MarkdownDemoTheme? {
        get {
            guard let rawValue = UserDefaults.standard.object(forKey: selectedThemeKey) as? Int else {
                return nil
            }
            return MarkdownDemoTheme(rawValue: rawValue)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: selectedThemeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedThemeKey)
            }
        }
    }
}

private final class MarkdownThemeCardControl: UIControl {
    let theme: MarkdownDemoTheme

    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let iconView = UIImageView()
    private let selectedView = UIImageView()
    private let swatchStack = UIStackView()

    init(theme: MarkdownDemoTheme) {
        self.theme = theme
        super.init(frame: .zero)
        setupUI()
        updateSelectionAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.72 : 1
        }
    }

    private func setupUI() {
        backgroundColor = theme.panelColor
        layer.cornerRadius = 16
        layer.borderWidth = 1
        layer.shadowOffset = CGSize(width: 0, height: 5)
        layer.shadowRadius = 10

        iconView.image = UIImage(systemName: theme.symbolName)
        iconView.tintColor = theme.accentColor
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = theme.name
        titleLabel.textColor = theme.primaryTextColor
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.text = theme.caption.uppercased()
        captionLabel.textColor = theme.secondaryTextColor
        captionLabel.font = .systemFont(ofSize: 9, weight: .bold)
        captionLabel.adjustsFontSizeToFitWidth = true
        captionLabel.minimumScaleFactor = 0.72
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        selectedView.image = UIImage(systemName: "checkmark.circle.fill")
        selectedView.tintColor = theme.accentColor
        selectedView.translatesAutoresizingMaskIntoConstraints = false

        swatchStack.axis = .horizontal
        swatchStack.spacing = 5
        swatchStack.translatesAutoresizingMaskIntoConstraints = false
        for color in theme.swatches {
            let swatch = UIView()
            swatch.backgroundColor = color
            swatch.layer.cornerRadius = 4
            swatch.layer.borderWidth = 0.5
            swatch.layer.borderColor = theme.borderColor.cgColor
            swatch.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 18),
                swatch.heightAnchor.constraint(equalToConstant: 8),
            ])
            swatchStack.addArrangedSubview(swatch)
        }

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(captionLabel)
        addSubview(selectedView)
        addSubview(swatchStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            selectedView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            selectedView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            selectedView.widthAnchor.constraint(equalToConstant: 18),
            selectedView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectedView.leadingAnchor, constant: -6),

            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: swatchStack.leadingAnchor, constant: -6),

            swatchStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            swatchStack.centerYAnchor.constraint(equalTo: captionLabel.centerYAnchor),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(theme.name)主题"
        accessibilityHint = "双击切换 Markdown 预览主题"
    }

    private func updateSelectionAppearance() {
        selectedView.isHidden = !isSelected
        layer.borderColor = (isSelected ? theme.accentColor : theme.borderColor).cgColor
        layer.borderWidth = isSelected ? 2 : 1
        layer.shadowColor = theme.accentColor.cgColor
        layer.shadowOpacity = isSelected ? 0.18 : 0
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }
}

final class MarkdownThemeGalleryViewController: UIViewController {
    private let headerView = UIView()
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let themeScrollView = UIScrollView()
    private let themeStackView = UIStackView()
    private let previewContainer = UIView()
    private let previewTitleLabel = UILabel()
    private let activeThemeLabel = UILabel()
    private let dividerView = UIView()
    private let markdownPreview = ScrollableMarkdownViewTextKit()

    private var themeControls: [MarkdownThemeCardControl] = []
    private var selectedTheme: MarkdownDemoTheme = .parchment

    override var preferredStatusBarStyle: UIStatusBarStyle {
        selectedTheme.interfaceStyle == .dark ? .lightContent : .darkContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        let initialTheme = themeFromLaunchArguments()
            ?? MarkdownDemoThemeStore.selectedTheme
            ?? .parchment
        apply(initialTheme, animated: false)
    }

    private func setupUI() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)

        var closeConfiguration = UIButton.Configuration.filled()
        closeConfiguration.image = UIImage(systemName: "xmark")
        closeConfiguration.cornerStyle = .capsule
        closeConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        closeButton.configuration = closeConfiguration
        closeButton.accessibilityLabel = "关闭主题画廊"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(closeButton)

        titleLabel.text = "Markdown 主题画廊"
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)

        subtitleLabel.text = "同一份内容，四种阅读气质"
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(subtitleLabel)

        themeScrollView.showsHorizontalScrollIndicator = false
        themeScrollView.alwaysBounceHorizontal = true
        themeScrollView.contentInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        themeScrollView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(themeScrollView)

        themeStackView.axis = .horizontal
        themeStackView.spacing = 12
        themeStackView.translatesAutoresizingMaskIntoConstraints = false
        themeScrollView.addSubview(themeStackView)

        for theme in MarkdownDemoTheme.allCases {
            let control = MarkdownThemeCardControl(theme: theme)
            control.addTarget(self, action: #selector(themeTapped(_:)), for: .touchUpInside)
            control.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                control.widthAnchor.constraint(equalToConstant: 156),
                control.heightAnchor.constraint(equalToConstant: 76),
            ])
            themeControls.append(control)
            themeStackView.addArrangedSubview(control)
        }

        previewContainer.layer.cornerRadius = 20
        previewContainer.layer.borderWidth = 1
        previewContainer.layer.masksToBounds = true
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewContainer)

        previewTitleLabel.text = "实时预览"
        previewTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        previewTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewTitleLabel)

        activeThemeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        activeThemeLabel.textAlignment = .center
        activeThemeLabel.layer.cornerRadius = 11
        activeThemeLabel.layer.masksToBounds = true
        activeThemeLabel.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(activeThemeLabel)

        dividerView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(dividerView)

        markdownPreview.markdownView.enableTypewriterEffect = false
        markdownPreview.showsVerticalScrollIndicator = true
        markdownPreview.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(markdownPreview)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            closeButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            closeButton.widthAnchor.constraint(equalToConstant: 38),
            closeButton.heightAnchor.constraint(equalToConstant: 38),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -16),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -16),

            themeScrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            themeScrollView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            themeScrollView.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            themeScrollView.heightAnchor.constraint(equalToConstant: 82),
            themeScrollView.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -12),

            themeStackView.topAnchor.constraint(equalTo: themeScrollView.contentLayoutGuide.topAnchor),
            themeStackView.leadingAnchor.constraint(equalTo: themeScrollView.contentLayoutGuide.leadingAnchor),
            themeStackView.trailingAnchor.constraint(equalTo: themeScrollView.contentLayoutGuide.trailingAnchor),
            themeStackView.bottomAnchor.constraint(equalTo: themeScrollView.contentLayoutGuide.bottomAnchor),
            themeStackView.heightAnchor.constraint(equalTo: themeScrollView.frameLayoutGuide.heightAnchor),

            previewContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            previewContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            previewContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            previewContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            previewContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
            previewContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),

            previewTitleLabel.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 16),
            previewTitleLabel.centerYAnchor.constraint(equalTo: activeThemeLabel.centerYAnchor),

            activeThemeLabel.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 11),
            activeThemeLabel.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -14),
            activeThemeLabel.heightAnchor.constraint(equalToConstant: 22),
            activeThemeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),

            dividerView.topAnchor.constraint(equalTo: activeThemeLabel.bottomAnchor, constant: 10),
            dividerView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            markdownPreview.topAnchor.constraint(equalTo: dividerView.bottomAnchor),
            markdownPreview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            markdownPreview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            markdownPreview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
        ])

        markdownPreview.onLinkTap = { url in
            guard UIApplication.shared.canOpenURL(url) else { return }
            UIApplication.shared.open(url)
        }
    }

    @objc private func themeTapped(_ sender: MarkdownThemeCardControl) {
        guard sender.theme != selectedTheme else { return }
        apply(sender.theme, animated: true)
    }

    private func apply(_ theme: MarkdownDemoTheme, animated: Bool) {
        selectedTheme = theme
        MarkdownDemoThemeStore.selectedTheme = theme
        overrideUserInterfaceStyle = theme.interfaceStyle
        setNeedsStatusBarAppearanceUpdate()

        for control in themeControls {
            control.isSelected = control.theme == theme
        }
        scrollSelectedThemeIntoView(animated: animated)

        view.backgroundColor = theme.canvasColor
        headerView.backgroundColor = theme.canvasColor
        titleLabel.textColor = theme.primaryTextColor
        subtitleLabel.textColor = theme.secondaryTextColor

        var closeConfiguration = closeButton.configuration
        closeConfiguration?.baseForegroundColor = theme.primaryTextColor
        closeConfiguration?.baseBackgroundColor = theme.blockColor
        closeButton.configuration = closeConfiguration

        previewContainer.backgroundColor = theme.panelColor
        previewContainer.layer.borderColor = theme.borderColor.cgColor
        previewTitleLabel.textColor = theme.secondaryTextColor
        dividerView.backgroundColor = theme.borderColor
        activeThemeLabel.text = "  \(theme.name)  "
        activeThemeLabel.textColor = theme.accentColor
        activeThemeLabel.backgroundColor = theme.accentColor.withAlphaComponent(0.12)

        let updatePreview = {
            self.markdownPreview.markdownView.resetForReuse()
            self.markdownPreview.backgroundColor = theme.panelColor
            self.markdownPreview.markdownView.backgroundColor = theme.panelColor
            self.markdownPreview.configuration = theme.makeConfiguration()
            self.markdownPreview.markdown = Self.previewMarkdown
            self.markdownPreview.setContentOffset(.zero, animated: false)
        }

        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(
                with: previewContainer,
                duration: 0.2,
                options: [.transitionCrossDissolve, .allowAnimatedContent],
                animations: updatePreview
            )
        } else {
            updatePreview()
        }
    }

    private func scrollSelectedThemeIntoView(animated: Bool) {
        guard let selectedControl = themeControls.first(where: { $0.theme == selectedTheme }) else { return }
        DispatchQueue.main.async { [weak self, weak selectedControl] in
            guard let self, let selectedControl else { return }
            self.view.layoutIfNeeded()
            let visibleRect = selectedControl
                .convert(selectedControl.bounds, to: self.themeScrollView)
                .insetBy(dx: -16, dy: 0)
            self.themeScrollView.scrollRectToVisible(
                visibleRect,
                animated: animated && !UIAccessibility.isReduceMotionEnabled
            )
        }
    }

    private func themeFromLaunchArguments() -> MarkdownDemoTheme? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let keyIndex = arguments.firstIndex(of: "-ThemeGalleryTheme"),
              arguments.indices.contains(keyIndex + 1) else { return nil }
        let value = arguments[keyIndex + 1].lowercased()
        return MarkdownDemoTheme.allCases.first { theme in
            switch theme {
            case .parchment: return value == "parchment"
            case .sage: return value == "sage"
            case .midnight: return value == "midnight"
            case .plum: return value == "plum"
            }
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private static let previewMarkdown = """
    # Build readable interfaces.

    A good theme creates **hierarchy**, protects contrast, and lets the content stay in focus. Try switching the cards above—the Markdown stays identical.

    > Design is not decoration. It is how information feels while you move through it.

    ## Component tokens

    | Element | Role | Config |
    |:--|:--|:--|
    | Code | Focus | `codeBlock` |
    | Quote | Voice | `blockquote` |
    | Table | Compare | `table` |

    ## Configuration

    ```swift
    var config = MarkdownConfiguration.default
    config.codeBlockAppearance = .init(
        cornerRadius: 14,
        borderWidth: 1,
        borderColor: accent
    )
    markdownView.configuration = config
    ```

    $$E = mc^2$$

    <details>
    <summary>Why keep layout tokens separate?</summary>

    Appearance can evolve independently while width, height, and scrolling remain predictable.
    </details>

    ![Image placeholder with themed border](theme-preview.invalid/cover.png)

    ---

    ### A small checklist

    - Keep body text contrast above 4.5:1.
    - Use one accent color with a clear job.
    - Let blocks differ without competing with the document.
    """
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
