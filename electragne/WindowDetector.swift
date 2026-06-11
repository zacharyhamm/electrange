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
struct WindowSurface {
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
    private var cachedList: [WindowSurface] = []
    private var cachedListScreenFrame: NSRect = .zero
    private var listTimestamp: TimeInterval = 0
    private static let listCacheLifetime: TimeInterval = 1.0

    // Single-window cache: refreshed faster than the list so the pet can
    // ride a window that's being dragged without lagging too far behind
    private var cachedFrame: NSRect?
    private var cachedFrameID: CGWindowID = 0
    private var frameTimestamp: TimeInterval = 0
    private static let frameCacheLifetime: TimeInterval = 0.15

    // Ignore tiny helper/utility windows apps create at the normal level
    private static let minimumWindowSize: CGFloat = 50

    /// Normal-level app windows currently on the given screen, frontmost
    /// first, in NSScreen (bottom-left origin) coordinates.
    func windows(on screen: NSScreen) -> [WindowSurface] {
        let now = ProcessInfo.processInfo.systemUptime
        if now - listTimestamp < Self.listCacheLifetime, cachedListScreenFrame == screen.frame {
            return cachedList
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

        cachedList = result
        cachedListScreenFrame = screen.frame
        listTimestamp = now
        return result
    }

    /// Current frame of a specific window, or nil if it's gone, minimized,
    /// or hidden. Used to track the window the pet is climbing/standing on.
    func frame(ofWindow id: CGWindowID) -> NSRect? {
        let now = ProcessInfo.processInfo.systemUptime
        if cachedFrameID == id, now - frameTimestamp < Self.frameCacheLifetime {
            return cachedFrame
        }

        var result: NSRect? = nil
        if let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
           let info = windowList.first,
           (info[kCGWindowIsOnscreen as String] as? Bool) == true,
           (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0 {
            result = Self.cocoaFrame(from: info)
        }

        cachedFrame = result
        cachedFrameID = id
        frameTimestamp = now
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
        return NSRect(x: x, y: primaryMaxY - y - height, width: width, height: height)
    }
}
