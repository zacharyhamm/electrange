//
//  ChatBubbleWindowController.swift
//  electragne
//
//  Streaming/persistence orchestrator for the chat bubble. The NSPanel
//  hosting side (monitors, observers, sizing) lives in
//  ChatBubblePanelHosting.swift.
//

import AppKit
import SwiftUI

/// Owns the auxiliary AppKit panel used for chat. Keeping the bubble separate
/// preserves the invariant that the pet window is exactly one pet wide/high.
final class ChatBubbleWindowController {
    weak var petWindow: NSWindow?
    var panel: ChatBubblePanel?
    var model = ChatBubbleModel()
    private var onDismiss: (() -> Void)?
    private let ollamaClient: any ChatClient
    private let geminiClient: any ChatClient
    private let openAICompatibleClient: any ChatClient
    private let toolRouter: ChatToolRouter
    let terminalController: TerminalPanelController?
    private var streamTask: Task<Void, Never>?
    private let confirmationBroker = ConfirmationBroker()
    /// The active conversation; persisted after every exchange and reloaded
    /// across app launches. Never trimmed — the request-time cap for the
    /// local model happens in startStream.
    private let chatStore: ChatStore
    private let memoryEngine: MemoryEngine
    private var currentChat: StoredChat
    private var activeStreamID: UUID?
    /// The chat the in-flight stream belongs to. Survives dismiss/new/switch
    /// so the stream can finish against the right transcript.
    private var streamingChatID: UUID?
    /// Accumulated partial text of the in-flight stream, kept outside the
    /// view model because the model is rebuilt on re-present and switch.
    private var streamedBuffer = ""
    private var streamedImages: [ChatImage] = []
    private var streamedImagePresentation: ChatImagePresentation = .thumbnails
    /// A machine-initiated conversation (calendar reminder, automation
    /// notice) waiting for the single in-flight stream slot.
    struct ProactivePrompt {
        let title: String
        let prompt: String
        var joinURL: URL? = nil
        var targetChatID: UUID? = nil
        var source: ChatMessageSource? = nil
    }
    private var pendingProactivePrompts: [ProactivePrompt] = []

    /// Whether the in-flight stream's chat is the one on screen; gates every
    /// view-model mutation the stream makes.
    private var streamIsForeground: Bool { streamingChatID == currentChat.id }

    var currentChatID: UUID { currentChat.id }
    /// User-resized terminal widths, scoped to the lifetime of each live chat session.
    private var terminalWidths: [UUID: CGFloat] = [:]

    func terminalWidth(for chatID: UUID, initialHeight: CGFloat) -> CGFloat {
        terminalWidths[chatID]
            ?? ChatBubblePlacement.preferredTerminalWidth(forHeight: initialHeight)
    }

    func rememberTerminalWidth(_ width: CGFloat, for chatID: UUID) {
        terminalWidths[chatID] = width
    }

    /// Tool calls belong to the stream's chat even if the owner switches
    /// conversations while the model is working.
    var toolChatID: UUID { streamingChatID ?? currentChat.id }

    private var history: [ChatMessage] {
        get { currentChat.messages }
        set { currentChat.messages = newValue }
    }

    var localMouseMonitor: Any?
    var globalMouseMonitor: Any?
    var windowObservers: [NSObjectProtocol] = []

