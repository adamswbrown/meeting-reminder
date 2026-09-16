import Combine
import Foundation

/// One writer, durable per-occurrence jobs, and generation-only recovery. Scheduling
/// is owned by PreCallBriefTriggerService so normal and fallback runs never overlap.
@MainActor
final class BriefingFallbackCoordinator: ObservableObject {
    enum Keys {
        static let enabled = "briefingFallbackEnabled"
        static let shortcut = "briefingFallbackShortcut"
        static let providerRetryAfter = "briefingPrimaryRetryAfter"
    }
    @Published private(set) var status = ""
    private(set) var jobs: [BriefingFallbackJob] = []
    private let store: BriefingFallbackStore
    private let defaults: UserDefaults
    private let occurrenceExists: (MeetingEvent) -> Bool?
    private let makeNotion: (String) throws -> BriefingNotionRepository
    private let gather: (MeetingEvent, BriefingNotionRepository) async -> BriefingContext
    private let generate: (BriefingContext, String) async throws -> (BriefingDraft, String, BriefingContext)
    private let recover: (String, String) async -> BriefingProcessResult
    private let delivery: BriefingDeliveryService
    private var loadError: String?
    var enabled: Bool { defaults.bool(forKey: Keys.enabled) }
    var coolingDown: Bool {
        enabled && (defaults.object(forKey: Keys.providerRetryAfter) as? Date ?? .distantPast) > Date()
    }

    init(store: BriefingFallbackStore = .standard, defaults: UserDefaults = .standard,
         occurrenceExists: @escaping (MeetingEvent) -> Bool? = { _ in true },
         makeNotion: @escaping (String) throws -> BriefingNotionRepository = { try .live(logPath: $0) },
         gather: @escaping (MeetingEvent, BriefingNotionRepository) async -> BriefingContext = {
             await BriefingFallbackProviders.context(meeting: $0, notion: $1)
         },
         generate: @escaping (BriefingContext, String) async throws -> (BriefingDraft, String, BriefingContext) = {
             try await BriefingFallbackProviders.generate(context: $0, shortcut: $1)
         },
         recover: @escaping (String, String) async -> BriefingProcessResult = {
             await BriefingProcess.claude(path: $0, prompt: $1, generationOnly: true)
         },
         delivery: BriefingDeliveryService = BriefingDeliveryService()) {
        self.store = store; self.defaults = defaults; self.occurrenceExists = occurrenceExists; self.makeNotion = makeNotion
        self.gather = gather; self.generate = generate; self.recover = recover; self.delivery = delivery
        do { jobs = try store.load(); refreshStatus() }
        catch { loadError = "Fallback queue could not be read; review its state file before retrying."; status = loadError! }
    }

    func noteExhaustion() {
        defaults.set(Date().addingTimeInterval(900), forKey: Keys.providerRetryAfter)
    }

    /// Returns only after the job is durable; caller can then mark its detection fired.
    func enqueue(_ meeting: MeetingEvent) throws {
        if let loadError { throw BriefingFallbackError.unavailable(loadError) }
        let job = BriefingFallbackJob(meeting: meeting)
        guard !jobs.contains(where: { $0.id == job.id }) else { return }
        var updated = jobs
        updated.append(job)
        try store.save(updated)
        jobs = updated
        refreshStatus()
    }

    func cancel(_ meetings: [MeetingEvent]) {
        let ids = Set(meetings.map(BriefingFallbackJob.occurrenceKey))
        var updated = jobs
        for index in updated.indices where ids.contains(updated[index].id) && updated[index].isActive {
            updated[index].phase = .cancelled
            updated[index].lastError = "Calendar occurrence was removed or rescheduled."
        }
        do { try store.save(updated); jobs = updated; refreshStatus() }
        catch { status = "Could not persist cancellation; fallback paused."; loadError = status }
    }

