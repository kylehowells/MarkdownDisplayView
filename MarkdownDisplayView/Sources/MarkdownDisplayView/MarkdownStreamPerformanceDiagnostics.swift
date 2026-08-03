//
//  MarkdownStreamPerformanceDiagnostics.swift
//  MarkdownDisplayView
//

import Foundation
import QuartzCore

/// Low-overhead, opt-in counters for diagnosing smart-stream CPU and duplicate UI work.
/// Enable `MD_STREAM_PERF_LOG=1`; optionally set `MD_STREAM_PERF_ONLY=1` to suppress
/// the library's verbose debug logs so logging itself does not distort the profile.
@available(iOS 15.0, *)
final class MarkdownStreamPerformanceDiagnostics {
    static let enabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["MD_STREAM_PERF_LOG"] == "1"
        #else
        false
        #endif
    }()

    private var generation = 0
    private var active = false
    private var startedAt: CFTimeInterval = 0
    private var lastSummaryAt: CFTimeInterval = 0

    private var receivedChunks = 0
    private var receivedCharacters = 0
    private var modulesQueued = 0
    private var modulesParsed = 0
    private var parsedElements = 0
    private var parseTotalMS = 0.0
    private var parseMaxMS = 0.0
    private var viewsCreated = 0
    private var viewCreateTotalMS = 0.0
    private var viewCreateMaxMS = 0.0
    private var renderFrames = 0
    private var renderFrameTotalMS = 0.0
    private var renderFrameMaxMS = 0.0
    private var heightRequests = 0
    private var heightMeasurements = 0
    private var heightCallbacks = 0
    private var heightTotalMS = 0.0
    private var heightMaxMS = 0.0
    private var duplicateElements = 0
    private var typewriterPeak = 0

    private var pendingModules = 0
    private var pendingViews = 0
    private var typewriterOutstanding = 0
    private var arrangedSubviews = 0

    func begin(generation: Int) {
        guard Self.enabled else { return }
        resetCounters()
        active = true
        self.generation = generation
        startedAt = CACurrentMediaTime()
        lastSummaryAt = startedAt
        emit("[MDPERF][BEGIN] gen=\(generation)")
    }

    private func resetCounters() {
        receivedChunks = 0
        receivedCharacters = 0
        modulesQueued = 0
        modulesParsed = 0
        parsedElements = 0
        parseTotalMS = 0
        parseMaxMS = 0
        viewsCreated = 0
        viewCreateTotalMS = 0
        viewCreateMaxMS = 0
        renderFrames = 0
        renderFrameTotalMS = 0
        renderFrameMaxMS = 0
        heightRequests = 0
        heightMeasurements = 0
        heightCallbacks = 0
        heightTotalMS = 0
        heightMaxMS = 0
        duplicateElements = 0
        typewriterPeak = 0
        pendingModules = 0
        pendingViews = 0
        typewriterOutstanding = 0
        arrangedSubviews = 0
    }

    func recordReceive(characters: Int) {
        guard Self.enabled, active else { return }
        receivedChunks += 1
        receivedCharacters += characters
        reportIfNeeded()
    }

    func recordModuleQueued(pendingModules: Int) {
        guard Self.enabled, active else { return }
        modulesQueued += 1
        self.pendingModules = pendingModules
        reportIfNeeded()
    }

    func recordModuleParsed(
        sequence: Int,
        durationMS: Double,
        elements: Int,
        pendingModules: Int,
        pendingViews: Int,
        typewriter: Int
    ) {
        guard Self.enabled, active else { return }
        modulesParsed += 1
        parsedElements += elements
        parseTotalMS += durationMS
        parseMaxMS = max(parseMaxMS, durationMS)
        updateBacklog(pendingModules: pendingModules, pendingViews: pendingViews, typewriter: typewriter)
        if durationMS >= 8 { emit("[MDPERF][SLOW_PARSE] gen=\(generation) seq=\(sequence) ms=\(format(durationMS))") }
        reportIfNeeded()
    }

    func recordViewCreated(
        sequence: Int,
        index: Int,
        type: String,
        durationMS: Double
    ) {
        guard Self.enabled, active else { return }
        viewsCreated += 1
        viewCreateTotalMS += durationMS
        viewCreateMaxMS = max(viewCreateMaxMS, durationMS)
        if durationMS >= 4 {
            emit("[MDPERF][SLOW_VIEW] gen=\(generation) seq=\(sequence) index=\(index) type=\(type) ms=\(format(durationMS))")
        }
    }

    func recordDuplicateElement(sequence: Int, index: Int, type: String) {
        guard Self.enabled, active else { return }
        duplicateElements += 1
        emit("[MDPERF][DUPLICATE] gen=\(generation) seq=\(sequence) index=\(index) type=\(type)")
    }

    func recordRenderFrame(
        durationMS: Double,
        created: Int,
        pendingModules: Int,
        pendingViews: Int,
        typewriter: Int,
        arrangedSubviews: Int
    ) {
        guard Self.enabled, active else { return }
        renderFrames += 1
        renderFrameTotalMS += durationMS
        renderFrameMaxMS = max(renderFrameMaxMS, durationMS)
        self.arrangedSubviews = arrangedSubviews
        updateBacklog(pendingModules: pendingModules, pendingViews: pendingViews, typewriter: typewriter)
        if durationMS >= 8 {
            emit("[MDPERF][SLOW_FRAME] gen=\(generation) ms=\(format(durationMS)) created=\(created) pendingViews=\(pendingViews) typewriter=\(typewriter) arranged=\(arrangedSubviews)")
        }
        reportIfNeeded()
    }

    func recordHeightRequest() {
        guard Self.enabled, active else { return }
        heightRequests += 1
        reportIfNeeded()
    }

    func recordHeightMeasurement(
        durationMS: Double,
        notified: Bool,
        force: Bool,
        source: String,
        arrangedSubviews: Int
    ) {
        guard Self.enabled, active else { return }
        heightMeasurements += 1
        heightTotalMS += durationMS
        heightMaxMS = max(heightMaxMS, durationMS)
        if notified { heightCallbacks += 1 }
        self.arrangedSubviews = arrangedSubviews
        if durationMS >= 8 {
            emit("[MDPERF][SLOW_HEIGHT] gen=\(generation) ms=\(format(durationMS)) notified=\(notified ? 1 : 0) force=\(force ? 1 : 0) source=\(source) arranged=\(arrangedSubviews)")
        }
        reportIfNeeded()
    }

    func recordTypewriterOutstanding(_ count: Int) {
        guard Self.enabled, active else { return }
        typewriterOutstanding = count
        typewriterPeak = max(typewriterPeak, count)
        reportIfNeeded()
    }

    func end(
        pendingModules: Int,
        pendingViews: Int,
        typewriter: Int,
        arrangedSubviews: Int
    ) {
        guard Self.enabled, active else { return }
        self.arrangedSubviews = arrangedSubviews
        updateBacklog(pendingModules: pendingModules, pendingViews: pendingViews, typewriter: typewriter)
        emitSummary(label: "END")
        active = false
    }

    private func updateBacklog(pendingModules: Int, pendingViews: Int, typewriter: Int) {
        self.pendingModules = pendingModules
        self.pendingViews = pendingViews
        typewriterOutstanding = typewriter
        typewriterPeak = max(typewriterPeak, typewriter)
    }

    private func reportIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastSummaryAt >= 1 else { return }
        lastSummaryAt = now
        emitSummary(label: "SUMMARY")
    }

    private func emitSummary(label: String) {
        let elapsed = max(0, CACurrentMediaTime() - startedAt)
        emit("[MDPERF][\(label)] scope=cumulative gen=\(generation) t=\(format(elapsed))s rx=\(receivedChunks)/\(receivedCharacters) modules=\(modulesQueued)/\(modulesParsed) parseMS=\(format(parseTotalMS))/\(format(parseMaxMS)) elements=\(parsedElements) views=\(viewsCreated) createMS=\(format(viewCreateTotalMS))/\(format(viewCreateMaxMS)) frames=\(renderFrames) frameMS=\(format(renderFrameTotalMS))/\(format(renderFrameMaxMS)) height=\(heightRequests)/\(heightMeasurements)/\(heightCallbacks) heightMS=\(format(heightTotalMS))/\(format(heightMaxMS)) backlog=\(pendingModules)/\(pendingViews)/\(typewriterOutstanding) typewriterPeak=\(typewriterPeak) arranged=\(arrangedSubviews) duplicates=\(duplicateElements)")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func emit(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }
}

