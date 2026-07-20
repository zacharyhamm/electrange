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
    @State private var appModel = AppModel()

    var body: some Scene {
        // Window (not WindowGroup) so File > New Window can't spawn a second
        // pet view fighting over the same NSWindow
        Window("Electragne", id: "pet") {
            ContentView(appModel: appModel)
                .onAppear {
                    appDelegate.appModel = appModel
                    appModel.startCalendarMonitoring { [weak appDelegate] event in
                        appDelegate?.presentCalendarReminder(event)
                    }
                    appModel.startAutomations { [weak appDelegate] name, payload in
                        appDelegate?.presentAutomationNotice(name: name, payload: payload)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
