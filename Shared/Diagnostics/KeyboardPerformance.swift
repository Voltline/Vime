import Foundation

/// Opt-in, bounded in-process timing. Stores durations only, never key values or
/// host text; disabled in normal operation. Converter measurements are thread safe.
nonisolated enum KeyboardPerformance {
    enum Stage: String, CaseIterable, Sendable {
        case emojiDecode, emojiVisibleDecode, symbolCellConfiguration, symbolHeaderUpdate
        case nativeNextWords
        case touchDownToVisual, touchUpToType, typeToMarked
        case candidateRequestToResult, candidateCompute, resultToCandidateUI, candidateUIUpdate
        // Accepted initial lists are measured through layout; cancelled requests
        // have a separate series and never inflate that interaction percentile.
        case inputToCandidateInteractive, candidateRequestCancelled
        case candidateButtonConfiguration, candidateTitleMeasurement, candidatePublication
        case candidateWidthCacheLookup, candidateTextLayout, candidateWidthCacheInsert
        case candidatePresentationPreparation
        // Counts describe model opportunities, not whether its preferred order
        // differs from the dictionary. Recorded only during opt-in profiling.
        case candidateModelEligible, candidateModelWindowAvailable, candidateModelScoringStarted
        case candidateModelRefinementReady, candidateModelUsed, candidateModelOrderChanged
        case candidateModelInitialPreparationExpired, candidateModelRefinementPreparationExpired
        case correctionCompute, correctionRequestToResult
        case baseConversion, candidateReranking, classicTypo, experimentalTypo, contextEvaluation
        case lexiconLookup, prefixConversion
        case lmCandidateScoring, lmNextWords, lmNextWordScoring, personalization, learningAcceptance
        case lmScoringPrediction, lmScoringPrefixReuse
        case candidateQueueWait, modelQueueWait, supplementaryQueueWait, learningPersistence, learningLockWait
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var enabled = false
        var samples: [Stage: [Double]] = [:]
        var totalCounts: [Stage: UInt64] = [:]
        var windows: [Stage: Window] = [:]
    }

    /// Whole-window count/mean/max plus a bounded tail for percentiles. Keeping
    /// totals separately avoids treating the last 256 calls as a lifetime count.
    private struct Window {
        var count: UInt64 = 0
        var sum = 0.0
        var maximum = 0.0
        var tail: [Double] = []

        mutating func append(_ value: Double) {
            count += 1
            sum += value
            maximum = max(maximum, value)
            if tail.count == 256 { tail.removeFirst() }
            tail.append(value)
        }
    }
    private static let storage = Storage()

    static func configure(enabled: Bool, reset: Bool = false) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.enabled = enabled
        if reset {
            storage.samples = [:]
            storage.totalCounts = [:]
            storage.windows = [:]
        }
    }

    static func start() -> TimeInterval? {
        storage.lock.lock()
        let enabled = storage.enabled
        storage.lock.unlock()
        return enabled ? ProcessInfo.processInfo.systemUptime : nil
    }

    static func record(_ stage: Stage, since start: TimeInterval?) {
        guard let start else { return }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard storage.enabled else { return }
        // Mutate the stored tail directly. A local array copy followed by
        // append triggers CoW allocation for every instrumented cell/glyph.
        if storage.samples[stage, default: []].count == 256 { storage.samples[stage]?.removeFirst() }
        storage.samples[stage, default: []].append(milliseconds)
        storage.totalCounts[stage, default: 0] += 1
        storage.windows[stage, default: Window()].append(milliseconds)
    }

    static func report() -> [String: [String: Double]] {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return Dictionary(uniqueKeysWithValues: storage.samples.map { stage, values in
            let sorted = values.sorted()
            return (stage.rawValue, ["count": Double(values.count), "totalCount": Double(storage.totalCounts[stage, default: 0]),
                "meanMs": values.reduce(0, +) / Double(values.count),
                "p95Ms": sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))], "maxMs": sorted.last!])
        })
    }

    /// Drains only interval aggregates; the usual report remains available.
    /// p95TailMs covers the most recent 256 calls in this interval, while
    /// windowCount/meanMs/maxMs cover every call since the previous drain.
    static func takeWindowReport() -> [String: [String: Double]] {
        storage.lock.lock(); defer { storage.lock.unlock() }
        let result = Dictionary(uniqueKeysWithValues: storage.windows.map { stage, window in
            let sorted = window.tail.sorted()
            return (stage.rawValue, ["windowCount": Double(window.count),
                "totalCount": Double(storage.totalCounts[stage, default: 0]),
                "percentileSampleCount": Double(sorted.count),
                "meanMs": window.sum / Double(window.count),
                "p95TailMs": sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))],
                "maxMs": window.maximum])
        })
        storage.windows = [:]
        return result
    }
}
