# macOS 27 "Golden Gate" on-device AI — research notes

**Date:** 2026-08-09
**Status:** Research only. **Not a design, not approved, nothing implemented.**
Parked until Adam has a Golden Gate device to test on.
**Revisit when:** a Mac running macOS 27 (M3+, ≥12 GB RAM) is available, or Apple
publishes the AFM 3 on-device context-window figure — whichever comes first.

> ⚠️ **Superseded in part (2026-08-27).** Apple's developer site was unreachable from the
> session that wrote this (see *Research caveats*); it is reachable now. Three numbers below
> are wrong: the on-device context window is **8,192**, not 4,096; `tokenCount(for:)` now
> exists; and PCC's 32K is *not* tight for a multi-meeting brief — a measured, pre-computed
> six-meeting day is ~730 tokens. **Finding 3 and the "Conclusion" section should be read
> against** [2026-08-27 PCC morning-brief prompt research](2026-08-27-pcc-morning-brief-prompt-research.md).
> Findings 1 and 2 (no first-party briefing; `fm` gives inference, not context) still hold.

## Why this exists

Question asked: does macOS 27 ship a first-party morning-briefing feature, and if not,
is there any benefit to computing our pre-call briefings **locally** on Apple's on-device
models (`fm` CLI / Foundation Models) rather than sending them to Claude?

Context for the question: with Apple Mail holding the Outlook mailbox, plus local Jira
and Salesforce API access, the raw material for a briefing is arguably already on the
machine — which is roughly what `breifingskill.txt` assembles today, just remotely.

---

## Finding 1 — there is no first-party morning briefing

**macOS 27 Golden Gate does not ship a daily brief, morning digest, or "here's your day"
feature.** Nor does iOS 27 or watchOS 27. Searched under several names (daily brief,
morning summary, catch me up, digest, start your day) across Apple's announcements and
the reliable Mac press; it consistently isn't there.

The closest first-party thing is the **user-built Shortcut** pattern Apple itself demos —
first meeting + weather + reminders due today. That's templating, not synthesis.

**Implication:** nothing is coming to replace our pipeline. No need to plan around
Apple eating this feature.

### Golden Gate grounding facts

- Announced 8 June 2026 at WWDC; dev beta same day; public beta 13 July 2026; ships ~Sept 2026.
- **Apple silicon only** — first macOS to drop Intel, last with full Rosetta 2.
- Apple Intelligence runs on all supported Macs, but **on-device Siri AI needs M3+ with
  ≥12 GB RAM**. Below that, requests route to Private Cloud Compute (PCC).
- Headline feature is the rebuilt **Siri AI**: conversational, personal-context aware
  (indexes Mail, Messages, Calendar, Notes, Photos, files), on-screen aware, acts via
  App Intents. Lives in Spotlight (⌘-Space = "search or ask") plus a standalone Siri app.

---

## Finding 2 — the premise needs a correction

The personal context described above — Apple Mail holding Outlook mail, indexed and
queryable — belongs to **Siri AI**, not to `fm`. Two different things sharing a model:

| | What it has | Scriptable? |
|---|---|---|
| **Siri AI** | Privileged semantic index across Mail, Messages, Calendar, Notes, Photos, files | **No.** Can't cron it, can't pipe it, can't make it write to Slack. |
| **`fm` CLI** | Nothing. A bare model with a prompt. | Yes — that's the whole point of it. |

So "local model + local data = same as the skill today" doesn't hold. `fm` gives us
**inference, not context**. Every extractor would still be ours to write: EventKit, Mail
scripting or Graph, Jira REST, Salesforce API.

One bridge worth watching: the Foundation Models framework added a **Spotlight-backed
local search tool** for RAG. That *does* give the model retrieval over the local index —
but it's a framework tool, not something `fm` hands you for free.

---

## Finding 3 — the number that decides it

| | On-device (AFM 3 Core / Core Advanced) | PCC server model | Claude |
|---|---|---|---|
| **Context window** | **~4,096 tokens** | 32,000 tokens | 200k+ |
| Size | 3B dense / 20B sparse (1–4B active) | undisclosed, larger | frontier |
| Latency | sub-100ms | network | network |
| Cost | zero, unmetered | free tier under 2M downloads | metered |
| Benchmarks | MMLU 67.8, IFEval 85.1 | — | ~90 MMLU |

