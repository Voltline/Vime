import Foundation

/// Korean 2-beolsik next-letter plausibility prior for `KeyHitCorrection`.
///
/// Combines Hangul syllable composition structure (e.g., a bare consonant strongly
/// expects a vowel) with mmap'd `KoreanLexicon` prefix reachability, so edge grazes
/// toward an implausible neighbor resolve to the valid Korean continuation while
/// intentional taps remain anchored.
nonisolated enum KoreanKeyPrior {
    /// Builds a `KeyHitCorrection.Prior` given the composing jamo so far (including held keys).
    /// Returns `nil` when the input is non-Hangul (e.g. temporary Latin input).
    static func prior(
        afterJamos jamos: [Character],
        activeState: HangulComposer.ActiveSyllable?,
        lexicon: KoreanLexicon = .shared
    ) -> KeyHitCorrection.Prior? {
        guard !jamos.isEmpty else { return nil }
        guard jamos.allSatisfy({ HangulComposer.choseongIndex[$0] != nil || HangulComposer.jungseongIndex[$0] != nil }) else {
            return nil
        }
        let prefix = String(jamos)
        let prefixReachable = lexicon.hasPrefix(jamoPrefix: prefix)

        return { letter in
            let isConsonant = HangulComposer.choseongIndex[letter] != nil
            let isVowel = HangulComposer.jungseongIndex[letter] != nil
            guard isConsonant || isVowel else { return 0 }

            // Lexicon confirmation is the strongest positive signal.
            if prefixReachable && lexicon.hasPrefix(jamoPrefix: prefix + String(letter)) {
                return 1.0
            }

            // Structural Hangul syllable plausibility fallback (covers OOV words, names, slang).
            switch activeState {
            case nil:
                // Start of syllable: consonants are normal, bare vowels are rare.
                return isConsonant ? 1.0 : 0.1
            case .consonant, .compoundConsonant:
                // After an initial consonant (e.g. ㄱ) or standalone compound consonant (e.g. ㄺ),
                // a vowel forms a syllable; another consonant is rare.
                return isVowel ? 1.0 : 0.05
            case .vowel:
                // After a bare vowel, a consonant starts a normal syllable; another bare vowel is rare.
                return isConsonant ? 1.0 : 0.05
            case .syllable(_, let jung, let jong):
                if jong == 0 {
                    if isConsonant { return 1.0 }
                    if let nextJung = HangulComposer.jungseongIndex[letter],
                       HangulComposer.compoundVowel[jung]?[nextJung] != nil {
                        return 1.0
                    }
                    // A non-combining vowel immediately after CV starts a bare vowel (very rare).
                    return 0.05
                } else {
                    // After CVC: a vowel spills the batchim into the next syllable; a consonant either
                    // forms a compound batchim or starts the next syllable. Both are structurally valid.
                    if prefixReachable {
                        // When the prefix was in the lexicon, prefer continuations that stay in-lexicon.
                        return 0.35
                    }
                    return 1.0
                }
            }
        }
    }
}
