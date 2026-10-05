# Development notes

## 2026-10-05

Playback gained a sample-clock position, metering, seeking and pause/resume. After-recording preview used the effects graph while retaining original audio. Focused rendered-audio checks established generic preview/export effects and bypass behavior; they did not resolve the separate DeepFilter allocation-latency/live-bypass acceptance item.

Folders were stored in an atomically written `.library-index.json`, leaving UUID session directories stable. Trash moved the entire recording into `.Trash/<UUID>` and restoration moved it back. Folder deletion cleared assignments rather than deleting recordings. The session manifest committed audio metadata and transcript state last; the transcript sidecar served only as recovery data. Batch Trash snapshotted the confirmed IDs, performed throwing save preflight before moving directories, and preserved failed selections on partial success.

Offline refinement rerecognized saved `source.caf` with the configured local GGUF on a serial worker. Requests were bounded to 30 seconds, preferring silence boundaries; recognition context was not retained between chunks. Successful recognition and persistence preceded text replacement, with the original transcript/status retained for restoration. The native offline call could not be interrupted mid-call, so cancellation discarded its result and waited for handle cleanup.

UI revisions enlarged and aligned icon actions, retained help/accessibility labels, widened segmented-control hit areas, and collapsed recording/export settings behind their button. Live waveform bars used bounded recent peaks and UI-only interpolation instead of compressing accumulated history; pause froze motion. Focused library/refinement/playback, ASR backlog, batch Trash and waveform checks passed for their recorded scopes. Full visual/VoiceOver operation remained outside those automated claims.

Microphone investigation established that the engine's input/output nodes shared an AUHAL handle: retargeting an input-only SAudio device also invalidated output. US-2x2HR exposed a 192 kHz hardware clock while recording requested 48 kHz. The repair introduced owned process-private input/output routing and normalized fresh advancing tap clocks into recording-rate frames before arming capture. It retained native input formats, original audio and explicit cleanup failures, without writing system device defaults or physical rates.

The last ordinary build passed, but the selected-device check failed before recording: AUHAL rejected the private route as unusable (`-10851`, `build/device-switch-critical-4.json`). Native microphone authorization succeeded. A further source repair omitted descriptive subdevice channel-count keys, waited asynchronously for alive/rate/channel capabilities and both active device UIDs, and distinguished assignment from readback failures. Preparation timing was a possible cause, not an established fix. This latest source and its adjusted/new readiness tests were not built or executed; the user chose to perform the trial build/run through `script/build_and_run.sh`. Current acceptance, preserved attempt limits and exact resumption scope remained solely in `PLANS.md`.

## 2026-10-04

The user requested execution of the saved plan and authorized multi-agent work. Construction uses the latest v5 reference. The current Swift preparation skill permits shell-first builds; the plan's Xcode MCP path remains in use where available. XcodeGen 2.46.0 is already installed. Swift 6.4 / Xcode 27.0 target arm64 macOS 26.

Audio, native plugin hosting, and the app/ASR integration are implemented with distinct ownership to allow independent review of realtime and native-lifetime concerns. Installed SDK and plugin files remain untouched.

AVAudioNode tap and playback completion closures inherited MainActor checks when created inside isolated methods. Nonisolated Sendable factories removed the audio-thread actor trap; actual microphone recording and natural playback completion subsequently succeeded.

The default NeMo C ABI configuration emitted a single final only at stream close. Token-silence endpointing at 800 ms now creates utterance finals during capture. The transcript displays a start/end range instead of a permanently zero initial start marker. A two-utterance Japanese fixture verified live finalization, advancing timestamps, and retention after stop.

DeepFilter's latency depends on its allocated maximum block size. Preflight latency differed from live allocation and explained the earlier 80 ms advance. Capture now arms both taps from a common future sample boundary after engine allocation. The repaired 82.973333-second mixed recording had identical source/processed frame counts and zero measured lag before and after pause. Export also reads latency and tail only after its engine starts; affected export checks passed.

Supercharger AU and DeepFilter VST3 custom editors worked, and DeepFilter Mix=50% plus plugin states survived relaunch. The repaired 12:40 live run maintained zero measured branch lag and no continuing memory growth. An audio-device configuration change paused it before latency drain, so the original and transcript were retained while processed output stayed explicitly incomplete. The user played an effects-applied 24-bit WAV export whose frame count matched the entire original. Remaining actual-app acceptance stays in PLANS.md.

MCP build and four affected tests passed after the current repairs; strict Swift formatting and Release bundle signatures passed. XcodeGen's Xcode version metadata now matches 27.0 after reviewing the target settings through MCP, clearing the stale recommended-settings notice. Device acceptance and attempt limits remain solely in PLANS.md.

The isolated scanner timeout/cache fixture passed without touching installed plugins or their production cache. macOS temporary-directory aliases required comparing canonical paths; cached results retained the scanner's actual path key.

An earlier manually stopped 36.488-second recording saved three Japanese final segments with advancing time ranges and no warning. At the user's requested pause, no recording remained active; the Release bundle, saved sessions and resumption notes were retained.

The final handoff consolidated existing acceptance evidence instead of repeating microphone flows. Actual I16/I24/F32 WAV and 96/192 kbps AAC exports retained all 1,751,424 program frames and played in QuickTime; F32 was sample-identical to source. The later timed recording retained 41.176 seconds, with the clock frozen at 30 seconds across the five-second pause. Final Release staging and relaunch/session persistence succeeded. The delivered app is `dist/EasyPod.app`.

The plugin picker gained grouped accessibility content, explicit effect-name/AU/VST3 add labels, and standard bordered buttons. Search and DeepFilter addition succeeded in the staged app. Automation still summarized list rows, so independent child-button exposure and full VoiceOver navigation were not established.

After-recording preview, remaining original/processed effect comparisons, some interruption recovery scenarios, and full VoiceOver navigation remained unverified in PLANS.md. The plan was bounded to prevent repeated acceptance loops: reuse evidence for unchanged behavior, retain attempt counts across handoffs, and reopen only the specific requirement implicated by a reported issue or explicit verification request. Outstanding audits did not authorize automatic continuation after delivery.
