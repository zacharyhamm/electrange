//
//  AnimationParser.swift
//  electragne
//
//  Created by zacharyhamm on 2/4/26.
//

import Foundation
import AppKit
import os

// MARK: - Animation Models

nonisolated struct PetAnimation: Identifiable {
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
}

nonisolated struct NextAnimation {
    let animationID: String
    let probability: Int // 1-100 weight
    let only: String // "none", "taskbar", etc.
}

// Child spawn definition - spawns a separate window when parent animation plays
nonisolated struct ChildSpawn {
    let parentAnimationID: String  // Animation that triggers the spawn
    let xExpression: String        // Position expression (e.g., "imageX-imageW*0.9")
    let yExpression: String
    let nextAnimationID: String    // Animation for the child to play

    /// Evaluate the position expressions against the spawn variables the
    /// caller assembled ("imageX", "imageW", "screenW", "random", ...).
    func x(variables: [String: Double]) -> CGFloat {
        evaluate(xExpression, variables: variables)
    }

    func y(variables: [String: Double]) -> CGFloat {
        evaluate(yExpression, variables: variables)
    }

    private func evaluate(_ expr: String, variables: [String: Double]) -> CGFloat {
        guard !expr.isEmpty else { return 0 }
        guard let value = ExpressionEvaluator.evaluate(expr, variables: variables),
              value.isFinite else {
            Log.animation.error("Could not evaluate expression: \(expr, privacy: .public)")
            return 0
        }
        return CGFloat(value)
    }
}

// Represents either a static repeat count or a dynamic expression
nonisolated enum RepeatValue {
    case fixed(Int)
    case random(divisor: Int, offset: Int) // random/divisor+offset
    case randomMultiplied(multiplier: Int) // random*multiplier
    case expression(String) // Arbitrary arithmetic, e.g. "(screenW/2)/30-6"

    // Upper bound keeps a bad value from overflowing downstream frame-count math
    private static let maxRepeatCount = 100_000

    // Reads NSScreen/UserDefaults, so this one member stays main-actor.
    @MainActor func evaluate() -> Int {
        let value: Int
        switch self {
        case .fixed(let fixed):
            value = fixed
        case .random(let divisor, let offset):
            // random 0-99 divided by divisor, plus offset
            guard divisor > 0 else { return Swift.max(0, offset) }
            let (sum, overflow) = (Int.random(in: 0...99) / divisor).addingReportingOverflow(offset)
            value = overflow ? Self.maxRepeatCount : sum
        case .randomMultiplied(let multiplier):
            let (product, overflow) = Int.random(in: 0...99).multipliedReportingOverflow(by: multiplier)
            value = overflow ? Self.maxRepeatCount : product
        case .expression(let expr):
            value = Self.evaluateRepeatExpression(expr)
        }
        return Swift.min(Swift.max(0, value), Self.maxRepeatCount)
    }

    @MainActor private static func evaluateRepeatExpression(_ expr: String) -> Int {
        // Translate desktopPet's C# "Convert(x,System.Int32)" int-cast into plain parentheses
        var translated = expr.replacingOccurrences(of: "Convert(", with: "(")
        translated = translated.replacingOccurrences(of: ",System.Int32)", with: ")")
        translated = translated.replacingOccurrences(of: ", System.Int32)", with: ")")

        let screenFrame = NSScreen.main?.frame ?? .zero
        let visibleFrame = NSScreen.main?.visibleFrame ?? .zero
        let storedSize = UserDefaults.standard.double(forKey: PetSizeConstants.storageKey)
        let petSize = storedSize > 0 ? storedSize : PetSizeConstants.defaultSize

        let variables: [String: Double] = [
            "screenW": screenFrame.width,
            "screenH": screenFrame.height,
            "areaW": visibleFrame.width,
            "areaH": visibleFrame.height,
            "imageW": petSize,
            "imageH": petSize,
            "imageX": 0,
            "imageY": 0,
            "random": Double(Int.random(in: 0...99)),
            "randS": Double(Int.random(in: 0...99)),
        ]

        guard let value = ExpressionEvaluator.evaluate(translated, variables: variables),
              value.isFinite else {
            return 1 // Matches the previous default for unparseable repeat values
        }
        // Clamp before converting: Int(_:) traps on out-of-range doubles
        return Int(Swift.min(Swift.max(value, 0), Double(maxRepeatCount)))
    }

    static func parse(_ string: String) -> RepeatValue {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Check for "random/N+M" pattern
        if trimmed.hasPrefix("random/") {
            let rest = String(trimmed.dropFirst(7)) // Remove "random/"
            if let plusIndex = rest.firstIndex(of: "+") {
                let divisorStr = String(rest[..<plusIndex])
                let offsetStr = String(rest[rest.index(after: plusIndex)...])
                if let divisor = Int(divisorStr), divisor > 0, let offset = Int(offsetStr) {
                    return .random(divisor: divisor, offset: offset)
                }
            } else if let divisor = Int(rest), divisor > 0 {
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

        // Anything else ("10+random/10", "(screenW/2)/30-6", ...) is evaluated
        // as an arithmetic expression each time the animation plays
        guard !trimmed.isEmpty else { return .fixed(1) }
        return .expression(trimmed)
    }
}

// MARK: - XML Parser

nonisolated class AnimationParser: NSObject, XMLParserDelegate {
    private var animations: [PetAnimation] = []
    private var currentAnimationID = ""
    private var currentAnimationName = ""
    private var currentFrames: [Int] = []
    private var currentElement = ""
    private var currentText = ""

    // Start block values
    private var startMoveX: CGFloat = 0
    private var startMoveY: CGFloat = 0
    private var startInterval: TimeInterval = 200
    private var startOffsetY: CGFloat = 0

    // End block values
    private var endMoveX: CGFloat = 0
    private var endMoveY: CGFloat = 0
    private var endInterval: TimeInterval = 200

    // Sequence attributes
    private var repeatValue: RepeatValue = .fixed(1)
    private var repeatFrom: Int = 0

    // Next animation transitions
    private var nextAnimations: [NextAnimation] = []
    private var currentNextProbability: Int = 0
    private var currentNextOnly: String = "none"

    // Track which block we're in
    private var inStartBlock = false
    private var inEndBlock = false
    private var inSequenceBlock = false

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
            repeatValue = .fixed(1)
            repeatFrom = 0
            nextAnimations = []

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
            if inStartBlock {
                startOffsetY = CGFloat(Double(currentText) ?? 0)
            }

        case "frame":
            if let frameNum = Int(currentText) {
                currentFrames.append(frameNum)
            }

        case "next":
            if inChildBlock {
                currentChildNext = currentText
            } else if !currentText.isEmpty {
                // Border/gravity-block transitions are parsed past but unused
                if inSequenceBlock {
                    nextAnimations.append(NextAnimation(
                        animationID: currentText,
                        probability: currentNextProbability,
                        only: currentNextOnly
                    ))
                }
            }

        case "start":
            inStartBlock = false

        case "end":
            inEndBlock = false

        case "sequence":
            inSequenceBlock = false

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
                    repeatFrom: min(max(0, repeatFrom), currentFrames.count - 1),
                    offsetY: startOffsetY,
                    startMoveX: startMoveX,
                    startMoveY: startMoveY,
                    endMoveX: finalEndMoveX,
                    endMoveY: finalEndMoveY,
                    nextAnimations: nextAnimations
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

        currentText = ""
    }
}
