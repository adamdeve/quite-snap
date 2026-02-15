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
    @StateObject private var snapService = WindowSnapService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(snapService)
                .onAppear {
                    appDelegate.snapService = snapService
                    snapService.start()
                }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var snapService: WindowSnapService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        snapService?.start()
    }
}
