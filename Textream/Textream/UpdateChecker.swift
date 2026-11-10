//
//  UpdateChecker.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 9.02.2026.
//

import AppKit
import Security

/// Checks GitHub for new releases and installs them in place.
///
/// Only used by direct-download builds. App Store builds are updated
/// exclusively through the App Store.
class UpdateChecker {
    static let shared = UpdateChecker()

    private let repoOwner = "f"
    private let repoName = "textream"
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private let retryWhilePromptingInterval: TimeInterval = 15 * 60

    private var periodicTimer: Timer?
    private var dismissedVersion: String?
    private var isInstalling = false
    private var progressPanel: NSPanel?

    private struct Release {
        let version: String
        let pageURL: URL
        let dmgURL: URL?
    }

    private enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The release asset built for the running macOS version.
    private var preferredAssetName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            ? "Textream.dmg"
            : "Textream-macos15.dmg"
    }

    // MARK: - Checking

    /// Check now, then once a day while the app stays open.
    func startPeriodicChecks() {
        checkForUpdates(silent: true)
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdates(silent: true)
        }
    }

    /// Check GitHub for the latest release and prompt the user if an update is available.
    func checkForUpdates(silent: Bool = false) {
        guard !isInstalling else { return }

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            DispatchQueue.main.async {
                if let error {
                    if !silent {
                        self.showError("Could not check for updates.\n\(error.localizedDescription)")
                    }
                    return
                }

                guard let data, let release = self.parseRelease(data) else {
                    if !silent {
                        self.showError("Could not parse the release information.")
                    }
                    return
                }

                guard self.isVersion(release.version, newerThan: self.currentVersion) else {
                    if !silent { self.showUpToDate() }
                    return
                }

                if silent {
                    // Never interrupt someone who is reading from the prompter.
                    if TextreamService.shared.overlayController.isShowing {
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.retryWhilePromptingInterval) {
                            self.checkForUpdates(silent: true)
                        }
                        return
                    }
                    // Respect "Later" until the next launch.
                    if self.dismissedVersion == release.version { return }
                }

                self.showUpdateAvailable(release)
            }
        }.resume()
    }

    private func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let htmlURLString = json["html_url"] as? String,
              let pageURL = URL(string: htmlURLString) else {
            return nil
        }

        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmgURL = assets
            .first { ($0["name"] as? String) == preferredAssetName }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap { URL(string: $0) }

        return Release(version: version, pageURL: pageURL, dmgURL: dmgURL)
    }

    // MARK: - Version comparison

    private func isVersion(_ remote: String, newerThan local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    // MARK: - Installing

    /// In-place installs need a Developer ID signature to compare against and
    /// a writable install location (not a disk image or translocated copy).
    private var canInstallInPlace: Bool {
        guard currentTeamIdentifier() != nil else { return false }
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent)
    }

    private func install(_ release: Release, from dmgURL: URL) {
        guard !isInstalling else { return }
        guard TextreamService.shared.confirmDiscardIfNeeded() else { return }

        isInstalling = true
        showProgress("Downloading Textream \(release.version)…")

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextreamUpdate-\(UUID().uuidString)", isDirectory: true)

        URLSession.shared.downloadTask(with: dmgURL) { [weak self] tempURL, response, error in
            guard let self else { return }
            do {
                if let error { throw error }
                guard let tempURL,
                      (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError.message("The download did not complete.")
                }
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                let dmgPath = workDir.appendingPathComponent("Textream.dmg")
                try FileManager.default.moveItem(at: tempURL, to: dmgPath)

                DispatchQueue.main.async { self.updateProgress("Installing Textream \(release.version)…") }
                let installedURL = try self.installApp(fromDiskImage: dmgPath, workDir: workDir, expectedVersion: release.version)
                try? FileManager.default.removeItem(at: workDir)

                DispatchQueue.main.async { self.relaunch(at: installedURL) }
            } catch {
                try? FileManager.default.removeItem(at: workDir)
                DispatchQueue.main.async {
                    self.isInstalling = false
                    self.hideProgress()
                    self.showInstallFailed(error.localizedDescription, release: release)
                }
            }
        }.resume()
    }

    /// Mounts the disk image, verifies the app inside, and swaps it in for the
    /// running copy. Returns the location of the installed app.
    private func installApp(fromDiskImage dmgPath: URL, workDir: URL, expectedVersion: String) throws -> URL {
        let mountPoint = workDir.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmgPath.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let contents = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.message("The disk image does not contain an app.")
        }

        try verify(newApp, expectedVersion: expectedVersion)

        // Stage next to the current app so the final swap stays on one volume.
        let currentApp = Bundle.main.bundleURL
        let staged = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".Textream-\(expectedVersion)-\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [newApp.path, staged.path])

        do {
            let result = try FileManager.default.replaceItemAt(currentApp, withItemAt: staged)
            return result ?? currentApp
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// The new app must be the same app, a newer version, and signed with the
    /// same Developer ID team as the running copy.
    private func verify(_ appURL: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: appURL),
              let bundleID = bundle.bundleIdentifier,
              bundleID == Bundle.main.bundleIdentifier else {
            throw UpdateError.message("The downloaded app is not Textream.")
        }

        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard version == expectedVersion, isVersion(version, newerThan: currentVersion) else {
            throw UpdateError.message("The downloaded app has an unexpected version (\(version)).")
        }

        guard let teamID = currentTeamIdentifier() else {
            throw UpdateError.message("This copy of Textream is not signed with a Developer ID.")
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw UpdateError.message("Could not read the downloaded app's signature.")
        }

        let requirementText = """
            anchor apple generic \
            and identifier "\(bundleID)" \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] \
            and certificate leaf[subject.OU] = "\(teamID)"
            """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess else {
            throw UpdateError.message("Could not build the signature requirement.")
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw UpdateError.message("The downloaded app's signature does not match this copy of Textream.")
        }
    }

    private func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Waits for this process to exit, then opens the installed app.
    private func relaunch(at appURL: URL) {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", pid, appURL.path]
        do {
            try process.run()
        } catch {
            isInstalling = false
            hideProgress()
            showError("Textream was updated. Please reopen it to finish.")
            return
        }
        NSApp.terminate(nil)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let name = (tool as NSString).lastPathComponent
            throw UpdateError.message("\(name) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    // MARK: - Progress

    private func showProgress(_ text: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
            styleMask: [.titled, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Updating Textream"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: text)
        label.identifier = NSUserInterfaceItemIdentifier("status")

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        panel.contentView = stack

        panel.center()
        panel.orderFrontRegardless()
        progressPanel = panel
    }

    private func updateProgress(_ text: String) {
        let label = progressPanel?.contentView?.subviews
            .first { $0.identifier?.rawValue == "status" } as? NSTextField
        label?.stringValue = text
    }

    private func hideProgress() {
        progressPanel?.close()
        progressPanel = nil
    }

    // MARK: - Alerts

    private func showUpdateAvailable(_ release: Release) {
        let installable = release.dmgURL != nil && canInstallInPlace

        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Textream \(release.version) is available. You are currently running \(currentVersion)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: installable ? "Install and Relaunch" : "Download")
        alert.addButton(withTitle: "Later")
        if installable {
            alert.addButton(withTitle: "Release Notes")
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if installable, let dmgURL = release.dmgURL {
                install(release, from: dmgURL)
            } else {
                NSWorkspace.shared.open(release.pageURL)
            }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            dismissedVersion = release.version
        }
    }

    private func showInstallFailed(_ message: String, release: Release) {
        let alert = NSAlert()
        alert.messageText = "Update Failed"
        alert.informativeText = "\(message)\n\nYou can download Textream \(release.version) from the release page instead."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "Textream \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
