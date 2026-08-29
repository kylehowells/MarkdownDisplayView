import UIKit

// MARK: - MarkdownTextPosition

@available(iOS 15.0, *)
final class MarkdownTextPosition: UITextPosition {
    let offset: Int

    init(offset: Int) {
        self.offset = offset
        super.init()
    }
}

// MARK: - MarkdownTextRange

@available(iOS 15.0, *)
final class MarkdownTextRange: UITextRange {
    let range: NSRange

    init(range: NSRange) {
        self.range = range
        super.init()
    }

    override var start: UITextPosition {
        MarkdownTextPosition(offset: range.location)
    }

    override var end: UITextPosition {
        MarkdownTextPosition(offset: range.location + range.length)
    }

    override var isEmpty: Bool {
        range.length == 0
    }
}

// MARK: - MarkdownTextSelectionRect

@available(iOS 15.0, *)
final class MarkdownTextSelectionRect: UITextSelectionRect {
    private let value: CGRect
    private let startsSelection: Bool
    private let endsSelection: Bool

    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        value = rect
        startsSelection = containsStart
        endsSelection = containsEnd
        super.init()
    }

    override var rect: CGRect { value }
    override var containsStart: Bool { startsSelection }
    override var containsEnd: Bool { endsSelection }
    override var isVertical: Bool { false }
    override var writingDirection: NSWritingDirection { .natural }
}

// MARK: - MarkdownTextSelectionSupport

/// Read-only TextKit geometry used by `UITextInteraction` without introducing a second rendering view.
@available(iOS 15.0, *)
final class MarkdownTextSelectionSupport {
    let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)

    var selectedRange = NSRange(location: 0, length: 0)
    var selectionAffinity: UITextStorageDirection = .forward

    var containerSize: CGSize {
        get { textContainer.size }
        set {
            guard textContainer.size != newValue else { return }
            textContainer.size = newValue
            ensureLayout()
        }
    }

    init() {
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.usesFontLeading = true
        layoutManager.allowsNonContiguousLayout = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
    }

    func setAttributedText(_ attributedText: NSAttributedString) {
        textStorage.beginEditing()
        textStorage.setAttributedString(attributedText)
        textStorage.endEditing()
        selectedRange = clampedRange(selectedRange)
        ensureLayout()
    }

    func clampedRange(_ range: NSRange) -> NSRange {
        let location = min(max(0, range.location), textStorage.length)
        let length = min(max(0, range.length), textStorage.length - location)
        return NSRange(location: location, length: length)
    }

    func clampedOffset(_ position: UITextPosition) -> Int {
        let offset = (position as? MarkdownTextPosition)?.offset ?? 0
        return min(max(0, offset), textStorage.length)
    }

    func rangeValue(_ range: UITextRange?) -> NSRange {
        guard let range = range as? MarkdownTextRange else { return NSRange(location: 0, length: 0) }
        return clampedRange(range.range)
    }

    func caretRect(for position: UITextPosition, fallbackLineHeight: CGFloat) -> CGRect {
        ensureLayout()
        guard layoutManager.numberOfGlyphs > 0 else {
            return CGRect(x: 0, y: 0, width: 2, height: fallbackLineHeight)
        }

        let index = clampedOffset(position)
        let characterIndex = min(index, max(0, textStorage.length - 1))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        var rect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        if index >= textStorage.length {
            rect.origin.x = rect.maxX
        }
        rect.size.width = 2
        return rect.integral
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        ensureLayout()
        let characterRange = rangeValue(range)
        guard characterRange.length > 0 else { return [] }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )

        var rectValues: [CGRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: glyphRange,
            in: textContainer,
            using: { rect, _ in
                guard rect.isNull == false, rect.isEmpty == false else { return }
                rectValues.append(rect.integral)
            }
        )

        return rectValues.enumerated().map({ index, rect in
            MarkdownTextSelectionRect(
                rect: rect,
                containsStart: index == 0,
                containsEnd: index == rectValues.count - 1
            )
        })
    }

    func closestPosition(to point: CGPoint) -> UITextPosition {
        ensureLayout()
        let boundedPoint = CGPoint(
            x: max(0, min(point.x, textContainer.size.width)),
            y: max(0, min(point.y, textContainer.size.height))
        )
        let index = layoutManager.characterIndex(
            for: boundedPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return MarkdownTextPosition(offset: min(index, textStorage.length))
    }

    func wordRange(near location: Int) -> UITextRange? {
        guard textStorage.length > 0 else { return nil }
        let safeLocation = min(max(0, location), max(0, textStorage.length - 1))
        let units = Array(textStorage.string.utf16)
        guard units.isEmpty == false else { return nil }

        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let safeIndex = min(safeLocation, units.count - 1)
        guard let scalar = UnicodeScalar(Int(units[safeIndex])), wordCharacters.contains(scalar) else {
            return MarkdownTextRange(range: NSRange(location: safeIndex, length: 1))
        }

        var lowerBound = safeIndex
        var upperBound = safeIndex
        while lowerBound > 0,
              let scalar = UnicodeScalar(Int(units[lowerBound - 1])),
              wordCharacters.contains(scalar) {
            lowerBound -= 1
        }
        while upperBound < units.count,
              let scalar = UnicodeScalar(Int(units[upperBound])),
              wordCharacters.contains(scalar) {
            upperBound += 1
        }
        return MarkdownTextRange(range: NSRange(location: lowerBound, length: upperBound - lowerBound))
    }

    private func ensureLayout() {
        layoutManager.ensureLayout(for: textContainer)
    }
}

