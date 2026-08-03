//
//  MarkdownEChartsExtension.swift
//  ExampleForMarkdown
//
//  演示如何通过自定义语法解析和视图提供者渲染 ECharts。
//

import UIKit
import WebKit
import MarkdownDisplayKit

// MARK: - ECharts Parser

/// 支持以下自定义标签：
///
/// <echarts height="320">
/// { "series": [{ "type": "bar", "data": [1, 2, 3] }] }
/// </echarts>
public final class MarkdownEChartsParser: MarkdownCustomParser {
    public let identifier = "echarts"
    public let streamingBlockTagName: String? = "echarts"
    public let pattern = #"(?i)<echarts(?:\s+height\s*=\s*["']?(\d+(?:\.\d+)?)["']?)?\s*>([\s\S]*?)</echarts\s*>"#

    private static let defaultHeight: CGFloat = 320
    private static let minimumHeight: CGFloat = 220
    private static let maximumHeight: CGFloat = 640

    public init() {}

    public func parse(match: NSTextCheckingResult, in text: String) -> CustomElementData? {
        guard match.numberOfRanges >= 3,
              let rawRange = Range(match.range, in: text),
              let optionRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        let optionJSON = String(text[optionRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let height = parsedHeight(match: match, in: text)
        var payload = [
            "optionJSON": optionJSON,
            "height": String(Double(height))
        ]
        if !Self.isValidOptionJSON(optionJSON) {
            payload["validationError"] = "ECharts 配置必须是合法的 JSON 对象"
        }

        return CustomElementData(
            type: "echarts",
            rawText: String(text[rawRange]),
            payload: payload
        )
    }

    private static func isValidOptionJSON(_ optionJSON: String) -> Bool {
        guard let data = optionJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return object is [String: Any]
    }

    private func parsedHeight(match: NSTextCheckingResult, in text: String) -> CGFloat {
        guard match.range(at: 1).location != NSNotFound,
              let heightRange = Range(match.range(at: 1), in: text),
              let value = Double(text[heightRange]) else {
            return Self.defaultHeight
        }
        return min(Self.maximumHeight, max(Self.minimumHeight, CGFloat(value)))
    }
}

// MARK: - ECharts View Provider

public final class MarkdownEChartsViewProvider: MarkdownCustomViewProvider {
    public let supportedType = "echarts"

    public init() {}

    public func createView(
        for data: CustomElementData,
        configuration: MarkdownConfiguration,
        containerWidth: CGFloat
    ) -> UIView {
        let size = calculateSize(
            for: data,
            configuration: configuration,
            containerWidth: containerWidth
        )
        if let message = data.payload["validationError"] {
            return EChartsErrorView(message: message, frame: CGRect(origin: .zero, size: size))
        }
        return EChartsWebView(
            optionJSON: data.payload["optionJSON"] ?? "{}",
            frame: CGRect(origin: .zero, size: size)
        )
    }

    public func calculateSize(
        for data: CustomElementData,
        configuration: MarkdownConfiguration,
        containerWidth: CGFloat
    ) -> CGSize {
        let height = data.payload["height"].flatMap(Double.init).map { CGFloat($0) } ?? 320
        return CGSize(width: max(1, containerWidth - 32), height: height)
    }
}

private final class EChartsErrorView: UIView {
    private let chartHeight: CGFloat

    init(message: String, frame: CGRect) {
        self.chartHeight = max(1, frame.height)
        super.init(frame: frame)

        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        clipsToBounds = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 14)
        label.textAlignment = .center
        label.numberOfLines = 0
        addSubview(label)

        heightAnchor.constraint(equalToConstant: chartHeight).isActive = true
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: chartHeight)
    }
}

// MARK: - ECharts Web View

private final class EChartsWebView: UIView, WKNavigationDelegate {
    private static var nextDiagnosticID = 0
    private static var liveDiagnosticCount = 0
    private let webView: WKWebView
    private let optionJSON: String
    private let chartHeight: CGFloat
    private let diagnosticID: Int
    private var navigationStart: CFTimeInterval = 0

