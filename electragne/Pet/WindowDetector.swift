//
//  WindowDetector.swift
//  electragne
//
//  Created by Claude on 6/11/26.
//

import AppKit
import CoreGraphics

// MARK: - Window Surface

/// A normal app window the pet could climb and walk on
nonisolated struct WindowSurface: Equatable {
    let id: CGWindowID
    let frame: NSRect
}

// MARK: - Window Detector

/// Finds other apps' windows using CGWindowList, so the pet can climb their
/// sides and walk along their tops. Like DockDetector, results are cached so
/// the 60Hz movement timers don't hit CGWindowListCopyWindowInfo every tick.
class WindowDetector {
    static let shared = WindowDetector()

    private init() {}

    // Full window list cache (per screen)
    private var listCache = TimedCache<NSRect, [WindowSurface]>(lifetime: 1.0)

    // Single-window cache: refreshed faster than the list so the pet can
    // ride a window that's being dragged without lagging too far behind
    private var frameCache = TimedCache<CGWindowID, NSRect?>(lifetime: 0.15)

    // Ignore tiny helper/utility windows apps create at the normal level
    private static let minimumWindowSize: CGFloat = 50

    /// Normal-level app windows currently on the given screen, frontmost
    /// first, in NSScreen (bottom-left origin) coordinates.
    func windows(on screen: NSScreen) -> [WindowSurface] {
        let now = ProcessInfo.processInfo.systemUptime
        if let hit = listCache.cached(for: screen.frame, now: now) {
            return hit
        }

        var result: [WindowSurface] = []
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)

        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in windowList {
                guard (info[kCGWindowLayer as String] as? Int) == 0,  // normal app windows only
                      (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0,
                      (info[kCGWindowOwnerPID as String] as? Int) != myPID,
                      let idNumber = info[kCGWindowNumber as String] as? Int,
                      let frame = Self.cocoaFrame(from: info) else {
                    continue
                }

                guard frame.width >= Self.minimumWindowSize,
                      frame.height >= Self.minimumWindowSize,
                      screen.frame.intersects(frame) else {
                    continue
                }

                result.append(WindowSurface(id: CGWindowID(idNumber), frame: frame))
            }
        }

        listCache.store(result, for: screen.frame, now: now)
        return result
    }

    /// Current frame of a specific window, or nil if it's gone, minimized,
    /// or hidden. Used to track the window the pet is climbing/standing on.
    func frame(ofWindow id: CGWindowID) -> NSRect? {
        let now = ProcessInfo.processInfo.systemUptime
        if let hit = frameCache.cached(for: id, now: now) {
            return hit
        }

        var result: NSRect? = nil
        if let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
           let info = windowList.first,
           (info[kCGWindowIsOnscreen as String] as? Bool) == true,
           (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0 {
            result = Self.cocoaFrame(from: info)
        }

        frameCache.store(result, for: id, now: now)
        return result
    }

    /// Convert a CGWindowList bounds dictionary to NSScreen coordinates.
    /// CGWindowList y values are measured down from the top-left of the
    /// primary screen, regardless of which screen the window is on.
    private static func cocoaFrame(from info: [String: Any]) -> NSRect? {
        guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"],
              let y = bounds["Y"],
              let width = bounds["Width"],
              let height = bounds["Height"] else {
            return nil
        }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return ScreenGeometry.cocoaRect(x: x, quartzY: y, width: width, height: height,
                                        primaryMaxY: primaryMaxY)
    }
}
