//
//  TextreamApp.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let openAbout = Notification.Name("openAbout")
}

enum AppRuntime {
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let isRunningUITests =
        ProcessInfo.processInfo.arguments.contains("-ui-testing") ||
        ProcessInfo.processInfo.environment["TEXTREAM_UI_TESTING"] == "1"
    static let isHeadlessTestRuntime = isRunningTests && !isRunningUITests
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isHeadlessTestRuntime else { return }
        UITestRuntimeSupport.configureIfNeeded()
        NSWindow.allowsAutomaticWindowTabbing = false
        let launchedByURL: Bool
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchedByURL = event.eventClass == kInternetEventClass
        } else {
            launchedByURL = false
        }
        if launchedByURL {
            TextreamService.shared.launchedExternally = true
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isHeadlessTestRuntime else { return }
        NSApp.servicesProvider = TextreamService.shared
        if !AppRuntime.isRunningUITests {
            NSUpdateDynamicServices()
        }
        AttachedDiagnosticsStore.shared.refreshPermissionState()
        AttachedDiagnosticsStore.shared.markInactive(
            message: "Attached mode inactive",
            targetWindowID: NotchSettings.shared.attachedTargetWindowID,
            targetWindowLabel: NotchSettings.shared.attachedTargetWindowLabel
        )

        if TextreamService.shared.launchedExternally {
            TextreamService.shared.hideMainWindow()
        }

        if !AppRuntime.isRunningUITests {
            // Silent update check on launch
            UpdateChecker.shared.checkForUpdates(silent: true)

            // Start browser server if enabled
            TextreamService.shared.updateBrowserServer()

            // Start director server if enabled
            TextreamService.shared.updateDirectorServer()

            // Set window delegate to intercept close, disable tabs and fullscreen
            DispatchQueue.main.async {
                for window in NSApp.windows where !(window is NSPanel) {
                    window.delegate = self
                    window.tabbingMode = .disallowed
                    window.collectionBehavior.remove(.fullScreenPrimary)
                    window.collectionBehavior.insert(.fullScreenNone)
                }
                self.removeUnwantedMenus()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !AppRuntime.isHeadlessTestRuntime else { return }
        AttachedDiagnosticsStore.shared.refreshPermissionState()
    }

    private func removeUnwantedMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Remove View and Window menus (keep Edit for copy/paste)
        let menusToRemove = ["View", "Window"]
        for title in menusToRemove {
            if let index = mainMenu.items.firstIndex(where: { $0.title == title }) {
                mainMenu.removeItem(at: index)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if TextreamService.shared.hasUnsavedChanges {
            guard TextreamService.shared.confirmDiscardIfNeeded() else { return false }
        }
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if TextreamService.shared.launchedExternally {
            TextreamService.shared.launchedExternally = false
            NSApp.setActivationPolicy(.regular)
        }
        if !flag {
            // Show existing window instead of letting SwiftUI create a duplicate
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension == "textream" {
                TextreamService.shared.openFileAtURL(url)
                // Show the main window for file opens
                for window in NSApp.windows where !(window is NSPanel) {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            } else {
                let wasExternal = TextreamService.shared.launchedExternally
                TextreamService.shared.launchedExternally = true
                if !wasExternal {
                    NSApp.setActivationPolicy(.accessory)
                }
                TextreamService.shared.hideMainWindow()
                TextreamService.shared.handleURL(url)
            }
        }
    }
}

@main
struct TextreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        UITestRuntimeSupport.configureIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            if AppRuntime.isHeadlessTestRuntime {
                Color.clear
                    .frame(width: 1, height: 1)
            } else {
                rootContentView
                    .onOpenURL { url in
                        if url.pathExtension == "textream" {
                            TextreamService.shared.openFileAtURL(url)
                        } else {
                            TextreamService.shared.handleURL(url)
                        }
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Textream") {
                    NotificationCenter.default.post(name: .openAbout, object: nil)
                }
                Divider()
                Button("Check for Updates…") {
                    UpdateChecker.shared.checkForUpdates()
                }
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open File or Presentation…") {
                    TextreamService.shared.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Save") {
                    TextreamService.shared.saveFile()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As…") {
                    TextreamService.shared.saveFileAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .windowArrangement) { }
            CommandGroup(replacing: .help) {
                Button("Textream Help") {
                    if let url = URL(string: "https://github.com/f/textream") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rootContentView: some View {
        if AppRuntime.isRunningUITests {
            UITestHarnessRootView()
        } else {
            ContentView()
        }
    }
}
