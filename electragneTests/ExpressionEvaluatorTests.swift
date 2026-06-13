//
//  ExpressionEvaluatorTests.swift
//  electragneTests
//

import Testing
@testable import electragne

struct ExpressionEvaluatorTests {
    private let noVars: [String: Double] = [:]

    // MARK: - Precedence & associativity

    @Test(arguments: [
        ("2+3*4", 14.0),
        ("2*3+4", 10.0),
        ("10-2-3", 5.0),      // left-associative subtraction
        ("100/10/2", 5.0),    // left-associative division
        ("(2+3)*4", 20.0),
        ("((1+2)*(3+4))", 21.0),
        ("2+3*4-5", 9.0),
    ])
    func arithmetic(expr: String, expected: Double) {
        #expect(ExpressionEvaluator.evaluate(expr, variables: noVars) == expected)
    }

    // MARK: - Modulo (truncatingRemainder)

    @Test(arguments: [
        ("7%3", 1.0),
        ("10%4", 2.0),
        ("-7%3", -1.0),       // unary minus binds tighter than %
    ])
    func modulo(expr: String, expected: Double) {
        #expect(ExpressionEvaluator.evaluate(expr, variables: noVars) == expected)
    }

    // MARK: - Unary

    @Test(arguments: [
        ("-5", -5.0),
        ("--5", 5.0),
        ("3*-2", -6.0),
        ("+4", 4.0),
    ])
    func unary(expr: String, expected: Double) {
        #expect(ExpressionEvaluator.evaluate(expr, variables: noVars) == expected)
    }

    // MARK: - Variables

    @Test func variableSubstitution() {
        let vars = ["imageX": 100.0, "imageW": 40.0]
        #expect(ExpressionEvaluator.evaluate("imageX-imageW*0.9", variables: vars) == 64.0)
    }

    @Test func unknownIdentifierReturnsNil() {
        #expect(ExpressionEvaluator.evaluate("foo+1", variables: noVars) == nil)
    }

    @Test func whitespaceAndTabsIgnored() {
        #expect(ExpressionEvaluator.evaluate(" 2 +\t3 ", variables: noVars) == 5.0)
    }

    // MARK: - Division by zero (non-finite, not nil — callers check isFinite)

    @Test func divisionByZeroIsInfinite() {
        let result = ExpressionEvaluator.evaluate("1/0", variables: noVars)
        #expect(result != nil)
        #expect(result?.isFinite == false)
    }

    @Test func zeroOverZeroIsNaN() {
        let result = ExpressionEvaluator.evaluate("0/0", variables: noVars)
        #expect(result?.isNaN == true)
    }

    // MARK: - Malformed input returns nil

    @Test(arguments: ["", "1.2.3", ".", "2+", "(2+3", ")", "2 3", "@", "*5"])
    func malformedReturnsNil(expr: String) {
        #expect(ExpressionEvaluator.evaluate(expr, variables: noVars) == nil)
    }

    // MARK: - Recursion-depth cap

    @Test func shallowNestingSucceeds() {
        // 10 levels of parentheses is comfortably under the depth cap.
        let expr = String(repeating: "(", count: 10) + "1" + String(repeating: ")", count: 10)
        #expect(ExpressionEvaluator.evaluate(expr, variables: noVars) == 1.0)
    }

    @Test func deepNestingTripsTheCap() {
        // Far past the cap: the depth guard must return nil rather than overflow.
        let expr = String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100)
        #expect(ExpressionEvaluator.evaluate(expr, variables: noVars) == nil)
    }
}
