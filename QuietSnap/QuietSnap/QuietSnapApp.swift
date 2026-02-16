//
//  QuietSnapApp.swift
//  QuietSnap
//
//  Created by Adam on 2/15/26.
//

import SwiftUI

@main
struct QuietSnapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var snapService: WindowSnapService

    init() {
        let service = WindowSnapService()
        _snapService = StateObject(wrappedValue: service)
        appDelegate.snapService = service
    }

    var body: some Scene {
#if os(macOS)
        MenuBarExtra("QuietSnap", systemImage: "rectangle.3.offgrid") {
            ContentView()
                .environmentObject(snapService)

            Divider()

            Button("Quit QuietSnap") {
                NSApp.terminate(nil)
            }
        }
        .menuBarExtraStyle(.window)
#else
        WindowGroup {
            ContentView()
                .environmentObject(snapService)
        }
#endif
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var snapService: WindowSnapService?

    func applicationDidFinishLaunching(_ notification: Notification) {
#if os(macOS)
        NSApp.setActivationPolicy(.accessory)
#endif
        snapService?.start()
    }
}
