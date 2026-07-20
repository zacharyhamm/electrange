//
//  ChatBubblePanelHosting.swift
//  electragne
//
//  The NSPanel side of the chat bubble: panel construction, placement and
//  sizing, mouse monitors, and window observers. Streaming/persistence
//  orchestration stays in ChatBubbleWindowController.swift.
//

import AppKit
import SwiftUI

final class ChatBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension ChatBubbleWindowController {
    func reposition() {
        guard let panel, let petWindow else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(petWindow.frame) })
            ?? petWindow.screen
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        // Cap the bubble so it fits on screen with the pet below it, and
        // shrink it now if it's already past the cap (setContentSize is not
        // constrained by maxSize; only user resizing is).
        let maxSize = ChatBubblePlacement.maxSize(
            petFrame: petWindow.frame,
            visibleFrame: visibleFrame
        )
        panel.maxSize = maxSize
        if panel.frame.width > maxSize.width || panel.frame.height > maxSize.height {
            panel.setContentSize(CGSize(
                width: min(panel.frame.width, maxSize.width),
                height: min(panel.frame.height, maxSize.height)
            ))
        }

        let placement = ChatBubblePlacement.calculate(
            petFrame: petWindow.frame,
            visibleFrame: visibleFrame,
            bubbleSize: panel.frame.size
        )
        model.tailEdge = placement.tailEdge
        model.tailOffset = placement.tailOffset
        panel.setFrameOrigin(placement.origin)
    }

    private static let savedWidthKey = "chatBubbleExpandedWidth"
    private static let savedHeightKey = "chatBubbleExpandedHeight"

    /// The expanded size, honoring whatever size the user last dragged the
    /// bubble to.
    private var expandedSize: CGSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: Self.savedWidthKey)
        let height = defaults.double(forKey: Self.savedHeightKey)
        guard width >= ChatBubblePlacement.minPanelSize.width,
              height >= ChatBubblePlacement.minPanelSize.height else {
            return ChatBubblePlacement.expandedSize
        }
        return CGSize(width: width, height: height)
    }

    private func persistPanelSize() {
        guard let panel else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(panel.frame.width), forKey: Self.savedWidthKey)
        defaults.set(Double(panel.frame.height), forKey: Self.savedHeightKey)
    }

    func setExpanded(_ expanded: Bool) {
        guard let panel else { return }
        let size = expanded ? expandedSize : ChatBubblePlacement.defaultSize
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
        reposition()
    }

    func makePanel(rootView: ChatBubbleView) -> ChatBubblePanel {
        let panel = ChatBubblePanel(
            contentRect: CGRect(origin: .zero, size: ChatBubblePlacement.defaultSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = ChatBubblePlacement.minPanelSize
        panel.maxSize = ChatBubblePlacement.maxPanelSize
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        PetWindowPresentation.enforce(on: panel)
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: rootView)
        return panel
    }

    func installEventMonitors() {
        removeEventMonitors()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss(notify: true)
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            // The bubble handles its own controls. The pet handles a second
            // click itself, avoiding a dismiss-then-reopen race in this monitor.
            if event.window === self.panel || event.window === self.petWindow {
                return event
            }
            DispatchQueue.main.async {
                self.dismiss(notify: true)
            }
            return event
        }
    }

    func removeEventMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    func installWindowObservers(for window: NSWindow) {
        removeWindowObservers()
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let observer = center.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in self?.reposition()
            }
            windowObservers.append(observer)
        }
        let screenObserver = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }
        windowObservers.append(screenObserver)

        // After the user drags the bubble to a new size, remember it and
        // re-anchor so the tail points back at the pet.
        if let panel {
            let resizeObserver = center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                self?.persistPanelSize()
                self?.reposition()
            }
            windowObservers.append(resizeObserver)
        }
    }

    func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }
}
