import Foundation

enum KeyboardNumberSymbols {
    static let defaults = ["+", "-", "/", "*", "%", "¥", "(", ")", "=", ":", "@", "#"]
    static let maximumCount = 32
    static let maximumLength = 4
    static let settingsURL = URL(string: "vime://settings/number-symbols")!

    static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var symbols: [String] = []
        for value in values {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= maximumLength,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(text).inserted else { continue }
            symbols.append(text)
            if symbols.count == maximumCount { break }
        }
        return symbols
    }

    static func title(for symbol: String) -> String {
        switch symbol { case "-": "−"; case "/": "÷"; case "*": "×"; default: symbol }
    }
}
