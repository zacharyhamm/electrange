//
//  AnimationParser.swift
//  electragne
//
//  Created by zacharyhamm on 2/4/26.
//

import Foundation
import AppKit

// MARK: - Animation Models

struct PetAnimation: Identifiable {
    let id: String
    let name: String
    let frames: [Int] // Frame numbers from sprite sheet
    let startInterval: TimeInterval
    let endInterval: TimeInterval
    let repeatCount: RepeatValue // How many times to loop the repeatfrom section
    let repeatFrom: Int // Frame index to loop back to (0-indexed)
    let offsetY: CGFloat

    // Movement per frame (pixels)
    let startMoveX: CGFloat
    let startMoveY: CGFloat
    let endMoveX: CGFloat
    let endMoveY: CGFloat

    // Next animation transitions (probability-based)
    let nextAnimations: [NextAnimation]

    // Border-triggered transitions (when hitting screen edges)
    let borderTransitions: [NextAnimation]

    // Gravity-triggered transitions (when landing)
    let gravityTransitions: [NextAnimation]

    var interval: TimeInterval { startInterval } // Compatibility
}

struct NextAnimation {
    let animationID: String
    let probability: Int // 1-100 weight
    let only: String // "none", "taskbar", etc.
}

// Child spawn definition - spawns a separate window when parent animation plays
struct ChildSpawn {
    let parentAnimationID: String  // Animation that triggers the spawn
    let xExpression: String        // Position expression (e.g., "imageX-imageW*0.9")
    let yExpression: String
    let nextAnimationID: String    // Animation for the child to play

    // Evaluate position expression given current pet state
    func evaluateX(imageX: CGFloat, imageY: CGFloat, imageW: CGFloat, imageH: CGFloat,
                   screenW: CGFloat, screenH: CGFloat, areaW: CGFloat, areaH: CGFloat,
                   random: Int, randS: Int) -> CGFloat {
        return evaluateExpression(xExpression, imageX: imageX, imageY: imageY,
                                  imageW: imageW, imageH: imageH, screenW: screenW,
                                  screenH: screenH, areaW: areaW, areaH: areaH,
                                  random: random, randS: randS)
    }

    func evaluateY(imageX: CGFloat, imageY: CGFloat, imageW: CGFloat, imageH: CGFloat,
                   screenW: CGFloat, screenH: CGFloat, areaW: CGFloat, areaH: CGFloat,
                   random: Int, randS: Int) -> CGFloat {
        return evaluateExpression(yExpression, imageX: imageX, imageY: imageY,
                                  imageW: imageW, imageH: imageH, screenW: screenW,
                                  screenH: screenH, areaW: areaW, areaH: areaH,
                                  random: random, randS: randS)
    }

    private func evaluateExpression(_ expr: String, imageX: CGFloat, imageY: CGFloat,
                                    imageW: CGFloat, imageH: CGFloat, screenW: CGFloat,
                                    screenH: CGFloat, areaW: CGFloat, areaH: CGFloat,
                                    random: Int, randS: Int) -> CGFloat {
        guard !expr.isEmpty else { return 0 }

        var expression = expr

        // Replace variables with values
        expression = expression.replacingOccurrences(of: "screenW", with: "\(screenW)")
        expression = expression.replacingOccurrences(of: "screenH", with: "\(screenH)")
        expression = expression.replacingOccurrences(of: "areaW", with: "\(areaW)")
        expression = expression.replacingOccurrences(of: "areaH", with: "\(areaH)")
        expression = expression.replacingOccurrences(of: "imageX", with: "\(imageX)")
        expression = expression.replacingOccurrences(of: "imageY", with: "\(imageY)")
        expression = expression.replacingOccurrences(of: "imageW", with: "\(imageW)")
        expression = expression.replacingOccurrences(of: "imageH", with: "\(imageH)")
        expression = expression.replacingOccurrences(of: "randS", with: "\(randS)")
        expression = expression.replacingOccurrences(of: "random", with: "\(random)")

        // Validate expression contains only safe characters (numbers, operators, parentheses, decimals, whitespace)
        let safeCharacters = CharacterSet(charactersIn: "0123456789.+-*/() ")
        guard expression.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) else {
            print("Unsafe expression rejected: '\(expr)'")
            return 0
        }

