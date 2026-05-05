# Native Voice Transcription + Summarisation

**Date:** 2026-05-05
**Status:** Design — for review before implementation
**Sibling plan:** [2026-05-05-remove-minutes-and-obsidian-design.md](./2026-05-05-remove-minutes-and-obsidian-design.md) (recommended to apply that one **first**)

---

## Problem

Today the app has two recording stories:

1. **Minutes integration** — feature-flagged off by default. Spawns the third-party `silverstein/minutes` Rust CLI. The CLI captures **only the user's microphone**, not the other side of the conversation. Adam can't get it working reliably (stale device config, missing model, audio routing fragility).
2. **Notion integration** — creates a page on meeting join and lets Notion's AI Meeting Notes block do recording + summarisation. Notion's recorder also captures only the user's mic. Summarisation is gated behind Notion AI usage, on Notion's servers.

The single hard requirement neither integration solves: **capture both sides of the conversation (mic + system audio) without virtual audio devices like BlackHole**.

## Goal

A first-party, in-process pipeline that:

1. Captures **mic and system audio** as two physically separate streams — no audio routing kludges, no third-party CLI
2. Transcribes both streams locally (no network)
3. Labels each line by source (`me` vs `them`) — diarisation for free
4. Summarises the transcript locally (Apple Foundation Models on macOS 26+, with graceful fallback)
5. Pushes the structured note to the existing Notion meeting page (replaces Notion AI's role; the calendar-driven Notion page creation **stays** as the trigger and entry-point)

The Live Transcript pane and Post-Meeting Nudge UI stay — they're rebuilt to subscribe to the new in-process source instead of polling Minutes' JSONL file.

## Non-goals (v1)

- Real speaker diarisation beyond `me`/`them` (one Zoom call, three other speakers — they all collapse into `them`)
- Per-app system audio capture (system-wide is fine for v1; Process Taps is a future enhancement)
- Editing transcripts in-app — Notion is the edit surface
- Multi-language transcription beyond what `SFSpeechRecognizer` supports out of the box (English-only default, locale-pickable in Settings)
- Cloud transcription as a fallback if on-device fails — we either transcribe locally or we don't
- Storing audio files long-term (transcripts only; audio buffers are transient)

---

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│  AudioCaptureService  (new)                                    │
│                                                                │
│   AVAudioEngine ──► mic PCM stream ──┐                         │
│                                       ├──► merged TimedAudio   │
│   SCStream (audio) ─► sys PCM stream ─┘                        │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  TranscriptionService  (new)                                   │
│                                                                │
│   SFSpeechRecognizer (mic)   ──► .me lines    ──┐              │
│   SFSpeechRecognizer (sys)   ──► .them lines  ──┴──► merged    │
│                                                                │
│   @Published var lines: [TranscriptLine]                       │
│   @Published var isRunning: Bool                               │
│   @Published var energySilent: Bool  // for end detection      │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  SummarizationService  (new)                                   │
│                                                                │
│   if #available(macOS 26):                                     │
│       LanguageModelSession (FoundationModels) ──► structured   │
│   else:                                                        │
│       Lightweight regex extractor over the transcript          │
│                                                                │
│   Returns a MeetingSummary                                     │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  NotionService.appendStructuredSummary  (new method)           │
│                                                                │
│   Patches the existing Notion meeting page with summary,       │
│   action items, decisions, optional full transcript toggle.    │
└────────────────────────────────────────────────────────────────┘
```

The trigger flow is unchanged: `MeetingMonitor.currentMeetingInProgress` going non-nil starts the pipeline; going nil stops it. `OverlayCoordinator` orchestrates this just as it currently does for Minutes.

### New service: `AudioCaptureService`

`Services/AudioCaptureService.swift`. `@MainActor`, `ObservableObject`. Owns two capture sources and exposes them as `AsyncStream<TimedAudioBuffer>` per source. Tagged buffers carry `(source: .mic | .system, pcm: AVAudioPCMBuffer, hostTime: UInt64)`.

**Mic capture** — standard `AVAudioEngine`:
- `inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil)` → tap callback yields buffers into the mic stream
- Format converted to 16 kHz mono Float32 (what SFSpeechRecognizer expects) via `AVAudioConverter`
- Started/stopped via `start()`/`stop()`

**System audio capture** — `ScreenCaptureKit`:
- `SCShareableContent.current` → pick the main display
- `SCContentFilter(display:excludingApplications:exceptingWindows:)` — exclude our own bundle ID with `excludesCurrentProcessAudio = true` to avoid feedback loops
- `SCStreamConfiguration` with `capturesAudio = true`, `sampleRate = 48000`, `channelCount = 2`, plus a 2×2 black pixel video region we ignore (SCStream requires *some* video config; we minimise it to ~zero cost)
- Implement `SCStreamOutput.stream(_:didOutputSampleBuffer:of: .audio)` — yield buffers into the system stream
- Output is `CMSampleBuffer` of LPCM; we convert to `AVAudioPCMBuffer` and downsample to 16 kHz mono Float32 to match the mic stream

**Permissions handled lazily, never at launch:**
- `AVCaptureDevice.requestAccess(for: .audio)` on first mic capture attempt — surfaces the standard mic prompt
- ScreenCaptureKit triggers the Screen Recording TCC prompt the first time `SCStream.startCapture()` is called
- If the user denies either, `AudioCaptureService` publishes a `permissionDenied: PermissionKind?` value, which the UI surfaces as a "Grant in System Settings" hint

### New service: `TranscriptionService`

`Services/TranscriptionService.swift`. `@MainActor`, `ObservableObject`. Subscribes to `AudioCaptureService`'s two streams and runs an `SFSpeechRecognizer` per stream.

**Why SFSpeechRecognizer?** Three options were on the table:

| Option | OS | Dep | Quality | Picked? |
|---|---|---|---|---|
| `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true`) | macOS 13+ | None | OK | ✅ Yes — matches floor, no deps |
| `SpeechAnalyzer` / `SpeechTranscriber` | macOS 26+ | None | Excellent | Add behind `if #available` later |
| `WhisperKit` (Argmax) | macOS 13+ | SPM | Excellent | Breaks "no external deps" rule (CLAUDE.md) |

