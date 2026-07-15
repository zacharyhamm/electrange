//
//  AnimationID.swift
//  electragne
//

import Foundation

/// Type-safe animation identifiers to replace magic strings
enum AnimationID: String {
    // Basic movements
    case walk = "1"
    case rotate1a = "2"
    case rotate1b = "3"
    case drag = "4"
    case fall = "5"

    // Landing
    case fallSoft = "9"
    case fallHard = "10"

    // Behaviors
    case piss = "11"
    case pissEnd = "12"

    // Sleep sequence
    case sleep1 = "15"
    case sleep2 = "16"
    case sleep3 = "17"
    case sleep4 = "18"
    case sleep5 = "19"
    case sleep6 = "20"

    // Actions
    case jump = "25"
    case eat = "26"
    case flower = "27"

    // Running
    case runBegin = "35"

    // Window climbing
    case verticalWalkUp = "37"
    case verticalWalkOver = "42"

    // Dock animations
    case lookDown = "43"
    case jumpDown = "44"
    case jumpDown2 = "45"
    case jumpDown3 = "46"
    case walkTask2 = "50"

    /// Sleep animation sequence in order
    static let sleepSequence: [AnimationID] = [.sleep1, .sleep2, .sleep3, .sleep4, .sleep5, .sleep6]
}
