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

        let placement = ChatBubblePlacement.calculate(
            petFrame: petWindow.frame,
            visibleFrame: visibleFrame,
            bubbleSize: panel.frame.size
        )
        let maximumSize = ChatBubblePlacement.maxSize(
            petFrame: petWindow.frame,
            visibleFrame: visibleFrame
        )
        let minimumWidth = ChatBubblePlacement.minPanelSize.width
            + (model.terminalView == nil ? 0 : ChatBubblePlacement.terminalLayoutSpacing)
        panel.minSize = CGSize(
            width: min(minimumWidth, maximumSize.width),
            height: min(ChatBubblePlacement.minPanelSize.height, maximumSize.height)
        )
        panel.maxSize = maximumSize
        if panel.frame.size != placement.size {
            panel.setContentSize(placement.size)
        }
        model.terminalWidth = model.terminalView == nil
            ? 0
            : ChatBubblePlacement.terminalWidth(
                panelWidth: placement.size.width,
                chatWidth: expandedSize.width
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
        guard width > 0, height > 0 else {
            return ChatBubblePlacement.expandedSize
        }
        return CGSize(width: width, height: height)
    }

    /// Persists the *chat column* size: the terminal column's width (if one
    /// is showing) is excluded so reopening without a terminal isn't wide.
    private func persistPanelSize() {
        guard let panel else { return }
        let defaults = UserDefaults.standard
        let terminalSpacing = model.terminalView == nil ? 0 : ChatBubblePlacement.terminalLayoutSpacing
        defaults.set(
            Double(panel.frame.width - model.terminalWidth - terminalSpacing),
            forKey: Self.savedWidthKey
        )
        defaults.set(Double(panel.frame.height), forKey: Self.savedHeightKey)
        if model.terminalView != nil {
            rememberTerminalWidth(model.terminalWidth, for: currentChatID)
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard let panel else { return }
        var size = expanded ? expandedSize : ChatBubblePlacement.defaultSize
        model.terminalWidth = model.terminalView == nil
            ? 0
            : terminalWidth(for: currentChatID, initialHeight: size.height)
        if model.terminalView != nil {
            size.width += model.terminalWidth + ChatBubblePlacement.terminalLayoutSpacing
        }
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
            let liveResizeObserver = center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                self?.reposition()
            }
            windowObservers.append(liveResizeObserver)

            let resizeObserver = center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.reposition()
                self.persistPanelSize()
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
