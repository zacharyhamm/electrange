//
//  Logging.swift
//  electragne
//
//  Centralized os.Logger instances. Use these instead of print() so output is
//  leveled, structured, and filterable in Console.app / `log stream`:
//    log stream --predicate 'subsystem == "org.impolexg.electragne"'
//

import os

nonisolated enum Log {
    /// Matches PRODUCT_BUNDLE_IDENTIFIER so logs are filterable by subsystem.
    private static let subsystem = "org.impolexg.electragne"

    /// Animation parsing and playback (AnimationParser, AnimationManager).
    static let animation = Logger(subsystem: subsystem, category: "animation")
    /// Sprite-sheet frame extraction (SpriteRenderer).
    static let rendering = Logger(subsystem: subsystem, category: "rendering")
    /// App/window/screen lifecycle (PetViewModel, AppDelegate).
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    /// Movement / dock / physics tracing.
    static let physics = Logger(subsystem: subsystem, category: "physics")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
    /// MCP server connections and OAuth (MCPServerManager, MCPOAuth).
    static let mcp = Logger(subsystem: subsystem, category: "mcp")
}
