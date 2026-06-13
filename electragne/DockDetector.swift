//
//  DockDetector.swift
//  electragne
//
//  Created by Claude on 2/4/26.
//

import AppKit
import CoreGraphics

// MARK: - Dock Position

enum DockPosition {
    case bottom
    case left
    case right
}

// MARK: - Dock Info

struct DockInfo {
    let position: DockPosition
    let frame: NSRect

    /// The Y coordinate of the top of the dock (for bottom dock)
    /// or the X coordinate of the inner edge (for left/right dock)
    var topEdge: CGFloat {
        switch position {
        case .bottom: return frame.maxY
        case .left: return frame.maxX
        case .right: return frame.minX
        }
    }

    /// Check if a point is within the dock's horizontal bounds (for bottom dock)
    func containsX(_ x: CGFloat, petWidth: CGFloat) -> Bool {
        switch position {
        case .bottom:
            return x + petWidth > frame.minX && x < frame.maxX
        case .left, .right:
            return false
        }
    }
}

// MARK: - Dock Detector

/// Detects macOS Dock position and size using CGWindowList to find the actual Dock window.
class DockDetector {
    static let shared = DockDetector()

    private init() {}

    // Cache so the 60Hz physics/movement timers don't hit
    // CGWindowListCopyWindowInfo (an expensive syscall) on every tick.
    // Keyed by screen frame since the pet asks about the screen it's on.
    private var cache = TimedCache<NSRect, DockInfo?>(lifetime: 1.0)

    /// Get dock information for the given screen by finding the Dock
    /// application's window there. Returns nil if the dock is hidden, not
    /// detectable, or lives on a different screen.
    /// The result is cached for a second; call from the main thread.
    func getDockInfo(for screen: NSScreen) -> DockInfo? {
        let now = ProcessInfo.processInfo.systemUptime
        if let hit = cache.cached(for: screen.frame, now: now) {
            return hit
        }

        let info = computeDockInfo(for: screen)
        cache.store(info, for: screen.frame, now: now)
        return info
    }

    private func computeDockInfo(for screen: NSScreen) -> DockInfo? {
        // Try to find the actual Dock window bounds (requires Screen Recording permission)
        if let (dockFrame, position) = findDockWindowFrame(on: screen) {
            return DockInfo(position: position, frame: dockFrame)
        }

        // Fallback: estimate dock bounds based on screen geometry
        // CGWindowList doesn't work in sandboxed apps without Screen Recording permission
        let position = inferDockPosition(screen: screen)
        return estimateDockBounds(screen: screen, position: position)
    }

    /// Estimate dock bounds when we can't read the actual window
    /// Uses the dock height and estimates width based on typical icon counts
    private func estimateDockBounds(screen: NSScreen, position: DockPosition) -> DockInfo? {
        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        switch position {
        case .bottom:
            let dockHeight = visibleFrame.origin.y - fullFrame.origin.y
            guard dockHeight > 10 else { return nil }

            // Estimate dock width conservatively
            // Dock icons are roughly square, estimate ~10 icons
            // This tends to underestimate rather than overestimate
            let estimatedIconSize = dockHeight * 0.75
            let estimatedIconCount: CGFloat = 10
            let estimatedWidth = min(
                estimatedIconSize * estimatedIconCount,
                fullFrame.width * 0.4  // cap at 40% of screen width
            )

            // Center the dock on screen
            let dockX = fullFrame.origin.x + (fullFrame.width - estimatedWidth) / 2

            return DockInfo(
                position: .bottom,
                frame: NSRect(
                    x: dockX,
                    y: fullFrame.origin.y,
                    width: estimatedWidth,
                    height: dockHeight
                )
            )

        case .left:
            let dockWidth = visibleFrame.origin.x - fullFrame.origin.x
            guard dockWidth > 10 else { return nil }

            let estimatedIconSize = dockWidth * 0.75
            let estimatedIconCount: CGFloat = 10
            let estimatedHeight = min(
                estimatedIconSize * estimatedIconCount,
                fullFrame.height * 0.4
            )
            let dockY = fullFrame.origin.y + (fullFrame.height - estimatedHeight) / 2

            return DockInfo(
                position: .left,
                frame: NSRect(
                    x: fullFrame.origin.x,
                    y: dockY,
                    width: dockWidth,
                    height: estimatedHeight
                )
            )

        case .right:
            let dockWidth = fullFrame.maxX - visibleFrame.maxX
            guard dockWidth > 10 else { return nil }

            let estimatedIconSize = dockWidth * 0.75
            let estimatedIconCount: CGFloat = 10
            let estimatedHeight = min(
                estimatedIconSize * estimatedIconCount,
                fullFrame.height * 0.4
            )
            let dockY = fullFrame.origin.y + (fullFrame.height - estimatedHeight) / 2

            return DockInfo(
                position: .right,
                frame: NSRect(
                    x: visibleFrame.maxX,
                    y: dockY,
                    width: dockWidth,
                    height: estimatedHeight
                )
            )
        }
    }

