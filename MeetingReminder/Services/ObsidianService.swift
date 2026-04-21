import AppKit
import Foundation
import SwiftUI

/// Represents a single vault registered with the Obsidian desktop app.
/// Parsed from `~/Library/Application Support/obsidian/obsidian.json`.
struct ObsidianVault: Identifiable, Hashable {
    /// Obsidian's internal vault id (a 16-char hex string).
    let id: String
    /// Absolute filesystem path to the vault root.
    let path: URL
    /// Human-readable vault name (the final path component).
    var name: String { path.lastPathComponent }
    /// Timestamp Obsidian recorded for this vault's last open.
    let lastOpened: Date?
}

/// Integration with the Obsidian desktop app.
///
/// Responsibilities:
/// - Detect whether Obsidian.app is installed (via bundle id `md.obsidian`)
/// - Read the vault registry from `~/Library/Application Support/obsidian/obsidian.json`
/// - Given a markdown file on disk, work out which vault it belongs to and
///   open it via the `obsidian://open?vault=<name>&file=<relative>` URL scheme
///
/// The URL scheme is the only supported way to deep-link into Obsidian without
/// a plugin. It requires the vault to already be registered with the app —
/// i.e. the user has opened it at least once. If the vault isn't registered
/// we fall back to launching Obsidian and letting the user open the file.
@MainActor
final class ObsidianService: ObservableObject {
    // MARK: - Published State

    @Published var isInstalled: Bool = false
    @Published var vaults: [ObsidianVault] = []
    @Published var lastError: String?

    // MARK: - User preferences

    /// Master feature flag — when false the entire Obsidian integration is
    /// dormant (no auto-open, no post-meeting button, no dashboard hooks).
    /// Defaults to false; user opts in from Settings → Obsidian.
    @AppStorage("obsidianIntegrationEnabled") var integrationEnabled: Bool = false

    /// When true, the app will automatically open the meeting note in Obsidian
    /// after a meeting ends (mirrors the Notion auto-open behaviour).
    @AppStorage("obsidianAutoOpenEnabled") var autoOpenEnabled: Bool = true

    // MARK: - Init

    init() {
        detect()
    }

    // MARK: - Detection

    /// Looks up Obsidian.app by bundle id and re-reads the vault registry.
    /// Safe to call repeatedly — this is how the Settings UI refreshes state.
    func detect() {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian")
        self.isInstalled = (appURL != nil)
        self.vaults = loadVaults()
        self.lastError = nil
    }

