//
//  ChatBubbleWindowController.swift
//  electragne
//
//  Streaming/persistence orchestrator for the chat bubble and the NSPanel
//  that hosts it.
//

import AppKit
import SwiftUI

/// Owns the auxiliary AppKit panel used for chat. Keeping the bubble separate
/// preserves the invariant that the pet window is exactly one pet wide/high.
final class ChatBubbleWindowController {
    private weak var petWindow: NSWindow?
    private var panel: ChatBubblePanel?
    private var model = ChatBubbleModel()
    private var onDismiss: (() -> Void)?
    private let ollamaClient: any ChatClient
    private let geminiClient: any ChatClient
    private let openAICompatibleClient: any ChatClient
    private let toolRouter: ChatToolRouter
    private var streamTask: Task<Void, Never>?
    private let confirmationBroker = ConfirmationBroker()
    /// The active conversation; persisted after every exchange and reloaded
    /// across app launches. Never trimmed — the request-time cap for the
    /// local model happens in startStream.
    private let chatStore: ChatStore
    private let memoryEngine: MemoryEngine
    private var currentChat: StoredChat
    private var activeStreamID: UUID?
    private var pendingCalendarEvents: [CalendarEventDetails] = []

    private var history: [ChatMessage] {
        get { currentChat.messages }
        set { currentChat.messages = newValue }
    }

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    init(
        ollamaClient: any ChatClient = OllamaClient(),
        geminiClient: any ChatClient = GeminiClient(),
        openAICompatibleClient: any ChatClient = OpenAICompatibleClient(),
        toolRouter: ChatToolRouter,
        chatStore: ChatStore = ChatStore(),
        memoryEngine: MemoryEngine
    ) {
        self.ollamaClient = ollamaClient
        self.geminiClient = geminiClient
        self.openAICompatibleClient = openAICompatibleClient
        self.toolRouter = toolRouter
        self.chatStore = chatStore
        self.memoryEngine = memoryEngine

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
                onSelectModel: { [weak self] id in self?.selectModel(id) },
                onConfirmTool: { [weak self] in self?.resolveToolConfirmation(approved: true) },
                onCancelTool: { [weak self] in self?.resolveToolConfirmation(approved: false) }
            )
            refreshChatList()
            refreshModels()
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

        teardownStream()
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

    func startCalendarEventConversation(_ event: CalendarEventDetails) {
        pendingCalendarEvents.append(event)
        startNextCalendarEventConversation()
    }

    private func startNextCalendarEventConversation() {
        guard streamTask == nil, !pendingCalendarEvents.isEmpty else { return }
        let event = pendingCalendarEvents.removeFirst()
        resolveToolConfirmation(approved: false)
        activeStreamID = nil
        chatStore.save(currentChat)
        currentChat = StoredChat(title: event.summary)
        model.text = ""
        model.entries = []
        model.phase = .idle
        refreshChatList()
        startStream(
            userMessage: event.reminderPrompt,
            toolsEnabled: false,
            openURLAfterResponse: event.joinURL
        )
    }

    private func startStream(
        userMessage: String,
        toolsEnabled: Bool = true,
        openURLAfterResponse: URL? = nil
    ) {
        resolveToolConfirmation(approved: false)
        streamTask?.cancel()

        model.text = ""
        model.status = "Thinking…"
        model.phase = .streaming
        model.entries.append(ChatBubbleEntry(role: .user, text: userMessage))
        model.entries.append(ChatBubbleEntry(role: .assistant, text: ""))
        setExpanded(true)

        history.append(ChatMessage(role: "user", content: userMessage))
        let extractionContext = Array(history.dropLast().suffix(4))

        let provider = ChatProviderPreference.selected
        let client: any ChatClient = switch provider {
        case .ollama: ollamaClient
        case .gemini: geminiClient
        case .openAICompatible: openAICompatibleClient
        }
        let model = model
        var messages = history
        if let memories = memoryEngine.contextBlock(for: userMessage) {
            // Injected into the outgoing request only, right before the new
            // user turn — never persisted to the chat or shown in the bubble.
            messages.insert(
                ChatMessage(role: "system", content: memories),
                at: messages.count - 1
            )
        }
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
                        guard toolsEnabled else {
                            return .error("Tools are disabled while summarizing a calendar event.")
                        }
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
            } catch {
                model.phase = .failed(
                    error is URLError
                        ? "\(provider.displayName) not reachable"
                        : error.localizedDescription
                )
            }

            // Record the exchange, unless a newer stream has taken over the
            // history bookkeeping since.
            guard let self, self.activeStreamID == streamID else { return }
            if streamed.isEmpty, openURLAfterResponse == nil {
                // Nothing came back (error or cancelled early); drop the
                // question so a retry doesn't duplicate it, and the empty
                // answer placeholder from the transcript.
                self.history.removeLast()
                if model.entries.last?.role == .assistant, model.entries.last?.text.isEmpty == true {
                    model.entries.removeLast()
                }
            } else {
                if !streamed.isEmpty {
                    self.history.append(ChatMessage(role: "assistant", content: streamed))
                }
                self.persistCurrentChat()
                if toolsEnabled, !streamed.isEmpty {
                    // Form a memory from the completed exchange. Proactive
                    // calendar summaries (toolsEnabled == false) are excluded:
                    // repetitive machine traffic would silt the graph.
                    let chatID = self.currentChat.id
                    Task {
                        await self.memoryEngine.ingest(
                            userText: userMessage,
                            assistantText: streamed,
                            chatID: chatID,
                            context: extractionContext,
                            client: Self.memoryClient(fallback: client)
                        )
                    }
                }
            }