@available(iOS 15.0, *)
final class MarkdownStreamBufferPerformanceDiagnostics {
    private var lastSummaryAt = CACurrentMediaTime()
    private var calls = 0
    private var inputCharacters = 0
    private var modules = 0
    private var totalMS = 0.0
    private var maxMS = 0.0
    private var tailNow = 0
    private var tailMax = 0
    private var pending = "none"

    func reset() {
        guard MarkdownStreamPerformanceDiagnostics.enabled else { return }
        lastSummaryAt = CACurrentMediaTime()
        calls = 0
        inputCharacters = 0
        modules = 0
        totalMS = 0
        maxMS = 0
        tailNow = 0
        tailMax = 0
        pending = "none"
    }

    func record(
        inputCharacters: Int,
        tailCharacters: Int,
        durationMS: Double,
        modules: Int,
        hasPendingStructure: Bool,
        pendingType: PendingStructureType?
    ) {
        guard MarkdownStreamPerformanceDiagnostics.enabled else { return }
        calls += 1
        self.inputCharacters += inputCharacters
        self.modules += modules
        totalMS += durationMS
        maxMS = max(maxMS, durationMS)
        tailNow = tailCharacters
        tailMax = max(tailMax, tailCharacters)
        pending = hasPendingStructure ? (pendingType?.rawValue ?? "custom") : "none"

        let now = CACurrentMediaTime()
        guard now - lastSummaryAt >= 1 else { return }
        #if DEBUG
        print("[MDPERF][BUFFER] window=\(String(format: "%.1f", now - lastSummaryAt))s calls=\(calls) chars=\(self.inputCharacters) tailNow=\(tailNow) tailMax=\(tailMax) appendMS=\(String(format: "%.1f", totalMS))/\(String(format: "%.1f", maxMS)) pending=\(pending) modules=\(self.modules)")
        #endif
        lastSummaryAt = now
        calls = 0
        self.inputCharacters = 0
        self.modules = 0
        totalMS = 0
        maxMS = 0
        tailMax = tailNow
    }
}
