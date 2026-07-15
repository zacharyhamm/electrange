//
//  ToolConfirmationDetails.swift
//  electragne
//
//  The user-facing confirmation card shown before a tool mutates anything.
//  Shared by every tool family.
//

import Foundation

nonisolated struct ToolConfirmationDetails: Equatable, Sendable {
    let title: String
    let primaryText: String
    let details: [(label: String, value: String)]
    let actionLabel: String

    static func == (lhs: ToolConfirmationDetails, rhs: ToolConfirmationDetails) -> Bool {
        lhs.title == rhs.title
            && lhs.primaryText == rhs.primaryText
            && lhs.details.elementsEqual(rhs.details, by: ==)
            && lhs.actionLabel == rhs.actionLabel
    }
}