    func runNext(cliPath: String, logPath: String, preferredJobID: String? = nil) async -> String? {
        guard enabled, loadError == nil,
              var job = jobs.filter({ $0.isActive && $0.nextAttempt <= Date()
                    && (preferredJobID == nil || $0.id == preferredJobID) })
                .sorted(by: {
                    if ($0.phase == .pending) != ($1.phase == .pending) { return $0.phase == .pending }
                    if $0.phase == .pending { return $0.meeting.startDate < $1.meeting.startDate }
                    return $0.nextAttempt < $1.nextAttempt
                }).first else { return nil }
        do {
            // Pending briefs expire; enrichment may still be useful for a week after the meeting.
            if job.phase == .pending && job.meeting.startDate < Date().addingTimeInterval(-300) {
                job.phase = .cancelled; job.lastError = "Meeting started before a fallback could be saved."
                try checkpoint(job); return "Fallback expired before generation."
            }
            if job.createdAt < Date().addingTimeInterval(-7 * 86400) {
                job.reviewFromPhase = job.phase; job.phase = .needsReview; job.lastError = "Recovery paused after seven days."
                try checkpoint(job); return "Briefing recovery needs review."
            }
            let notion = try makeNotion(logPath)
            // Checkpointed mutations must be reconciled after crashes/timeouts. Missing
            // markers are NOT proof a timed-out write failed: hold for human review.
            if job.phase == .creating {
                if let page = try await notion.matchingPage(job.meeting),
                   try await notion.hasMarker(job.fallbackMarker, pageID: page.id) {
                    job.pageID = page.id; job.pageURL = page.url; job.phase = .saved
                    job.nextAttempt = Date().addingTimeInterval(900); try checkpoint(job)
                    return "Recovered fallback page; enrichment queued."
                }
                job.reviewFromPhase = .creating; job.phase = .needsReview; job.lastError = "Uncertain fallback write; no marker found."
                try checkpoint(job); return "Fallback write needs review."
            }
            if job.phase == .enriching {
                if let id = job.pageID, try await notion.hasMarker(job.enrichmentMarker, pageID: id) {
                    job.phase = .complete; try checkpoint(job)
                    return "Recovered completed enrichment."
                }
                job.reviewFromPhase = .enriching; job.phase = .needsReview; job.lastError = "Uncertain enrichment append; no marker found."
                try checkpoint(job); return "Enrichment write needs review."
            }
            guard let exists = occurrenceExists(job.meeting) else {
                throw BriefingFallbackError.unavailable("Calendar access unavailable; fallback paused until the occurrence can be checked.")
            }
            if !exists {
                job.phase = .cancelled; job.lastError = "Calendar occurrence no longer exists or is no longer selected."
                try checkpoint(job); return "Fallback cancelled for a removed or rescheduled occurrence."
            }
            if try await notion.shouldSkip(job.meeting) {
                job.phase = .cancelled; job.lastError = "Matched an active briefing skip rule."
                try checkpoint(job); return "Meeting excluded by briefing skip rules."
            }
            if job.phase == .pending {
                // Cross-runner exclusion BEFORE spending a generation. The scheduled
                // runner can be mid-write for this same occurrence; deferring costs
                // one retry, duplicating costs a second briefing page.
                var leaseNote: String?
                switch await notion.claimLease(job.meeting, jobID: job.id) {
                case .heldByOther(let owner):
                    job.retry("Another briefing runner (\(owner)) holds this occurrence.")
                    try checkpoint(job)
                    return "Deferred to the \(owner) briefing runner."
                case .unavailable(let reason):
                    leaseNote = reason
                case .acquired:
                    break
                }
                var context = await gather(job.meeting, notion)
                if let leaseNote { context.coverage.append(leaseNote) }
                let shortcut = defaults.string(forKey: Keys.shortcut) ?? ""
                let (draft, provider, usedContext) = try await generate(context, shortcut)
                guard canWrite(job.id), occurrenceExists(job.meeting) == true else {
                    await notion.releaseLease(job.meeting, jobID: job.id)
                    return nil
                }
                job.context = usedContext; job.draft = draft; job.provider = provider
                job.phase = .creating
                try checkpoint(job) // durable BEFORE the first potentially ambiguous remote write
                let page = try await notion.saveFallback(job)
                job.pageID = page.id; job.pageURL = page.url; job.phase = .saved
                job.lastError = nil; job.attempts = 0; job.nextAttempt = Date().addingTimeInterval(900)
                try checkpoint(job)
                // The page now exists, so it is its own dedup key; holding the lease
                // any longer would only block the scheduled runner's own reconciliation.
                await notion.releaseLease(job.meeting, jobID: job.id)
                // Delivery comes AFTER the durable save so a failed post never costs
                // the briefing, and is checkpointed so a crash can't repeat it.
                var record = job.delivery ?? .init()
                record = await delivery.announce(job: job, context: usedContext, record: record)
                record = await delivery.syncActions(job: job, context: usedContext, record: record)
                job.delivery = record
                try checkpoint(job)
                let delivered = record.slackTS == nil ? "not announced" : "announced"
                return "Fallback saved to Notion (\(provider)); \(delivered); enrichment queued."
            }
            if job.phase == .saved {
                if coolingDown {
                    job.nextAttempt = defaults.object(forKey: Keys.providerRetryAfter) as? Date ?? Date().addingTimeInterval(900)
                    try checkpoint(job); return nil
                }
                guard let pageID = job.pageID else { throw BriefingFallbackError.uncertainWrite }
                try await notion.validatePage(pageID, meeting: job.meeting)
                if try await notion.hasMarker(job.enrichmentMarker, pageID: pageID) {
                    job.phase = .complete; try checkpoint(job); return "Briefing already enriched."
                }
                var context = await gather(job.meeting, notion)
                context.evidence.append(.init(id: "existing-page", source: "Current briefing including user edits",
                    text: try await notion.pageText(pageID, maxCharacters: 12000), url: job.pageURL))
                let result = await recover(cliPath,
                    "Add useful, grounded detail to the existing briefing. Do not repeat its summary.\n" + context.prompt(evidenceCharacters: 36000))
                if result.providerExhausted { noteExhaustion(); throw BriefingFallbackError.unavailable("Claude usage remains exhausted.") }
                guard result.succeeded else { throw BriefingFallbackError.unavailable("Claude recovery failed; retry scheduled.") }
                let draft = try BriefingDraft.parse(result.text)
                guard canWrite(job.id), occurrenceExists(job.meeting) == true else { return nil }
                job.phase = .enriching; try checkpoint(job)
                try await notion.enrich(job, draft: draft, context: context)
                job.phase = .complete; job.lastError = nil
                try checkpoint(job)
                // Reconcile delivery against the refreshed context: a threaded reply
                // (never a new alert) and only genuinely-new action items.
                var record = job.delivery ?? .init()
                record = await delivery.syncActions(job: job, context: context, record: record)
                record = await delivery.announceEnrichment(job: job, record: record)
                job.delivery = record
                try checkpoint(job)
                defaults.removeObject(forKey: Keys.providerRetryAfter)
                return "Claude enriched the existing Notion briefing."
            }
        } catch {
            // Keep uncertain-write phases for read-only reconciliation on the next run.
            // Do not persist provider stderr, credentials or source text as errors.
            let message = (error as? BriefingFallbackError)?.localizedDescription ?? "Fallback operation failed; retry scheduled."
            if job.phase == .pending, let notion = try? makeNotion(logPath) {
                // Only the pending phase can still be holding a lease; a creating/
                // enriching job has already written and must keep its checkpoint.
                await notion.releaseLease(job.meeting, jobID: job.id)
            }
            job.retry(message)
            do { try checkpoint(job) }
            catch { loadError = "Fallback checkpoint failed; paused to protect against duplicate writes."; status = loadError! }
            return message
        }
        return nil
    }

