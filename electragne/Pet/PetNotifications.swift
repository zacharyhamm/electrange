//
//  PetNotifications.swift
//  electragne
//
//  Cross-object signals between AppDelegate and PetViewModel. Slated for
//  removal in favor of direct calls (refactor phase A1).
//

import Foundation

extension Notification.Name {
    static let petShouldPause = Notification.Name("petShouldPause")
    static let petShouldResume = Notification.Name("petShouldResume")
    static let petShouldSummonChat = Notification.Name("petShouldSummonChat")
}
