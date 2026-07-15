//
//  Weak.swift
//  electragne
//

import Foundation

/// Weak reference wrapper to avoid retaining objects like child windows
struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) {
        self.value = value
    }
}