// MARK: - UITextInput

@available(iOS 15.0, *)
extension MarkdownTextViewTK2 {
    weak var inputDelegate: UITextInputDelegate? {
        get { selectionSupportInputDelegate }
        set { selectionSupportInputDelegate = newValue }
    }

    var tokenizer: UITextInputTokenizer {
        if let tokenizer = selectionSupportTokenizer { return tokenizer }
        let tokenizer = UITextInputStringTokenizer(textInput: self)
        selectionSupportTokenizer = tokenizer
        return tokenizer
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set { }
    }

    var selectedTextRange: UITextRange? {
        get { MarkdownTextRange(range: selectionSupport.selectedRange) }
        set { setSelectedRange(selectionSupport.rangeValue(newValue)) }
    }

    var markedTextRange: UITextRange? { nil }
    var beginningOfDocument: UITextPosition { MarkdownTextPosition(offset: 0) }
    var endOfDocument: UITextPosition { MarkdownTextPosition(offset: selectionSupport.textStorage.length) }
    var hasText: Bool { selectionSupport.textStorage.length > 0 }

    override var canBecomeFirstResponder: Bool { isTextSelectionEnabled }
    override var canResignFirstResponder: Bool { true }

    func insertText(_ text: String) { }
    func deleteBackward() { }

    var selectionAffinity: UITextStorageDirection {
        get { selectionSupport.selectionAffinity }
        set { selectionSupport.selectionAffinity = newValue }
    }

    func text(in range: UITextRange) -> String? {
        let range = selectionSupport.rangeValue(range)
        guard let swiftRange = Range(range, in: selectionSupport.textStorage.string) else { return nil }
        return String(selectionSupport.textStorage.string[swiftRange])
    }