    /// Reads and parses `~/Library/Application Support/obsidian/obsidian.json`.
    /// The file is a JSON object of the form:
    /// ```
    /// {
    ///   "vaults": {
    ///     "<vault-id>": { "path": "/abs/path", "ts": 1720000000000, "open": true }
    ///   }
    /// }
    /// ```
    /// Missing file (fresh Obsidian install, user hasn't opened anything yet) is
    /// not an error — it just means `vaults` is empty.
    private func loadVaults() -> [ObsidianVault] {
        let configURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")

        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaultsDict = json["vaults"] as? [String: [String: Any]]
        else { return [] }

        var out: [ObsidianVault] = []
        for (id, entry) in vaultsDict {
            guard let path = entry["path"] as? String else { continue }
            let lastOpened: Date? = (entry["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000.0) }
            out.append(ObsidianVault(
                id: id,
                path: URL(fileURLWithPath: path),
                lastOpened: lastOpened
            ))
        }
        // Most-recent first so the Settings UI puts the active vault at the top
        return out.sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
    }

    // MARK: - Vault resolution

    /// Given an absolute path to a markdown file, return the vault that contains it
    /// (if any), plus the file's path relative to that vault's root.
    ///
    /// The Minutes CLI uses a symlink strategy by default: the markdown file lives
    /// at `~/meetings/<slug>.md` and a symlink is placed inside the vault at
    /// `<vault>/areas/meetings/<slug>.md`. To match against the vault's path we
    /// have to check BOTH the real path and the symlinked path.
    func resolveVaultAndRelativePath(for fileURL: URL) -> (vault: ObsidianVault, relativePath: String)? {
        guard !vaults.isEmpty else { return nil }

        // Candidate paths to test against each vault root:
        //   1. The real file path (e.g. ~/meetings/foo.md)
        //   2. Any symlinks inside each vault that point at the real file
        let realFilePath = fileURL.resolvingSymlinksInPath().path

        for vault in vaults {
            let vaultRoot = vault.path.resolvingSymlinksInPath().path

            // Case 1: the file literally lives inside the vault
            if realFilePath.hasPrefix(vaultRoot + "/") {
                let relative = String(realFilePath.dropFirst(vaultRoot.count + 1))
                return (vault, relative)
            }

            // Case 2: the file is reachable via a symlink inside the vault.
            // Minutes places meetings at `<vault>/areas/meetings/<slug>.md`,
            // configurable via `meetings_subdir`. We walk the vault looking for
            // any symlink whose resolved target matches the real file path.
            if let match = findSymlinkToFile(in: vault.path, targetRealPath: realFilePath) {
                let relative = String(match.dropFirst(vaultRoot.count + 1))
                return (vault, relative)
            }
        }
        return nil
    }

    /// Walk the top-level directories of the vault (shallow — only 3 levels deep)
    /// looking for a symlink whose resolved target is `targetRealPath`.
    /// Returns the absolute path of the symlink inside the vault, or nil.
    private func findSymlinkToFile(in vaultRoot: URL, targetRealPath: String) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: vaultRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        // Bound the search — don't walk arbitrary trees.
        var visited = 0
        let maxFiles = 5000

        for case let entry as URL in enumerator {
            visited += 1
            if visited > maxFiles { break }

            let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])

            // Descend into directories (the enumerator does this automatically,
            // but we need to let it through)
            if values?.isDirectory == true { continue }

            // Only care about symlinks
            if values?.isSymbolicLink != true { continue }

            let resolved = entry.resolvingSymlinksInPath().path
            if resolved == targetRealPath {
                return entry.path
            }
        }
        return nil
    }

    // MARK: - Opening

    /// Open a meeting note in Obsidian, or fall back gracefully.
    ///
    /// The preferred path is the `obsidian://open` URL scheme with the resolved
    /// vault name and relative path. If we can't find a matching vault, we launch
    /// Obsidian.app itself so the user is at least in the right editor.
    /// As a last resort (no Obsidian installed) we open the file with the system
    /// default handler.
    func openMeetingNote(at fileURL: URL) {
        guard isInstalled else {
            self.lastError = "Obsidian.app is not installed — install from obsidian.md"
            NSWorkspace.shared.open(fileURL)
            return
        }

        if let (vault, relative) = resolveVaultAndRelativePath(for: fileURL),
           let url = obsidianURL(vault: vault.name, relativePath: relative) {
            NSWorkspace.shared.open(url)
            return
        }

        // Couldn't map the file to a vault. Just launch Obsidian so the user
        // can open it manually, and print the path so they know where to look.
        self.lastError = "Meeting file is not inside a registered Obsidian vault: \(fileURL.path)"
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") {
            NSWorkspace.shared.open([], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Build an `obsidian://open?vault=...&file=...` URL. The file parameter
    /// should NOT include the `.md` extension — Obsidian adds it automatically
    /// and rejects the query otherwise.
    private func obsidianURL(vault: String, relativePath: String) -> URL? {
        var fileParam = relativePath
        if fileParam.hasSuffix(".md") {
            fileParam = String(fileParam.dropLast(3))
        }

        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vault),
            URLQueryItem(name: "file", value: fileParam),
        ]
        return components.url
    }

    // MARK: - Dashboard installer

    /// Where the dashboard ends up in the user's vault, based on their
    /// Minutes `vault.path` + `meetings_subdir` config. The dashboard file is
    /// placed in the **parent** of the meetings folder so Minutes never sees
    /// it. Returns `nil` if we can't read the Minutes config.
    ///
    /// Example: with `meetings_subdir = "02_Areas/Work/meetings"`, the dashboard
    /// is written to `<vault>/02_Areas/Work/Meetings Dashboard.md`.
    func dashboardInstallURL() -> URL? {
        guard let (vaultPath, meetingsSubdir) = readMinutesVaultConfig() else {
            return nil
        }
        // Parent directory of the meetings subdir.
        let subdirURL = URL(fileURLWithPath: meetingsSubdir, relativeTo: vaultPath)
        let parent = subdirURL.deletingLastPathComponent()
        return parent.appendingPathComponent("Meetings Dashboard.md")
    }

    /// Whether the dashboard is already installed at its expected location.
    func dashboardIsInstalled() -> Bool {
        guard let url = dashboardInstallURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Write the Dataview dashboard markdown to the computed install location.
    /// If the file already exists, it is overwritten (the caller is expected
    /// to confirm overwrite in the UI first). Returns the written URL on
    /// success, or nil on failure (with `lastError` set).
    @discardableResult
    func installDashboard() -> URL? {
        guard let installURL = dashboardInstallURL() else {
            self.lastError = "Could not determine install location — is Minutes' vault config set up?"
            return nil
        }

        let parent = installURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            try dashboardMarkdown.write(
                to: installURL,
                atomically: true,
                encoding: .utf8
            )
            self.lastError = nil
            return installURL
        } catch {
            self.lastError = "Failed to write dashboard: \(error.localizedDescription)"
            return nil
        }
    }

    /// Parse the `[vault]` section of `~/.config/minutes/config.toml` for
    /// `path` + `meetings_subdir`. We only care about those two fields, so
    /// this is a minimal line-based parser.
    private func readMinutesVaultConfig() -> (vaultPath: URL, meetingsSubdir: String)? {
        let configURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config")
            .appendingPathComponent("minutes")
            .appendingPathComponent("config.toml")

        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        var inVaultSection = false
        var path: String?
        var subdir: String?

        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inVaultSection = (line == "[vault]")
                continue
            }
            guard inVaultSection, line.contains("=") else { continue }

            if line.hasPrefix("path") {
                path = extractTomlString(from: line)
            } else if line.hasPrefix("meetings_subdir") {
                subdir = extractTomlString(from: line)
            }
        }

        guard let path, let subdir else { return nil }
        return (URL(fileURLWithPath: path), subdir)
    }

    private func extractTomlString(from line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: eq)...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return value.isEmpty ? nil : value
    }
}