**4,096 tokens is shared input + output.** A single pre-call briefing — attendee history,
recent thread context, Jira tickets, Salesforce account state — is comfortably 20k–100k
tokens. It does not fit. Not close. Even PCC's 32k is tight for a multi-meeting brief.

> ⚠️ **Load-bearing uncertainty.** 4,096 is the *documented iOS 26* figure. Apple confirmed
> 32k for PCC at WWDC 2026 but **has not published a new on-device number for AFM 3**.
> If it has quietly gone up, the conclusion below softens considerably.
> **This is the single most important thing to measure first on real hardware.**

---

## Conclusion — where local actually wins

**Not the briefing itself.** A 3B model with 4k context will not execute
`breifingskill.txt` (~1560 lines, conditional, judgment-heavy). That's precisely the
failure mode of a small model: plausible-sounding briefs that quietly drop the nuance
the rules exist to capture.

**The win is the tier below the briefing** — and it maps onto a problem we already have.
`CLAUDE.md` notes the scheduled task fires only ~3×/day, so same-day meetings booked
between runs get missed; `PreCallBriefTriggerService` patches that by spawning headless
`claude` on new meetings. That's a metered, rate-limited, network-dependent call sitting
in a reactive hot path.

Four real benefits from moving **that layer** local:

1. **Run on every calendar change, not on a schedule.** Zero marginal cost and no rate
   limit means the gate can evaluate constantly. This is the actual unlock.
2. **Fuzzy work that fits in 4k.** `IntradayDiffClassifier` deciding reschedule-vs-new.
   `RelationLinker` — which today does exact case-insensitive title equality and *skips*
   ambiguous matches — could disambiguate fuzzily for free. Each is a few hundred tokens.
3. **Triage before escalation.** Local decides *whether* a meeting warrants a brief;
   Claude composes only when the answer is yes. Cuts cloud calls hard, no quality loss.
4. **Privacy posture.** Salesforce account context and customer assessment data currently
   leaves the machine on every brief. Triage-locally means only meetings clearing the bar
   send anything out, and we choose what.

`fm serve` exposes a local **OpenAI-compatible HTTP endpoint**, so wiring this in is
closer to a base-URL change than a rewrite.

### Recommended shape (if pursued)

Hybrid, split on the context boundary: **`fm` for triage, classification, and matching;
Claude for composition.** Don't try to move the brief itself on-device.

Apple has effectively conceded this architecture — the Foundation Models framework now
routes to Claude through the same Swift API, with a per-request choice of on-device /
PCC / frontier.

### Narrowest high-value first cut

Replace `RelationLinker`'s exact-title-match-or-skip with local fuzzy disambiguation via
`fm`. Small, self-contained, obviously testable, zero cost per call, and it fixes a real
thing the sync silently gives up on today. Good first exercise of the toolchain without
betting anything on it.

---

## What to test once hardware is available

1. **Measure the real on-device context window.** Everything above hinges on this.
   Feed increasing prompt sizes to `fm respond` until `contextWindowExceeded`.
2. **Does `fm schema` produce reliable structured JSON** for the gate/classifier
   decisions? Structured output is the whole reason this would be usable from Swift.
3. **Sanity-check triage quality** — can a 3B model reliably answer "is this meeting
   briefing-worthy?" given our rules compressed to a few hundred tokens?
4. **Latency under a real reactive load** — the sub-100ms claim, on a hot path firing on
   every `.EKEventStoreChanged`.
5. **Check whether `fm` is present and usable in a non-interactive/launchd context**, not
   just an interactive shell. `PreCallBriefTriggerService` runs headless.
6. **Confirm the M3/12 GB floor matters** — if Adam's machine is under it, on-device
   silently becomes PCC and the privacy argument evaporates.

---

## Other Golden Gate notes worth keeping

- **`fm` CLI** at `/usr/bin/fm`. Subcommands `respond`, `chat`, `schema`, `serve`.
  Structured JSON output, transcript persistence, token accounting, OpenAI-compatible
  local REST server. Apple session: *"Build AI-powered scripts with the fm CLI and
  Python SDK"* (WWDC26 session 334).
