import Foundation

/// Opt-in, bounded in-process timing. Stores durations only, never key values or
/// host text; disabled in normal operation. Converter measurements are thread safe.
nonisolated enum KeyboardPerformance {
    enum Stage: String, CaseIterable, Sendable {
        case touchDownToVisual, touchUpToType, typeToMarked
        case candidateRequestToResult, candidateCompute, resultToCandidateUI, candidateUIUpdate
        case candidateButtonConfiguration, candidateTitleMeasurement, candidatePublication
        case correctionCompute, correctionRequestToResult
        case baseConversion, candidateReranking, classicTypo, experimentalTypo, contextEvaluation
        case lmCandidateScoring, lmNextWords, lmNextWordScoring, personalization, learningAcceptance
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var enabled = false
        var samples: [Stage: [Double]] = [:]
    }
    private static let storage = Storage()

    static func configure(enabled: Bool, reset: Bool = false) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.enabled = enabled
        if reset { storage.samples = [:] }
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
        var values = storage.samples[stage, default: []]
        if values.count == 256 { values.removeFirst() }
        values.append(milliseconds)
        storage.samples[stage] = values
    }

    static func report() -> [String: [String: Double]] {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return Dictionary(uniqueKeysWithValues: storage.samples.map { stage, values in
            let sorted = values.sorted()
            return (stage.rawValue, ["count": Double(values.count), "meanMs": values.reduce(0, +) / Double(values.count),
                "p95Ms": sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))], "maxMs": sorted.last!])
        })
    }
}