SFSpeechRecognizer is the only option that ships today on macOS 13 with zero dependencies. We layer in `SpeechTranscriber` as an availability-gated upgrade once the implementation is stable.

**Streaming pattern:** one `SFSpeechAudioBufferRecognitionRequest` per source, with `shouldReportPartialResults = true` and `requiresOnDeviceRecognition = true`. Audio buffers from the source's `AsyncStream` are appended to the request via `append(_:)`. Partial results flow into the published `lines` array; finals close the line.

**Long meeting handling:** SFSpeechRecognizer historically had a ~1-minute task limit for streaming requests. We mitigate by:

1. Tracking each task's elapsed time and rotating to a fresh request every 50 seconds at a detected silence boundary
2. On rotation, the partial buffer that hasn't yet been finalised gets stitched into the next request's preamble so we don't lose mid-sentence audio
3. **Verify on macOS 14/15:** Apple may have lifted this limit; the rotation is defensive

**Output schema:**

```swift
enum TranscriptSource { case mic, system }

struct TranscriptLine: Identifiable, Equatable {
    let id: UUID
    let source: TranscriptSource          // me / them
    let text: String                       // current best (partial or final)
    let isFinal: Bool
    let startedAt: Date                    // when the segment began
    let updatedAt: Date
}

@Published var lines: [TranscriptLine]    // capped at last 200, like LiveTranscriptService today
@Published var isRunning: Bool
```

**Energy-based silence detection** (replaces the old `kAudioDevicePropertyDeviceIsRunningSomewhere` heuristic):

Compute RMS over each incoming buffer per stream. When **both** streams' RMS stays below `~-50 dBFS` for 30 continuous seconds, publish `energySilent = true`. `MeetingMonitor` consumes this in place of the old `audioInactiveSince` debounce. This is strictly better than the device-running flag because:
- It's not fooled by us holding the mic (we ARE the recorder; the device is always "running")
- It can distinguish "nobody's talking" from "audio is playing music in background" by being a per-stream measurement
- It works for ad-hoc meetings (the only end signal short of manual press)

