//
//  UpdateChecker.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 9.02.2026.
//

import AppKit

class UpdateChecker {
    static let shared = UpdateChecker()

    private let repoOwner = "f"
    private let repoName = "textream"

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Check GitHub for the latest release and prompt the user if an update is available.
    func checkForUpdates(silent: Bool = false) {
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
                        self.showError(L10n.tr("Could not check for updates.\n%@", error.localizedDescription))
                    }
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let htmlURL = json["html_url"] as? String else {
                    if !silent {
                        self.showError(L10n.tr("Could not parse the release information."))
                    }
                    return
                }

                let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

                if self.isVersion(latestVersion, newerThan: self.currentVersion) {
                    self.showUpdateAvailable(latestVersion: latestVersion, releaseURL: htmlURL)
                } else if !silent {
                    self.showUpToDate()
                }
            }
        }.resume()
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

    // MARK: - Alerts

    private func showUpdateAvailable(latestVersion: String, releaseURL: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Update Available")
        alert.informativeText = L10n.tr("Textream %@ is available. You are currently running %@.", latestVersion, currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr("Download"))
        alert.addButton(withTitle: L10n.tr("Later"))

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: releaseURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("You're Up to Date")
        alert.informativeText = L10n.tr("Textream %@ is the latest version.", currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr("OK"))
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Update Check Failed")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("OK"))
        alert.runModal()
    }
}
