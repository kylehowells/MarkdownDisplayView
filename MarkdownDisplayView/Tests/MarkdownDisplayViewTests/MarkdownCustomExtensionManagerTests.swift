import Foundation
import Testing
@testable import MarkdownDisplayView

private final class ConcurrentTestParser: MarkdownCustomParser {
    let identifier: String
    let pattern: String

    init(identifier: String) {
        self.identifier = identifier
        self.pattern = NSRegularExpression.escapedPattern(for: "[\(identifier)]")
    }

    func parse(match: NSTextCheckingResult, in text: String) -> CustomElementData? {
        // 回查 manager，验证 preprocess 没有持锁执行第三方 parser。
        _ = MarkdownCustomExtensionManager.shared.allParsers
        return CustomElementData(type: identifier, rawText: (text as NSString).substring(with: match.range))
    }
}

@Test func customExtensionRegistrySupportsConcurrentRegistrationAndParsing() {
    let manager = MarkdownCustomExtensionManager.shared
    let prefix = "concurrency-\(UUID().uuidString)"
    let parsers = (0..<100).map { ConcurrentTestParser(identifier: "\(prefix)-\($0)") }

    DispatchQueue.concurrentPerform(iterations: parsers.count) { index in
        let parser = parsers[index]
        manager.register(parser: parser)
        _ = manager.allParsers
        _ = manager.preprocessCustomElements(in: "[\(parser.identifier)]")
    }

    let expectedIdentifiers = Set(parsers.map(\.identifier))
    let registeredIdentifiers = Set(manager.allParsers.map(\.identifier))
    #expect(expectedIdentifiers.isSubset(of: registeredIdentifiers))

    let sampleParser = parsers[parsers.count / 2]
    let matches = manager.preprocessCustomElements(in: "[\(sampleParser.identifier)]")
    #expect(matches.contains { $0.data.type == sampleParser.identifier })
}
