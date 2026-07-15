import AppKit
import SwiftUI

enum ChatBubbleTailEdge: Equatable {
    case top
    case bottom
}

/// Pure placement result so screen-edge behavior can be unit tested without a window.
struct ChatBubblePlacement: Equatable {
    static let defaultSize = CGSize(width: 320, height: 140)
    static let expandedSize = CGSize(width: 340, height: 380)
    static let minPanelSize = CGSize(width: 320, height: 140)
    static let maxPanelSize = CGSize(width: 720, height: 900)
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

/// Renders chat text with inline markdown (bold, italics, [title](url)
/// links) and makes bare URLs tappable; SwiftUI Text opens links with the
/// default browser.
enum ChatTextFormatter {
    nonisolated static func linkified(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)

        // Second pass: bare URLs the markdown parser left as plain text.
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) {
            let plain = String(attributed.characters)
            let fullRange = NSRange(plain.startIndex..., in: plain)
            for match in detector.matches(in: plain, options: [], range: fullRange) {
                guard let url = match.url,
                      let range = Range(match.range, in: plain) else { continue }
                let startOffset = plain.distance(from: plain.startIndex, to: range.lowerBound)
                let length = plain.distance(from: range.lowerBound, to: range.upperBound)
                let lower = attributed.index(attributed.startIndex, offsetByCharacters: startOffset)
                let upper = attributed.index(lower, offsetByCharacters: length)
                // Don't clobber markdown links.
                guard !attributed[lower..<upper].runs.contains(where: { $0.link != nil }) else {
                    continue
                }
                attributed[lower..<upper].link = url
            }
        }

        for run in attributed.runs where run.link != nil {
            attributed[run.range].underlineStyle = .single
        }
        return attributed
    }

    /// AppKit rendition of `linkified` for NSTextView: inline presentation
    /// intents become concrete fonts, links keep their `.link` attribute.
    static func displayText(_ text: String, size: CGFloat = 12) -> NSAttributedString {
        let attributed = linkified(text)
        let base = NSFont.systemFont(ofSize: size)
        let result = NSMutableAttributedString()

        for run in attributed.runs {
            let segment = String(attributed.characters[run.range])
            var font = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
                } else {
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty {
                        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
                        font = NSFont(descriptor: descriptor, size: size) ?? base
                    }
                }
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: segment, attributes: attributes))
        }
        return result
    }
}

/// Offscreen TextKit stack used to measure chat text. Measuring must never
/// touch the displayed NSTextView's own text container: mutating it during
/// SwiftUI's sizing probes leaves the container and frame inconsistent, which
/// breaks reflow when the bubble is resized.
@MainActor
private enum ChatTextMeasurer {
    private static let storage = NSTextStorage()
    private static let manager = NSLayoutManager()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return container
    }()

    static func size(of attributed: NSAttributedString, width: CGFloat) -> CGSize {
        storage.setAttributedString(attributed)
        container.size = NSSize(width: max(width, 8), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return CGSize(
            width: min(used.width.rounded(.up), width),
            height: used.height.rounded(.up)
        )
    }
}

/// Chat text rendered by NSTextView so links get the pointing-hand cursor on
/// hover — SwiftUI Text can't change the cursor per-run. Also provides native
/// text selection and opens links with the default browser.
private struct LinkedText: NSViewRepresentable {
    let text: String
    var fontSize: CGFloat = UserPreferences.defaultChatFontSize

    /// Caches the formatted string and its measurements so repeated SwiftUI
    /// update/sizing passes don't re-run markdown parsing, link detection,
    /// and TextKit layout when nothing changed.
    final class Coordinator {
        private var cachedText: String?
        private var cachedFontSize: CGFloat?
        private var cachedDisplay: NSAttributedString?
        private var sizesByWidth: [CGFloat: CGSize] = [:]
        var appliedToView = false

        func display(for text: String, size: CGFloat) -> NSAttributedString {
            if let cachedDisplay, cachedText == text, cachedFontSize == size {
                return cachedDisplay
            }
            let display = ChatTextFormatter.displayText(text, size: size)
            cachedText = text
            cachedFontSize = size
            cachedDisplay = display
            sizesByWidth = [:]
            appliedToView = false
            return display
        }

