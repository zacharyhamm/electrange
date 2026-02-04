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

    /// Get current dock information by finding the Dock application's window.
    /// Returns nil if dock is hidden or not detectable.
    func getDockInfo() -> DockInfo? {
        guard let screen = NSScreen.main else { return nil }

        // First, determine dock position from screen geometry
        let position = inferDockPosition(screen: screen)

        // Try to find the actual Dock window bounds (requires Screen Recording permission)
        if let dockFrame = findDockWindowFrame(screen: screen) {
            return DockInfo(position: position, frame: dockFrame)
        }

        // Fallback: estimate dock bounds based on screen geometry
        // CGWindowList doesn't work in sandboxed apps without Screen Recording permission
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
            let dockX = (fullFrame.width - estimatedWidth) / 2

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
            let dockY = (fullFrame.height - estimatedHeight) / 2

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
            let dockY = (fullFrame.height - estimatedHeight) / 2

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

    /// Find the Dock application's window frame using CGWindowList
    /// Note: This requires Screen Recording permission in sandboxed apps
    private func findDockWindowFrame(screen: NSScreen) -> NSRect? {
        // Get list of all windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let screenHeight = screen.frame.height
        let screenWidth = screen.frame.width
        var bestDockFrame: NSRect? = nil
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
            let flippedY = screenHeight - y - height

            // Skip tiny windows (dock has indicator windows, tooltips, etc.)
            let area = width * height
            if area < 1000 {
                continue
            }

            // IMPORTANT: Skip windows that span the full screen width or height
            // These are likely desktop/background layers, not the actual dock bar
            if width >= screenWidth - 10 || height >= screenHeight - 10 {
                continue
            }

            // For bottom dock: should be wide and short, near Y=0
            if width > height && flippedY < 10 && area > bestDockArea {
                bestDockFrame = NSRect(x: x, y: 0, width: width, height: height)
                bestDockArea = area
            }

            // For left dock: should be tall and narrow, near X=0
            if height > width && x < 10 && area > bestDockArea {
                bestDockFrame = NSRect(x: 0, y: flippedY, width: width, height: height)
                bestDockArea = area
            }

            // For right dock: should be tall and narrow, near right edge
            if height > width && x + width > screenWidth - 10 && area > bestDockArea {
                bestDockFrame = NSRect(x: x, y: flippedY, width: width, height: height)
                bestDockArea = area
            }
        }

        return bestDockFrame
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


    /// Get the dock's position, or .bottom as default if not detectable
    func getDockPosition() -> DockPosition {
        return getDockInfo()?.position ?? .bottom
    }

    /// Check if the dock appears to be hidden (no visible dock space)
    func isDockHidden() -> Bool {
        return getDockInfo() == nil
    }
}
