import Foundation
import SwiftUI

// MARK: - Models

/// A single item in the server changelog (an added feature, fix, etc.)
struct ServerChangelogItem: Decodable, Sendable {
    let title: String
    let content: String
    let raw: String?
}

/// One version entry from `/api/changelog`
struct ServerChangelogEntry: Sendable {
    let version: String
    let date: String
    let added: [ServerChangelogItem]
    let fixed: [ServerChangelogItem]
    let changed: [ServerChangelogItem]
    let removed: [ServerChangelogItem]

    /// Renders the changelog as clean markdown suitable for `MarkdownView`.
    var markdownText: String {
        var sections: [String] = []

        func renderItem(_ item: ServerChangelogItem) -> String {
            // `raw` is HTML (for the web browser) — never use it in a Markdown renderer.
            // Use `title` + `content` which are always plain text.
            //
            // New format: title = "📜 Chat scroll position on load."
            //             content = "Opening a chat conversation now reliably..."
            //   → "* **📜 Chat scroll position on load.** Opening a chat..."
            //
            // Old format: title = ""
            //             content = "🔇 Voice Mode mute control. Voice Mode now includes..."
            //   The first sentence IS the title — split on first ". " and bold it.
            //   → "* **🔇 Voice Mode mute control.** Voice Mode now includes..."

            let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedContent = item.content.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmedTitle.isEmpty {
                // Explicit title provided
                if trimmedContent.isEmpty {
                    return "* **\(trimmedTitle)**"
                }
                return "* **\(trimmedTitle)** \(trimmedContent)"
            }

            // No title — content starts with the title baked in as the first sentence.
            // Split on the first ". " (period + space) to extract it.
            if let dotRange = trimmedContent.range(of: ". ") {
                let firstSentence = String(trimmedContent[trimmedContent.startIndex..<dotRange.lowerBound])
                let rest = String(trimmedContent[dotRange.upperBound...])
                return "* **\(firstSentence).** \(rest)"
            }

            // No period found — just show the whole thing as plain bullet
            return "* \(trimmedContent)"
        }

        if !added.isEmpty {
            sections.append("### What's New\n" + added.map(renderItem).joined(separator: "\n"))
        }
        if !changed.isEmpty {
            sections.append("### Improvements\n" + changed.map(renderItem).joined(separator: "\n"))
        }
        if !fixed.isEmpty {
            sections.append("### Bug Fixes\n" + fixed.map(renderItem).joined(separator: "\n"))
        }
        if !removed.isEmpty {
            sections.append("### Removed\n" + removed.map(renderItem).joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }
}

/// Passed to the sheet when a newer server version is detected.
struct ServerUpdateInfo: Identifiable, Sendable {
    var id: String { version }
    let version: String
    let serverName: String
    /// The full base URL of the server (e.g. "https://chat.abhiinnovate.com").
    /// Used to construct the favicon URL in the update sheet.
    let serverURL: String
    let changelogs: [ServerChangelogEntry]
}

// MARK: - Raw Decodable Wrappers

private struct VersionUpdatesResponse: Decodable {
    let current: String
    let latest: String
}

/// The changelog endpoint returns `{ "0.9.2": { ... }, "0.9.1": { ... } }`
/// We decode it as a dictionary of raw entries.
private struct RawChangelogEntry: Decodable {
    let date: String?
    let added: [ServerChangelogItem]?
    let fixed: [ServerChangelogItem]?
    let changed: [ServerChangelogItem]?
    let removed: [ServerChangelogItem]?
}

// MARK: - ServerUpdateChecker

/// Checks the connected Open WebUI server for a newer version using
/// `/api/version/updates` and `/api/changelog`.
///
/// - Runs on every app launch (when authenticated).
/// - Mirrors the same pending/available pattern as `UpdateChecker`.
/// - Fails silently — the server check is non-critical.
@Observable
@MainActor
final class ServerUpdateChecker {

    // MARK: Published State

    /// Non-nil when a newer server version is available and the sheet should show.
    var availableUpdate: ServerUpdateInfo? = nil

    /// Persists after the sheet is dismissed — used to keep the update icon visible.
    var pendingUpdate: ServerUpdateInfo? = nil

    /// `true` while an on-demand check is in progress.
    var isChecking: Bool = false

    // MARK: Public API

    /// Checks for a server update using the provided authenticated `APIClient`.
    /// Safe to call on every app launch.
    func checkForUpdates(using apiClient: APIClient?) async {
        guard let apiClient else { return }
        do {
            guard let info = try await fetchUpdateInfo(from: apiClient) else { return }
            pendingUpdate = info
            availableUpdate = info
        } catch {
            // Fail silently
        }
    }

    /// On-demand check triggered from Settings → About (Server section).
    func checkForUpdatesManually(using apiClient: APIClient?) async {
        isChecking = true
        defer { isChecking = false }
        guard let apiClient else { return }
        do {
            guard let info = try await fetchUpdateInfo(from: apiClient) else {
                // Up to date
                availableUpdate = nil
                pendingUpdate = nil
                return
            }
            pendingUpdate = info
            availableUpdate = info
        } catch {
            // Fail silently
        }
    }

    /// Hides the sheet but keeps `pendingUpdate` so the update icon stays visible.
    func dismissUpdate() {
        availableUpdate = nil
    }

    /// Re-presents the sheet for the pending update (called from the update icon).
    func reopenUpdate() {
        availableUpdate = pendingUpdate
    }

    /// Clears all update state (called on server switch / logout).
    func reset() {
        availableUpdate = nil
        pendingUpdate = nil
        isChecking = false
    }

    // MARK: Private Helpers

    private func fetchUpdateInfo(from apiClient: APIClient) async throws -> ServerUpdateInfo? {
        // 1. Check if an update is available
        let request = try apiClient.network.buildRequest(
            path: "/api/version/updates",
            authenticated: true,
            timeout: 10
        )
        let (data, response) = try await apiClient.network.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }

        let versionResponse = try JSONDecoder().decode(VersionUpdatesResponse.self, from: data)
        let latestVersion = versionResponse.latest
        let currentVersion = versionResponse.current

        guard isNewer(remote: latestVersion, than: currentVersion) else {
            // Server is up to date — clear any lingering state
            availableUpdate = nil
            pendingUpdate = nil
            return nil
        }

        // 2. Fetch the top 3 changelogs (latest + recent history)
        let changelogs = (try? await fetchChangelogs(upTo: latestVersion, from: apiClient)) ?? []

        // Derive a friendly server name from the base URL
        let serverName = URL(string: apiClient.baseURL)?.host ?? apiClient.baseURL

        return ServerUpdateInfo(
            version: latestVersion,
            serverName: serverName,
            serverURL: apiClient.baseURL,
            changelogs: changelogs
        )
    }

    /// Fetches `/api/changelog`, sorts all versions descending by semver,
    /// and returns the top 3 entries that are ≤ `latestVersion`.
    private func fetchChangelogs(upTo latestVersion: String, from apiClient: APIClient) async throws -> [ServerChangelogEntry] {
        let request = try apiClient.network.buildRequest(
            path: "/api/changelog",
            authenticated: true,
            timeout: 10
        )
        let (data, response) = try await apiClient.network.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }

        let allEntries = try JSONDecoder().decode([String: RawChangelogEntry].self, from: data)

        return allEntries
            .filter { !isNewer(remote: $0.key, than: latestVersion) }
            .sorted { isNewer(remote: $0.key, than: $1.key) }
            .prefix(3)
            .map { (version, raw) in
                ServerChangelogEntry(
                    version: version,
                    date: raw.date ?? "",
                    added: raw.added ?? [],
                    fixed: raw.fixed ?? [],
                    changed: raw.changed ?? [],
                    removed: raw.removed ?? []
                )
            }
    }

    /// Returns `true` if `remote` is strictly newer than `local` (semver comparison).
    private func isNewer(remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(r.count, l.count)
        for i in 0..<maxLen {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
