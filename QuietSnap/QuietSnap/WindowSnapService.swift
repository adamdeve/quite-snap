//
//  WindowSnapService.swift
//  QuietSnap
//
//  Created by Adam on 2/15/26.
//

import AppKit
import ApplicationServices
import Carbon
import Combine
import Foundation
import ServiceManagement

@MainActor
final class WindowSnapService: ObservableObject {
    private enum Preferences {
        static let horizontalMarginKey = "horizontalSnapMargin"
        static let defaultHorizontalMargin: CGFloat = 80
    }

    @Published private(set) var isAccessibilityGranted = false
    @Published private(set) var isRunning = false
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var launchAtLoginError: String?
    @Published var horizontalSnapMargin: CGFloat {
        didSet {
            let clamped = max(0, horizontalSnapMargin)
            if clamped != horizontalSnapMargin {
                horizontalSnapMargin = clamped
                return
            }
            UserDefaults.standard.set(horizontalSnapMargin, forKey: Preferences.horizontalMarginKey)
        }
    }

    private let launchCenter = NSWorkspace.shared.notificationCenter
    private let verticalSnapMargin: CGFloat = 24
    private let minimumWindowArea: CGFloat = 20_000
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    init() {
        let savedValue = UserDefaults.standard.object(forKey: Preferences.horizontalMarginKey) as? Double
        horizontalSnapMargin = CGFloat(savedValue ?? Preferences.defaultHorizontalMargin)
        refreshLaunchAtLoginStatus()
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
    }

    func start() {
        registerManualSnapHotKeyIfNeeded()

        refreshAccessibilityStatus(promptIfNeeded: true)
        guard isAccessibilityGranted else { return }

        if !isRunning {
            launchCenter.addObserver(
                self,
                selector: #selector(handleAppLaunch(_:)),
                name: NSWorkspace.didLaunchApplicationNotification,
                object: nil
            )
            isRunning = true
        }
    }

    func refreshAccessibilityStatus(promptIfNeeded: Bool = false) {
        if promptIfNeeded {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        isAccessibilityGranted = AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func snapFrontmostAppManually() {
        refreshAccessibilityStatus()
        guard isAccessibilityGranted else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        resizeEligibleWindow(for: app, allowMinimized: true)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        launchAtLoginError = nil

        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled {
                try service.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            launchAtLoginError = error.localizedDescription
            refreshLaunchAtLoginStatus()
        }
    }

    func refreshLaunchAtLoginStatus() {
        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    @objc
    private func handleAppLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        scheduleResizeAttempts(for: app)
    }

    private func scheduleResizeAttempts(for app: NSRunningApplication) {
        let delays: [TimeInterval] = [0.4, 0.8, 1.5, 2.5]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.resizeEligibleWindow(for: app)
            }
        }
    }

    private func resizeEligibleWindow(for app: NSRunningApplication, allowMinimized: Bool = false) {
        guard isAccessibilityGranted else { return }
        guard app.processIdentifier > 0 else { return }
        guard !app.isTerminated else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = firstEligibleWindow(in: appElement, allowMinimized: allowMinimized) else { return }

        let wasMinimized = (copyAttribute(kAXMinimizedAttribute, from: window) as? Bool) == true
        if wasMinimized {
            setMinimized(false, for: window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.snapWindow(window, in: app)
            }
            return
        }

        snapWindow(window, in: app)
    }

