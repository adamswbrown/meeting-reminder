import AppKit
import SwiftUI

/// Floating panel that shows the matched pre-call brief for the active meeting.
/// Opens at the 5-min reminder (or on meeting join), survives being dismissed,
/// and can be re-opened from the context panel or menu bar.
struct BriefPanelView: View {
    let event: MeetingEvent
    @ObservedObject var service: PreCallBriefService
    let onClose: () -> Void

    @State private var brief: PreCallBrief?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showPicker = false
    @State private var isUnattached = false  // true when matching returned nothing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if isLoading && brief == nil {
                loadingState
            } else if let brief {
                briefBody(brief)
            } else if isUnattached {
                noBriefState
            } else if let err = loadError {
                errorState(err)
            } else {
                // Initial empty state before first load attempt completes
                loadingState
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .onAppear {
            if brief == nil && !isLoading {
                loadBrief()
            }
        }
        .sheet(isPresented: $showPicker) {
            BriefPickerView(service: service, eventID: event.id) { summary in
                showPicker = false
                if let summary {
                    service.attach(summary: summary, to: event.id)
                    brief = nil
                    isUnattached = false
                    loadBrief()
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(brief?.title ?? event.title)
                    .font(.headline)
                    .lineLimit(1)
                if let cp = brief?.customerPartner {
                    Text(cp)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                } else {
                    Text("Pre-Call Brief")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if let brief {
                Button {
                    NotionService.openInNotionApp(brief.pageURL)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open in Notion")
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var loadingState: some View {
        VStack(alignment: .center, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(brief == nil ? "Looking up brief…" : "Reloading…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private func briefBody(_ brief: PreCallBrief) -> some View {
        ScrollView {
            MarkdownBody(markdown: brief.markdown)
                .padding(16)
        }

        Divider()

        HStack(spacing: 12) {
            Button {
                rematch()
            } label: {
                Label("Re-match", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Button {
                showPicker = true
            } label: {
                Label("Attach different brief…", systemImage: "link.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var noBriefState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.ellipsis")
                    .foregroundColor(.secondary)
                Text("No brief found for this meeting.")
                    .font(.callout)
            }

            Button {
                showPicker = true
            } label: {
                Label("Search Notion…", systemImage: "magnifyingglass")
            }

            Button {
                openCreateBriefInNotion()
            } label: {
                Label("Create new brief in Notion", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private func errorState(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Couldn't load brief")
                    .font(.callout.weight(.semibold))
            }
            Text(err)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .textSelection(.enabled)

            HStack {
                Button("Retry") { loadBrief() }
                    .buttonStyle(.borderedProminent)
                Button("Attach manually…") { showPicker = true }
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Actions

    private func loadBrief() {
        guard service.isConfigured else {
            loadError = "Connect Notion in Settings to see briefs."
            return
        }
        isLoading = true
        loadError = nil
        Task {
            if let matched = await service.match(for: event) {
                let fetched = await service.fetchBrief(pageID: matched.pageID)
                await MainActor.run {
                    isLoading = false
                    if let fetched {
                        brief = fetched
                        isUnattached = false
                    } else {
                        loadError = service.lastError ?? "Couldn't fetch page content"
                    }
                }
            } else {
                await MainActor.run {
                    isLoading = false
                    if let err = service.lastError {
                        loadError = err
                    } else {
                        isUnattached = true
                    }
                }
            }
        }
    }

    private func rematch() {
        brief = nil
        isLoading = true
        loadError = nil
        isUnattached = false
        Task {
            if let matched = await service.rematch(for: event) {
                let fetched = await service.fetchBrief(pageID: matched.pageID)
                await MainActor.run {
                    isLoading = false
                    if let fetched {
                        brief = fetched
                    } else {
                        loadError = service.lastError ?? "Couldn't fetch page content"
                    }
                }
            } else {
                await MainActor.run {
                    isLoading = false
                    isUnattached = true
                }
            }
        }
    }

    private func openCreateBriefInNotion() {
        // Deep-link to the DB; the user types the title themselves. Notion's
        // URL-based page creation requires a template ID we don't have, so
        // we open the DB and let the user click "New".
        let dbURL = URL(string: "https://www.notion.so/\(service.databaseID)")
            ?? URL(string: "https://www.notion.so")!
        NotionService.openInNotionApp(dbURL)
    }
}

// MARK: - Markdown body

/// Block-level markdown renderer. Splits the document into blocks (headings,
/// bullet/numbered lists, blockquotes, code, dividers, paragraphs) and renders
/// each as its own SwiftUI view so it visually matches the Notion source.
/// Inline syntax (bold, italic, links) inside a block is still parsed via
/// `AttributedString(markdown:)` so nothing is lost.
struct MarkdownBody: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                render(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func render(block: MDBlock) -> some View {
        switch block {
        case .heading1(let text):
            Text(inline(text))
                .font(.title2.weight(.bold))
                .padding(.top, 4)
        case .heading2(let text):
            Text(inline(text))
                .font(.title3.weight(.semibold))
                .padding(.top, 2)
        case .heading3(let text):
            Text(inline(text))
                .font(.headline)
        case .paragraph(let text):
            Text(inline(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Text(inline(item))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(idx + 1).")
                            .font(.callout.monospacedDigit())
                            .foregroundColor(.secondary)
                        Text(inline(item))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .todoList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                            .foregroundColor(item.checked ? .accentColor : .secondary)
                            .font(.caption)
                        Text(inline(item.text))
                            .font(.callout)
                            .strikethrough(item.checked, color: .secondary)
                            .foregroundColor(item.checked ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                Text(inline(text))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .callout(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("💡")
                Text(inline(text))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12))
            .cornerRadius(6)
        case .code(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(6)
                .textSelection(.enabled)
        case .divider:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attributed
        }
        return AttributedString(text)
    }

    // MARK: - Parser

    struct TodoItem {
        let text: String
        let checked: Bool
    }

    enum MDBlock {
        case heading1(String)
        case heading2(String)
        case heading3(String)
        case paragraph(String)
        case bulletList([String])
        case numberedList([String])
        case todoList([TodoItem])
        case quote(String)
        case callout(String)
        case code(String)
        case divider
    }

    static func parse(_ markdown: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        func flushParagraph(_ buffer: inout [String]) {
            if !buffer.isEmpty {
                let joined = buffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !joined.isEmpty {
                    blocks.append(.paragraph(joined))
                }
                buffer.removeAll()
            }
        }

        var paragraphBuffer: [String] = []

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))

            // Blank line — end paragraph
            if line.isEmpty {
                flushParagraph(&paragraphBuffer)
                i += 1
                continue
            }

            // Divider
            if line == "---" || line == "***" {
                flushParagraph(&paragraphBuffer)
                blocks.append(.divider)
                i += 1
                continue
            }

            // Headings
            if line.hasPrefix("### ") {
                flushParagraph(&paragraphBuffer)
                blocks.append(.heading3(String(line.dropFirst(4))))
                i += 1
                continue
            }
            if line.hasPrefix("## ") {
                flushParagraph(&paragraphBuffer)
                blocks.append(.heading2(String(line.dropFirst(3))))
                i += 1
                continue
            }
            if line.hasPrefix("# ") {
                flushParagraph(&paragraphBuffer)
                blocks.append(.heading1(String(line.dropFirst(2))))
                i += 1
                continue
            }

            // Code fence
            if line.hasPrefix("```") {
                flushParagraph(&paragraphBuffer)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let codeLine = lines[i]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(codeLine)
                    i += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n")))
                continue
            }

            // Callout (our fetcher emits "> 💡 ..." for callouts)
            if line.hasPrefix("> 💡 ") {
                flushParagraph(&paragraphBuffer)
                var calloutLines: [String] = [String(line.dropFirst(5))]
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                    if next.hasPrefix("> ") {
                        calloutLines.append(String(next.dropFirst(2)))
                        i += 1
                    } else { break }
                }
                blocks.append(.callout(calloutLines.joined(separator: " ")))
                continue
            }

            // Quote
            if line.hasPrefix("> ") {
                flushParagraph(&paragraphBuffer)
                var quoteLines: [String] = [String(line.dropFirst(2))]
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                    if next.hasPrefix("> ") {
                        quoteLines.append(String(next.dropFirst(2)))
                        i += 1
                    } else { break }
                }
                blocks.append(.quote(quoteLines.joined(separator: " ")))
                continue
            }

            // To-do list: "- [ ] " or "- [x] "
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                flushParagraph(&paragraphBuffer)
                var items: [TodoItem] = []
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                    if next.hasPrefix("- [ ] ") {
                        items.append(TodoItem(text: String(next.dropFirst(6)), checked: false))
                        i += 1
                    } else if next.hasPrefix("- [x] ") || next.hasPrefix("- [X] ") {
                        items.append(TodoItem(text: String(next.dropFirst(6)), checked: true))
                        i += 1
                    } else { break }
                }
                blocks.append(.todoList(items))
                continue
            }

            // Bullet list: "- " or "* "
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph(&paragraphBuffer)
                var items: [String] = []
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                    if (next.hasPrefix("- ") || next.hasPrefix("* "))
                        && !next.hasPrefix("- [ ] ") && !next.hasPrefix("- [x] ") && !next.hasPrefix("- [X] ") {
                        items.append(String(next.dropFirst(2)))
                        i += 1
                    } else { break }
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Numbered list: "1. ", "2. ", ...
            if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushParagraph(&paragraphBuffer)
                var items: [String] = []
                items.append(String(line[match.upperBound...]))
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                    if let m = next.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                        items.append(String(next[m.upperBound...]))
                        i += 1
                    } else { break }
                }
                blocks.append(.numberedList(items))
                continue
            }

            // Default — accumulate into a paragraph
            paragraphBuffer.append(line)
            i += 1
        }

        flushParagraph(&paragraphBuffer)
        return blocks
    }
}

// MARK: - Brief picker

struct BriefPickerView: View {
    @ObservedObject var service: PreCallBriefService
    let eventID: String
    let onDone: (BriefSummary?) -> Void

    @State private var briefs: [BriefSummary] = []
    @State private var searchText: String = ""
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Attach brief")
                    .font(.headline)
                Spacer()
                Button("Cancel") { onDone(nil) }
            }
            .padding()

            Divider()

            TextField("Search by title…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.top, 8)

            if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading recent briefs…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredBriefs) { summary in
                    Button {
                        onDone(summary)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title)
                                .font(.callout)
                            HStack(spacing: 6) {
                                if let cp = summary.customerPartner {
                                    Text(cp)
                                        .font(.caption2)
                                        .foregroundColor(.accentColor)
                                }
                                if let d = summary.date {
                                    Text(Self.formatDate(d))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 480, height: 480)
        .onAppear {
            Task {
                let recent = await service.listRecentBriefs(daysBack: 60)
                await MainActor.run {
                    briefs = recent
                    isLoading = false
                }
            }
        }
    }

    private var filteredBriefs: [BriefSummary] {
        if searchText.isEmpty { return briefs }
        let q = searchText.lowercased()
        return briefs.filter {
            $0.title.lowercased().contains(q)
                || ($0.customerPartner?.lowercased().contains(q) ?? false)
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

// MARK: - Window controller

@MainActor
final class BriefPanelWindowController {
    private var panel: NSPanel?

    func show(
        event: MeetingEvent,
        service: PreCallBriefService,
        onClose: @escaping () -> Void
    ) {
        close()

        guard let screen = NSScreen.main else { return }

        // Borderless panel — no titlebar/traffic lights since the view has its
        // own close button. `.fullSizeContentView` isn't needed without a
        // titlebar; `.resizable` works with borderless panels via edge drag.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.title = "Pre-Call Brief"
        panel.setFrameAutosaveName("BriefPanel")

        let view = BriefPanelView(
            event: event,
            service: service,
            onClose: { [weak self] in
                self?.close()
                onClose()
            }
        )

        panel.contentView = NSHostingView(rootView: view)

        // Only set position if autosaved frame didn't place it — default to
        // upper-left of main screen so it doesn't overlap the context panel
        // (which lives in the upper-right corner).
        if panel.frame.origin == .zero {
            let x = screen.visibleFrame.minX + 40
            let y = screen.visibleFrame.maxY - 660
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible == true }
}