- **Foundation Models framework 2026 additions:** image input; server-side model routing
  (call Claude or Gemini through the same Swift API); **Dynamic Profiles** for multi-agent
  workflows; built-in Vision tools (BarcodeReaderTool, OCRTool) and the Spotlight RAG
  search tool. Free PCC access for devs under 2M first-time downloads. Framework going
  **open source**.
- **Shortcuts "Use Model" action** — per-step choice of on-device / server / ChatGPT.
  Apple's own cited example is *filtering calendar events and summarizing content*.
- **Models:** AFM 3 Core (3B dense), AFM 3 Core Advanced (20B sparse, 1–4B active,
  natively multimodal — text/image/audio).
- **Intel drop** is a deployment constraint if this app ever has users beyond Adam.

---

## Research caveats

Recorded so future-me knows how much to trust the above:

- **`apple.com` and `developer.apple.com` were blocked by the session's egress proxy**, as
  were Wikipedia and MacStories. Every `WebFetch` failed. Findings come from search-result
  summaries, not from reading Apple's newsroom posts and developer docs directly. The
  Golden Gate facts are consistent across MacRumors, Macworld, AppleInsider, 9to5Mac and
  MacStories — solid, but **not verified against Apple's own words**.
- The **absence** of a briefing feature is a negative finding from repeated targeted
  searching. Reasonably strong, not airtight — Apple's "250 changes" list couldn't be fetched.
- `fm` CLI details lean partly on Medium posts (normally discount these), but the existence
  of WWDC26 session 334 with that exact title corroborates the substance.
- **Disputed:** some low-quality sources claim Apple's new foundation models were built on
  Gemini technology. AppleInsider explicitly refutes this. Treat as unreliable.
- **Re-verify the context-window numbers from primary sources before designing anything.**

## Sources

- [macOS Golden Gate roundup — MacRumors](https://www.macrumors.com/roundup/macos-27/)
- [macOS 27 hands-on — MacRumors](https://www.macrumors.com/2026/06/12/macos-golden-gate-hands-on/)
- [Siri AI in iOS 27 — MacRumors](https://www.macrumors.com/guide/ios-27-siri/)
- [Platforms State of the Union 2026 — MacRumors](https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/)
- [macOS 27 guide — Macworld](https://www.macworld.com/article/3139330/macos-27-mac-features-siri-apple-intelligence-release-date-compatibility.html)
- [Golden Gate beta review — AppleInsider](https://appleinsider.com/articles/26/06/12/macos-golden-gate-beta-review-its-nothing-without-siri-ai)
- [Apple's foundation models and Gemini — AppleInsider](https://appleinsider.com/articles/26/06/08/apples-new-foundation-models-dont-contain-a-drop-of-gemini-as-we-said-they-wouldnt)
- [New Siri AI in iOS 27 — 9to5Mac](https://9to5mac.com/2026/06/08/new-siri-whats-new/)
- [Apple's third-generation Foundation Models explained — 9to5Mac](https://9to5mac.com/2026/06/11/apples-new-foundation-models-explained-on-device-ai-cloud-ai-and-everything-in-between/)
- [Siri AI and Apple Intelligence overview — MacStories](https://www.macstories.net/news/siri-ai-and-the-latest-in-apple-intelligence-the-macstories-overview/)
- [AFM 3 and AFM Core Advanced — MacStories](https://www.macstories.net/linked/the-third-generation-of-apples-foundation-models-and-afm-core-advanced/)
- [Third generation of Apple's Foundation Models — Apple ML Research](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models)
- [TN3193: Managing the on-device model's context window — Apple Developer](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)
- [What's new in the Foundation Models framework — WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
- [Build AI-powered scripts with the fm CLI and Python SDK — WWDC26 session 334](https://developer.apple.com/videos/play/wwdc2026/334/)
- [Apple Foundation Models in appleOS 27 — Michael Tsai](https://mjtsai.com/blog/2026/06/16/apple-foundation-models-in-appleos-27/)
- [The local inference boundary: AFM 3 and token economics — Thoughtworks](https://www.thoughtworks.com/insights/blog/generative-ai/local-inference-boundary-reflections-apple-afm3-token-economics)
- [Apple Foundation Models — Claude Platform Docs](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models)
