//
//  MarkdownDisplayView.swift
//  MarkdownDisplayView
//
//  Created by 朱继超 on 12/15/25.
//

import UIKit
import Foundation
import Combine
import NaturalLanguage
// MARK: - MarkdownViewTextKit

/// TextKit 2 版本的 Markdown 渲染视图
@available(iOS 15.0, *)
public final class MarkdownViewTextKit: UIView {

    
    // MARK: - Properties
    
    lazy var typewriterEngine: TypewriterEngine = {
        let engine = TypewriterEngine()
        engine.onComplete = { [weak self] in
            // 队列播放完毕的回调
            mdLog("✅ [Typewriter] All animations completed")

            // ⭐️ [FOOTNOTE_DEBUG] 调试日志
            mdLog("[FOOTNOTE_DEBUG] 🔔 TypewriterEngine.onComplete triggered, isRealStreamingMode=\(self?.isRealStreamingMode ?? false), isStreaming=\(self?.isStreaming ?? false)")

            // ⚡️ 流式优化：打字机动画完成后渲染脚注
            self?.renderFootnotesIfPending()
            self?.tryFinishRealStreamDrain()
        }
        // ⚡️ 核心修复：当打字机揭示了新视图（导致高度变化）时，立即通知父视图更新高度
        engine.onLayoutChange = { [weak self] in
            self?.scheduleHeightChangeNotification()
        }
        engine.onOutstandingTaskCountChange = { [weak self] count in
            guard let self else { return }
            if self.realStreamBackpressureActive, count <= self.realStreamTypewriterLowWatermark {
                self.realStreamBackpressureActive = false
                self.scheduleRealStreamRenderPump()
                self.startNextSmartStreamParseIfPossible()
            }
            self.tryFinishRealStreamDrain()
        }
        // ⭐️ 震动反馈：每次输出内容时触发
        engine.onTypewriterStep = { [weak self] in
            guard let self else { return }
            self.triggerHapticFeedback()
            self.onStreamingStep?()
        }
        return engine
    }()

    // 配置开关
    public var enableTypewriterEffect: Bool = true

    public func updateTypewriterSpeed(charsPerStep: Int? = nil,
                                      baseDuration: TimeInterval? = nil,
                                      elementGapDuration: TimeInterval? = nil) {
        typewriterEngine.updateSpeed(
            charsPerStep: charsPerStep,
            baseDuration: baseDuration,
            elementGapDuration: elementGapDuration
        )
    }
    
    public var configuration: MarkdownConfiguration = .default {
        didSet {
            streamBuffer.updateMinModuleLength(configuration.streamMinModuleLength)
            scheduleRerender()
        }
    }
    
    public var markdown: String = "" {
        didSet {
            // 🔍 性能监控：记录渲染开始时间
            if !isStreaming {
                renderStartTime = CFAbsoluteTimeGetCurrent()
                mdLog("🔍 [Perf] ========== Markdown Set ==========")
            }
            scheduleRerender()
        }
    }

    /// 直接显示由 `MarkdownRenderer.prepare(_:)` 生成的预渲染内容，跳过 Markdown 字符串解析。
    @MainActor
    public func setPreparedContent(_ preparedContent: MarkdownPreparedContent) {
        resetForReuse()

        renderStartTime = CFAbsoluteTimeGetCurrent()
        let containerWidth = preparedContent.preparedWidth

        tableOfContents = preparedContent.tableOfContents
        tocSectionId = preparedContent.tocSectionId
        imageAttachments = preparedContent.imageAttachments
        cachedContainerWidth = containerWidth
        parseCache.cachedElements = preparedContent.elements
        parseCache.cachedAttachments = preparedContent.imageAttachments
        parseCache.cachedTOCItems = preparedContent.tableOfContents
        parseCache.tocSectionId = preparedContent.tocSectionId

        updateViews(
            newElements: preparedContent.elements,
            footnotes: [],
            containerWidth: containerWidth,
            parseDuration: 0,
            perfStartTime: renderStartTime,
            precalculatedTextHeights: preparedContent.fixedTextHeights
        )
    }
    
