import Foundation

/// Real learning is enabled in worker tests. Each fixture owns a new memory
/// directory so earlier selections cannot contaminate corpus or baseline ranks.
func isolatedLearningDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("VimeCandidateTests/" + UUID().uuidString)
}
