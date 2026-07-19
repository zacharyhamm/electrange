//
//  CGFloat+Clamped.swift
//  electragne
//

import Foundation

extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
