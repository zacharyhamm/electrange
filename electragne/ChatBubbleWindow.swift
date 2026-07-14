import AppKit
import SwiftUI

enum ChatBubbleTailEdge: Equatable {
    case top
    case bottom
}

/// Pure placement result so screen-edge behavior can be unit tested without a window.
struct ChatBubblePlacement: Equatable {
    static let defaultSize = CGSize(width: 280, height: 122)
    static let screenMargin: CGFloat = 8
    static let petGap: CGFloat = 4

    let origin: CGPoint
    let tailEdge: ChatBubbleTailEdge
    let tailOffset: CGFloat

    static func calculate(
        petFrame: CGRect,
        visibleFrame: CGRect,
        bubbleSize: CGSize = defaultSize
    ) -> ChatBubblePlacement {
        let minX = visibleFrame.minX + screenMargin
        let maxX = visibleFrame.maxX - screenMargin - bubbleSize.width
        let desiredX = petFrame.midX - bubbleSize.width / 2
        let x = maxX >= minX ? min(max(desiredX, minX), maxX) : visibleFrame.minX

        let aboveY = petFrame.maxY + petGap
        let fitsAbove = aboveY + bubbleSize.height <= visibleFrame.maxY - screenMargin
        let tailEdge: ChatBubbleTailEdge = fitsAbove ? .bottom : .top

        let desiredY = fitsAbove
            ? aboveY
            : petFrame.minY - petGap - bubbleSize.height
        let minY = visibleFrame.minY + screenMargin
        let maxY = visibleFrame.maxY - screenMargin - bubbleSize.height
        let y = maxY >= minY ? min(max(desiredY, minY), maxY) : visibleFrame.minY

        let minimumTailOffset: CGFloat = 28
        let tailOffset = min(
            max(petFrame.midX - x, minimumTailOffset),
            bubbleSize.width - minimumTailOffset
        )

        return ChatBubblePlacement(
            origin: CGPoint(x: x, y: y),
            tailEdge: tailEdge,
            tailOffset: tailOffset
        )
    }
}

@Observable
private final class ChatBubbleModel {
    var text = ""
    var tailEdge: ChatBubbleTailEdge = .bottom
    var tailOffset = ChatBubblePlacement.defaultSize.width / 2
}

/// Owns the auxiliary AppKit panel used for chat. Keeping the bubble separate
/// preserves the invariant that the pet window is exactly one pet wide/high.
final class ChatBubbleWindowController {
    private weak var petWindow: NSWindow?
    private var panel: ChatBubblePanel?
    private var model = ChatBubbleModel()
    private var onDismiss: (() -> Void)?

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    func present(
        anchoredTo petWindow: NSWindow,
        onDismiss: @escaping () -> Void,
        onSubmit: @escaping (String) -> Void
    ) {
        self.petWindow = petWindow
        self.onDismiss = onDismiss

        if panel == nil {
            model = ChatBubbleModel()
            let bubbleView = ChatBubbleView(
                model: model,
                onDismiss: { [weak self] in self?.dismiss(notify: true) },
                onSubmit: onSubmit
            )
            let panel = makePanel(rootView: bubbleView)
            self.panel = panel
            installEventMonitors()
            installWindowObservers(for: petWindow)
        }

        reposition()
        panel?.makeKeyAndOrderFront(nil)
    }

    func dismiss(notify: Bool) {
        guard panel != nil else { return }
        let callback = notify ? onDismiss : nil

        removeEventMonitors()
        removeWindowObservers()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        petWindow = nil
        onDismiss = nil

        callback?()
    }

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
        model.tailEdge = placement.tailEdge
        model.tailOffset = placement.tailOffset
        panel.setFrameOrigin(placement.origin)
    }

    private func makePanel(rootView: ChatBubbleView) -> ChatBubblePanel {
        let panel = ChatBubblePanel(
            contentRect: CGRect(origin: .zero, size: ChatBubblePlacement.defaultSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: rootView)
        return panel
    }

    private func installEventMonitors() {
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

    private func removeEventMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func installWindowObservers(for window: NSWindow) {
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
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    deinit {
        removeEventMonitors()
        removeWindowObservers()
    }
}

private final class ChatBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ChatBubbleView: View {
    @Bindable var model: ChatBubbleModel
    let onDismiss: () -> Void
    let onSubmit: (String) -> Void

    @FocusState private var inputIsFocused: Bool

    private var trimmedText: String {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            ChatBubbleShape(edge: model.tailEdge, tailOffset: model.tailOffset)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    ChatBubbleShape(edge: model.tailEdge, tailOffset: model.tailOffset)
                        .stroke(Color.primary.opacity(0.7), lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(0.16), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text("What can I help with?")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close chat")
                }

                HStack(spacing: 8) {
                    TextField("Ask me anything…", text: $model.text)
                        .textFieldStyle(.roundedBorder)
                        .focused($inputIsFocused)
                        .onSubmit(submit)

                    Button(action: submit) {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedText.isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.top, model.tailEdge == .top ? 19 : 12)
            .padding(.bottom, model.tailEdge == .bottom ? 19 : 12)
            .padding(.horizontal, 14)
        }
        .onExitCommand(perform: onDismiss)
        .onAppear {
            DispatchQueue.main.async {
                inputIsFocused = true
            }
        }
    }

    private func submit() {
        guard !trimmedText.isEmpty else { return }
        onSubmit(trimmedText)
    }
}

private struct ChatBubbleShape: Shape {
    let edge: ChatBubbleTailEdge
    let tailOffset: CGFloat

    private let tailHeight: CGFloat = 10
    private let tailHalfWidth: CGFloat = 9
    private let cornerRadius: CGFloat = 13

    func path(in rect: CGRect) -> Path {
        let bodyRect: CGRect
        switch edge {
        case .top:
            bodyRect = CGRect(
                x: rect.minX,
                y: rect.minY + tailHeight,
                width: rect.width,
                height: rect.height - tailHeight
            )
        case .bottom:
            bodyRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: rect.height - tailHeight
            )
        }

        var path = Path(roundedRect: bodyRect, cornerRadius: cornerRadius)
        var tail = Path()
        switch edge {
        case .top:
            tail.move(to: CGPoint(x: tailOffset - tailHalfWidth, y: bodyRect.minY + 1))
            tail.addLine(to: CGPoint(x: tailOffset, y: rect.minY))
            tail.addLine(to: CGPoint(x: tailOffset + tailHalfWidth, y: bodyRect.minY + 1))
        case .bottom:
            tail.move(to: CGPoint(x: tailOffset - tailHalfWidth, y: bodyRect.maxY - 1))
            tail.addLine(to: CGPoint(x: tailOffset, y: rect.maxY))
            tail.addLine(to: CGPoint(x: tailOffset + tailHalfWidth, y: bodyRect.maxY - 1))
        }
        tail.closeSubpath()
        path.addPath(tail)
        return path
    }
}