        // Additional validation to prevent crashes
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }

        // Check balanced parentheses
        var parenCount = 0
        for char in trimmed {
            if char == "(" { parenCount += 1 }
            if char == ")" { parenCount -= 1 }
            if parenCount < 0 { return 0 }  // More closing than opening
        }
        guard parenCount == 0 else { return 0 }

        // Check for invalid patterns that would crash NSExpression
        let invalidPatterns = ["++", "--", "**", "//", "+-", "-+", "*+", "/+",
                               "+*", "+/", "-*", "-/", "*/", "/*", "()", "( )"]
        for pattern in invalidPatterns {
            if trimmed.contains(pattern) { return 0 }
        }

        // Check doesn't end with an operator
        if let lastChar = trimmed.last, "+-*/(".contains(lastChar) { return 0 }

        // Check doesn't start with problematic operators (leading minus is OK)
        if let firstChar = trimmed.first, "+*/".contains(firstChar) { return 0 }

        // Evaluate using NSExpression with exception safety
        return evaluateExpressionSafely(trimmed)
    }

    private func evaluateExpressionSafely(_ expression: String) -> CGFloat {
        // NSExpression can throw Objective-C exceptions which aren't caught by Swift try/catch.
        // We use a more defensive approach: validate thoroughly above, and here we just
        // handle the case where expressionValue returns something unexpected.
        let nsExpr: NSExpression
        nsExpr = NSExpression(format: expression)

        guard let result = nsExpr.expressionValue(with: nil, context: nil) as? NSNumber else {
            return 0
        }

        let value = result.doubleValue
        // Guard against infinity/NaN from division by zero
        guard value.isFinite else { return 0 }

        return CGFloat(value)
    }
}

// Represents either a static repeat count or a dynamic expression
enum RepeatValue {
    case fixed(Int)
    case random(divisor: Int, offset: Int) // random/divisor+offset
    case randomMultiplied(multiplier: Int) // random*multiplier

    func evaluate() -> Int {
        switch self {
        case .fixed(let value):
            return value
        case .random(let divisor, let offset):
            // random 0-99 divided by divisor, plus offset
            return Int.random(in: 0...99) / divisor + offset
        case .randomMultiplied(let multiplier):
            return Int.random(in: 0...99) * multiplier
        }
    }

    static func parse(_ string: String) -> RepeatValue {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Check for "random/N+M" pattern
        if trimmed.hasPrefix("random/") {
            let rest = String(trimmed.dropFirst(7)) // Remove "random/"
            if let plusIndex = rest.firstIndex(of: "+") {
                let divisorStr = String(rest[..<plusIndex])
                let offsetStr = String(rest[rest.index(after: plusIndex)...])
                if let divisor = Int(divisorStr), let offset = Int(offsetStr) {
                    return .random(divisor: divisor, offset: offset)
                }
            } else if let divisor = Int(rest) {
                return .random(divisor: divisor, offset: 0)
            }
        }

        // Check for "random*N" pattern
        if trimmed.hasPrefix("random*") {
            let rest = String(trimmed.dropFirst(7))
            if let multiplier = Int(rest) {
                return .randomMultiplied(multiplier: multiplier)
            }
        }

        // Static value
        if let value = Int(trimmed) {
            return .fixed(value)
        }

        return .fixed(1) // Default
    }
}

// MARK: - XML Parser

class AnimationParser: NSObject, XMLParserDelegate {
    private var animations: [PetAnimation] = []
    private var currentAnimationID = ""
    private var currentAnimationName = ""
    private var currentFrames: [Int] = []
    private var currentElement = ""
    private var currentText = ""
    private var elementStack: [String] = [] // Track nested elements

    // Start block values
    private var startMoveX: CGFloat = 0
    private var startMoveY: CGFloat = 0
    private var startInterval: TimeInterval = 200
    private var startOffsetY: CGFloat = 0

    // End block values
    private var endMoveX: CGFloat = 0
    private var endMoveY: CGFloat = 0
    private var endInterval: TimeInterval = 200
    private var endOffsetY: CGFloat = 0

    // Sequence attributes
    private var repeatValue: RepeatValue = .fixed(1)
    private var repeatFrom: Int = 0

    // Next animation transitions
    private var nextAnimations: [NextAnimation] = []
    private var borderTransitions: [NextAnimation] = []
    private var gravityTransitions: [NextAnimation] = []
    private var currentNextProbability: Int = 0
    private var currentNextOnly: String = "none"

    // Track which block we're in
    private var inStartBlock = false
    private var inEndBlock = false
    private var inSequenceBlock = false
    private var inBorderBlock = false
    private var inGravityBlock = false

    // Image info
    var tilesX = 16
    var tilesY = 11
    var imageData: Data?

    // Child spawns
    var childSpawns: [ChildSpawn] = []
    private var inChildsBlock = false
    private var inChildBlock = false
    private var currentChildAnimationID = ""
    private var currentChildX = ""
    private var currentChildY = ""
    private var currentChildNext = ""

    func parseAnimations(from url: URL) -> [PetAnimation]? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        parser.delegate = self
        parser.parse()
        return animations
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        elementStack.append(elementName)
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "animation":
            currentAnimationID = attributeDict["id"] ?? ""
            currentAnimationName = ""
            currentFrames = []
            startMoveX = 0
            startMoveY = 0
            endMoveX = 0
            endMoveY = 0
            startInterval = 200
            endInterval = 200
            startOffsetY = 0
            endOffsetY = 0
            repeatValue = .fixed(1)
            repeatFrom = 0
            nextAnimations = []
            borderTransitions = []
            gravityTransitions = []