    init(
        ollamaClient: any ChatClient = OllamaClient(),
        geminiClient: any ChatClient = GeminiClient(),
        openAICompatibleClient: any ChatClient = OpenAICompatibleClient(),
        toolRouter: ChatToolRouter,
        chatStore: ChatStore = ChatStore(),
        memoryEngine: MemoryEngine,
        terminalController: TerminalPanelController? = nil
    ) {
        self.terminalController = terminalController
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
            model.entries = Self.entries(from: history)
            attachStreamIfActive()
            let bubbleView = ChatBubbleView(
                model: model,
                onDismiss: { [weak self] in self?.dismiss(notify: true) },
                onSubmit: { [weak self] message in self?.startStream(userMessage: message) },
                onNewChat: { [weak self] in self?.startNewChat() },
                onSelectChat: { [weak self] id in self?.switchToChat(id: id) },
                onSelectModel: { [weak self] id in self?.selectModel(id) },
                onConfirmTool: { [weak self] in self?.resolveToolConfirmation(approved: true) },
                onCancelTool: { [weak self] in self?.resolveToolConfirmation(approved: false) },
                onCloseTerminal: { [weak self] in self?.closeTerminal() }
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
        restoreTerminal()
    }

    /// Shows the terminal column for the current chat, creating its session
    /// on first use. False when the bubble isn't on screen (the tool's guard).
    @discardableResult
    func showTerminal() -> Bool {
        guard panel != nil, let terminalController else { return false }
        model.terminalView = terminalController.view(for: currentChat.id)
        setExpanded(true)
        return true
    }

    func writeTerminal(_ input: TerminalWriteInput) -> Bool {
        guard panel != nil, let terminalController else { return false }
        let chatID = toolChatID
        guard terminalController.send(input, for: chatID) else { return false }
        if chatID == currentChat.id {
            model.terminalView = terminalController.view(for: chatID)
            setExpanded(true)
        }
        return true
    }

    func readTerminal(maxLines: Int) -> TerminalReadResult? {
        terminalController?.read(maxLines: maxLines, for: toolChatID)
    }

    /// The user closed the terminal column; the shell stays alive and the
    /// bubble shrinks back to the chat column.
    private func closeTerminal() {
        terminalController?.markClosed(currentChat.id)
        model.terminalView = nil
        setExpanded(true)
    }

    /// Attaches the current chat's terminal (and only it), if wanted, and
    /// sizes the bubble for whichever columns are showing.
    private func restoreTerminal() {
        guard panel != nil else { return }
        let hadTerminal = model.terminalView != nil
        let wants = terminalController?.wantsVisible(for: currentChat.id) == true
        model.terminalView = wants ? terminalController?.view(for: currentChat.id) : nil
        if wants || hadTerminal {
            setExpanded(true)
        }
    }

    func dismiss(notify: Bool) {
        guard panel != nil else { return }
        let callback = notify ? onDismiss : nil

        // The stream (if any) keeps running; its chat is still current, so
        // tokens keep landing in the buffer and the next present() reattaches.
        resolveToolConfirmation(approved: false)
        pendingProactivePrompts.removeAll { $0.source == nil }
        removeEventMonitors()
        removeWindowObservers()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        petWindow = nil
        onDismiss = nil

        callback?()
    }

    /// The transcript rows for a stored history.
    private static func entries(from history: [ChatMessage]) -> [ChatBubbleEntry] {
        history.map { turn in
            if turn.role == "tool" {
                return ChatBubbleEntry(role: .tool, text: turn.content)
            }
            return ChatBubbleEntry(
                role: turn.source == nil
                    ? (turn.role == "user" ? .user : .assistant)
                    : .automation,
                text: turn.content,
                images: turn.images ?? []
            )
        }
    }

    /// Saves the current chat and puts `chat` on screen with a blank
    /// transcript, cancelling any pending tool confirmation.
    private func resetTranscript(to chat: StoredChat) {
        resolveToolConfirmation(approved: false)
        chatStore.save(currentChat)
        currentChat = chat
        model.text = ""
        model.entries = []
        model.phase = .idle
        refreshChatList()
        restoreTerminal()
    }

    @discardableResult
    func startProactiveConversation(_ prompt: ProactivePrompt) -> Bool {
        if let chatID = prompt.targetChatID,
           chatID != currentChat.id,
           chatStore.load(id: chatID) == nil {
            return false
        }
        pendingProactivePrompts.append(prompt)
        startNextProactiveConversation()
        return true
    }

    private func startNextProactiveConversation() {
        guard streamTask == nil, !pendingProactivePrompts.isEmpty else { return }
        let prompt = pendingProactivePrompts.removeFirst()
        activeStreamID = nil
        if let chatID = prompt.targetChatID {
            guard let chat = chatID == currentChat.id ? currentChat : chatStore.load(id: chatID) else {
                startNextProactiveConversation()
                return
            }
            resetTranscript(to: chat)
        } else {
            resetTranscript(to: StoredChat(title: prompt.title))
        }
        startStream(
            userMessage: prompt.prompt,
            toolsEnabled: false,
            openURLAfterResponse: prompt.joinURL,
            source: prompt.source
        )
    }

    func startStream(
        userMessage: String,
        toolsEnabled: Bool = true,
        openURLAfterResponse: URL? = nil,
        source: ChatMessageSource? = nil
    ) {
        resolveToolConfirmation(approved: false)
        if let backgroundID = streamingChatID, backgroundID != currentChat.id {
            // A stream is still running for another chat; record its partial
            // progress there before this chat takes over.
            // ponytail: one in-flight stream; a per-chat task map if parallel
            // streams ever matter.
            streamTask?.cancel()
            activeStreamID = nil
            finalizeBackgroundExchange(
                chatID: backgroundID,
                streamed: streamedBuffer,
                images: streamedImages
            )
        }
        streamTask?.cancel()

        model.text = ""
        model.status = "Thinking…"
        model.phase = .streaming
        model.entries.append(ChatBubbleEntry(
            role: source == nil ? .user : .automation,
            text: userMessage
        ))
        model.entries.append(ChatBubbleEntry(role: .assistant, text: ""))
        setExpanded(true)

        history.append(ChatMessage(role: "user", content: userMessage, source: source))
        if source != nil { persistCurrentChat() }
        let extractionContext = Array(
            history.dropLast().filter { $0.role != "tool" }.suffix(4)
        )

        let provider = ChatProviderPreference.selected
        let client: any ChatClient = switch provider {
        case .ollama: ollamaClient
        case .gemini: geminiClient
        case .openAICompatible: openAICompatibleClient
        }
        // Tool records (and legacy stored tool_calls) are display-only; replaying
        // them breaks provider pairing rules (Gemini thought signatures,
        // OpenAI tool_call_id), so they never go back on the wire.
        var messages = history.filter { $0.role != "tool" && $0.toolCalls == nil }
        if let memories = memoryEngine.contextBlock(for: userMessage) {
            // Injected into the outgoing request only, right before the new
            // user turn — never persisted to the chat or shown in the bubble.
            messages.insert(
                ChatMessage(role: "system", content: memories),
                at: messages.count - 1
            )
        }
        let streamID = UUID()
        let chatID = currentChat.id
        activeStreamID = streamID
        streamingChatID = chatID
        streamedBuffer = ""
        streamedImages = []
        streamedImagePresentation = .thumbnails

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.streamChat(
                    history: messages,
                    onStatus: { status in
                        guard self.activeStreamID == streamID, self.streamIsForeground else { return }
                        self.model.status = status
                    },
                    onToolCall: { call in
                        guard toolsEnabled else {
                            return .error("Tools are disabled in this proactive conversation.")
                        }
                        return await self.executeToolCall(call)
                    },
                    onImages: { batch in
                        guard self.activeStreamID == streamID else { return }
                        self.receiveImages(batch)
                    },
                    onToken: { token in
                        guard self.activeStreamID == streamID else { return }
                        self.streamedBuffer += token
                        guard self.streamIsForeground else { return }
                        self.model.status = ""
                        self.model.appendToken(token)
                    }
                )
                if self.activeStreamID == streamID, self.streamIsForeground {
                    self.model.phase = .idle
                }
            } catch is CancellationError {
                // A new message superseded this stream.
            } catch let error as URLError where error.code == .cancelled {
                // URLSession reports Task cancellation as URLError.cancelled.
            } catch {
                if self.activeStreamID == streamID, self.streamIsForeground {
                    self.model.phase = .failed(
                        error is URLError
                            ? "\(provider.displayName) not reachable"
                            : error.localizedDescription
                    )
                }
            }

            // Record the exchange, unless a newer stream has taken over the
            // history bookkeeping since.
            guard self.activeStreamID == streamID else { return }
            let streamed = self.streamedBuffer
            let images = self.streamedImages
            if self.currentChat.id == chatID {
                if streamed.isEmpty, images.isEmpty, openURLAfterResponse == nil,
                   source == nil, self.history.last?.role == "user" {
                    // Nothing came back (error or cancelled early); drop the
                    // question so a retry doesn't duplicate it, and the empty
                    // answer placeholder from the transcript. When tool records
                    // followed the question, keep everything instead — tools
                    // ran, possibly with side effects.
                    self.history.removeLast()
                    if self.model.entries.last?.role == .assistant,
                       self.model.entries.last?.text.isEmpty == true {
                        self.model.entries.removeLast()
                    }
                } else {
                    if !streamed.isEmpty || !images.isEmpty {
                        self.history.append(ChatMessage(
                            role: "assistant",
                            content: streamed,
                            images: images.isEmpty ? nil : images
                        ))
                    }
                    self.persistCurrentChat()
                }
            } else {
                // The user moved on to another chat mid-stream; finish the
                // exchange against the persisted copy instead.
                self.finalizeBackgroundExchange(chatID: chatID, streamed: streamed, images: images)
            }
            if toolsEnabled, !streamed.isEmpty {
                // Form a memory from the completed exchange. Proactive
                // calendar summaries (toolsEnabled == false) are excluded:
                // repetitive machine traffic would silt the graph.
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
            self.streamingChatID = nil
            self.startNextProactiveConversation()
        }
    }