    init(optionJSON: String, frame: CGRect) {
        self.optionJSON = optionJSON
        self.chartHeight = max(1, frame.height)
        Self.nextDiagnosticID += 1
        Self.liveDiagnosticCount += 1
        self.diagnosticID = Self.nextDiagnosticID

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        self.webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: frame)
        webView.navigationDelegate = self
        logWebPerformance(event: "create", detail: "live=\(Self.liveDiagnosticCount) optionChars=\(optionJSON.count)")
        setupUI()
        loadChart()
    }

    deinit {
        Self.liveDiagnosticCount = max(0, Self.liveDiagnosticCount - 1)
        logWebPerformance(event: "destroy", detail: "live=\(Self.liveDiagnosticCount)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: chartHeight)
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "ECharts 图表"

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        addSubview(webView)

        heightAnchor.constraint(equalToConstant: chartHeight).isActive = true
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func loadChart() {
        let encodedOption = Data(optionJSON.utf8).base64EncodedString()
        webView.loadHTMLString(Self.html(optionBase64: encodedOption), baseURL: nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationStart = CACurrentMediaTime()
        logWebPerformance(event: "navStart", detail: "live=\(Self.liveDiagnosticCount)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let durationMS = (CACurrentMediaTime() - navigationStart) * 1000
        logWebPerformance(event: "navFinish", detail: "ms=\(String(format: "%.1f", durationMS)) live=\(Self.liveDiagnosticCount)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let durationMS = (CACurrentMediaTime() - navigationStart) * 1000
        logWebPerformance(event: "navFail", detail: "ms=\(String(format: "%.1f", durationMS)) code=\((error as NSError).code)")
    }

    private func logWebPerformance(event: String, detail: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["MD_STREAM_PERF_LOG"] == "1" else { return }
        print("[MDPERF][WEB] type=echarts id=\(diagnosticID) event=\(event) \(detail())")
        #endif
    }

    private static func html(optionBase64: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <style>
            :root { color-scheme: light dark; }
            html, body, #chart {
              width: 100%;
              height: 100%;
              margin: 0;
              padding: 0;
              overflow: hidden;
              background: transparent;
            }
            #status {
              position: absolute;
              inset: 0;
              display: flex;
              align-items: center;
              justify-content: center;
              box-sizing: border-box;
              padding: 20px;
              color: #6b7280;
              font: 14px -apple-system, BlinkMacSystemFont, sans-serif;
              text-align: center;
            }
          </style>
        </head>
        <body>
          <div id="chart"><div id="status">正在加载 ECharts…</div></div>
          <script>
            function showError(message) {
              var container = document.getElementById('chart');
              if (!container) return;
              container.innerHTML = '<div id="status"></div>';
              document.getElementById('status').textContent = message;
            }

            function renderChart() {
              try {
                if (typeof echarts === 'undefined') {
                  showError('ECharts 脚本加载失败，请检查网络连接');
                  return;
                }

                var bytes = Uint8Array.from(atob('\(optionBase64)'), function(c) {
                  return c.charCodeAt(0);
                });
                var option = JSON.parse(new TextDecoder('utf-8').decode(bytes));
                if (typeof option.backgroundColor === 'undefined') {
                  option.backgroundColor = 'transparent';
                }
                var container = document.getElementById('chart');
                container.innerHTML = '';

                var theme = window.matchMedia('(prefers-color-scheme: dark)').matches
                  ? 'dark'
                  : null;
                var chart = echarts.init(container, theme, { renderer: 'canvas' });
                chart.setOption(option);
                window.addEventListener('resize', function() { chart.resize(); });
              } catch (error) {
                showError('ECharts 渲染失败：' + error.message);
              }
            }
          </script>
          <script
            src="https://cdn.jsdelivr.net/npm/echarts@5.5.1/dist/echarts.min.js"
            onload="renderChart()"
            onerror="showError('ECharts 脚本加载失败，请检查网络连接')">
          </script>
        </body>
        </html>
        """
    }
}

// MARK: - Convenience Registration

public extension MarkdownCustomExtensionManager {
    func registerEChartsExtension() {
        register(parser: MarkdownEChartsParser())
        register(viewProvider: MarkdownEChartsViewProvider())
    }
}