        case "start":
            inStartBlock = true
            inEndBlock = false

        case "end":
            inEndBlock = true
            inStartBlock = false

        case "sequence":
            inSequenceBlock = true
            // Parse repeat and repeatfrom attributes
            if let repeatStr = attributeDict["repeat"] {
                repeatValue = RepeatValue.parse(repeatStr)
            }
            if let repeatFromStr = attributeDict["repeatfrom"], let rf = Int(repeatFromStr) {
                repeatFrom = rf
            }

        case "next":
            // Parse next animation transition
            currentNextProbability = Int(attributeDict["probability"] ?? "0") ?? 0
            currentNextOnly = attributeDict["only"] ?? "none"

        case "border":
            inBorderBlock = true

        case "gravity":
            inGravityBlock = true

        case "childs":
            inChildsBlock = true

        case "child":
            if inChildsBlock {
                inChildBlock = true
                currentChildAnimationID = attributeDict["animationid"] ?? ""
                currentChildX = ""
                currentChildY = ""
                currentChildNext = ""
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "name":
            currentAnimationName = currentText

        case "tilesx":
            tilesX = Int(currentText) ?? 16

        case "tilesy":
            tilesY = Int(currentText) ?? 11

        case "png":
            if let data = Data(base64Encoded: currentText) {
                imageData = data
            }

        case "interval":
            let value = TimeInterval(Double(currentText) ?? 200)
            if inStartBlock {
                startInterval = value
            } else if inEndBlock {
                endInterval = value
            } else {
                // Interval outside start/end block - use for both
                startInterval = value
                endInterval = value
            }

        case "offsety":
            let value = CGFloat(Double(currentText) ?? 0)
            if inStartBlock {
                startOffsetY = value
            } else if inEndBlock {
                endOffsetY = value
            }

        case "frame":
            if let frameNum = Int(currentText) {
                currentFrames.append(frameNum)
            }

        case "next":
            if inChildBlock {
                currentChildNext = currentText
            } else if !currentText.isEmpty {
                let next = NextAnimation(
                    animationID: currentText,
                    probability: currentNextProbability,
                    only: currentNextOnly
                )
                // Store in appropriate array based on current block
                if inBorderBlock {
                    borderTransitions.append(next)
                } else if inGravityBlock {
                    gravityTransitions.append(next)
                } else if inSequenceBlock {
                    nextAnimations.append(next)
                }
            }

        case "start":
            inStartBlock = false

        case "end":
            inEndBlock = false

        case "sequence":
            inSequenceBlock = false

        case "border":
            inBorderBlock = false

        case "gravity":
            inGravityBlock = false

        case "animation":
            if !currentAnimationID.isEmpty && !currentFrames.isEmpty {
                // If end values weren't specified, use start values
                let finalEndMoveX = endMoveX == 0 && startMoveX != 0 ? startMoveX : endMoveX
                let finalEndMoveY = endMoveY == 0 && startMoveY != 0 ? startMoveY : endMoveY
                let finalEndInterval = endInterval == 200 && startInterval != 200 ? startInterval : endInterval

                let animation = PetAnimation(
                    id: currentAnimationID,
                    name: currentAnimationName,
                    frames: currentFrames,
                    startInterval: startInterval / 1000.0,
                    endInterval: finalEndInterval / 1000.0,
                    repeatCount: repeatValue,
                    repeatFrom: repeatFrom,
                    offsetY: startOffsetY,
                    startMoveX: startMoveX,
                    startMoveY: startMoveY,
                    endMoveX: finalEndMoveX,
                    endMoveY: finalEndMoveY,
                    nextAnimations: nextAnimations,
                    borderTransitions: borderTransitions,
                    gravityTransitions: gravityTransitions
                )
                animations.append(animation)
            }

        case "childs":
            inChildsBlock = false

        case "child":
            if inChildBlock && !currentChildAnimationID.isEmpty && !currentChildNext.isEmpty {
                let childSpawn = ChildSpawn(
                    parentAnimationID: currentChildAnimationID,
                    xExpression: currentChildX,
                    yExpression: currentChildY,
                    nextAnimationID: currentChildNext
                )
                childSpawns.append(childSpawn)
            }
            inChildBlock = false

        case "x":
            if inChildBlock {
                currentChildX = currentText
            } else {
                let value = CGFloat(Double(currentText) ?? 0)
                if inStartBlock {
                    startMoveX = value
                } else if inEndBlock {
                    endMoveX = value
                }
            }

        case "y":
            if inChildBlock {
                currentChildY = currentText
            } else {
                let value = CGFloat(Double(currentText) ?? 0)
                if inStartBlock {
                    startMoveY = value
                } else if inEndBlock {
                    endMoveY = value
                }
            }

        default:
            break
        }

        elementStack.removeLast()
        currentText = ""
    }
}
