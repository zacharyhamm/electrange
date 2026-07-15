//
//  ExpressionEvaluator.swift
//  electragne
//

import Foundation

/// Minimal arithmetic expression evaluator for the position/repeat expressions
/// found in animations.xml (e.g. "imageX-imageW*0.9").
///
/// Supports numbers, named variables, + - * / %, parentheses, and unary minus.
/// Unlike NSExpression, it can never raise an Objective-C exception: any
/// malformed input simply returns nil. Variables are resolved from a dictionary
/// rather than substituted into the string, so negative values and scientific
/// notation can't produce malformed expressions.
enum ExpressionEvaluator {

    static func evaluate(_ expression: String, variables: [String: Double]) -> Double? {
        guard let tokens = tokenize(expression) else { return nil }
        var parser = Parser(tokens: tokens, variables: variables)
        guard let value = parser.parseExpression(), parser.isAtEnd else { return nil }
        return value
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case op(Character)  // + - * / %
        case leftParen
        case rightParen
    }

    private static func tokenize(_ expression: String) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(expression)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t":
                i += 1
            case "+", "-", "*", "/", "%":
                tokens.append(.op(c))
                i += 1
            case "(":
                tokens.append(.leftParen)
                i += 1
            case ")":
                tokens.append(.rightParen)
                i += 1
            case "0"..."9", ".":
                var numberText = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." {
                    numberText.append(chars[i])
                    i += 1
                }
                // Double(_:) rejects malformed numbers like "1.2.3" or "."
                guard let value = Double(numberText) else { return nil }
                tokens.append(.number(value))
            default:
                guard c.isLetter else { return nil }
                var name = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber {
                    name.append(chars[i])
                    i += 1
                }
                tokens.append(.identifier(name))
            }
        }
        return tokens
    }

    // MARK: - Recursive descent parser

    private struct Parser {
        let tokens: [Token]
        let variables: [String: Double]
        var index = 0
        var depth = 0
        // Bounds recursion so a pathological input like "((((..." can't
        // overflow the stack.
        static let maxDepth = 32

        var isAtEnd: Bool { index >= tokens.count }

        mutating func parseExpression() -> Double? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maxDepth else { return nil }

            guard var value = parseTerm() else { return nil }
            while case .op(let c) = peek(), c == "+" || c == "-" {
                index += 1
                guard let rhs = parseTerm() else { return nil }
                value = (c == "+") ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func parseTerm() -> Double? {
            guard var value = parseUnary() else { return nil }
            while case .op(let c) = peek(), c == "*" || c == "/" || c == "%" {
                index += 1
                guard let rhs = parseUnary() else { return nil }
                switch c {
                case "*": value *= rhs
                case "/": value /= rhs  // /0 yields inf/nan; callers check isFinite
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        private mutating func parseUnary() -> Double? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maxDepth else { return nil }

            if case .op(let c) = peek(), c == "+" || c == "-" {
                index += 1
                guard let value = parseUnary() else { return nil }
                return (c == "-") ? -value : value
            }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> Double? {
            switch peek() {
            case .number(let value):
                index += 1
                return value
            case .identifier(let name):
                index += 1
                return variables[name]
            case .leftParen:
                index += 1
                guard let value = parseExpression(), case .rightParen = peek() else { return nil }
                index += 1
                return value
            default:
                return nil
            }
        }

        private func peek() -> Token? {
            index < tokens.count ? tokens[index] : nil
        }
    }
}
