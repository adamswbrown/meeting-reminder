# Local briefing fallback when the main model reaches its usage limit

**Date:** 2026-09-15

**Status:** Design recorded; implementation and model evaluation deferred until Adam has upgraded to macOS 27 and the required development tools are available.

## Outcome

When the main briefing model has exhausted its credits or usage allowance, Meeting Reminder should produce a useful briefing with Apple's on-device model. It must still retrieve relevant Notion and Teams context and save the briefing through the usual workflow.

When the main model becomes available again, it should enrich **the same existing Notion briefing page**, preserving its link, Adam's edits and meeting notes. Recovery must not create another briefing, duplicate action items or send another new-meeting alert.

Example: a meeting arrives while the main model is limited. The app gathers available context, writes a short briefing labelled **Local fallback**, and delivers its link. After the limit resets, the main model reads that page and additional context, improves the generated sections, and changes the label to **Full briefing** only after the update succeeds.

## Agreed scope

- Keep the main model as the preferred briefing generator.
- Use Apple's on-device model as a fallback for confirmed model credit or usage exhaustion.
- Make context retrieval and delivery independent of that model's allowance.
- Support the relevant Notion MCP and `teams-mcp` capabilities, or existing direct integrations where suitable.
- Persist unfinished enrichment work across app restarts and sleep.
- Upgrade the existing briefing in place when access returns.
- Preserve user-authored content, completed tasks and stable links.

The first implementation should cover the app's intraday briefing path. The scheduled main briefing runner must recognize fallback pages as eligible for enrichment; extending automatic fallback generation to that runner is a separate integration step. Do not silently change the external scheduled task as part of this documentation work.

## Current implementation

Relevant code:

- [`FoundationModelsBriefService.swift`](../../MeetingReminder/Services/FoundationModelsBriefService.swift): uses `SystemLanguageModel`, requests a short brief, action items and a Slack line with guided generation. It assumes a 4,096-token window and caps prior notes at 1,500 characters.
- [`NotionPriorNotesReader.swift`](../../MeetingReminder/Services/NotionPriorNotesReader.swift): already reads prior notes directly through the app's Notion integration. It currently returns `nil` for both missing notes and retrieval errors, which is insufficient for reporting source coverage.
- [`PreCallBriefTriggerService.swift`](../../MeetingReminder/Services/PreCallBriefTriggerService.swift): normally launches the main CLI briefing workflow. An experimental opt-in route uses the local model, but posts only its Slack line. It does not save the generated full brief or action items. It also marks the event fired after an unsuccessful local attempt, so its current completion tracking cannot be reused unchanged.
- [`INTRADAY-BRIEFINGS.md`](../INTRADAY-BRIEFINGS.md): describes the existing main runner, scheduled counterpart and shared Notion state. The private executable briefing ruleset must be inspected during implementation to establish the actual current delivery and task destinations.

This is a starting point, not an existing automatic fallback. There is no verified independent Teams connection, credit-limit classifier or durable enrichment queue in this path.

## Proposed architecture

```text
Calendar event / briefing request
                |
       Resolve existing briefing + durable job
                |
       Main model available? -------- confirmed usage exhaustion
                |                               |
       Main briefing runner             Independent context retrieval
                |                       (Calendar, Notion, Teams)
                |                               |
                |                       On-device brief generation
                |                               |
                +-------- Save/update same Notion page
                                                |
                                     Deliver once; persist outcome
                                                |
                                  Local fallback awaits enrichment
                                                |
                                 Main model access returns
                                                |
                            Read current page + refresh context
                                                |
                          Enrich same page; reconcile existing tasks
```

The application owns identity, retries, source retrieval, persistence and delivery. The local model writes from selected evidence. It may receive a small set of targeted lookup tools where evaluation shows these help; it should not need to navigate the entire main agent ruleset or every MCP tool to produce a basic fallback.

### Independent MCP access

Apple's model can call application-defined tools. An MCP client in the application or a local helper connects those tools to the relevant servers. Model weights do not themselves hold MCP connections or authentication.