    private func receiveImages(_ batch: ChatImageBatch) {
        guard !batch.images.isEmpty else { return }
        // A requested gallery wins over Gemini's later three-image grounding lookup.
        guard streamedImagePresentation != .gallery || batch.presentation == .gallery else { return }
        streamedImages = batch.images
        streamedImagePresentation = batch.presentation
        guard streamIsForeground,
              let index = model.entries.lastIndex(where: { $0.role == .assistant }) else { return }
        model.entries[index].images = batch.images
    }

    private func executeToolCall(_ call: ChatToolCall) async -> ChatToolResult {
        let verboseEntryID = appendVerboseToolEntry(for: call)
        let result = await toolRouter.execute(
            call,
            confirm: { [weak self] details in
                guard let self else { return false }
                return await self.requestConfirmation(details)
            },
            onStatus: { [weak self] status in
                guard let self, self.streamIsForeground else { return }
                self.model.status = status
            }
        )
        if let verboseEntryID {
            finishVerboseToolEntry(verboseEntryID, with: result)
        }
        return result
    }

    /// When verbose mode is on, inserts a transcript row for the call and
    /// returns its id. Inserted before the trailing empty assistant entry so
    /// appendToken keeps writing to the assistant entry.
    private func appendVerboseToolEntry(for call: ChatToolCall) -> UUID? {
        guard UserPreferences.verboseToolCalls(), streamIsForeground else { return nil }
        return insertToolEntry(
            "⚙ \(call.name) \(Self.compactJSON(call.arguments, limit: 200))"
        )
    }