### New service: `SummarizationService`

`Services/SummarizationService.swift`. `@MainActor`, `ObservableObject`. Takes a `[TranscriptLine]` and a `MeetingEvent`, returns a `MeetingSummary`.

**FoundationModels path (`#available(macOS 26, *)`):**

```swift
let session = LanguageModelSession(instructions: prompt)
let response = try await session.respond(
    to: transcriptText,
    generating: MeetingSummary.self  // @Generable struct, see below
)
```

`MeetingSummary` is `@Generable` so the model returns typed Swift values directly, no JSON parsing.

```swift
@Generable
struct MeetingSummary: Codable, Equatable {
    @Guide(description: "1-3 sentence executive summary")
    let summary: String

    @Guide(description: "Concrete next-step tasks committed to during the meeting")
    let actionItems: [ActionItem]

    @Guide(description: "Decisions reached during the meeting")
    let decisions: [Decision]

    @Generable
    struct ActionItem: Codable, Equatable, Identifiable {
        var id: UUID { UUID() }
        let task: String
        let assignee: String?       // "Alice" or "me"
        let due: String?            // free-form: "by Friday", "this week"
    }

    @Generable
    struct Decision: Codable, Equatable, Identifiable {
        var id: UUID { UUID() }
        let text: String
    }
}
```

**Long-transcript chunking** — FoundationModels has a finite context window. For meetings >~30 min we map-reduce: split transcript into ~10-min windows, summarise each, then summarise the summaries. Implementation deferred until we hit the limit in practice — most calls are <30 min.

**Fallback path (macOS 13–25):**

A regex-based extractor that pulls bullet-able sentences from the transcript. Reuses the same patterns `LiveTranscriptService.analyze` currently uses for in-call coach hints (commitment phrases like "I'll send", "by Friday", question detection). Output is intentionally low-fidelity: better than nothing, but the user is told in the post-meeting nudge that "Local AI summary requires macOS 26+ — install for richer notes."

The boundary between paths is invisible to callers: `SummarizationService.summarize(transcript:event:) async throws -> MeetingSummary` returns the same type either way. The fallback marks `summary` as a one-line transcript-length stat instead of natural language.

### Modified service: `NotionService`

Adds `appendStructuredSummary(_ summary: MeetingSummary, to pageID: String) async throws`.

The flow:
1. On meeting join, `NotionService.createMeetingPage(for:)` runs as today — creates the page, returns the URL. Page ID is captured in a new `@Published var lastCreatedPageID: String?`.
2. On meeting end, `appendStructuredSummary` PATCHes children blocks onto that page using `POST /v1/blocks/{pageID}/children`:

```
[heading_2] Summary
[paragraph]  <summary text>

[heading_2] Action items
[to_do] <task>            ← unchecked
[to_do] <task>            ← unchecked
...

[heading_2] Decisions
[bulleted_list_item] <decision>
...

[toggle]    Full transcript          ← collapsed by default
  [paragraph]  [10:03] me: ...
  [paragraph]  [10:03] them: ...
  ...
```

The toggle gives the user the raw transcript without cluttering the page. Notion limits each `rich_text` to 2000 chars, so transcript paragraphs are chunked the same way `createMeetingPage` already chunks calendar notes.

**Failure handling:** if Notion isn't configured, the post-meeting nudge falls back to "copy as markdown" — the structured summary is still useful even without a destination. If the API call fails, the error surfaces in `lastError` and the nudge shows a "Retry push to Notion" button.

### Replaces / refactors