- **Notion:** reuse the existing direct client where it provides the required capabilities, or establish an independently authenticated Notion MCP client. Verify access to the briefing database and all required source pages.
- **Teams:** inspect the actual `teams-mcp` implementation, launch/endpoint configuration, transport, authentication and supported search/read operations. Verify access from the app's background execution context.
- **Assistant-hosted connectors:** do not assume a connector or login configured inside the main assistant is accessible to this app. Establish a supported independent connection where necessary.
- **Implementation choice:** evaluate the official MCP Swift SDK against this project's toolchain and current lack of package dependencies. A local helper is an alternative if the existing MCP runtime is easier to reuse. Choose after inspecting the servers, not by assuming a URL or command.
- **Credentials:** use supported authorization flows and Keychain storage. Keep tokens, private feed URLs and server secrets out of this document and logs.

Ordinary source reads must not require a successful call to the exhausted main model. MCP servers and underlying services can have their own availability, permissions and quotas; local generation does not remove those dependencies. Any tool that internally invokes a paid model needs separate assessment.

“Local fallback” describes model inference. Notion and Teams retrieval and external delivery still use the network. An unavailable on-device model must be reported explicitly; do not silently substitute Private Cloud Compute.

### Context supplied to the local model

Gather meeting identity, current time and attendees; relevant previous Notion notes; outstanding actions; and a bounded selection of related Teams messages or transcripts when accessible. Preserve source IDs/links and retrieval times.

Distinguish `available`, `no matching content`, `unavailable` and `truncated` per source. A failed Teams request must not become a claim that no relevant Teams discussion exists. Briefings should state material gaps briefly and avoid inventing details.

Select context by meeting relevance and recency, and paginate source reads as needed. Query the runtime context capacity and token count, reserving space for instructions, tool schemas and output. Summarize or select long source material in bounded stages where necessary. Treat retrieved text as evidence, not instructions to execute.

### Token limits and budget

Context size is a primary design constraint. Apple's WWDC26 example reports **8,192 tokens** from `SystemLanguageModel.contextSize`, while some Apple documentation still describes **4,096 tokens**. Neither establishes the capacity on Adam's machine before the upgrade. Read the installed model's capacity at runtime and support a smaller budget; do not assume every macOS 27 configuration has 8K available.

This is the total session context, not a daily token allowance or an input-only limit. Instructions, prompts, tool definitions and arguments/results, generated type schemas and guide descriptions, previous session turns, and the response all consume space.

Illustrative starting budgets for a fresh final-generation session:

| Content | 8,192-token model | 4,096-token model |
|---|---:|---:|
| Instructions and output schema | 800 | 600 |
| Meeting details | 400 | 300 |
| Selected Notion and Teams evidence | 5,000 | 2,000 |
| Generated briefing reserve | 1,200 | 700 |
| Safety margin | 792 | 496 |
| **Total** | **8,192** | **4,096** |

These are planning allocations, not measured prompt sizes or guaranteed output lengths. Count the actual instructions, schema and serialized evidence using the framework's token-counting APIs. If tool definitions or additional session history are introduced, charge them against the same budget and reduce the evidence allowance. Configure an output cap where supported; an output reserve alone does not constrain generation.

The final generation route should normally expose no MCP catalogue to the model. The app can discover and invoke MCP tools independently, then pass only selected evidence to a fresh model session. The full main-agent ruleset, raw MCP JSON, complete transcripts and broad tool descriptions are unsuitable default input for this budget.

### Long-source processing

1. Retrieve and filter sources in application code using meeting identity, participants, relevance and recency. Keep source IDs, dates and links alongside excerpts.
2. If useful material exceeds the evidence allowance, divide it into token-bounded chunks. Extract compact facts, decisions, unresolved questions and actions in separate fresh sessions, each with its own measured input and output budget.
3. Preserve source references, names, dates, action owners and uncertainty in each extraction. Keep originals available outside model context for verification and later main-model enrichment.
4. Deduplicate and select extracted evidence in code before final synthesis. Count the combined evidence again: chunking inputs does not guarantee the summaries fit together. Prefer selecting the most useful evidence over repeatedly compressing summaries until their provenance is lost.
5. Generate one compact briefing in a fresh session using the applicable budget above. Explicitly record material source omissions or truncation.