    private func firstEligibleWindow(in appElement: AXUIElement, allowMinimized: Bool = false) -> AXUIElement? {
        guard let windows = copyAttribute(kAXWindowsAttribute, from: appElement) as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            if isEligible(window: window, allowMinimized: allowMinimized) {
                return window
            }
        }
        return nil
    }

    private func isEligible(window: AXUIElement, allowMinimized: Bool = false) -> Bool {
        if (copyAttribute(kAXRoleAttribute, from: window) as? String) != kAXWindowRole as String {
            return false
        }

        if let subrole = copyAttribute(kAXSubroleAttribute, from: window) as? String,
           subrole != kAXStandardWindowSubrole as String {
            return false
        }

        if !allowMinimized, (copyAttribute(kAXMinimizedAttribute, from: window) as? Bool) == true {
            return false
        }

        if (copyAttribute("AXFullScreen", from: window) as? Bool) == true {
            return false
        }

        guard let currentSize = sizeValue(from: copyAttribute(kAXSizeAttribute, from: window), type: .cgSize) else {
            return false
        }

        return currentSize.width * currentSize.height >= minimumWindowArea
    }

    private func snapWindow(_ window: AXUIElement, in app: NSRunningApplication) {
        guard let (targetFrame, screen) = targetFrame(for: app) else { return }
        let targetAXOrigin = toAXOrigin(from: targetFrame, in: screen)

        guard let currentPosition = pointValue(from: copyAttribute(kAXPositionAttribute, from: window), type: .cgPoint),
              let currentSize = sizeValue(from: copyAttribute(kAXSizeAttribute, from: window), type: .cgSize) else {
            return
        }

        let positionDelta = abs(currentPosition.x - targetAXOrigin.x) + abs(currentPosition.y - targetAXOrigin.y)
        let sizeDelta = abs(currentSize.width - targetFrame.size.width) + abs(currentSize.height - targetFrame.size.height)
        if positionDelta < 8, sizeDelta < 12 {
            return
        }

        var origin = targetAXOrigin
        var size = targetFrame.size
        if let originValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    private func targetFrame(for app: NSRunningApplication) -> (CGRect, NSScreen)? {
        let screen = appScreen(for: app) ?? NSScreen.main
        guard let screen else { return nil }

        let frame = screen.visibleFrame
        let maxHorizontalInset = max(8, (frame.width / 2) - 120)
        let horizontalInset = min(maxHorizontalInset, horizontalSnapMargin)

        let targetWidth = min(frame.width, max(240, frame.width - (horizontalInset * 2)))
        let centeredX = frame.midX - (targetWidth / 2)
        let targetRect = CGRect(
            x: centeredX,
            y: frame.minY + verticalSnapMargin,
            width: targetWidth,
            height: min(frame.height, max(240, frame.height - (verticalSnapMargin * 2)))
        )

        return (targetRect, screen)
    }

    private func appScreen(for app: NSRunningApplication) -> NSScreen? {
        guard let appElement = app.focusedWindowElement,
              let axPoint = pointValue(from: copyAttribute(kAXPositionAttribute, from: appElement), type: .cgPoint) else {
            return NSScreen.main
        }

        for screen in NSScreen.screens {
            let appKitPoint = CGPoint(x: axPoint.x, y: screen.frame.maxY - axPoint.y)
            if screen.frame.contains(appKitPoint) {
                return screen
            }
        }

        return NSScreen.main
    }

    private func toAXOrigin(from appKitRect: CGRect, in screen: NSScreen) -> CGPoint {
        CGPoint(x: appKitRect.origin.x, y: screen.frame.maxY - appKitRect.maxY)
    }

    private func registerManualSnapHotKeyIfNeeded() {
        guard hotKeyRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let eventHandler: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let service = Unmanaged<WindowSnapService>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                service.snapFrontmostAppManually()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            eventHandler,
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: fourCharCode(from: "QSNP"), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Return),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func setMinimized(_ minimized: Bool, for window: AXUIElement) {
        let value: CFTypeRef = minimized ? kCFBooleanTrue : kCFBooleanFalse
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value)
    }

    private func fourCharCode(from string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    private func copyAttribute(_ name: String, from element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    private func pointValue(from rawValue: AnyObject?, type: AXValueType) -> CGPoint? {
        guard let rawValue, CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == type else { return nil }

        switch type {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetValue(value, type, &point) else { return nil }
            return point
        default:
            return nil
        }
    }

    private func sizeValue(from rawValue: AnyObject?, type: AXValueType) -> CGSize? {
        guard let rawValue, CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == type else { return nil }

        switch type {
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetValue(value, type, &size) else { return nil }
            return size
        default:
            return nil
        }
    }
}

private extension NSRunningApplication {
    var focusedWindowElement: AXUIElement? {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard error == .success, let window = value, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(window, to: AXUIElement.self)
    }
}