| Existing file | Disposition |
|---|---|
| `Services/MinutesService.swift` | **Deleted** by sibling Plan B |
| `Services/LiveTranscriptService.swift` | **Rewritten** — same shape (lines, hints, isRunning, preview), but subscribes to `TranscriptionService` instead of polling JSONL |
| `Models/MinutesMeeting.swift` | **Replaced** by `Models/MeetingTranscript.swift` (see below) |
| `Views/LiveTranscriptView.swift` | Light edits — `.transcriptRow` shows `me`/`them` chip; coach hints move to TranscriptionService |
| `Views/PostMeetingNudgeView.swift` | **Rewritten** — driven by `MeetingSummary` instead of `MinutesMeeting`; "Open in Obsidian" button removed; "Push to Notion" / "Pushed ✓" pill replaces it |
| `Views/ContextPanelView.swift` | Prep brief section deleted (Minutes-only feature) |
| `Views/MenuBarView.swift` | Recording status pills now driven by `TranscriptionService.isRunning` instead of `MinutesService.status` |

### New model: `MeetingTranscript`

`Models/MeetingTranscript.swift`. Represents a complete recorded meeting, in-memory only.

```swift
struct MeetingTranscript: Identifiable, Equatable {
    let id: UUID
    let event: MeetingEvent
    let lines: [TranscriptLine]
    let summary: MeetingSummary?      // nil while summarisation is in flight
    let startedAt: Date
    let endedAt: Date
}
```

Persistence is deliberately minimal: the durable artefact lives in Notion. We keep the last completed transcript in `OverlayCoordinator` for the duration of the post-meeting nudge, then drop it. (If the user wants offline retention later, we add a JSON dump to `~/Library/Application Support/MeetingReminder/transcripts/`.)

---

## OverlayCoordinator wiring

Replaces the current Minutes/Obsidian sink in `MeetingReminderApp.swift`. After Plan B has removed the old paths, the new wiring looks like:

```swift
// On meeting in-progress:
monitor.$currentMeetingInProgress
    .compactMap { $0 }
    .sink { [weak self] event in
        // 1. Notion page creation (unchanged)
        if self.notionService.isActive {
            Task { ... createMeetingPage ... openInNotionApp ... }
        }
        // 2. Native recording (NEW — replaces minutes record)
        if self.recordingPreferences.autoRecord {
            Task {
                await self.audioCaptureService.start(
                    captureMic: self.recordingPreferences.captureMic,
                    captureSystem: self.recordingPreferences.captureSystem
                )
                self.transcriptionService.start(
                    micStream: self.audioCaptureService.micStream,
                    systemStream: self.audioCaptureService.systemStream
                )
                if self.recordingPreferences.showLiveTranscript {
                    self.liveTranscriptController.show(...)
                }
            }
        }
        // 3. Context panel (unchanged)
        self.contextPanelController.show(event: event, ...)
        // 4. Pre-call brief (unchanged)
        self.showBriefPanelIfConfigured(for: event)
    }

// On meeting ended:
monitor.$currentMeetingInProgress
    .scan / removeDuplicates / pairwise transition ...
    .sink { [weak self] (previous, current) in
        guard let ended = previous, current == nil else { return }

        // Stop capture + transcription, snapshot final lines
        let lines = await self.transcriptionService.stopAndCollect()
        await self.audioCaptureService.stop()

        // Summarise
        let summary = try? await self.summarizationService.summarize(
            transcript: lines, event: ended
        )
        let transcript = MeetingTranscript(
            id: UUID(),
            event: ended,
            lines: lines,
            summary: summary,
            startedAt: ended.startDate,
            endedAt: Date()
        )

        // Push to Notion if a page exists for this event
        if let pageID = self.notionService.pageID(for: ended.id),
           let summary {
            try? await self.notionService.appendStructuredSummary(summary, to: pageID)
        }

        // Show the nudge with the complete transcript + summary
        self.postMeetingController.show(transcript: transcript, ...)
    }
```

`MeetingMonitor.externalRecordingActive` is removed entirely — we own the mic now, so silence detection works again, but it uses the new energy-based signal from `TranscriptionService.energySilent` rather than the old Core Audio device-running flag.

---

## Settings

The Integrations tab is gone (Plan B removes it). A new top-level **Recording** tab takes its place, with these controls:

| Key | Type | Default | Purpose |
|---|---|---|---|
| `recordingAutoStart` | Bool | true | Start recording automatically when joining a meeting |
| `recordingCaptureMic` | Bool | true | Capture microphone (you) |
| `recordingCaptureSystem` | Bool | true | Capture system audio (them). Disabling makes this single-stream and skips Screen Recording prompt. |
| `recordingShowLiveTranscript` | Bool | true | Show floating transcript pane during meetings |
| `recordingInCallCoachEnabled` | Bool | true | Heuristic mention/question/commitment hints |
| `recordingCoachUserName` | String | `""` | Override for mention detection (defaults to `NSFullUserName()`) |
| `recordingTranscriptionLocale` | String | `en-US` | SFSpeechRecognizer locale picker |
| `recordingSummarisationEnabled` | Bool | true | Run summarisation after meeting ends |
| `recordingPushToNotion` | Bool | true | Append summary to Notion meeting page |
| `recordingKeepFullTranscriptInNotion` | Bool | true | Embed full transcript in a collapsed toggle block |

Status section in the same tab shows:
- Microphone permission state with Request / Open System Settings button
- Screen Recording permission state with Request / Open System Settings button
- macOS 26+ availability for FoundationModels (with `if #available` reflecting status)
- Last recording's pipeline trace (capture started → transcription started → summary generated → Notion pushed) with timestamps — useful for debugging

The existing Notion tab is unchanged. The existing per-tier alert toggles, calendars, checklist, etc. stay where they are.

---

## Permissions and Info.plist

Two new keys in `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Meeting Reminder records your microphone during meetings to transcribe what you say. Recording stops automatically when the meeting ends. Audio never leaves your Mac.</string>

<key>NSScreenCaptureDescription</key>
<string>Meeting Reminder captures the audio playing through your speakers during meetings (the other side of the call) to transcribe what's said. Only audio is read — your screen is never recorded. Audio never leaves your Mac.</string>
```

(Verify the exact key for ScreenCaptureKit's TCC string — Apple's docs sometimes reference `NSScreenCaptureUsageDescription`. Test on a fresh user account before shipping.)

Entitlements file (`MeetingReminder.entitlements`) needs no changes:
- App sandbox stays disabled (already is)
- `network.client` already present (used by Notion)
- No special microphone or screen-recording entitlement exists in the sandbox-disabled world; permission is granted via TCC at first use

---

## Testing

The project has no unit test target for these services (consistent with the codebase pattern — verification is manual, per CLAUDE.md). Verification plan:

1. **Mic-only recording** — disable `recordingCaptureSystem`. Start ad-hoc meeting. Speak into mic. Verify lines appear in Live Transcript pane labelled `me`. End meeting. Verify summary is generated and pushed to Notion.
2. **System-only recording** — disable `recordingCaptureMic`. Play a YouTube video with clear speech. Verify lines appear labelled `them`.
3. **Both streams** — enable both. Start a Zoom call with a friend. Verify interleaved labelled lines, no echo, no double-counting (the `excludesCurrentProcessAudio` flag is critical here).
4. **Long meeting** — record for 90 minutes. Verify the SFSpeechRecognizer task rotation doesn't drop audio at the boundary (script: speak a known sentence at minute 49, 50, 51 — listen for it in the transcript).
5. **Permissions denied** — boot a fresh user account. First recording attempt should prompt for both mic and screen recording. Deny each. Verify the UI shows "Grant in System Settings" with a working button to System Settings → Privacy & Security.
6. **No Foundation Models** — run on macOS 13/14/15. Verify the regex fallback path produces *some* action items and that the post-meeting nudge shows the "macOS 26+ for richer notes" hint.
7. **With Foundation Models** — run on macOS 26+. Verify `@Generable` decoding produces well-formed `MeetingSummary` values.
8. **Notion push** — confirm the meeting page in Notion has Summary heading, Action items as `to_do` blocks, Decisions as bullets, Full transcript as a toggle.
9. **Energy-based end detection** — start ad-hoc meeting, sit silent for 35 seconds. Verify meeting ends automatically.
10. **Preview** — `overlayCoordinator.previewLiveTranscript()` should still work with seeded sample data (the sample data feeder lives in the rebuilt `LiveTranscriptService`).