Chunking allows processing more material across calls, but does not expand the context available to any one call. It can lose details and connections between sources, so evaluate it against representative long notes and Teams threads. Bound calls, elapsed time and retries so a fallback still arrives in time to help. If necessary, deliver a smaller grounded brief with coverage gaps and leave deeper synthesis for main-model recovery.

If generation nevertheless exceeds the context window, retry once in a fresh session with less evidence and a shorter output target. Preserve meeting identity and source coverage information. If that fails, retain the pending job and report the failure rather than marking the briefing complete.

## Detecting exhaustion and recovery

The main runner should return a structured result that separates generation, page persistence and delivery outcomes. Prefer explicit provider/CLI usage-limit signals over broad matching of arbitrary output text.

| Result | Behaviour |
|---|---|
| Main briefing succeeds | Record the page ID and completed delivery stages. |
| Confirmed credits exhausted or model usage limit reached | Record a cooldown and invoke local fallback. |
| Authentication failure, source-service rate limit, network error or unknown failure | Report/classify separately; do not label it credit exhaustion. |
| Local model unavailable or generation fails | Retain recoverable work and report the failure; do not mark it delivered. |
| Page save succeeds but delivery fails | Retry delivery for the existing page without regenerating it. |

Before fallback writes anything, reconcile any page or task already created by a partially completed main run. A missing success response does not prove no write occurred.

Persist the reason, provider/account scope, observed time and reset time when the provider supplies one. Avoid repeatedly invoking a known-limited model for each new meeting. If no reliable reset time is exposed, use bounded backoff and an inexpensive supported availability check or controlled retry. An estimated reset time permits a retry; it is not proof that access has returned. Do not buy credits or redeem reset credits automatically.

On recovery, resume queued enrichment serially, prioritising upcoming meetings. Keep jobs for meetings that already took place; retain the original pre-meeting evidence timestamp and distinguish later context so an enriched page does not imply that post-meeting facts were known beforehand. Cancellation or manual page deletion should pause the job for reconciliation rather than recreate content automatically.

## Stable identity and safe updates

Maintain one logical job per meeting occurrence, mapped to the existing Calendar Events row and briefing page ID. Use stable calendar identity and recurrence information; a title alone is insufficient. Reschedules should retain the mapped page when the occurrence is confidently identified.

Persist at least:

- Meeting/occurrence key and Notion briefing page ID.
- Generation quality (`localFallback` or `full`) separately from save, delivery and enrichment states.
- Last completed stage, attempts, retry time and limit metadata.
- Source references, coverage and evidence timestamps.
- IDs and last-written fingerprints of application-managed Notion blocks.
- Existing action-item identities and delivery message IDs where available.

Create identifiable generated sections and a separate area for Adam's own notes. Before enrichment, fetch the current page and compare generated blocks with their last-written content:

- Update unchanged generated blocks in place.
- Preserve user-edited blocks. Put additional information in a clearly labelled enrichment section when a safe merge is uncertain.
- Preserve unrelated blocks, comments and meeting notes; do not replace the whole page body.
- Reconcile actions by stable identity and preserve user edits and completion state. Do not create duplicates because wording changed.
- Keep the existing delivery link. Where supported, update the original status message instead of posting another alert.
- Mark **Full briefing** only after all required page updates are confirmed. A failed enrichment leaves the local briefing usable and the job retryable.

Retries must converge on the same result, including after a timeout with an unknown write outcome. Notion writes are not assumed to be transactional. Re-read to reconcile partial writes and record progress per stage.