    func replace(_ range: UITextRange, withText text: String) { }
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) { }
    func unmarkText() { }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        let start = selectionSupport.clampedOffset(fromPosition)
        let end = selectionSupport.clampedOffset(toPosition)
        return MarkdownTextRange(range: NSRange(location: min(start, end), length: abs(end - start)))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        let value = selectionSupport.clampedOffset(position) + offset
        guard value >= 0, value <= selectionSupport.textStorage.length else { return nil }
        return MarkdownTextPosition(offset: value)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard offset != 0 else { return position }
        switch direction {
        case .left:
            return self.position(from: position, offset: -offset)
        case .right:
            return self.position(from: position, offset: offset)
        case .up, .down:
            let rect = caretRect(for: position)
            return closestPosition(to: CGPoint(
                x: rect.midX,
                y: rect.midY + (direction == .up ? -rect.height : rect.height) * CGFloat(abs(offset))
            ))
        @unknown default:
            return nil
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let left = selectionSupport.clampedOffset(position)
        let right = selectionSupport.clampedOffset(other)
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        selectionSupport.clampedOffset(toPosition) - selectionSupport.clampedOffset(from)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        let range = selectionSupport.rangeValue(range)
        switch direction {
        case .left, .up:
            return MarkdownTextPosition(offset: range.location)
        case .right, .down:
            return MarkdownTextPosition(offset: range.location + range.length)
        @unknown default:
            return nil
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let index = selectionSupport.clampedOffset(position)
        switch direction {
        case .left, .up:
            return MarkdownTextRange(range: NSRange(location: max(0, index - 1), length: index > 0 ? 1 : 0))
        case .right, .down:
            return MarkdownTextRange(range: NSRange(
                location: index,
                length: index < selectionSupport.textStorage.length ? 1 : 0
            ))
        @unknown default:
            return nil
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .natural }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) { }
    func firstRect(for range: UITextRange) -> CGRect { selectionRects(for: range).first?.rect ?? .zero }

    func caretRect(for position: UITextPosition) -> CGRect {
        let fallbackHeight: CGFloat
        if selectionSupport.textStorage.length > 0 {
            let index = min(selectionSupport.textStorage.length - 1, selectionSupport.clampedOffset(position))
            fallbackHeight = (selectionSupport.textStorage.attribute(
                .font,
                at: index,
                effectiveRange: nil
            ) as? UIFont)?.lineHeight ?? UIFont.systemFont(ofSize: 17).lineHeight
        } else {
            fallbackHeight = UIFont.systemFont(ofSize: 17).lineHeight
        }
        return selectionSupport.caretRect(for: position, fallbackLineHeight: fallbackHeight)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        selectionSupport.selectionRects(for: range)
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        selectionSupport.closestPosition(to: point)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        let range = selectionSupport.rangeValue(range)
        let offset = selectionSupport.clampedOffset(selectionSupport.closestPosition(to: point))
        return MarkdownTextPosition(offset: max(range.location, min(offset, range.location + range.length)))
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        let index = selectionSupport.clampedOffset(selectionSupport.closestPosition(to: point))
        return MarkdownTextRange(range: NSRange(
            location: index,
            length: index < selectionSupport.textStorage.length ? 1 : 0
        ))
    }

    func textStyling(at position: UITextPosition, in direction: UITextStorageDirection) -> [NSAttributedString.Key: Any]? {
        guard selectionSupport.textStorage.length > 0 else { return nil }
        let index = min(selectionSupport.clampedOffset(position), selectionSupport.textStorage.length - 1)
        return selectionSupport.textStorage.attributes(at: index, effectiveRange: nil)
    }

    func position(within range: UITextRange, atCharacterOffset offset: Int) -> UITextPosition? {
        let range = selectionSupport.rangeValue(range)
        let value = range.location + offset
        guard value >= range.location, value <= range.location + range.length else { return nil }
        return MarkdownTextPosition(offset: value)
    }

    func characterOffset(of position: UITextPosition, within range: UITextRange) -> Int {
        selectionSupport.clampedOffset(position) - selectionSupport.rangeValue(range).location
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            return selectionSupport.selectedRange.length > 0
        case #selector(select(_:)):
            return selectionSupport.textStorage.length > 0 && selectionSupport.selectedRange.length == 0
        case #selector(selectAll(_:)):
            return selectionSupport.textStorage.length > 0
                && selectionSupport.selectedRange.length < selectionSupport.textStorage.length
        default:
            return false
        }
    }

    override func copy(_ sender: Any?) {
        UIPasteboard.general.string = text(in: selectedTextRange ?? MarkdownTextRange(range: selectionSupport.selectedRange)) ?? ""
    }

    override func select(_ sender: Any?) {
        becomeFirstResponder()
        selectedTextRange = selectionSupport.wordRange(near: selectionSupport.selectedRange.location)
    }

    override func selectAll(_ sender: Any?) {
        becomeFirstResponder()
        selectedTextRange = MarkdownTextRange(range: NSRange(location: 0, length: selectionSupport.textStorage.length))
    }

    override func resignFirstResponder() -> Bool {
        selectionSupport.selectedRange = NSRange(location: 0, length: 0)
        return super.resignFirstResponder()
    }

    private func setSelectedRange(_ range: NSRange) {
        let range = selectionSupport.clampedRange(range)
        guard NSEqualRanges(range, selectionSupport.selectedRange) == false else { return }
        inputDelegate?.selectionWillChange(self)
        selectionSupport.selectedRange = range
        inputDelegate?.selectionDidChange(self)
        becomeFirstResponder()
    }
}
