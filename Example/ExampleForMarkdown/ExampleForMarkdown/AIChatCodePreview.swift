//
//  AIChatCodePreview.swift
//  ExampleForMarkdown
//
//  HTML / JS 代码块「预览」功能：
//  - ```html 代码块：点击「预览」用 WKWebView 直接渲染页面
//  - ```js / ```javascript 代码块：注入 console 捕获 shell 后执行，控制台输出显示在页面底部
//

import UIKit
import WebKit
import MarkdownDisplayView

// MARK: - 渲染器

/// 为 html / js / javascript 代码块追加「▶ 预览」按钮的渲染器。
public final class AIChatHTMLJSRenderer: MarkdownCodeBlockRenderer {

    public let supportedLanguage: String

    public init(language: String) {
        self.supportedLanguage = language.lowercased()
    }

    public func renderCodeBlock(
        code: String,
        configuration: MarkdownConfiguration,
        containerWidth: CGFloat
    ) -> UIView {
        return AIChatCodeBlockView(
            code: code,
            language: supportedLanguage,
            configuration: configuration,
            containerWidth: containerWidth
        )
    }

    public func calculateSize(
        code: String,
        configuration: MarkdownConfiguration,
        containerWidth: CGFloat
    ) -> CGSize {
        return AIChatCodeBlockView.measure(code: code, containerWidth: containerWidth)
    }
}

// MARK: - 代码块视图（代码 + 预览按钮）

final class AIChatCodeBlockView: UIView {

    private static let headerHeight: CGFloat = 40
    private static let codeFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let horizontalPadding: CGFloat = 12
    private static let bottomPadding: CGFloat = 12

    private let code: String
    private let language: String
    private let configuration: MarkdownConfiguration
    private let totalHeight: CGFloat

    private let headerView = UIView()
    private let scrollView = UIScrollView()
    private let codeLabel = UILabel()

    init(code: String, language: String, configuration: MarkdownConfiguration, containerWidth: CGFloat) {
        self.code = code
        self.language = language
        self.configuration = configuration

        let lineCount = max(code.components(separatedBy: "\n").count, 1)
        let textHeight = CGFloat(lineCount) * Self.codeFont.lineHeight
        self.totalHeight = Self.headerHeight + textHeight + Self.bottomPadding

        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: totalHeight).isActive = true
        backgroundColor = configuration.codeBackgroundColor
        layer.cornerRadius = configuration.codeBlockAppearance.cornerRadius
        layer.borderWidth = configuration.codeBlockAppearance.borderWidth
        layer.borderColor = configuration.codeBlockAppearance.borderColor.cgColor
        layer.masksToBounds = true

        buildUI(configuration: configuration, containerWidth: containerWidth)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: totalHeight)
    }

    static func measure(code: String, containerWidth: CGFloat) -> CGSize {
        let lineCount = max(code.components(separatedBy: "\n").count, 1)
        let textHeight = CGFloat(lineCount) * codeFont.lineHeight
        return CGSize(width: containerWidth, height: headerHeight + textHeight + bottomPadding)
    }

    private func buildUI(configuration: MarkdownConfiguration, containerWidth: CGFloat) {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = configuration.codeBackgroundColor.withAlphaComponent(0.6)
        addSubview(headerView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.bounces = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.font = Self.codeFont
        codeLabel.textColor = configuration.codeTextColor
        codeLabel.numberOfLines = 0
        codeLabel.lineBreakMode = .byCharWrapping
        codeLabel.text = code
        scrollView.addSubview(codeLabel)

        let badge = UILabel()
        badge.text = Self.badgeText(for: language)
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .secondaryLabel
        badge.translatesAutoresizingMaskIntoConstraints = false

        let previewButton = UIButton(type: .system)
        previewButton.setTitle("▶ 预览", for: .normal)
        previewButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        previewButton.setTitleColor(configuration.linkColor, for: .normal)
        previewButton.addTarget(self, action: #selector(previewTapped), for: .touchUpInside)
        previewButton.translatesAutoresizingMaskIntoConstraints = false

        headerView.addSubview(badge)
        headerView.addSubview(previewButton)

        let lines = code.components(separatedBy: "\n")
        let lineCount = max(lines.count, 1)
        let longestWidth = lines.map {
            ($0 as NSString).size(withAttributes: [.font: Self.codeFont]).width
        }.max() ?? 0
        let availableWidth = max(0, containerWidth - Self.horizontalPadding * 2)
        let contentWidth = max(longestWidth, availableWidth)
        let textHeight = CGFloat(lineCount) * Self.codeFont.lineHeight

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            codeLabel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            codeLabel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Self.horizontalPadding),
            codeLabel.widthAnchor.constraint(equalToConstant: contentWidth),
            codeLabel.heightAnchor.constraint(equalToConstant: textHeight),

            badge.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: Self.horizontalPadding),
            badge.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            previewButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -Self.horizontalPadding),
            previewButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor)
        ])
    }

    @objc private func previewTapped() {
        AIChatCodePreviewPresenter.present(code: code, language: language)
    }

    private static func badgeText(for language: String) -> String {
        switch language.lowercased() {
        case "html", "htm": return "HTML"
        case "js", "javascript": return "JavaScript"
        default: return language.uppercased()
        }
    }
}

