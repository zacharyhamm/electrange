//
//  electragneApp.swift
//  electragne
//
//  Created by zacharyhamm on 2/3/26.
//

import SwiftUI

@main
struct ElectragneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Window (not WindowGroup) so File > New Window can't spawn a second
        // pet view fighting over the same NSWindow
        Window("Electragne", id: "pet") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