            if let url = openURLAfterResponse {
                _ = await self.executeToolCall(ChatToolCall(
                    id: UUID().uuidString,
                    name: "open_url",
                    arguments: ["url": .string(url.absoluteString)]
                ))
            }

            guard self.activeStreamID == streamID else { return }
            self.streamTask = nil
            self.activeStreamID = nil
            self.startNextCalendarEventConversation()
        }
    }

    private func executeToolCall(_ call: ChatToolCall) async -> ChatToolResult {
        await toolRouter.execute(
            call,
            confirm: { [weak self] details in
                guard let self else { return false }
                return await self.requestConfirmation(details)
            },
            onStatus: { [weak self] status in self?.model.status = status }
        )
    }

    private func requestConfirmation(_ details: ToolConfirmationDetails) async -> Bool {
        let id = UUID()
        model.pendingToolConfirmation = PendingToolConfirmation(
            id: id,
            details: details
        )
        model.status = "Confirm action…"
        let approved = await confirmationBroker.request()
        if model.pendingToolConfirmation?.id == id {
            model.pendingToolConfirmation = nil
        }
        return approved && !Task.isCancelled
    }

    private func resolveToolConfirmation(approved: Bool) {
        model.pendingToolConfirmation = nil
        confirmationBroker.resolve(approved: approved)
    }

    /// Cancels any in-flight stream and does the exchange bookkeeping its
    /// task would have done, synchronously — clearing `activeStreamID` here
    /// makes the cancelled task's own cleanup block bail out, so it must
    /// happen now or the unanswered user turn stays in the transcript.
    private func teardownStream() {
        resolveToolConfirmation(approved: false)
        pendingCalendarEvents.removeAll()
        streamTask?.cancel()
        if activeStreamID != nil {
            if model.entries.last?.role == .assistant, model.entries.last?.text.isEmpty == true {
                // Nothing streamed; drop the question so a retry doesn't
                // duplicate it, and the empty answer placeholder.
                model.entries.removeLast()
                if history.last?.role == "user" { history.removeLast() }
            } else if let partial = model.entries.last, partial.role == .assistant {
                history.append(ChatMessage(role: "assistant", content: partial.text))
                persistCurrentChat()
            }
        }
        streamTask = nil
        activeStreamID = nil
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

    /// The client memory extraction uses: the chat client, unless Settings
    /// picked a dedicated memory provider (and optionally model).
    private static func memoryClient(fallback: any ChatClient) -> any ChatClient {
        guard let provider = MemoryProviderPreference.selected else { return fallback }
        let model = MemoryProviderPreference.model
        return switch provider {
        case .ollama: OllamaClient(model: model)
        case .gemini: GeminiClient(model: model)
        case .openAICompatible: OpenAICompatibleClient(model: model)
        }
    }

    /// The current provider's model UserDefaults key; nil to hide the picker.
    private static func modelKey(for provider: ChatProvider) -> String {
        switch provider {
        case .ollama: UserPreferences.ollamaModelKey
        case .gemini: UserPreferences.geminiModelKey
        case .openAICompatible: UserPreferences.openAICompatibleModelKey
        }
    }

    private static func storedModel(for provider: ChatProvider) -> String {
        switch provider {
        case .ollama: UserPreferences.ollamaModel()
        case .gemini: UserPreferences.geminiModel()
        case .openAICompatible: UserPreferences.openAICompatibleModel()
        }
    }

    /// Fetches the active provider's model list so the header picker can
    /// appear when there is more than one to choose from.
    private func refreshModels() {
        let provider = ChatProviderPreference.selected
        let current = Self.storedModel(for: provider)
        model.currentModel = current
        model.availableModels = [current]

        let model = model
        Task {
            do {
                let fetched = try await provider.listModelIDs()
                // Keep the stored selection present even if the fetch omits it.
                var seen = Set<String>()
                model.availableModels = ([current] + fetched.sorted()).filter { seen.insert($0).inserted }
            } catch {
                // No list, no picker; the configured model still works.
            }
        }
    }

    private func selectModel(_ id: String) {
        let provider = ChatProviderPreference.selected
        UserDefaults.standard.set(id, forKey: Self.modelKey(for: provider))
        model.currentModel = id
    }

    private func startNewChat() {
        teardownStream()
        chatStore.save(currentChat)
        currentChat = StoredChat()
        model.text = ""
        model.entries = []
        model.phase = .idle
        refreshChatList()
    }

    private func switchToChat(id: UUID) {
        guard id != currentChat.id, let chat = chatStore.load(id: id) else { return }
        teardownStream()
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
        PetWindowPresentation.enforce(on: panel)
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