// MARK: - 预览弹出

private enum AIChatCodePreviewPresenter {
    static func present(code: String, language: String) {
        guard let top = topViewController() else { return }
        let preview = AIChatCodePreviewViewController(code: code, language: language)
        let nav = UINavigationController(rootViewController: preview)
        nav.modalPresentationStyle = .fullScreen
        top.present(nav, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        if let nav = top as? UINavigationController { top = nav.visibleViewController ?? nav.topViewController }
        if let tab = top as? UITabBarController { top = tab.selectedViewController }
        return top
    }
}

// MARK: - 预览页面

final class AIChatCodePreviewViewController: UIViewController, WKNavigationDelegate {

    private enum Kind {
        case html
        case javascript
    }

    private let code: String
    private let kind: Kind

    private let webView = WKWebView()

    init(code: String, language: String) {
        self.code = code
        switch language.lowercased() {
        case "html", "htm":
            self.kind = .html
        default:
            self.kind = .javascript
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()

        switch kind {
        case .html:
            webView.loadHTMLString(code, baseURL: nil)
        case .javascript:
            webView.navigationDelegate = self
            webView.loadHTMLString(Self.jsShellHTML, baseURL: nil)
        }
    }

    private func setupUI() {
        let closeButton = UIBarButtonItem(
            title: "关闭",
            style: .done,
            target: self,
            action: #selector(closeTapped)
        )
        navigationItem.leftBarButtonItem = closeButton
        navigationItem.title = (kind == .html ? "预览 · HTML" : "预览 · JavaScript")

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = true
        webView.backgroundColor = .systemBackground
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard kind == .javascript else { return }
        // shell 加载完成后，用 evaluateJavaScript 执行用户代码，
        // 避免把用户代码内联进 <script> 带来的 </script> 转义问题。
        webView.evaluateJavaScript(code) { [weak self] _, error in
            guard let self, let error else { return }
            let escaped = error.localizedDescription
            self.webView.evaluateJavaScript(
                "var __e=document.getElementById('__console'); if(__e){var d=document.createElement('div'); d.style.color='#f66'; d.textContent='[error] \\(escaped)'; __e.appendChild(d);}",
                completionHandler: nil
            )
        }
    }

    /// 固定的 shell：劫持 console.* 输出到页面底部 #__console 区域。
    /// 不内联任何用户代码，因此无需处理转义。
    private static let jsShellHTML = """
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
            html, body { margin: 0; padding: 0; }
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 8px; }
            #__console {
                position: fixed; bottom: 0; left: 0; right: 0; max-height: 45vh; overflow: auto;
                background: #1e1e1e; color: #d4d4d4; font-family: Menlo, Consolas, monospace;
                font-size: 12px; padding: 10px; white-space: pre-wrap; word-break: break-all;
                border-top: 1px solid #333;
            }
            #__console:empty { display: none; }
        </style>
    </head>
    <body>
        <div id="__app"></div>
        <div id="__console"></div>
        <script>
        (function () {
            var consoleEl = document.getElementById('__console');
            function fmt(args) {
                return Array.prototype.map.call(args, function (a) {
                    try {
                        if (typeof a === 'object' && a !== null) { return JSON.stringify(a); }
                        return String(a);
                    } catch (e) { return String(a); }
                }).join(' ');
            }
            function line(level, args) {
                var el = document.createElement('div');
                el.textContent = '[' + level + '] ' + fmt(args);
                consoleEl.appendChild(el);
            }
            ['log', 'info', 'warn', 'error', 'debug'].forEach(function (m) {
                console[m] = function () { line(m, arguments); };
            });
            window.onerror = function (msg, src, ln, col) {
                var el = document.createElement('div');
                el.textContent = '[error] ' + msg + ' (line ' + ln + ')';
                el.style.color = '#f66';
                consoleEl.appendChild(el);
                return false;
            };
        })();
        </script>
    </body>
    </html>
    """
}

// MARK: - 注册

public extension MarkdownCustomExtensionManager {
    /// 注册 HTML / JS 代码块预览渲染器。
    func registerHTMLJSPreviewRenderer() {
        register(codeBlockRenderer: AIChatHTMLJSRenderer(language: "html"))
        register(codeBlockRenderer: AIChatHTMLJSRenderer(language: "htm"))
        register(codeBlockRenderer: AIChatHTMLJSRenderer(language: "js"))
        register(codeBlockRenderer: AIChatHTMLJSRenderer(language: "javascript"))
    }
}