        func measuredSize(for display: NSAttributedString, width: CGFloat) -> CGSize {
            if let cached = sizesByWidth[width] {
                return cached
            }
            let size = ChatTextMeasurer.size(of: display, width: width)
            sizesByWidth[width] = size
            return size
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // Track the final SwiftUI-assigned frame so text re-wraps to the real
        // width even when it differs from the last sizeThatFits probe.
        view.textContainer?.widthTracksTextView = true
        view.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let display = context.coordinator.display(for: text, size: fontSize)
        if !context.coordinator.appliedToView {
            view.textStorage?.setAttributedString(display)
            context.coordinator.appliedToView = true
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? ChatBubblePlacement.defaultSize.width
        let display = context.coordinator.display(for: text, size: fontSize)
        return context.coordinator.measuredSize(for: display, width: width)
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

private struct PendingToolConfirmation: Equatable, Identifiable {
    let id: UUID
    let details: ToolConfirmationDetails
}

@Observable
private final class ChatBubbleModel {
    var text = ""
    var tailEdge: ChatBubbleTailEdge = .bottom
    var tailOffset = ChatBubblePlacement.defaultSize.width / 2
    var entries: [ChatBubbleEntry] = []
    var status = "Thinking…"
    var phase: ChatBubblePhase = .idle
    var availableChats: [ChatSummary] = []
    var currentChatID: UUID?
    var fontSize: CGFloat = UserPreferences.chatFontSize()
    var pendingToolConfirmation: PendingToolConfirmation?

    var isStreaming: Bool { phase == .streaming }

    func adjustFontSize(by delta: CGFloat) {
        fontSize = (fontSize + delta).clamped(to: UserPreferences.chatFontSizeRange)
        UserPreferences.setChatFontSize(fontSize)
    }

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
    private let ollamaClient: OllamaClient
    private let geminiClient: GeminiClient
    private let reminderCreator: any ReminderCreating
    private let desktopToolExecutor: any DesktopToolExecuting
    private var streamTask: Task<Void, Never>?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    /// The active conversation; persisted after every exchange and reloaded
    /// across app launches. Never trimmed — the request-time cap for the
    /// local model happens in startStream.
    private let chatStore: ChatStore
    private var currentChat: StoredChat
    /// Request cap for the local Ollama model (Gemini gets the full history).
    private static let maxOllamaHistoryMessages = 100
    private var activeStreamID: UUID?

    private var history: [OllamaMessage] {
        get { currentChat.messages }
        set { currentChat.messages = newValue }
    }

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    init(
        ollamaClient: OllamaClient = OllamaClient(),
        geminiClient: GeminiClient = GeminiClient(),
        reminderCreator: (any ReminderCreating)? = nil,
        desktopToolExecutor: (any DesktopToolExecuting)? = nil,
        chatStore: ChatStore = ChatStore()
    ) {
        self.ollamaClient = ollamaClient
        self.geminiClient = geminiClient
        self.reminderCreator = reminderCreator ?? AppleReminderService()
        self.desktopToolExecutor = desktopToolExecutor ?? DesktopToolService()
        self.chatStore = chatStore

        // Resume the most recent chat across launches; start fresh otherwise.
        if let recent = chatStore.listSummaries().first,
           let chat = chatStore.load(id: recent.id) {
            currentChat = chat
        } else {
            currentChat = StoredChat()
        }
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
                onSubmit: { [weak self] message in self?.startStream(userMessage: message) },
                onNewChat: { [weak self] in self?.startNewChat() },
                onSelectChat: { [weak self] id in self?.switchToChat(id: id) },
                onConfirmTool: { [weak self] in self?.resolveToolConfirmation(approved: true) },
                onCancelTool: { [weak self] in self?.resolveToolConfirmation(approved: false) }
            )
            refreshChatList()
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

        resolveToolConfirmation(approved: false)
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
        resolveToolConfirmation(approved: false)
        streamTask?.cancel()

        model.text = ""
        model.status = "Thinking…"
        model.phase = .streaming
        model.entries.append(ChatBubbleEntry(role: .user, text: userMessage))
        model.entries.append(ChatBubbleEntry(role: .assistant, text: ""))
        setExpanded(true)

        history.append(OllamaMessage(role: "user", content: userMessage))

        let useGemini = ChatProviderPreference.useGemini
        let client: any ChatClient = useGemini ? geminiClient : ollamaClient
        let model = model
        // Gemini's context fits the whole conversation; only the local model
        // needs a request-time cap. Storage and transcript are never trimmed.
        let messages = useGemini
            ? history
            : Array(history.suffix(Self.maxOllamaHistoryMessages))
        let streamID = UUID()
        activeStreamID = streamID

        streamTask = Task { [weak self] in
            var streamed = ""
            do {
                try await client.streamChat(
                    history: messages,
                    onStatus: { status in model.status = status },
                    onToolCall: { [weak self] call in
                        guard let self else { return .error("The chat was closed.") }
                        return await self.executeToolCall(call)
                    },
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
            } catch GeminiError.missingAPIKey {
                model.phase = .failed(
                    "Gemini needs an API key — put it in ~/.gemini.api.key"
                )
            } catch GeminiError.quotaExceeded {
                model.phase = .failed("Gemini quota exceeded — try again later")
            } catch GeminiError.toolRoundLimit {
                model.phase = .failed("Gemini used too many tool steps — try a simpler request")
            } catch is URLError {
                model.phase = .failed(useGemini ? "Gemini not reachable" : "Ollama not reachable")
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
                self.history.append(OllamaMessage(role: "assistant", content: streamed))
                self.persistCurrentChat()
            }
        }
    }

    private func executeToolCall(_ call: ChatToolCall) async -> ChatToolResult {
        if call.name == "create_reminder" {
            let request: ReminderRequest
            do {
                request = try ReminderRequest(toolCall: call)
            } catch {
                return .error("A reminder title is required.")
            }
            let details = ToolConfirmationDetails(
                title: "Create this reminder?",
                primaryText: request.title,
                details: [
                    ("List", request.listName ?? "Default"),
                    ("Due", request.due ?? "None"),
                    ("Notes", request.notes ?? "None"),
                ].filter { $0.1 != "None" },
                actionLabel: "Create"
            )
            guard await requestConfirmation(details) else {
                return Self.cancelledToolResult()
            }
            model.status = "Saving reminder…"
            return await reminderCreator.createReminder(request)
        }

        let request: DesktopToolRequest
        do {
            request = try DesktopToolRequest(toolCall: call)
        } catch DesktopToolError.unsupportedTool(let name) {
            return .error("Unknown tool ‘\(name)’.")
        } catch DesktopToolError.missingArgument(let name) {
            return .error("The ‘\(name)’ argument is required.")
        } catch DesktopToolError.invalidWebURL {
            return .error("Only complete HTTP and HTTPS web addresses can be opened.")
        } catch {
            return .error("That tool request was invalid.")
        }

        if let details = desktopToolExecutor.confirmationDetails(for: request),
           !(await requestConfirmation(details)) {
            return Self.cancelledToolResult()
        }
        model.status = request.isFileSearch ? "Searching approved folders…" : "Opening…"
        return await desktopToolExecutor.execute(request)
    }

    private func requestConfirmation(_ details: ToolConfirmationDetails) async -> Bool {
        model.pendingToolConfirmation = PendingToolConfirmation(
            id: UUID(),
            details: details
        )
        model.status = "Confirm action…"
        let approved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    model.pendingToolConfirmation = nil
                    continuation.resume(returning: false)
                } else {
                    confirmationContinuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveToolConfirmation(approved: false)
            }
        }
        return approved && !Task.isCancelled
    }

    private func resolveToolConfirmation(approved: Bool) {
        model.pendingToolConfirmation = nil
        guard let continuation = confirmationContinuation else { return }
        confirmationContinuation = nil
        continuation.resume(returning: approved)
    }

    private static func cancelledToolResult() -> ChatToolResult {
        ChatToolResult(response: [
            "status": .string("cancelled"),
            "message": .string("The owner cancelled this action."),
        ])
    }

    private func persistCurrentChat() {
        if currentChat.title.isEmpty,
           let firstUserTurn = history.first(where: { $0.role == "user" }) {
            currentChat.title = ChatStore.title(for: firstUserTurn.content)
        }
        currentChat.updatedAt = Date()
        chatStore.save(currentChat)
        refreshChatList()
    }

    private func refreshChatList() {
        model.availableChats = chatStore.listSummaries()
        model.currentChatID = currentChat.id
    }

    private func startNewChat() {
        resolveToolConfirmation(approved: false)
        streamTask?.cancel()
        streamTask = nil
        chatStore.save(currentChat)
        currentChat = StoredChat()
        model.entries = []
        model.phase = .idle
        refreshChatList()
    }

    private func switchToChat(id: UUID) {
        guard id != currentChat.id, let chat = chatStore.load(id: id) else { return }
        resolveToolConfirmation(approved: false)
        streamTask?.cancel()
        streamTask = nil
        chatStore.save(currentChat)
        currentChat = chat
        model.phase = .idle
        model.entries = chat.messages.map { turn in
            ChatBubbleEntry(role: turn.role == "user" ? .user : .assistant, text: turn.content)
        }
        refreshChatList()
        setExpanded(true)
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

    private func setExpanded(_ expanded: Bool) {
        guard let panel else { return }
        let size = expanded ? expandedSize : ChatBubblePlacement.defaultSize
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
        reposition()
    }

    private func makePanel(rootView: ChatBubbleView) -> ChatBubblePanel {
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
    let onNewChat: () -> Void
    let onSelectChat: (UUID) -> Void
    let onConfirmTool: () -> Void
    let onCancelTool: () -> Void

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
                    Text("sheepchat. baaa.")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    Menu {
                        Button("New Chat", action: onNewChat)
                        if !model.availableChats.isEmpty {
                            Divider()
                            ForEach(model.availableChats) { chat in
                                Button {
                                    onSelectChat(chat.id)
                                } label: {
                                    if chat.id == model.currentChatID {
                                        Label(chat.title, systemImage: "checkmark")
                                    } else {
                                        Text(chat.title)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Chats")

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
                    // A separate view so per-keystroke updates to model.text
                    // don't re-evaluate (and re-measure) the transcript.
                    ChatTranscriptView(
                        model: model,
                        onConfirmTool: onConfirmTool,
                        onCancelTool: onCancelTool
                    )
                }
            }
            .padding(.top, model.tailEdge == .top ? 19 : 12)
            .padding(.bottom, model.tailEdge == .bottom ? 19 : 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onExitCommand(perform: onDismiss)
        .background {
            // Invisible buttons so Cmd+/Cmd- adjust the chat font while the
            // bubble is the key window ("+" is also reachable as Cmd-=).
            Group {
                Button("") { model.adjustFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("") { model.adjustFontSize(by: 1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("") { model.adjustFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
            }
            .buttonStyle(.plain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
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

    private func submit() {
        guard !trimmedText.isEmpty, !model.isStreaming else { return }
        onSubmit(trimmedText)
    }
}

/// The scrollable conversation. Kept separate from ChatBubbleView so typing
/// (which mutates model.text every keystroke) doesn't re-render the rows.
private struct ChatTranscriptView: View {
    let model: ChatBubbleModel
    let onConfirmTool: () -> Void
    let onCancelTool: () -> Void

    private var showsStatusRow: Bool {
        guard model.isStreaming else { return false }
        guard model.pendingToolConfirmation == nil else { return false }
        // Before the first token, or whenever a web search is in flight.
        if model.entries.last?.text.isEmpty == true { return true }
        return model.status.hasPrefix("Searching")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.entries) { entry in
                        transcriptRow(for: entry)
                    }

                    if let confirmation = model.pendingToolConfirmation {
                        toolConfirmationCard(confirmation)
                    }

                    if case .failed(let message) = model.phase {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: model.fontSize))
                            .foregroundStyle(.red)
                    }

                    if showsStatusRow {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(model.status)
                                .font(.system(size: model.fontSize))
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
            .onChange(of: model.pendingToolConfirmation) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func toolConfirmationCard(
        _ confirmation: PendingToolConfirmation
    ) -> some View {
        let details = confirmation.details
        return VStack(alignment: .leading, spacing: 7) {
            Label(details.title, systemImage: "checkmark.shield")
                .font(.system(size: model.fontSize, weight: .semibold))

            Text(details.primaryText)
                .font(.system(size: model.fontSize, weight: .medium))
                .textSelection(.enabled)

            ForEach(Array(details.details.enumerated()), id: \.offset) { _, detail in
                detailRow(label: detail.label, value: detail.value)
            }

            HStack {
                Button("Cancel", action: onCancelTool)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(details.actionLabel, action: onConfirmTool)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.35))
        )
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(label):")
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.system(size: model.fontSize))
    }

    @ViewBuilder
    private func transcriptRow(for entry: ChatBubbleEntry) -> some View {
        switch entry.role {
        case .user:
            LinkedText(text: entry.text, fontSize: model.fontSize)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.18))
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            if !entry.text.isEmpty {
                LinkedText(text: entry.text, fontSize: model.fontSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
