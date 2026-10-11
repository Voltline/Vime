import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Keep raw Roman suffixes where they can independently reproduce the expected
/// kana. Upstream independent segments group n+following syllable together, even
/// when that syllable alone is a valid suffix. Freeze only an inseparable cluster
/// (e.g. a boundary between き and ょ), through azooKey's surface-count API.
nonisolated enum CompositionSegmentBoundary {
    static func remainder(of query: ComposingText, consuming readingCount: Int) -> ComposingText {
        let count = max(0, min(readingCount, query.convertTarget.count))
        let expected = String(query.convertTarget.dropFirst(count))
        let map = query.inputIndexToSurfaceIndexMap()
        if let index = map.first(where: { $0.value == count })?.key {
            var remainder = query; remainder.prefixComplete(composingCount: .inputCount(index))
            if remainder.convertTarget == expected { return remainder }
        }
        let lower = map.filter { $0.value < count }.map(\.key).max() ?? 0
        let upper = map.filter { $0.value > count }.map(\.key).min() ?? query.input.count
        if lower <= upper {
            for index in stride(from: upper, through: lower, by: -1) {
                var remainder = query; remainder.prefixComplete(composingCount: .inputCount(index))
                if remainder.convertTarget == expected { return remainder }
            }
        }
        var remainder = query; remainder.prefixComplete(composingCount: .surfaceCount(count))
        return remainder
    }
}
