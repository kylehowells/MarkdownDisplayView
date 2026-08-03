//
//  MarkdownLog.swift
//  MarkdownDisplayView
//

import Foundation

enum MarkdownLogConfiguration {
    static func verboseEnabled(environment: [String: String]) -> Bool {
        environment["MD_VERBOSE_LOG"] == "1"
            && environment["MD_STREAM_PERF_ONLY"] != "1"
    }

    #if DEBUG
    static let verboseEnabled = verboseEnabled(environment: ProcessInfo.processInfo.environment)
    #else
    static let verboseEnabled = false
    #endif
}

var mdVerboseLoggingEnabled: Bool { MarkdownLogConfiguration.verboseEnabled }

/// 调试日志。
///
/// 使用 `@autoclosure` 而非直接把 `print` 包进 `#if DEBUG`：字符串插值是 eager 求值的，
/// 若只守卫 `print` 本身，release 下插值里的表达式（如流式缓存的 `text.count`，
/// 对 grapheme 串是 O(n) 遍历）仍会在热路径上每 token 执行一次。
@inline(__always)
func mdLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    if mdVerboseLoggingEnabled {
        print(message())
    }
    #endif
}