    public var onLinkTap: ((URL) -> Void)?
    public var onImageTap: ((String) -> Void)?
    public var onHeightChange: ((CGFloat) -> Void)?
    /// TypewriterEngine 每次实际揭示文字或块级内容时触发。
    /// 可用于让外层滚动容器跟随真实播放进度，而不是跟随网络数据到达。
    public var onStreamingStep: (() -> Void)?
    public var onTOCItemTap: ((MarkdownTOCItem) -> Void)?
    let inlineSegmentAttributeKey = NSAttributedString.Key("MarkdownInlineSegment")
    // 🆕 新增：用于暂存流式输出结束时的回调
    var onStreamComplete: (() -> Void)?
    // 新增属性来存储原子区间
    var streamAtomicRanges: [NSRange] = []
    // ⚡️ 性能优化：原子区间起始位置索引（O(1)查找）
    var atomicRangeStartSet: Set<Int> = []
    
    public internal(set) var tableOfContents: [MarkdownTOCItem] = []
    
    let contentStackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.alignment = .fill
        sv.spacing = 0
        return sv
    }()
    
    var cancellables = Set<AnyCancellable>()
    var imageAttachments: [(attachment: MarkdownImageAttachment, urlString: String)] = []
    var renderWorkItem: DispatchWorkItem?
    var refreshWorkItem: DispatchWorkItem?

    var headingViews: [String: UIView] = [:]
    var oldElements: [MarkdownRenderElement] = []

    // 异步渲染队列（串行，避免并发渲染）
    let renderQueue = DispatchQueue(label: "com.markdown.render", qos: .userInitiated)

    // 渲染版本控制（解决竞态问题）
    var renderVersion: Int = 0
    let renderVersionLock = NSLock()
    
    /// About streaming
    var streamTimer: Timer?
    var streamingStartTimestamp: CFAbsoluteTime = 0  // ⭐️ 流式开始时间戳
    var firstLatexShown: Bool = false  // ⭐️ 是否已显示第一个公式
    var streamFullText: String = ""
    var streamCurrentIndex: Int = 0
    var isStreaming = false  // ✅ 默认非流式模式

    var streamTokens: [String] = []
    var streamTokenIndex: Int = 0
    var currentStreamingUnit: StreamingUnit = .word

    // ⭐️ 新增：暂停显示控制
    var isPausedForDisplay: Bool = false

    // ⭐️ 新增：用户交互锁定标记，防止流式更新打断点击事件处理
    var isUserInteractingWithDetails: Bool = false

    // ⚠️ 视图复用缓存已禁用（会导致内容错位问题）
    // 原因：基于内容hash的缓存策略会导致不同位置的相似内容被错误复用
    // private var viewCache: [String: UIView] = [:]
    // private let maxCacheSize: Int = 100
    
    // 添加属性
    var tocSectionView: UIView?
    var tocSectionId: String?
    
    // 脚注优化缓存
    var currentFootnotes: [MarkdownFootnote] = []
    var cachedFootnoteView: UIView?
    /// 标记是否有待渲染的脚注（等待打字机动画完成）
    var pendingFootnoteRender = false

    // ⚡️ 首屏优化：分批渲染配置
    /// 首屏渲染目标高度（屏幕高度的倍数，默认3屏）
    let firstScreenHeightMultiplier: CGFloat = 3.0
    /// 离屏渲染延迟时间（秒）
    let offscreenRenderDelay: TimeInterval = 0.05
    /// 离屏渲染工作项（用于取消）
    var offscreenRenderWorkItem: DispatchWorkItem?
    /// 占位视图（用于预留离屏内容空间，避免布局跳动）
    var placeholderView: UIView?

    // ⚡️ Performance Monitoring
    var renderCosts: [String: Double] = [:]
    /// 记录渲染开始时间（从设置 markdown 属性开始）
    var renderStartTime: CFAbsoluteTime = 0

    // MARK: - 增量解析缓存（流式渲染性能优化）

    /// 解析缓存结构体
    struct ParseCache {
        var lastParsedLength: Int = 0                    // 上次解析到的字符位置
        var cachedElements: [MarkdownRenderElement] = [] // 已解析的元素
        var cachedFootnotes: [MarkdownFootnote] = []     // 已解析的脚注
        var cachedAttachments: [(attachment: MarkdownImageAttachment, urlString: String)] = []
        var cachedTOCItems: [MarkdownTOCItem] = []
        var tocSectionId: String? = nil
    }

    /// 解析缓存实例
    var parseCache = ParseCache()

    /// 缓存的容器宽度（用于检测宽度变化）
    var cachedContainerWidth: CGFloat = 0

    /// 供后台解析使用的容器宽度。
    ///
    /// 必须在主线程调用后取快照传入后台闭包 —— `UIScreen.main.bounds` 是 UIKit 状态，
    /// off-main 读取会触发 Main Thread Checker。
    ///
    /// 刻意不取 `bounds.width`：这些调用点都在流式解析路径上，此时自身可能尚未完成布局，
    /// `bounds.width` 会是未定形的中间值，据此排版会把正文压成每行一两个字。
    func currentContainerWidthForParsing() -> CGFloat {
        dispatchPrecondition(condition: .onQueue(.main))
        return UIScreen.main.bounds.width - 32
    }

    /// 配置哈希值（用于检测配置变化）
    var configurationHash: Int = 0

    // MARK: - 预解析流式显示（方案B - 进度百分比映射）

    /// 预解析的所有元素
    var streamParsedElements: [MarkdownRenderElement] = []

    /// 已显示的元素数量
    var streamDisplayedCount: Int = 0

    /// 预解析的脚注
    var streamParsedFootnotes: [MarkdownFootnote] = []

    /// 预解析的附件
    var streamParsedAttachments: [(attachment: MarkdownImageAttachment, urlString: String)] = []

    /// 预解析是否完成
    var streamPreParseCompleted: Bool = false

    /// 流式文本总长度
    var streamTotalTextLength: Int = 0

    func recordCost(for type: String, duration: Double) {
        renderCosts[type, default: 0] += duration
    }

    func printRenderCosts(totalDuration: Double) {
        guard !renderCosts.isEmpty else { return }
        mdLog("\n--- 📊 UI Render Performance (Total: \(String(format: "%.4f", totalDuration))sÅ) ---")
        let sortedCosts = renderCosts.sorted { $0.value > $1.value }
        for (type, cost) in sortedCosts {
            let percentage = (cost / totalDuration) * 100
            if cost > 0.0005 { // Filter out negligible costs (< 0.5ms)
                mdLog(String(format: "   🔸 %-15@ : %.4fs  (%5.1f%%)", type, cost, percentage))
            }
        }
        mdLog("-----------------------------------------------------")
    }

    /// 是否存在目录区域
    public var hasTableOfContentsSection: Bool {
        return tocSectionView != nil
    }
    
    var autoScrollEnabled: Bool = false

    /// 用户主动上滑离开底部后置为 true，暂停自动滚动直到其手动滑回底部
    var userScrolledAway: Bool = false

    /// 合并多次 token 触发的滚动请求，避免 asyncAfter 堆积
    var autoScrollWorkItem: DispatchWorkItem?

    /// 判定"已贴底"的容差
    static let autoScrollBottomTolerance: CGFloat = 44

    // 流式渲染节流（避免过度渲染）
    var lastStreamRenderTime: TimeInterval = 0
    let streamRenderThrottle: TimeInterval = 0.3  // 300ms 节流（大幅降低CPU占用）

    // MARK: - 流式输出震动反馈
    /// 震动反馈生成器（懒加载，仅在需要时创建）
    var hapticFeedbackGenerator: UIImpactFeedbackGenerator?
    /// 上次震动时间（用于节流）
    var lastHapticFeedbackTime: TimeInterval = 0

    // MARK: - 智能流式缓存（真流式模式）

    /// 流式缓存器实例
    lazy var streamBuffer: MarkdownStreamBuffer = {
        let buffer = MarkdownStreamBuffer(
            containerWidth: bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32,
            minModuleLength: configuration.streamMinModuleLength
        )
        // ⭐️ 移除回调绑定：等待动画现在只在流式开始/结束时控制
        // 避免频繁的状态变化导致 UI 闪烁
        return buffer
    }()

    /// 等待动画视图
    lazy var waitingIndicatorView: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.accessibilityIdentifier = "StreamWaitingIndicator"

        // 创建三点动画视图
        let dotsStack = UIStackView()
        dotsStack.axis = .horizontal
        dotsStack.spacing = 6
        dotsStack.distribution = .equalSpacing
        dotsStack.translatesAutoresizingMaskIntoConstraints = false

        for i in 0..<3 {
            let dot = UIView()
            dot.backgroundColor = UIColor.systemGray3
            dot.layer.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.tag = 100 + i
            dotsStack.addArrangedSubview(dot)

            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8)
            ])
        }

        container.addSubview(dotsStack)
        NSLayoutConstraint.activate([
            dotsStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            dotsStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 30)
        ])

        container.isHidden = true
        return container
    }()

    /// 等待动画定时器
    var waitingAnimationTimer: Timer?

    /// 是否正在显示等待动画
    var isShowingWaitingIndicator: Bool = false

    /// ⭐️ 等待检测定时器（检测 TypewriterEngine 空闲且无新数据到达）
    var waitingDetectionTimer: Timer?

    /// ⭐️ 上次收到数据的时间戳
    var lastDataReceivedTime: CFAbsoluteTime = 0

    /// ⭐️ 等待动画显示延迟（秒）- TypewriterEngine 空闲多久后显示等待动画
    let waitingIndicatorDelay: TimeInterval = 0.5

    // MARK: - Real streaming state

    var isRealStreamingMode = false
    var realStreamAccumulatedText = ""
    var realStreamParsedElementCount = 0
    var realStreamBlockQueue: [String] = []
    var realStreamOnComplete: (() -> Void)?
    var useSmartBufferMode = false
    struct PendingRealStreamElement {
        var element: MarkdownRenderElement
        let globalIndex: Int
    }
    var pendingRealStreamElements = TypewriterPendingQueue<PendingRealStreamElement>()
    var realStreamRenderPumpScheduled = false
    var realStreamRenderGeneration = 0
    var realStreamParseInFlightCount = 0
    struct PendingSmartStreamModule {
        let text: String
        let renderVersion: Int
        let renderGeneration: Int
    }
    var pendingSmartStreamModules = TypewriterPendingQueue<PendingSmartStreamModule>()
    var smartStreamParseActive = false
    var realStreamDrainCompletion: (() -> Void)?
    var isEndingRealStream = false
    var realStreamBackpressureActive = false
    let realStreamTypewriterHighWatermark = 24
    let realStreamTypewriterLowWatermark = 12
    let realStreamFrameBudget: CFTimeInterval = 0.004

    var heightNotificationScheduled = false
    var pendingForcedHeightNotification = false
    var lastHeightNotificationTimestamp: CFTimeInterval = 0
    var lastLayoutWidthForHeightMeasurement: CGFloat = 0

    // MARK: - Height reporting state

    var lastReportedHeight: CGFloat = 0

    // MARK: - Fake streaming state
    var fakeStreamLastSafePosition: Int = 0
    var fakeStreamParseDebounceItem: DispatchWorkItem?
    var fakeStreamUseIncrementalParse: Bool = true
    var fakeStreamLastParseTime: CFAbsoluteTime = 0
    var fakeStreamParseScheduled: Bool = false
    var fakeStreamChunks: [String] = []  // 分片列表
    var fakeStreamChunkIndex: Int = 0     // 当前解析到的片段索引
    var fakeStreamParsedText: String = "" // 已解析的文本
    // MARK: - Initialization

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    deinit {
        // ⚡️ 取消待执行的离屏渲染任务
        offscreenRenderWorkItem?.cancel()
        // ⚡️ 移除内存警告监听
        NotificationCenter.default.removeObserver(self)
    }

    public convenience init(markdown: String, configuration: MarkdownConfiguration = .default) {
        self.init(frame: .zero)
        self.configuration = configuration
        self.markdown = markdown
        scheduleRerender()
    }
    
    func setupUI() {
        addSubview(contentStackView)
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStackView.topAnchor.constraint(equalTo: topAnchor),
            contentStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // ⚡️ 监听内存警告，清理视图缓存
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning() {
        clearViewCache()
    }
    
    // MARK: - Public Methods
    
    /// 跳转到文档内的目录区域
    public func backToTableOfContentsSection() {
        guard let view = tocSectionView else { return }

        guard let sv = findParentScrollView() else { return }

        let frame = view.convert(view.bounds, to: sv)
        let targetY = max(0, frame.origin.y - 12)
        let maxY = max(0, sv.contentSize.height - sv.bounds.height + sv.contentInset.bottom)

        sv.setContentOffset(CGPoint(x: 0, y: min(targetY, maxY)), animated: true)
    }

    /// 查找父级 ScrollView（用于滚动位置补偿等）
    func findParentScrollView() -> UIScrollView? {
        var superview = self.superview
        while superview != nil {
            if let sv = superview as? UIScrollView {
                return sv
            }
            superview = superview?.superview
        }
        return nil
    }

    /// 判断是否嵌入在可复用的列表单元格中（UITableView/UICollectionView）
    func isEmbeddedInReusableCell() -> Bool {
        var superview = self.superview
        while let view = superview {
            if view is UITableViewCell || view is UICollectionViewCell {
                return true
            }
            superview = view.superview
        }
        return false
    }
    
    public func scrollToTOCItem(_ item: MarkdownTOCItem) {
        guard let view = headingViews[item.id] else { return }
        
        var scrollView: UIScrollView?
        var superview = self.superview
        while superview != nil {
            if let sv = superview as? UIScrollView {
                scrollView = sv
                break
            }
            superview = superview?.superview
        }
        
        guard let sv = scrollView else { return }
        
        let frame = view.convert(view.bounds, to: sv)
        let targetY = frame.origin.y - 12
        let maxY = max(0, sv.contentSize.height - sv.bounds.height + sv.contentInset.bottom)
        let clampedY = min(max(0, targetY), maxY)
        
        sv.setContentOffset(CGPoint(x: 0, y: clampedY), animated: true)
    }
    
    /// 手动播放视图的打字机动画（例如用于目录 TOC）
    /// - Parameter view: 需要动画显示的视图
    public func playTypewriterAnimation(for view: UIView) {
        guard enableTypewriterEffect else {
            view.isHidden = false
            return
        }
        
        // 1. 先隐藏视图，防止闪烁
        view.isHidden = true
        
        // 2. 加入打字机队列
        typewriterEngine.enqueue(view: view, isRoot: true)
        
        // 3. 启动引擎
        typewriterEngine.start()
    }
    
    public func generateTOCView() -> UIView {
        // 1. 准备整段富文本
        let tocTotalAttrString = NSMutableAttributedString()
        
        for (index, item) in tableOfContents.enumerated() {
            // 文本内容
            let itemText = "• " + item.title + (index < tableOfContents.count - 1 ? "\n" : "")
            let attrString = NSMutableAttributedString(string: itemText)
            let range = NSRange(location: 0, length: attrString.length)
            
            // 基础样式
            attrString.addAttribute(.font, value: configuration.bodyFont, range: range)
            attrString.addAttribute(.foregroundColor, value: configuration.tocTextColor, range: range)
            
            // 链接 (Fake Link) - 确保 ID 被正确编码
            if let encodedId = item.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "toc://\(encodedId)") {
                attrString.addAttribute(.link, value: url, range: range)
                // 显式控制下划线：TextKit 2 对 .link 属性有默认下划线行为，必须用 0 明确关闭
                attrString.addAttribute(
                    .underlineStyle,
                    value: configuration.linkUnderlineEnabled ? NSUnderlineStyle.single.rawValue : 0,
                    range: range
                )
            }
            
            // 缩进样式
            let indent = CGFloat(item.level - 1) * 20.0
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.headIndent = indent + 15 // 悬挂缩进
            paragraphStyle.firstLineHeadIndent = indent
            paragraphStyle.paragraphSpacing = 6 // 行间距
            attrString.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
            
            tocTotalAttrString.append(attrString)
        }
        
        // 2. 创建单个 TextView
        let containerWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32
        let tocContainer = createTextView(
            with: tocTotalAttrString,
            width: containerWidth,
            insets: UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        )
        
        // 3. 绑定点击事件
        if let textView = tocContainer.subviews.first(where: { $0 is MarkdownTextViewTK2 }) as? MarkdownTextViewTK2 {
            textView.onLinkTap = { [weak self] url in
                if url.scheme == "toc" {
                    // 解码 ID 并跳转
                    let encodedId = url.absoluteString.replacingOccurrences(of: "toc://", with: "")
                    if let id = encodedId.removingPercentEncoding,
                       let targetItem = self?.tableOfContents.first(where: { $0.id == id }) {
                        self?.onTOCItemTap?(targetItem)
                        self?.scrollToTOCItem(targetItem)
                    }
                } else {
                    self?.onLinkTap?(url)
                }
            }
        }
        
        return tocContainer
    }
    
    @objc private func tocItemTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index < tableOfContents.count else { return }
        let item = tableOfContents[index]
        onTOCItemTap?(item)
        scrollToTOCItem(item)
    }
    
}