    /// Jobs parked for human review, newest first.
    var reviewJobs: [BriefingFallbackJob] {
        jobs.filter { $0.phase == .needsReview }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Puts a parked job back in the queue in the phase it was parked from, so the
    /// next run re-reads the page and its markers before deciding anything. This is
    /// deliberately NOT a "regenerate": the original write may have landed, and
    /// repeating it is the one outcome the whole ledger exists to prevent.
    func resumeReview(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.phase == .needsReview }) else { return }
        var updated = jobs
        // A job parked by the seven-day expiry has no uncertain write to reconcile
        // and would immediately re-expire, so restart its clock as well.
        updated[index].phase = updated[index].reviewFromPhase ?? .pending
        updated[index].reviewFromPhase = nil
        updated[index].attempts = 0
        updated[index].nextAttempt = Date()
        updated[index].createdAt = Date()
        updated[index].lastError = nil
        persist(updated, failure: "Could not resume the review item; fallback paused.")
    }

    /// Closes a parked job without touching anything remote. The Notion page and any
    /// Slack/Todoist delivery stay exactly as they are — this only stops the app
    /// retrying, and records why.
    func dismissReview(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.phase == .needsReview }) else { return }
        var updated = jobs
        updated[index].phase = .cancelled
        updated[index].lastError = "Dismissed after review; no further automatic action."
        persist(updated, failure: "Could not dismiss the review item; fallback paused.")
    }

    private func persist(_ updated: [BriefingFallbackJob], failure: String) {
        do { try store.save(updated); jobs = updated; refreshStatus() }
        catch { status = failure; loadError = status }
    }

    private func canWrite(_ id: String) -> Bool {
        enabled && loadError == nil && jobs.first(where: { $0.id == id })?.isActive == true
    }

    private func checkpoint(_ job: BriefingFallbackJob) throws {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        var updated = jobs
        // A calendar cancellation may arrive while a model/HTTP request is suspended.
        // Retain its terminal state while still recording a remotely-created page ID.
        var merged = job
        if updated[index].phase == .cancelled { merged.phase = .cancelled }
        if [.saved, .complete, .cancelled].contains(merged.phase) {
            merged.context = nil; merged.draft = nil // source text need not live in the queue after delivery
            // `delivery` deliberately survives: it is the idempotency key that stops
            // a recovered job reposting to Slack or recreating Todoist tasks.
        }
        updated[index] = merged
        updated.removeAll { !$0.isActive && $0.phase != .needsReview && $0.createdAt < Date().addingTimeInterval(-30 * 86400) }
        try store.save(updated)
        jobs = updated
        refreshStatus()
    }

    private func refreshStatus() {
        let active = jobs.filter(\.isActive).count
        let review = jobs.filter { $0.phase == .needsReview }.count
        status = "\(active) queued · \(review) need review"
    }
}
