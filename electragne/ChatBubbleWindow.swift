import AppKit
import SwiftUI

enum ChatBubbleTailEdge: Equatable {
    case top
    case bottom
}

/// Pure placement result so screen-edge behavior can be unit tested without a window.
struct ChatBubblePlacement: Equatable {
    static let defaultSize = CGSize(width: 280, height: 122)
    static let expandedSize = CGSize(width: 280, height: 300)
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

enum ChatBubblePhase: Equatable {
    case idle
    case streaming
    case failed(String)
}

/// Turns plain chat text into an AttributedString whose URLs are tappable
/// links; SwiftUI Text opens them with the default browser.
enum ChatTextFormatter {
    nonisolated static func linkified(_ text: String) -> AttributedString {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return AttributedString(text)
        }

        let source = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: source.length)
        for match in detector.matches(in: text, options: [], range: fullRange) {
            guard let url = match.url else { continue }
            source.addAttribute(.link, value: url, range: match.range)
        }

        var attributed = AttributedString(source)
        for run in attributed.runs where run.link != nil {
            attributed[run.range].underlineStyle = .single
        }
        return attributed
    }
}

private struct ChatBubbleEntry: Equatable, Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
}

@Observable
private final class ChatBubbleModel {
    var text = ""
    var tailEdge: ChatBubbleTailEdge = .bottom
    var tailOffset = ChatBubblePlacement.defaultSize.width / 2
    var entries: [ChatBubbleEntry] = []
    var status = "Thinking…"
    var phase: ChatBubblePhase = .idle

    var isStreaming: Bool { phase == .streaming }

    func appendToken(_ token: String) {
        guard let last = entries.indices.last, entries[last].role == .assistant else { return }
        entries[last].text += token
    }
}

/// Owns the auxiliary AppKit panel used for chat. Keeping the bubble separate
/// preserves the invariant that the pet window is exactly one pet wide/high.
final class ChatBubbleWindowController {
    private weak var petWindow: NSWindow?
    private var panel: ChatBubblePanel?
    private var model = ChatBubbleModel()
    private var onDismiss: (() -> Void)?
    private let client: OllamaClient
    private var streamTask: Task<Void, Never>?
    /// Conversation memory for the app's lifetime; survives bubble dismissal.
    /// Capped at the most recent messages to keep the request context small.
    private var history: [OllamaMessage] = []
    private static let maxHistoryMessages = 100
    private var activeStreamID: UUID?

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    init(client: OllamaClient = OllamaClient()) {
        self.client = client
    }

    func present(
        anchoredTo petWindow: NSWindow,
        onDismiss: @escaping () -> Void
    ) {
        self.petWindow = petWindow
        self.onDismiss = onDismiss

        if panel == nil {
            model = ChatBubbleModel()
            model.entries = history.map { turn in
                ChatBubbleEntry(role: turn.role == "user" ? .user : .assistant, text: turn.content)
            }
            let bubbleView = ChatBubbleView(
                model: model,
                onDismiss: { [weak self] in self?.dismiss(notify: true) },
                onSubmit: { [weak self] message in self?.startStream(userMessage: message) }
            )
            let panel = makePanel(rootView: bubbleView)
            self.panel = panel
            installEventMonitors()
            installWindowObservers(for: petWindow)
        }

        reposition()
        if !model.entries.isEmpty {
            setExpanded(true)
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    func dismiss(notify: Bool) {
        guard panel != nil else { return }
        let callback = notify ? onDismiss : nil

        streamTask?.cancel()
        streamTask = nil
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

    private func startStream(userMessage: String) {
        streamTask?.cancel()

        model.text = ""
        model.status = "Thinking…"
        model.phase = .streaming
        model.entries.append(ChatBubbleEntry(role: .user, text: userMessage))
        model.entries.append(ChatBubbleEntry(role: .assistant, text: ""))
        setExpanded(true)

        appendToHistory(OllamaMessage(role: "user", content: userMessage))

        let client = client
        let model = model
        let messages = history
        let streamID = UUID()
        activeStreamID = streamID

        streamTask = Task { [weak self] in
            var streamed = ""
            do {
                try await client.streamChat(
                    history: messages,
                    onStatus: { status in model.status = status },
                    onToken: { token in
                        streamed += token
                        model.appendToken(token)
                    }
                )
                model.phase = .idle
            } catch is CancellationError {
                // Bubble dismissed or a new message superseded this stream.
            } catch let error as URLError where error.code == .cancelled {
                // URLSession reports Task cancellation as URLError.cancelled.
            } catch OllamaError.missingAPIKey {
                model.phase = .failed(
                    "Web search needs an ollama.com API key — set OLLAMA_API_KEY or put it in ~/.ollama/api_key"
                )
            } catch is URLError {
                model.phase = .failed("Ollama not reachable")
            } catch {
                model.phase = .failed("Something went wrong")
            }

            // Record the exchange, unless a newer stream has taken over the
            // history bookkeeping since.
            guard let self, self.activeStreamID == streamID else { return }
            if streamed.isEmpty {
                // Nothing came back (error or cancelled early); drop the
                // question so a retry doesn't duplicate it, and the empty
                // answer placeholder from the transcript.
                self.history.removeLast()
                if model.entries.last?.role == .assistant, model.entries.last?.text.isEmpty == true {
                    model.entries.removeLast()
                }
            } else {
                self.appendToHistory(OllamaMessage(role: "assistant", content: streamed))
            }
        }
    }

    private func appendToHistory(_ message: OllamaMessage) {
        history.append(message)
        if history.count > Self.maxHistoryMessages {
            history.removeFirst(history.count - Self.maxHistoryMessages)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard let panel else { return }
        let size = expanded ? ChatBubblePlacement.expandedSize : ChatBubblePlacement.defaultSize
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
        reposition()
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
                guard let self, !self.model.isStreaming else { return }
                self.dismiss(notify: true)
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
                guard !self.model.isStreaming else { return }
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
                    Text("O rly?")
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
                    .disabled(trimmedText.isEmpty || model.isStreaming)
                    .accessibilityLabel("Send")
                }

                if model.phase != .idle || !model.entries.isEmpty {
                    Divider()
                    transcriptArea
                }
            }
            .padding(.top, model.tailEdge == .top ? 19 : 12)
            .padding(.bottom, model.tailEdge == .bottom ? 19 : 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onExitCommand(perform: onDismiss)
        .onAppear {
            DispatchQueue.main.async {
                inputIsFocused = true
            }
        }
        .onChange(of: model.isStreaming) { _, streaming in
            if !streaming {
                inputIsFocused = true
            }
        }
    }

    private var showsStatusRow: Bool {
        guard model.isStreaming else { return false }
        // Before the first token, or whenever a web search is in flight.
        if model.entries.last?.text.isEmpty == true { return true }
        return model.status.hasPrefix("Searching")
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.entries) { entry in
                        transcriptRow(for: entry)
                    }

                    if case .failed(let message) = model.phase {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }

                    if showsStatusRow {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(model.status)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear
                    .frame(height: 1)
                    .id("bottom")
            }
            .onChange(of: model.entries) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: model.phase) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(for entry: ChatBubbleEntry) -> some View {
        switch entry.role {
        case .user:
            Text(ChatTextFormatter.linkified(entry.text))
                .font(.system(size: 12))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.18))
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            if !entry.text.isEmpty {
                Text(ChatTextFormatter.linkified(entry.text))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func submit() {
        guard !trimmedText.isEmpty, !model.isStreaming else { return }
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
