//
//  PetEnvironment.swift
//  electragne
//
//  Environment seams for the pet behavior core.
//

import AppKit
import CoreGraphics
import Foundation

/// Pure screen geometry; movement policies never need to know about NSScreen.
nonisolated struct ScreenInfo: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
}

/// Everything a movement decision can observe at one point in time.
nonisolated struct EnvironmentSnapshot: Equatable {
    var screens: [ScreenInfo]
    var dockInfo: DockInfo?
    var windowSurfaces: [WindowSurface]
    var petFrame: CGRect
}

@MainActor protocol PetEnvironmentSensing: AnyObject {
    func snapshot(includeWindows: Bool) -> EnvironmentSnapshot
}

@MainActor protocol PetSurfaceMoving: AnyObject {
    var frame: CGRect { get }
    func setOrigin(_ point: CGPoint)
}

@MainActor protocol TickScheduling: AnyObject {
    func start(interval: TimeInterval, _ tick: @escaping () -> Void)
    func stop()
    var isRunning: Bool { get }
}

/// Adapts the AppKit window owned by the app shell to the pet core's surface.
@MainActor final class WindowSurfaceAdapter: PetSurfaceMoving {
    weak var window: NSWindow?

    init(window: NSWindow? = nil) {
        self.window = window
    }

    var frame: CGRect { window?.frame ?? .zero }

    func setOrigin(_ point: CGPoint) {
        window?.setFrameOrigin(point)
    }
}

/// Live AppKit/Core Graphics implementation used by the application.
@MainActor final class LiveEnvironment: PetEnvironmentSensing {
    private let surface: PetSurfaceMoving
    private let dockDetector: DockDetector
    private let windowDetector: WindowDetector

    init(
        surface: PetSurfaceMoving,
        dockDetector: DockDetector? = nil,
        windowDetector: WindowDetector? = nil
    ) {
        self.surface = surface
        self.dockDetector = dockDetector ?? .shared
        self.windowDetector = windowDetector ?? .shared
    }

    func snapshot(includeWindows: Bool) -> EnvironmentSnapshot {
        let nativeScreens = NSScreen.screens
        let screens = nativeScreens.map { ScreenInfo(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let petFrame = surface.frame
        let midpoint = CGPoint(x: petFrame.midX, y: petFrame.midY)

        let selectedIndex = nativeScreens.firstIndex(where: { $0.frame.contains(midpoint) })
            ?? ScreenGeometry.screenContaining(
                x: midpoint.x,
                below: .greatestFiniteMagnitude,
                in: nativeScreens.map(\.frame)
            )
            ?? nativeScreens.indices.first

        guard let selectedIndex else {
            return EnvironmentSnapshot(
                screens: screens,
                dockInfo: nil,
                windowSurfaces: [],
                petFrame: petFrame
            )
        }

        let selectedScreen = nativeScreens[selectedIndex]
        return EnvironmentSnapshot(
            screens: screens,
            dockInfo: dockDetector.getDockInfo(for: selectedScreen),
            windowSurfaces: includeWindows ? windowDetector.windows(on: selectedScreen) : [],
            petFrame: petFrame
        )
    }
}