    /// Find the Dock application's window frame on the given screen using CGWindowList
    /// Note: This requires Screen Recording permission in sandboxed apps
    private func findDockWindowFrame(on screen: NSScreen) -> (NSRect, DockPosition)? {
        // Get list of all windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // CGWindowList y values are measured down from the top-left of the
        // *primary* screen (the one at NSScreen origin (0,0)), regardless of
        // which screen the window is on
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let screenFrame = screen.frame
        var best: (NSRect, DockPosition)? = nil
        var bestDockArea: CGFloat = 0

        // Find the Dock windows and pick the main bar (largest one at screen edge)
        for windowInfo in windowList {
            guard let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
                  ownerName == "Dock",
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }

            // CGWindowList uses top-left origin, convert to bottom-left (NSScreen coordinates)
            let flippedY = ScreenGeometry.cocoaY(quartzY: y, height: height, primaryMaxY: primaryMaxY)
            let windowFrame = NSRect(x: x, y: flippedY, width: width, height: height)

            // Skip tiny windows (dock has indicator windows, tooltips, etc.)
            let area = width * height
            if area < 1000 {
                continue
            }

            // Only consider dock windows on the screen the pet is on
            if !screenFrame.intersects(windowFrame) {
                continue
            }

            // IMPORTANT: Skip windows that span the full screen width or height
            // These are likely desktop/background layers, not the actual dock bar
            if width >= screenFrame.width - 10 || height >= screenFrame.height - 10 {
                continue
            }

            // For bottom dock: should be wide and short, near the screen's bottom edge
            if width > height && abs(flippedY - screenFrame.minY) < 10 && area > bestDockArea {
                best = (NSRect(x: x, y: screenFrame.minY, width: width, height: height), .bottom)
                bestDockArea = area
            }

            // For left dock: should be tall and narrow, near the screen's left edge
            if height > width && abs(x - screenFrame.minX) < 10 && area > bestDockArea {
                best = (NSRect(x: screenFrame.minX, y: flippedY, width: width, height: height), .left)
                bestDockArea = area
            }

            // For right dock: should be tall and narrow, near the screen's right edge
            if height > width && x + width > screenFrame.maxX - 10 && area > bestDockArea {
                best = (windowFrame, .right)
                bestDockArea = area
            }
        }

        return best
    }

    /// Infer dock position from screen geometry
    private func inferDockPosition(screen: NSScreen) -> DockPosition {
        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        let bottomDiff = visibleFrame.origin.y - fullFrame.origin.y
        let leftDiff = visibleFrame.origin.x - fullFrame.origin.x
        let rightDiff = fullFrame.maxX - visibleFrame.maxX

        if bottomDiff >= leftDiff && bottomDiff >= rightDiff && bottomDiff > 0 {
            return .bottom
        } else if leftDiff > rightDiff && leftDiff > 0 {
            return .left
        } else if rightDiff > 0 {
            return .right
        }

        return .bottom
    }
}
