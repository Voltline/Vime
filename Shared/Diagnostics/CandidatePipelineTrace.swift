import Foundation

/// Explicit, request-local replay instrumentation. Normal typing passes nil.
/// Retains counts/ranks only, never candidate lists or host context. References
/// come from the caller's fixture; no text is included in the exported snapshot.
/// Each stage replaces its previous sample, so incremental scoring stays bounded.
nonisolated final class CandidatePipelineTrace: @unchecked Sendable {
    enum Stage: String, Sendable {
        case native, pooled, ranked, eligible, planned, validated, supported, scored
        case modelRanked, publicationReady, initial, supplementary
    }
    enum ModelGate: String, Codable, Sendable {
        case engineMode, katakana, noContext, insufficientCandidates, personalLeader
        case memoryPressure, coldModel, deadlineExpired, ready, modelUnavailable, scoringFailed
    }
    struct Sample: Codable, Equatable, Sendable {
        let count: Int
        let referenceRank: Int?
        let elapsedMs: Double
    }
    struct Snapshot: Codable, Sendable {
        let revision: Int
        let stages: [String: Sample]
        let modelGate: ModelGate?
        let modelUsed: Bool
        let cancelledBeforePublication: Bool

        subscript(_ stage: Stage) -> Sample? { stages[stage.rawValue] }
        var top1Improved: Bool {
            guard let base = self[.ranked], let initial = self[.initial] else { return false }
            return base.referenceRank != 1 && initial.referenceRank == 1
        }
        var top1Regressed: Bool {
            guard let base = self[.ranked], let initial = self[.initial] else { return false }
            return base.referenceRank == 1 && initial.referenceRank != 1
        }
    }

    let revision: Int
    private let references: Set<String>
    private let consumedInputCount: Int
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var stages: [String: Sample] = [:]
    private var modelGate: ModelGate?
    private var modelUsed = false
    private var cancelledBeforePublication = false

    init(revision: Int, references: Set<String> = [], consumedInputCount: Int) {
        self.revision = revision
        self.references = Set(references.map(\.precomposedStringWithCanonicalMapping))
        self.consumedInputCount = consumedInputCount
    }

    private func sample(_ values: [CandidateSnapshot]) -> Sample? {
        guard values.allSatisfy({ $0.revision == revision }) else { return nil }
        let rank = references.isEmpty ? nil : values.firstIndex {
            $0.consumedInputCount == consumedInputCount
                && references.contains($0.text.precomposedStringWithCanonicalMapping)
        }.map { $0 + 1 }
        return Sample(count: values.count, referenceRank: rank,
            elapsedMs: (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
    }

    func record(_ stage: Stage, values: [CandidateSnapshot]) {
        guard let sample = sample(values) else { return }
        lock.lock(); defer { lock.unlock() }
        stages[stage.rawValue] = sample
    }

    func setModelGate(_ gate: ModelGate) {
        lock.lock(); defer { lock.unlock() }
        modelGate = gate
    }

    func expireModelWindow() {
        lock.lock(); defer { lock.unlock() }
        if modelGate == .ready { modelGate = .deadlineExpired }
    }

    func published(_ values: [CandidateSnapshot], modelUsed: Bool) {
        guard let sample = sample(values) else { return }
        lock.lock(); defer { lock.unlock() }
        stages[Stage.initial.rawValue] = sample
        self.modelUsed = modelUsed
    }

    func cancelBeforePublication() {
        lock.lock(); defer { lock.unlock() }
        cancelledBeforePublication = true
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(revision: revision, stages: stages, modelGate: modelGate,
            modelUsed: modelUsed, cancelledBeforePublication: cancelledBeforePublication)
    }
}
