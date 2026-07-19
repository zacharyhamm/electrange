//
//  ChatBubbleViews.swift
//  electragne
//
//  SwiftUI views for the chat bubble: the bubble itself, the transcript,
//  and the speech-bubble shape.
//

import SwiftUI

struct ChatBubbleView: View {
    @Bindable var model: ChatBubbleModel
    let onDismiss: () -> Void
    let onSubmit: (String) -> Void
    let onNewChat: () -> Void
    let onSelectChat: (UUID) -> Void
    let onSelectModel: (String) -> Void
    let onConfirmTool: () -> Void
    let onCancelTool: () -> Void

    @FocusState private var inputIsFocused: Bool
    @AppStorage(UserPreferences.chatOpacityKey)
    private var chatOpacity = UserPreferences.defaultChatOpacity

    private var trimmedText: String {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bubbleOpacity: Double {
        chatOpacity > 0
            ? chatOpacity.clamped(to: UserPreferences.chatOpacityRange)
            : UserPreferences.defaultChatOpacity
    }

    var body: some View {
        ZStack {
            ChatBubbleShape(edge: model.tailEdge, tailOffset: model.tailOffset)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(bubbleOpacity))
                .overlay {
                    ChatBubbleShape(edge: model.tailEdge, tailOffset: model.tailOffset)
                        .stroke(Color.primary.opacity(0.85), lineWidth: 3)
                }
                .shadow(color: .black.opacity(0.16 * bubbleOpacity), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text("sheepchat. baaa.")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    if model.availableModels.count > 1 {
                        Menu {
                            ForEach(model.availableModels, id: \.self) { id in
                                Button {
                                    onSelectModel(id)
                                } label: {
                                    if id == model.currentModel {
                                        Label(id, systemImage: "checkmark")
                                    } else {
                                        Text(id)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "cpu")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Model")
                    }

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
            .padding(.top, model.tailEdge == .top ? 24 : 14)
            .padding(.bottom, model.tailEdge == .bottom ? 24 : 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onExitCommand(perform: onDismiss)
        .background {
            // Window-scoped shortcuts. Invisible buttons let SwiftUI route
            // them while the chat panel is the key window.
            Group {
                Button("", action: onNewChat)
                    .keyboardShortcut("n", modifiers: .command)
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
        // Status is set while waiting, thinking, or running a tool, and
        // cleared on every content token.
        return !model.status.isEmpty
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
        case .tool:
            Text(entry.text)
                .font(.system(size: max(model.fontSize - 2, 9), design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChatBubbleShape: Shape {
    let edge: ChatBubbleTailEdge
    let tailOffset: CGFloat

    private let tailHeight: CGFloat = 14
    private let tailHalfWidth: CGFloat = 12
    private let cornerRadius: CGFloat = 18

    // One continuous subpath: the tail is a detour along the tail-side edge,
    // so a stroke never crosses the tail's base.
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

        let r = cornerRadius
        let topLeft = CGPoint(x: bodyRect.minX, y: bodyRect.minY)
        let topRight = CGPoint(x: bodyRect.maxX, y: bodyRect.minY)
        let bottomRight = CGPoint(x: bodyRect.maxX, y: bodyRect.maxY)
        let bottomLeft = CGPoint(x: bodyRect.minX, y: bodyRect.maxY)

        var path = Path()
        path.move(to: CGPoint(x: bodyRect.minX + r, y: bodyRect.minY))
        if edge == .top {
            path.addLine(to: CGPoint(x: tailOffset - tailHalfWidth, y: bodyRect.minY))
            path.addLine(to: CGPoint(x: tailOffset, y: rect.minY))
            path.addLine(to: CGPoint(x: tailOffset + tailHalfWidth, y: bodyRect.minY))
        }
        path.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: r)
        path.addArc(tangent1End: bottomRight, tangent2End: bottomLeft, radius: r)
        if edge == .bottom {
            path.addLine(to: CGPoint(x: tailOffset + tailHalfWidth, y: bodyRect.maxY))
            path.addLine(to: CGPoint(x: tailOffset, y: rect.maxY))
            path.addLine(to: CGPoint(x: tailOffset - tailHalfWidth, y: bodyRect.maxY))
        }
        path.addArc(tangent1End: bottomLeft, tangent2End: topLeft, radius: r)
        path.addArc(tangent1End: topLeft, tangent2End: topRight, radius: r)
        path.closeSubpath()
        return path
    }
}
