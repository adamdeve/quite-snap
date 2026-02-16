//
//  ContentView.swift
//  QuietSnap
//
//  Created by Adam on 2/15/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var snapService: WindowSnapService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("QuietSnap")
                .font(.title.bold())

            Text("Automatically resize newly opened app windows to an almost-maximized size.")
                .foregroundStyle(.secondary)

            HStack {
                Circle()
                    .fill(snapService.isAccessibilityGranted ? .green : .orange)
                    .frame(width: 10, height: 10)
                Text(snapService.isAccessibilityGranted ? "Accessibility permission granted" : "Accessibility permission required")
                    .font(.headline)
            }

            Button("Open Accessibility Settings") {
                snapService.openAccessibilitySettings()
            }

            Button("Recheck Permission") {
                snapService.refreshAccessibilityStatus()
                snapService.start()
            }
            .buttonStyle(.bordered)

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { snapService.isLaunchAtLoginEnabled },
                    set: { snapService.setLaunchAtLogin($0) }
                )
            )

            if let launchAtLoginError = snapService.launchAtLoginError {
                Text("Launch at Login error: \(launchAtLoginError)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Text("Horizontal snap area")
                        .font(.title3)

                    Slider(value: $snapService.horizontalSnapMargin, in: 0...240, step: 1)

                    Text("\(Int(snapService.horizontalSnapMargin)) px")
                        .font(.title3)
                        .monospacedDigit()
                }

                Text("If the area is too large, newly opened app windows may become too narrow.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("Manual snap shortcut: Control + Option + Return")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Once permission is granted, launch or relaunch an app and QuietSnap will resize its non-fullscreen window automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 260)
    }
}

#Preview {
    ContentView()
        .environmentObject(WindowSnapService())
}