    /// Inserts a `.tool` transcript row before the trailing empty assistant
    /// entry so appendToken keeps writing to the assistant entry.
    private func insertToolEntry(_ text: String) -> UUID {
        let entry = ChatBubbleEntry(role: .tool, text: text)
        if model.entries.last?.role == .assistant, model.entries.last?.text.isEmpty == true {
            model.entries.insert(entry, at: model.entries.count - 1)
        } else {
            model.entries.append(entry)
            model.entries.append(ChatBubbleEntry(role: .assistant, text: ""))
        }
        return entry.id
    }

    private func finishVerboseToolEntry(_ id: UUID, with result: ChatToolResult) {
        guard streamIsForeground,
              let index = model.entries.firstIndex(where: { $0.id == id }) else { return }
        model.entries[index].text += "\n→ \(Self.compactJSON(result.response, limit: 500))"
        // Shown tool rows persist with the chat; filtered off the wire in
        // startStream, rebuilt by entries(from:).
        history.append(ChatMessage(role: "tool", content: model.entries[index].text))
    }

    private static func compactJSON(_ values: [String: ChatToolValue], limit: Int) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(values))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return json.count > limit ? String(json.prefix(limit)) + "…" : json
    }

    private func requestConfirmation(_ details: ToolConfirmationDetails) async -> Bool {
        // A backgrounded stream has no UI to ask in; deny rather than hang.
        guard streamIsForeground else { return false }
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
        if streamIsForeground {
            // The user's decision is always worth recording, verbose or not.
            let record = "\(details.title) — \(approved ? "approved" : "denied")"
            _ = insertToolEntry(record)
            history.append(ChatMessage(role: "tool", content: record))
        }
        return approved && !Task.isCancelled
    }

    func resolveToolConfirmation(approved: Bool) {
        model.pendingToolConfirmation = nil
        confirmationBroker.resolve(approved: approved)
    }

    /// Records the outcome of a stream whose chat is no longer on screen,
    /// directly against the persisted copy: append the (partial) answer, or
    /// drop the unanswered question so a retry doesn't duplicate it. The chat
    /// is guaranteed on disk because leaving it (new/switch) saved it.
    private func finalizeBackgroundExchange(
        chatID: UUID,
        streamed: String,
        images: [ChatImage]
    ) {
        guard var chat = chatStore.load(id: chatID) else { return }
        if streamed.isEmpty, images.isEmpty, chat.messages.last?.source == nil {
            if chat.messages.last?.role == "user" { chat.messages.removeLast() }
        } else {
            chat.messages.append(ChatMessage(
                role: "assistant",
                content: streamed,
                images: images.isEmpty ? nil : images
            ))
        }
        chat.updatedAt = Date()
        if chat.messages.isEmpty {
            chatStore.delete(id: chatID)
        } else {
            chatStore.save(chat)
        }
        refreshChatList()
    }

    /// If the in-flight stream belongs to the chat now on screen, splice its
    /// partial output back into the freshly rebuilt transcript so tokens
    /// continue appending live.
    private func attachStreamIfActive() {
        guard streamIsForeground, streamTask != nil else { return }
        model.entries.append(ChatBubbleEntry(
            role: .assistant,
            text: streamedBuffer,
            images: streamedImages
        ))
        model.phase = .streaming
        model.status = streamedBuffer.isEmpty ? "Thinking…" : ""
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
    /// picked a dedicated memory provider (and optionally model). Thinking is
    /// disabled for OpenAI-compatible extraction: parsing one exchange into
    /// JSON needs no deliberation, and slow extraction loses memories when the
    /// app quits before the fire-and-forget ingest task finishes.
    private static func memoryClient(fallback: any ChatClient) -> any ChatClient {
        guard let provider = MemoryProviderPreference.selected else {
            if ChatProviderPreference.selected == .openAICompatible {
                return OpenAICompatibleClient(thinking: false)
            }
            return fallback
        }
        return provider.makeClient(model: MemoryProviderPreference.model, thinking: false)
    }

    /// Fetches the active provider's model list so the header picker can
    /// appear when there is more than one to choose from.
    private func refreshModels() {
        let provider = ChatProviderPreference.selected
        let current = provider.storedModel()
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
        UserDefaults.standard.set(id, forKey: provider.modelKey)
        model.currentModel = id
    }

    private func startNewChat() {
        resetTranscript(to: StoredChat())
    }

    private func switchToChat(id: UUID) {
        guard id != currentChat.id, let chat = chatStore.load(id: id) else { return }
        resolveToolConfirmation(approved: false)
        chatStore.save(currentChat)
        currentChat = chat
        model.phase = .idle
        model.entries = Self.entries(from: chat.messages)
        attachStreamIfActive()
        refreshChatList()
        setExpanded(true)
        restoreTerminal()
    }

    deinit {
        removeEventMonitors()
        removeWindowObservers()
    }
}
