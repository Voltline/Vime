import Foundation

/// A lead the model replaced after a pause (sentence correction or whole-
/// sentence generation). The strip shows the changed characters in brand blue
/// and plays the Vime mark once per correction.
nonisolated struct LateCorrectionMark: Equatable, Sendable {
    /// Tells one correction from the next, so the mark plays once for each.
    let id: Int
    /// Offsets, in characters of the new lead, of the characters it changed.
    let changed: [Int]

    /// Smaller corrections change the lead without the mark.
    static let minimumChanges = 2

    /// The characters of `new` outside a longest common subsequence with `old`.
    static func changedCharacters(from old: String, to new: String) -> [Int] {
        let a = Array(old), b = Array(new)
        guard !a.isEmpty else { return Array(b.indices) }
        // lengths[i][j]: the common subsequence of a[i...] and b[j...].
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var changed: [Int] = []
        var i = 0, j = 0
        while j < b.count {
            if i < a.count, a[i] == b[j] {
                i += 1; j += 1
            } else if i < a.count, lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                changed.append(j); j += 1
            }
        }
        return changed
    }
}
