//
//  ChatBubbleModel.swift
//  electragne
//
//  Observable state shared between ChatBubbleWindowController and the
//  SwiftUI bubble views.
//

import Foundation
import Observation
import SwiftTerm

enum ChatBubblePhase: Equatable {
    case idle
    case streaming
    case failed(String)
}

struct ChatBubbleEntry: Equatable, Identifiable {
    enum Role {
        case user
        case assistant
        case tool
        case automation
    }

    let id = UUID()
    let role: Role
    var text: String
    var images: [ChatImage] = []
}

struct PendingToolConfirmation: Equatable, Identifiable {
    let id: UUID
    let details: ToolConfirmationDetails
}

@Observable
final class ChatBubbleModel {
    var text = ""
    var tailEdge: ChatBubbleTailEdge = .bottom
    var tailOffset = ChatBubblePlacement.defaultSize.width / 2
    var entries: [ChatBubbleEntry] = []
    var status = "Thinking…"
    var phase: ChatBubblePhase = .idle
    var availableChats: [ChatSummary] = []
    var currentChatID: UUID?
    var availableModels: [String] = []
    var currentModel = ""
    var fontSize: CGFloat = UserPreferences.chatFontSize()
    var pendingToolConfirmation: PendingToolConfirmation?
    /// The current chat's terminal, shown beside the transcript when non-nil.
    /// The view is owned by TerminalPanelController; this is just attachment.
    var terminalView: LocalProcessTerminalView?
    var terminalWidth: CGFloat = 0

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