// MARK: - Dashboard template

/// Markdown template for the Meetings Dashboard. Requires the **Dataview** and
/// **Tasks** community plugins enabled in Obsidian. The `FROM` clauses use an
/// absolute-ish vault path (`02_Areas/Work/meetings`) — Obsidian follows the
/// symlink Minutes creates there transparently.
private let dashboardMarkdown: String = #"""
---
title: Meetings Dashboard
type: dashboard
tags:
  - dashboard
  - meetings
---

# Meetings Dashboard

Auto-updating view of all meetings recorded by Minutes. Requires the **Dataview** and **Tasks** community plugins.

> Install via Settings → Community plugins → Browse → search "Dataview" and "Tasks".

---

## This week

```dataview
TABLE WITHOUT ID
  file.link AS "Meeting",
  dateformat(date(date), "ccc d LLL HH:mm") AS "When",
  duration AS "Length",
  length(attendees) AS "People"
FROM "02_Areas/Work/meetings"
WHERE type = "meeting"
  AND date(date) >= date(today) - dur(7 days)
SORT date DESC
```

## Today

```dataview
TABLE WITHOUT ID
  file.link AS "Meeting",
  dateformat(date(date), "HH:mm") AS "Time",
  duration AS "Length"
FROM "02_Areas/Work/meetings"
WHERE type = "meeting"
  AND dateformat(date(date), "yyyy-MM-dd") = dateformat(date(today), "yyyy-MM-dd")
SORT date DESC
```

---

## Open action items

Action items from meeting notes that haven't been ticked off yet. Click a task to jump to the source meeting.

```dataview
TASK
FROM "02_Areas/Work/meetings"
WHERE !completed
  AND !contains(text, "None")
GROUP BY file.link
SORT file.ctime DESC
```

---

## Recent decisions

```dataview
LIST WITHOUT ID
  "**" + file.link + "** — " + default(decisions[0].text, "No decisions")
FROM "02_Areas/Work/meetings"
WHERE type = "meeting"
  AND length(decisions) > 0
  AND decisions[0].text != "None"
SORT date DESC
LIMIT 10
```

---

## People you're talking to most (last 30 days)

Useful for spotting who's been in your meetings a lot — and implicitly, who you haven't seen in a while.

```dataview
TABLE WITHOUT ID
  key AS "Person",
  rows.file.link AS "Recent meetings"
FROM "02_Areas/Work/meetings"
WHERE type = "meeting"
  AND date(date) >= date(today) - dur(30 days)
FLATTEN attendees AS person
WHERE person != "Unnamed speaker"
GROUP BY person AS key
SORT length(rows) DESC
LIMIT 10
```

---

## Losing touch (not seen in 30+ days)

People you used to meet with regularly but haven't seen recently. Compares attendees appearing in older meetings against the most recent 30-day window.

```dataview
TABLE WITHOUT ID
  key AS "Person",
  dateformat(max(rows.date), "yyyy-MM-dd") AS "Last seen",
  length(rows) AS "Past meetings"
FROM "02_Areas/Work/meetings"
WHERE type = "meeting"
FLATTEN attendees AS person
WHERE person != "Unnamed speaker"
GROUP BY person AS key
WHERE date(max(rows.date)) < date(today) - dur(30 days)
SORT max(rows.date) ASC
LIMIT 10
```

---

## All meetings (last 30)

```dataview
TABLE WITHOUT ID
  file.link AS "Meeting",
  dateformat(date(date), "yyyy-MM-dd HH:mm") AS "Date",
  duration AS "Length",
  length(action_items) AS "Actions",
  length(decisions) AS "Decisions"
FROM "02_Areas/Work/meetings"
WHERE type = "meeting"
SORT date DESC
LIMIT 30
```

---

## Stats

```dataview
TABLE WITHOUT ID
  "📊 Total meetings" AS "",
  length(rows) AS " "
FROM "02_Areas/Work/meetings"
WHERE type = "meeting"
GROUP BY true
```

```dataview
TABLE WITHOUT ID
  "⏱ Meetings this week" AS "",
  length(rows) AS " "
FROM "02_Areas/Work/meetings"
WHERE type = "meeting"
  AND date(date) >= date(today) - dur(7 days)
GROUP BY true
```

```dataview
TABLE WITHOUT ID
  "✅ Open action items" AS "",
  sum(length(filter(action_items, (a) => a.status = "open" AND a.task != "None"))) AS " "
FROM "02_Areas/Work/meetings"
WHERE type = "meeting"
GROUP BY true
```

---

> Installed by Meeting Reminder. Edit queries in-place — this file won't be overwritten unless you explicitly reinstall.
"""#

