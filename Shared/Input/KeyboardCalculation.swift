import Foundation

/// A bounded decimal parser; never evaluates code or uses NSExpression/KVC.
nonisolated struct KeyboardCalculation: Equatable, Sendable {
    static let maximumCharacters = 128
    static let symbols = ["(", ")", "「", "」", "[", "]", "%", "+", "−", "×", "÷", "=", "¥", "€", "$", "…", "〜", "@", "#"]
    let expression: String
    let result: String
    var equation: String { expression.hasSuffix("=") || expression.hasSuffix("＝") ? expression + result : expression + "=" + result }

    /// Take the complete arithmetic run before the caret, never a valid tail
    /// carved out of a malformed/overlong expression or an existing equation.
    static func trailing(in text: String) -> Self? {
        let tail = String(text.suffix(maximumCharacters + 1))
        let run = String(tail.reversed().prefix { isExpressionCharacter($0) }.reversed())
        let expression = run.trimmingCharacters(in: .whitespaces)
        guard !expression.isEmpty, run.count <= maximumCharacters,
              text.last?.isWhitespace != true else { return nil }
        let preceding = text.dropLast(run.count).last
        guard run.first?.isWhitespace == true || preceding?.isASCII != true || preceding?.isLetter != true else { return nil }
        return evaluate(expression)
    }

    static func evaluate(_ expression: String) -> Self? {
        guard expression.count <= maximumCharacters else { return nil }
        var normalized = ""
        for character in expression {
            switch character {
            case "０"..."９":
                guard let digit = character.wholeNumberValue else { return nil }
                normalized += String(digit)
            case "＋": normalized += "+"
            case "−", "－": normalized += "-"
            case "×", "＊": normalized += "*"
            case "÷", "／": normalized += "/"
            case "（": normalized += "("
            case "）": normalized += ")"
            case "．": normalized += "."
            case "％": normalized += "%"
            case "＝": normalized += "="
            default: normalized.append(character)
            }
        }
        if normalized.hasSuffix("=") { normalized.removeLast() }
        var parser = Parser(characters: Array(normalized))
        guard let value = parser.sum(depth: 0), parser.atEnd, parser.operations > 0 else { return nil }
        let result = NSDecimalNumber(decimal: value).stringValue
        guard result != "NaN", result.count <= 80 else { return nil }
        return Self(expression: expression, result: result)
    }

    private static func isExpressionCharacter(_ c: Character) -> Bool {
        "0123456789０１２３４５６７８９+-−－＋*/×÷＊／().（）．%％=＝ \t".contains(c)
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var operations = 0
        mutating func skipSpaces() { while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 } }
        var atEnd: Bool {
            mutating get { skipSpaces(); return index == characters.count }
        }
        mutating func take(_ c: Character) -> Bool {
            skipSpaces()
            guard index < characters.count, characters[index] == c else { return false }
            index += 1; return true
        }
        mutating func sum(depth: Int) -> Decimal? {
            guard var value = product(depth: depth) else { return nil }
            while true {
                let operation: Character
                if take("+") { operation = "+" }
                else if take("-") { operation = "-" }
                else { return value }
                guard let rhs = product(depth: depth), let next = calculate(value, rhs, operation) else { return nil }
                value = next
            }
        }
        mutating func product(depth: Int) -> Decimal? {
            guard var value = unary(depth: depth) else { return nil }
            while true {
                let operation: Character
                if take("*") { operation = "*" }
                else if take("/") { operation = "/" }
                else { return value }
                guard let rhs = unary(depth: depth), let next = calculate(value, rhs, operation) else { return nil }
                value = next
            }
        }
        mutating func unary(depth: Int) -> Decimal? {
            guard depth <= 16 else { return nil }
            if take("+") { return unary(depth: depth + 1) }
            if take("-") { return unary(depth: depth + 1).map { -$0 } }
            var value: Decimal
            if take("(") {
                guard let inner = sum(depth: depth + 1), take(")") else { return nil }
                value = inner
            } else {
                skipSpaces()
                let start = index
                var digits = 0, dots = 0
                while index < characters.count {
                    let c = characters[index]
                    if c.isASCII && c.isNumber { digits += 1 }
                    else if c == "." { dots += 1 }
                    else { break }
                    index += 1
                }
                guard digits > 0, digits <= 28, dots <= 1,
                      let number = Decimal(string: String(characters[start..<index]), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
                value = number
            }
            if take("%") {
                guard let percent = calculate(value, 100, "/") else { return nil }
                value = percent
            }
            return value
        }
        mutating func calculate(_ lhs: Decimal, _ rhs: Decimal, _ operation: Character) -> Decimal? {
            var a = lhs, b = rhs, result = Decimal()
            let error: Decimal.CalculationError
            switch operation {
            case "+": error = NSDecimalAdd(&result, &a, &b, .plain)
            case "-": error = NSDecimalSubtract(&result, &a, &b, .plain)
            case "*": error = NSDecimalMultiply(&result, &a, &b, .plain)
            default:
                guard b != 0 else { return nil }
                error = NSDecimalDivide(&result, &a, &b, .plain)
            }
            guard error == .noError || error == .lossOfPrecision else { return nil }
            operations += 1
            return result
        }
    }
}

/// Carries the entire host/mark snapshot so a held result cannot delete text
/// after a field change, selection change or new input.
nonisolated struct KeyboardTextReplacement: Equatable, Sendable {
    let anchor: KeyboardLearningContext
    let markedText: String?
    let committedSuffix: String
    let text: String
}