The scheduled runner and app must share the same identity and quality rules: an existing local page means “enrich this page,” not “skip forever” or “create another.” Establish one owner for an active job and a recovery mechanism for abandoned work. A local lock alone cannot coordinate with an external runner; select and verify a shared coordination approach before allowing both writers to enrich concurrently.

## Implementation sequence after the upgrade

1. Verify macOS/Xcode/SDK versions, actual local model availability, runtime capacity and background execution. Keep older macOS behaviour available through appropriate availability checks.
2. Inventory the main runner's error/reset signals, actual briefing rules and independently usable Notion/Teams connections. Prove source retrieval works while model access is limited.
3. Introduce durable job state, stable page mapping and separate persistence/delivery outcomes; reconcile partial main runs.
4. Implement measured context budgets, bounded long-source extraction and fresh-session synthesis; complete source coverage reporting, full-brief persistence and normal delivery.
5. Add confirmed-limit routing and cooldown handling.
6. Add recovery enrichment, preservation of user edits and shared deduplication with the scheduled runner.
7. Evaluate on representative meetings, then enable through an explicit fallback setting.

## Acceptance checks

- Simulated main credit exhaustion produces a source-grounded local briefing in the usual Notion destination with one delivery.
- Notion and Teams retrieval work without invoking the main model; absent permissions and unavailable sources are represented accurately.
- A partial main run followed by fallback uses the already-created page and does not repeat completed side effects.
- A cooldown prevents repeated failing main invocations; recovery enriches the same page and retains its URL.
- Restart, sleep/wake and retries preserve pending work and do not duplicate pages, tasks or alerts.
- Edits made by Adam between fallback and enrichment survive, including edits inside generated content and completed actions.
- Failed enrichment or an interrupted multi-block write leaves the existing briefing readable and can be reconciled safely.
- Recurring meetings, reschedules, cancellations, missing pages and two runners competing for the same job are handled explicitly.
- Budget calculations cover both 4,096- and 8,192-token capacities, accounting for schemas, optional tool definitions, output reserves and history. Validate real token counts on the installed model; simulated capacities test budgeting, not model availability.
- Oversized notes, Teams threads and combined chunk summaries are reduced within budget while retaining source references and key actions. Context overflow gets one smaller fresh-session retry; processing stays within its call/time limits.
- Real-model evaluation checks factual accuracy, missing key actions, source attribution, latency and behaviour near the context limit. Protocol compatibility alone does not establish reliable autonomous tool use.

## Evidence and unresolved details

This design uses the primary documentation checked on 2026-09-15:

- [Apple: What's new in Foundation Models, WWDC26](https://developer.apple.com/videos/play/wwdc2026/241/) demonstrates an 8,192-token context size and describes improved on-device capabilities. Query the installed model rather than hard-coding the demonstration value.
- [Apple: Managing the on-device foundation model's context window (TN3193)](https://developer.apple.com/documentation/Technotes/tn3193-managing-the-on-device-foundation-model-s-context-window) still specifies 4,096 tokens and explains that tool schemas, generated schemas, inputs and responses all count. The differing published capacities reinforce the need for runtime verification.
- [Apple: Foundation Models updates](https://developer.apple.com/documentation/updates/foundationmodels) recommends re-testing prompts when OS updates change the model.
- [Apple: Foundation Models](https://developer.apple.com/documentation/foundationmodels) documents guided generation and custom tool calling.
- [Official MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) provides clients, tool discovery/invocation and local/remote transports. Wiring these into Foundation Models is application integration work.

The earlier [August on-device research](2026-08-09-macos-golden-gate-on-device-ai-research.md) records provisional claims and recommends local triage. This document defines a narrower fallback use case where a shorter useful brief is acceptable. Its hardware, context and routing assumptions must be verified from the installed runtime and primary documentation rather than inherited from that research.

Still to establish during implementation: the exact `teams-mcp` connection and authorization path, current task/delivery destinations, reliable main-runner reset metadata, a shared coordination mechanism, and the quality of Apple's installed model on Adam's actual briefing material.