---

## Files

| File | Change |
|---|---|
| `Services/AudioCaptureService.swift` | NEW — AVAudioEngine + SCStream lifecycle |
| `Services/TranscriptionService.swift` | NEW — dual SFSpeechRecognizer, energy detection |
| `Services/SummarizationService.swift` | NEW — FoundationModels with regex fallback |
| `Services/RecordingPreferences.swift` | NEW — typed wrapper around the `recording*` `@AppStorage` keys |
| `Models/MeetingTranscript.swift` | NEW — `TranscriptLine`, `MeetingSummary`, `MeetingTranscript` |
| `Services/LiveTranscriptService.swift` | REWRITTEN — subscribes to TranscriptionService instead of polling JSONL |
| `Services/NotionService.swift` | EDIT — adds `appendStructuredSummary`, `pageID(for:)`, `lastCreatedPageID` |
| `Views/LiveTranscriptView.swift` | EDIT — me/them source chip on each row |
| `Views/PostMeetingNudgeView.swift` | REWRITTEN — drives off `MeetingTranscript`, no Obsidian branch |
| `Views/SettingsView.swift` | EDIT — new Recording tab, removes old Minutes/Obsidian content (Plan B did this) |
| `Views/MenuBarView.swift` | EDIT — recording status pills driven by TranscriptionService |
| `MeetingReminderApp.swift` | EDIT — wire new services in `OverlayCoordinator` |
| `MeetingReminder/Info.plist` | EDIT — add `NSMicrophoneUsageDescription`, `NSScreenCaptureDescription` |
| `MeetingReminder.xcodeproj/project.pbxproj` | EDIT — register 5 new Swift files |

LOC estimate: ~1500 lines new, ~400 lines edited, well below the ~1800 LOC of Minutes/Obsidian removed in Plan B. Net code reduction.

---

## Risks

1. **SFSpeechRecognizer accuracy on noisy system audio.** The other side of a Zoom call is already lossy/compressed. Quality might be noticeably worse than mic-side. Mitigation: run a 2-week dogfood phase before considering the SwiftPM rule for WhisperKit.
2. **ScreenCaptureKit performance overhead.** Even with a 2×2 video region, SCStream has non-trivial CPU. Mitigation: profile during a 1h meeting; if >5% CPU, switch to Core Audio Process Taps (macOS 14.2+) with a feature flag.
3. **Mic conflict with the call app.** Zoom/Teams already hold the mic; AVAudioEngine asks for shared input. Verify both can read simultaneously on macOS 13+. If one app gets exclusive access, we may need to use `AVCaptureSession` with `AVCaptureAudioDataOutput` instead, which is friendlier to sharing.
4. **Permission UX friction.** Two TCC prompts on first run is a lot. We delay both until first recording, and let users disable system audio capture entirely (single-stream, mic-only mode) to avoid the screen recording prompt. Mode is in onboarding too.
5. **FoundationModels output drift.** `@Generable` is robust but the model can occasionally produce empty or malformed structured output for very short transcripts. We validate post-hoc: if `actionItems` is empty AND `summary` is empty for a >2 min meeting, fall back to the regex extractor.
6. **Notion API rate limits.** 3 req/s. Single-meeting flow makes 2-3 calls (create + summary append + maybe transcript chunks). We're well under, but log 429s explicitly.

---

## Out of scope (future work)

- Per-app audio capture via Core Audio Process Taps (macOS 14.2+) — drops the Screen Recording permission requirement for users on Sonoma+
- Speaker diarisation beyond me/them — would need a clustering model on the system stream
- Disk-backed transcript history — keep last N meetings as JSON in app support dir
- "Open this transcript in <editor>" — Notion is the home for now; if Adam wants Obsidian back, he can subscribe to the new Notion page via a sync plugin
- WhisperKit upgrade path — revisit if SFSpeechRecognizer quality is insufficient after dogfooding
- `SpeechAnalyzer` upgrade path on macOS 26+ — drop-in replacement for SFSpeechRecognizer once Tahoe is the minimum target
