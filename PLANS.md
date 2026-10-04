# EasyPod — macOS Podcast Recorder Implementation Plan

## Progress Status

- [x] P1 — Investigate user requirements, the local environment, the installed ASR runtime, and plugin locations.
- [x] P2 — Generate UI concepts and incorporate icon controls, WAV export, VST3/AU, selectable effect timing, and bit depth.
- [x] P3 — Save the implementation design, dependency order, and acceptance criteria in this file.
- [x] P4 — Obtain the user's approval of the latest UI concept and feature arrangement (2026-10-04 instruction to execute this plan and begin construction).
- [x] P5 — Confirm Swift + SwiftUI for a Mac-only app, prioritizing ease of use, maintainability, and future feature additions.
- [x] I1 — Establish the Xcode app project, repository conventions, native dependencies, build workflow, and ad-hoc signing.
- [x] I2 — Implement the approved UI, settings, and recording-session persistence.
- [x] I3 — Implement microphone recording, pause, resume, stop, original-audio storage, and playback.
- [x] I4 — Implement live transcription with the installed Nemotron 3.5 model.
- [x] I5 — Implement AU/VST3 discovery, mixed effect chains, editors, and state persistence.
- [ ] I6 — Implement effects after recording and optional effects during recording.
- [x] I7 — Export actual recordings to WAV and AAC/M4A.
- [ ] I8 — Implement recovery and behavior for permission, storage, ASR, and plugin failures.
- [x] V1 — Verify builds, formatting, signatures, and normal app launch.
- [x] V2 — Verify recording, Japanese transcription, persistence, and WAV/AAC export on this Mac.
- [ ] V3 — Verify mixed AU/VST3 chains, both processing modes, restoration, and failures.
- [ ] V4 — Compare the app with the approved image and verify appearance, keyboard access, and accessibility.

Current: Final local build delivered. In response to the user's request to end the prolonged verification loop, the pending Release build was collected rather than repeated, signed/staged, launched, and the changed plugin-picker operation was verified. EasyPod is open in its normal new-recording state. No microphone recording or background validation is active. Existing independent evidence is combined below; this is a completed handoff of the implemented app, not a claim that every original acceptance audit passed.

Next: No automatic additional tests. Unchecked items retain the narrower unverified acceptance scope: after-recording preview, remaining original/processed effect comparisons, and some interruption recovery scenarios (I6/I8/V3), and full VoiceOver navigation (V4). Revisit only for a concrete user-reported issue or a specific request for those checks; do not restart the broad checklist or require new recordings merely to duplicate existing evidence.

This file is the sole authoritative progress tracker. Save material implementation and verification results here. Report only changed status and material limits to the user; show the full checklist only when requested. Keep raw logs and narrative history elsewhere.

Final handoff evidence: The plugin-picker patch is limited to accessible grouping, explicit AU/VST3 action names, and standard button styling. Debug and Release builds and strict formatting passed. dist/EasyPod.app passed deep/strict signature and plist checks and launched successfully; previous bundle is retained at build/stage.ajo22b8y/previous.app. Actual search and DeepFilter addition succeeded in the staged app. The automation accessibility snapshot still summarizes list rows, so independent child-button exposure and full VoiceOver interaction are not claimed. No new audio-processing source changes were made during this handoff.

Acceptance consolidation: I3/V2 use the existing before/after-pause Japanese speech and aligned audio, the later correctly timed pause/resume take, retained sessions/transcripts after relaunch, actual playback, and five-format exports. I7 combines the five actual format/header/sample/player checks, the user's effects-applied WAV with complete frame count and measured differences from source, and passing current export source-selection/double-processing/cancellation tests. No identical-session repetition is needed to establish those unchanged behaviors.

Build evidence: Current Debug and Release builds succeeded, strict Swift formatting passed, and Xcode build log/navigator reported zero issues. The staged Release passed deep/strict ad-hoc signing and Info.plist validation; all 11 Mach-O dependencies had no private installed-SDK paths. Normal launch and Codex Run wiring were observed. Final staging retained the prior bundle in build/stage.ajo22b8y/previous.app.

Targeted verification: Shared capture sample boundaries/pause clock, missing/corrupt processed-file recovery, Japanese mid-stream endpointing/advancing timestamps/final flush and invalid-model original preservation passed. Export checks passed after reading latency/tail from allocated engine units. The scanner timeout/cached-failure/forced-rescan fixture passed. These checks do not substitute for remaining actual-device acceptance.

Actual microphone evidence: The first device execution exposed an inherited Swift MainActor assertion in a tap; nonisolated Sendable factories corrected capture and playback callbacks. The second recorded 53 seconds with pause/resume, natural playback completion and a native-panel 24-bit mono/48 kHz WAV export. The repaired mixed run 811ACCF3-D98E-411B-9425-C8B289E8072B saved 3,982,720 frames in both CAFs (82.973333 seconds), completed without warnings, froze the clock during pause and retained 16 Japanese finals before and after resume. All measured intervals had zero-frame branch lag, with no nonfinite/full-scale-exceeding values. UI-control overhead extended the planned timing to approximately 62.48 + 20.49 recorded seconds; never describe this as a 40-second take.

Fourth device execution: The user's renewed response to the proposed repaired 30/5/10 flow authorized one extra execution after the three default attempts. Session 19A36272-8FF0-4E19-AD34-0CC01A625A04 saved 1,751,424 frames (36.488 seconds), completed with no warning, after the user pressed Stop. Three final Japanese segments persisted with ranges 0–5.287687, 5.287687–7.858375 and 7.858375–10.858375 seconds. The recording defaulted to after-recording mode with no effects. A user-interaction guard prevented sending the planned pause action; the user confirmed manually stopping. This established repaired timestamp progression and safe stop/persistence; the subsequent timed execution below supplied the pause-flow evidence.

Actual format exports from session 19A36272 are saved as output/verification/japanese-36-{16,24,32f}.wav and japanese-36-aac{96,192}.m4a. All contain 1,751,424 valid program frames at 48 kHz mono (36.488 seconds). Float WAV is sample-identical to source; I16/I24 errors are at most half an LSB. AAC targets measured 97,845/197,443 bps, with no decoded program-frame loss. All values are finite and within full scale. QuickTime loaded and played all five formats: I16 reached 29 seconds before closing; I24/F32/AAC96/AAC192 reached natural completion at 36 seconds. See output/verification/japanese-36-sample-comparison.json.

Timed microphone evidence: session 371213B8-8086-44BE-8407-D977749CA7A4 saved 1,976,448 frames (41.176 seconds) in after-recording mode without warning. The clock paused at 00:00:30, remained there after five seconds, resumed at 00:00:30 and stopped at 00:00:41. Two Japanese finals remained after stop; speech was observed before the pause in this take. The unchanged capture implementation already has before/after-pause speech evidence in the 82.973333-second take. The latest take and its transcript survived the final Release relaunch. Playback was already demonstrated by the unchanged PlaybackService on the earlier microphone session; standard-player playback of all five real exports also passed. Together with the earlier before/after-pause speech and current timed-flow evidence, this completes I3/V2 without another recording.

Actual plugin evidence: Supercharger AU and DeepFilter VST3 custom editors opened/closed; DeepFilter Mix=50% and plugin states survived Release relaunch. Reorder/bypass operated in the earlier app. The old 19:29 run preserved original audio and Japanese text but exposed an 80 ms processed advance and incomplete output. Capture now arms both branches from a common future sample boundary after engine allocation and preserves native close errors. The repaired short run above establishes normal-stop alignment/finalization.

Repaired long run: 99BEAB6C-4065-4A52-8703-04FB0EBB87E0 recorded 760.088 seconds before an audio-device configuration change safely paused it. The original and 58 Japanese finals were retained, and the interruption warning was visible. Seven measured intervals had zero-frame branch lag; footprint was 1.2 GB early and 1.1 GB late (1.4 GB peak), with no continuing growth. Processed audio was 1,443 frames short because interruption prevented latency drain; processedComplete correctly remained false. Do not claim complete processed output for this take. The user exported and played its 24-bit/48 kHz/mono WAV at the user-selected export location. Independent comparison found exact original frame count/duration, no missing frames, and zero-lag effects-applied output throughout the clip.

Verification budgets: V2 consumed five device executions: three default attempts, the renewed fourth attempt manually stopped at 36.488 seconds, and the subsequently authorized fifth timed attempt at 41.176 seconds. V2 is complete; no further attempt is scheduled. Native DeepFilter and mixed CLI smoke units exhausted 3/3; do not rename or rerun them. Formal ASR and recovery passed at 3/3, pause-clock tests passed at 2/3, export tests passed at 2/3, and scanner process-supervision tests passed at 3/3. Actual-app long live checking used two executions: the old alignment failure and the repaired configuration-interrupted run above. Preserve these counts across resumption; unused attempts are ceilings, not work to perform.

## Outcome, Requirements, and Scope

Build a simple, polished podcast recorder for Apple Silicon Macs running macOS 26 or later. Use Swift and SwiftUI for the application, with narrowly scoped native bridges where required. EasyPod is the working name derived from the repository directory.

The implementation language is confirmed. Prior discussion of Electron and Rust/Tauri does not create a Windows requirement. This plan is written in English; product-facing UI labels remain Japanese.

### Explicit Requirements

1. Present an image-generated UI design and obtain the user's approval before writing application code.
2. Record podcasts through a microphone.
3. Provide configurable audio quality, including bitrate where the format supports it.
4. Transcribe audio during recording using the already installed NeMo-Speech.cpp runtime and `nvidia/nemotron-3.5-asr-streaming-0.6b`. The model aliases supplied by the user are `nemotron-3.5` and `nemotron-asr`.
5. Use recognizable icons for recording transport actions, including stop and pause, without persistent text labels.
6. Export the actual recorded audio to WAV and other supported audio formats.
7. Support VST3 and AU audio-effect plugins.
8. Allow the user to choose effects after recording or during recording. Default to after recording. This timing choice is an explicit user decision.
9. Use local ad-hoc signing without an Apple Developer account.
10. Offer WAV bit depths of 16, 24, and 32 bits. The proposed 32-bit format is IEEE float, explicitly labeled "32 bit float"; the default is 24 bits.
11. Target Mac only and prioritize ease of use, maintainability, and future feature additions.
12. Use Swift + SwiftUI, as explicitly confirmed by the user.

### Supported Design Choices

- Use a Japanese UI and follow the system's light/dark appearance. Generated images show a light-appearance concept.
- Support one microphone input, with a timer, waveform, input-level meter, recording list, and playback.
- Default export settings to WAV, 48 kHz, 24 bits, and mono. Offer AAC/M4A to satisfy compressed-audio bitrate settings.
- Preserve original audio non-destructively. In after-recording mode, apply effects to preview and export. In during-recording mode, retain both original and processed audio.
- Process audio, transcription, and effects locally on this Mac. Reuse the installed model without downloading it again or sending recordings externally.
- Host audio effects in VST3, AUv2, and AUv3 formats when compatible with Apple Silicon. MIDI instruments, multitrack editing, publishing services, speaker diarization, and translation are outside the requested scope.

## Current System Evidence

Investigation date: 2026-10-04, Asia/Tokyo.

- Repository: `<repository-root>`. At initial inspection, it was on `main`, clean, and contained only `.gitattributes`. There was no app, test suite, Package.swift, project-specific AGENTS.md, or existing plan.
- The global instructions and `~/.codex/docs/library-notes.md` and `~/.codex/docs/macos-gotchas.md` have been read. Before coding, reread applicable instructions and the two mandatory reference documents if their contents are no longer available.
- Observed tools: Python 3.13.15; Swift 6.4 targeting arm64-apple-macosx26.0; Homebrew 7.0.7-38-g7cce6ea; Node 26.10.0; npm 12.1.0. Node and Python are not application runtime dependencies.
- NeMo-Speech.cpp 0.2.0 CLI: `~/.local/bin/nemo-speech`, resolving to `~/Library/Application Support/NeMoSpeech/bin/nemo-speech`.
- Installed SDK header: `~/Library/Application Support/NeMoSpeech/include/nemo_speech/asr.h`.
- Installed C ABI library: `~/Library/Application Support/NeMoSpeech/lib/libnemo_speech_asr_c.1.dylib`. Inspection with `otool -L` confirmed dependencies on the ASR runtime, ggml, Metal, CPU, and Accelerate components.
- Installed model: `~/Library/Caches/NeMoSpeech/models/nvidia/nemotron-3.5-asr-streaming-0.6b/1c8deaecc64b91f034d73e08dd8b64625eb3395d/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf`.
- Model metadata: 741,548,352 bytes, `runtime_compatible=true`, no reported errors or warnings, and support including `ja-JP`. These are metadata checks, not measurements of inference speed or accuracy.
- The runtime's doctor command reported ASR and Metal support and an Apple M4 CPU. Use CPU or Metal; do not introduce CUDA paths.
- Existing VST3 candidates: `~/Library/Audio/Plug-Ins/VST3/deepfilter-vst.vst3`, `/Library/Audio/Plug-Ins/VST3/Supercharger.vst3`, and `/Library/Audio/Plug-Ins/VST3/Ozone 12 Equalizer.vst3`.
- Existing AU candidates include `~/Library/Audio/Plug-Ins/Components/TB3003.component` and `/Library/Audio/Plug-Ins/Components/Supercharger.component`. Only their existence has been verified. Inspect architecture, licensing availability, bus layouts, and host compatibility during implementation; a filename alone does not prove usability.
- The user explicitly invoked `~/.codex/skills/preparing-for-coding-swift/SKILL.md`. It requires an Xcode project as the primary app format, Xcode-based release builds on Apple Silicon, MCP-first Xcode work, and relevant repository conventions. Its specific project/tooling instructions take precedence over the Build macOS Apps plugin's general shell-first defaults.
- Xcode MCP tool definitions are exposed in this session, including project builds, launches, targeted tests, build diagnostics, target settings, schemes, and workspace discovery. Their availability against this app cannot be verified until the project exists and is open in Xcode. No Xcode project has been opened or built during planning.

### Source-Backed Integration Facts

- NeMo's supported embedding boundary is a C ABI with opaque handles and matching destruction/close operations. Import the C header into Swift. Drive each ASR stream from one thread; on completion, finish, drain results, and close it. The SDK accepts mono float32 audio at input rates from 8 to 96 kHz. [Native SDK](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/sdk.md)
- The official Nemotron 3.5 model card includes Japanese `ja-JP` among transcription-ready languages. Verify actual recognition in V2. [Model card](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)
- SwiftUI supports integration with AppKit, allowing native platform controls and plugin editor views where needed. [SwiftUI](https://developer.apple.com/swiftui/)
- AU hosting supports registered-component discovery, asynchronous instantiation, custom editor views, and parameter access. macOS hosts can use third-party AUv2 and AUv3 effects. Retain default out-of-process behavior for AUv3. [Apple AU host sample](https://developer.apple.com/documentation/audiotoolbox/incorporating-audio-effects-and-instruments)
- Use the official Steinberg SDK for VST3 hosting. The current 3.8.x SDK is MIT-licensed and supports macOS and Apple Silicon. Pin the acquired tag or commit and preserve required license notices. [Official VST3 SDK](https://github.com/steinbergmedia/vst3sdk)
- VST3 processors expose bus configuration, processing setup, state, latency, and tail information. Select the correct realtime or offline processing mode. [IAudioProcessor](https://steinbergmedia.github.io/vst3_doc/vstinterfaces/classSteinberg_1_1Vst_1_1IAudioProcessor.html)
- Implement the custom AU adapter's render work in `internalRenderBlock`. Do not lock, allocate memory, or perform file operations on the render path. [Apple render block](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/renderblock)
- Use `AVEncoderBitRateKey` for compressed-audio target bitrate. The signing identity `-` creates an ad-hoc signature. [Encoder bitrate](https://developer.apple.com/documentation/avfaudio/avencoderbitratekey), [Ad-hoc signature](https://developer.apple.com/documentation/security/seccodesignatureflags/adhoc)

## UI Approval Candidate

The current candidate is [easypod-ui-v5.png](docs/design/easypod-ui-v5.png). It adapts the [user-provided reference](docs/design/user-reference-v4.png): v4 introduced Japanese labels, effects, and WAV settings; v5 displays the 16/24/32-bit menu. Use v5 as the pending implementation reference. Retain earlier concepts for reference only. Actual generation prompts are saved in [imagegen-prompts.md](docs/design/imagegen-prompts.md). These are generated mockups, not screenshots of an implemented app.

- Left pane: flat recording rows and a new-recording action.
- Center pane: microphone selector, input meter, and monitor controls at the top; a compact effect strip below; a broad coral-red waveform; icon transport controls with a compact timer to their right.
- Right pane: Japanese transcription, distinguishing interim and final content.
- Toolbar: export and settings icons. Disable export during active recording.
- Effect strip: Japanese choices "録音後" and "録音中", with after recording selected by default. Added effects show name, AU/VST3 format, bypass, and editor controls in flat rows. Support ordering and internal scrolling for longer chains.
- Transport symbols: red circle before recording; a white square on red during recording for stop; two vertical bars for pause; a triangle for resume/play. Use SF Symbols, tooltips, and VoiceOver labels rather than character glyphs.
- Export sheet: format, destination, quality, source audio, and whether to include effects. Connect it to actual file export.
- Full-width bottom section: collapsible "録音・書き出し設定", exposing bit depth, sample rate, WAV/M4A, and mono/stereo. WAV offers 16-bit integer, 24-bit integer, and 32-bit float. When M4A is selected, replace the quality field with AAC target bitrate. Share one settings model and disable unsafe changes during recording.
- Separate Settings window: detailed preferences such as model location. Keep primary quality controls directly accessible in the main window.
- Target window size: approximately 1280 × 900, minimum 1100 × 760. Adapt panes and scrolling without hiding primary actions. Do not copy image pixel dimensions as fixed layout constants.
- 2026-10-04 UI refinement: the user requested tighter width/spacing and lightly rounded rectangular controls like user-reference-v4.png. Use sidebar 236 px and transcript 328 px at 1280 px, scaling to 220/300 at 1100 px; cap central content width at 728 px. Group waveform/transport with a fixed 24 px gap. Quality and effect controls use 6 px outer corners and 4 px selected corners, 32 px control height, equal footer widths; retain reference-style circular transport and the native monitor switch. Use adaptive pale gray backgrounds with slightly darker sidebar/footer surfaces, white rectangular controls, and a softer coral accent, as subsequently requested by the user.

## Architecture and Design

### Confirmed Implementation

Use Swift and SwiftUI for the Mac-only app, with `EasyPod.xcodeproj` as the primary app project and a shared `EasyPod` scheme. Xcode owns the app target, resources, Info.plist, native-library embedding, signing, and any required entitlements. Stage a successfully built app at `dist/EasyPod.app`; do not manually reconstruct a SwiftPM executable into the release app. Use Package.swift only if a dependency library needs it, not as the app manifest. Target Swift 6.3 or later and macOS 26 or later using the installed Swift 6.4 toolchain; report dependencies that require a downgrade. Use `WindowGroup` and a dedicated `Settings` scene. Limit AppKit to plugin NSView/NSViewController integration, native file panels, and necessary window behavior.

Use Apple audio frameworks for capture, playback, AU effects, and export. Link the installed NeMo C ABI directly. Host VST3 through a small C++/Objective-C++ bridge using the official SDK, wrapped as an AUAudioUnit adapter for AVAudioEngine. Swift owns the UI, settings, recording management, persistence, export coordination, and ASR control. VST3's native boundary does not require turning the entire app into a C++ application.

Maintainability and extension points are concrete service boundaries: capture, transcription, effect processing, export, and persistence. Keep audio processing and native-handle lifetimes out of views. New export formats or supported ASR models should not require rebuilding the entire UI or altering existing original recordings. Avoid generic plugin frameworks and unnecessary abstraction layers.

All locations below are proposed and have not been created.

| Area | Proposed location | Responsibility |
| --- | --- | --- |
| App entry | `Sources/EasyPod/App/` | Launch, WindowGroup, Settings, commands, and orderly termination |
| Views | `Sources/EasyPod/Views/` | Three-pane layout, transport, effects, export sheet, and settings |
| Models | `Sources/EasyPod/Models/` | Session, RecordingSettings, TranscriptSegment, PluginDescriptor, EffectSlot, EffectTiming |
| Stores | `Sources/EasyPod/Stores/` | SessionStore and preferences; observable UI state updated on MainActor |
| Recording | `Sources/EasyPod/Services/AudioCaptureService.swift` | Microphone, AVAudioEngine, copied audio blocks, and level values |
| Effect processing | `Sources/EasyPod/Services/EffectChainService.swift` | AU/VST3 nodes, ordering, state, and separate live/preview/export instances |
| Plugin catalog | `Sources/EasyPod/Services/PluginCatalogService.swift` | Discovery, compatibility, scan results, and selection |
| ASR | `Sources/EasyPod/Services/TranscriptionService.swift` | Model loading, serial stream processing, interim/final results, shutdown |
| Files and export | `Sources/EasyPod/Services/` | SessionFileService, PlaybackService, AudioExportService |
| Native bridge | `Native/AudioPluginHost/` | C++ VST3 host, Objective-C++ AU adapter, C/ObjC API, scanner helper |
| C imports | `Sources/CNeMoASR/`, `Sources/CAudioPluginHost/` | Verified headers, module maps, native linking boundaries |
| Build and run | `script/build_and_run.sh` | User-facing Codex Run entry point and permitted CLI fallback for Xcode build, staging, launch, and verification |
| Build metadata | `EasyPod.xcodeproj/`, `Resources/`, `.codex/environments/environment.toml` | Shared scheme, app target, Info.plist, resources, native embedding, signing, Codex Run action |
| Repository conventions | `.gitignore`, `README.md`, `CHANGELOG.md`, `NOTES.md`, `AGENTS.md` | Relevant missing files for local build instructions, release changes, chronological decisions, and repository-specific coding rules |

Build only the required native SDK portions. Build the bridge with CMake and link it from Swift. Integrate bridge preparation and native embedding into Xcode target dependencies/build phases so MCP builds and CLI builds both produce a complete app. Pin third-party revisions and retain license notices. Copy required NeMo/ggml dylibs and Metal runtime resources into the app before final app signing, then verify rpaths and resolved locations. Do not modify or re-sign the user's installed SDK or plugins.

### Development and Repository Preparation

After UI approval, create and open EasyPod.xcodeproj in Xcode before invoking project-scoped MCP operations. Keep source editing in the user's preferred VS Code/file workflow; opening Xcode provides the workspace used by MCP. Prefer Xcode MCP for project structure, schemes, target settings, build/run/test operations, and diagnostics. After a Swift code edit, build through MCP and inspect its diagnostics before reporting completion.

Use CLI Xcode operations only when no target project is open, the required MCP capability is unavailable, or the task concerns a pure dependency package. Release builds must still build the app through its Xcode project. Do not replace this with a SwiftPM-only app build. Discover the actual tool arguments and open workspace identifier before calling MCP; do not invent them.

Keep one project-local script/build_and_run.sh and wire the Codex Run action to it after the script exists, using the Build macOS Apps bootstrap's action schema. The user-facing script builds the Xcode scheme and launches its complete app bundle. It is also the fallback when CLI operation is permitted, not the default agent workflow when MCP is available. Support the documented debug/log/telemetry/verify flags as applicable to macOS. Never terminate an active recording automatically to relaunch; obtain a safe stopping point first.

During I1, add only relevant missing repository files. Include .DS_Store and Thumbs.db in .gitignore, as well as actual build output paths. Use .gitkeep only for otherwise-empty directories that must be tracked. Keep NOTES.md as a chronological record of issues, decisions, and solutions, and CHANGELOG.md for user-visible implemented changes. Put repository-specific conventions and recurrence-prevention rules in AGENTS.md: UTF-8, English comments explaining behavior and rationale, the mandatory reference documents, Xcode/MCP workflow, ad-hoc signing, realtime audio constraints, native ownership rules, and prohibited destructive changes to installed models/plugins. PLANS.md remains the only checkbox tracker. These files are planned for the approved scaffold and are not created during this design-only stage.

### Audio Flow and Effect Timing

| Mode | Recording | Playback and export |
| --- | --- | --- |
| After recording — default | Microphone → original storage; ASR reads original audio | Original → current effect chain → preview/export; bypass permits original playback |
| During recording — optional | Microphone → original storage and ASR; a separate branch → effects → processed storage | Play/export processed audio or choose the original; do not apply the same effects twice |

In after-recording mode, chain edits during capture configure later preview/export and do not affect stored original audio. Select during-recording mode before capture. Disable timing, input, and chain-structure changes during active capture. Allow supported safe parameter changes and bypass. Reconfigure the chain only after stopping or while paused.

ASR always consumes a mono copy of original audio. Effect edits must not alter or duplicate transcription. Recording must not wait for model loading or delayed inference. If the ASR queue reaches its bound, catch up from stored original audio and display a lag state. Do not silently discard audio and present it as transcribed.

Copy non-interleaved float32 capture blocks into preallocated buffers. Use separate serial workers for disk storage and ASR. Keep inference, UI updates, synchronous waits, and file operations off realtime render/tap paths. Run effects on the engine render path, with VST3 buffers, buses, and parameter-event storage allocated beforehand.

The default internal audio format is 48 kHz float32 with the selected one or two channels. Convert device formats when necessary and convert ASR input to mono float32. Record plugin latency and align original and processed tracks in live mode. Pause for reconfiguration when latency or graph changes cannot preserve continuous capture.

### Storage and State

Store sessions under `~/Library/Application Support/EasyPod/Sessions/<UUID>/`, including `session.json`, `source.caf`, optional `processed.caf`, `transcript.json`, and plugin state blobs. Preserve original audio as float32 PCM in CAF; convert to WAV or AAC during export. Populate the recording list from stored sessions. Do not report completion if audio or metadata updates failed.

Recording states: idle → preparing → recording ↔ paused → finalizing → completed, with recoverable failure states. Base timers and transcript offsets on audio sample counts, excluding paused wall-clock time. Track ASR independently as loading, running, catchingUp, finishing, completed, or failed.

On pause, flush audio storage and finalize the current ASR utterance. If needed, create a new stream on resume with an accumulated sample-time offset. On stop, drain final audio, effect tails, and final ASR results before marking their corresponding outputs complete. After unexpected termination, reconcile CAF files with manifests and offer incomplete sessions for recovery.

### Plugin Hosting

- Discover AU effects with AVAudioUnitComponentManager and instantiate asynchronously. Retain default AUv3 out-of-process hosting and normal OS behavior for AUv2.
- Scan VST3 directories `/Library/Audio/Plug-Ins/VST3` and `~/Library/Audio/Plug-Ins/VST3`. Check arm64 compatibility and obtain module/class information in a separate scanner helper. Record timeout/crash results without endless automatic retries.
- Manage IComponent, IAudioProcessor, and IEditController using official SDK hosting helpers. Handle component/controller communication, processing setup, buses, activation, shutdown, and unload. Do not expose C++ ownership or exceptions to Swift.
- Treat the native VST3 AUAudioUnit adapter as an AVAudioEngine node. Allow AU and VST3 in one chain in any supported order. Negotiate mono/stereo layouts and conversions; report unsupported buses before insertion.
- Provide add, remove, reorder, bypass, and editor actions. Embed VST3 IPlugView and AU view controllers in dedicated AppKit windows. Offer a generic exposed-parameter editor when a plugin has no custom GUI.
- Persist AU fullState and VST3 component/controller state per session. Store identifier, format, version, and state so identically named plugins in different formats are not confused.
- Use independent instances for preview and export. Snapshot chain configuration at export start; later UI edits must not affect an in-progress export.
- Handle latency compensation, reset, and tails during offline processing. For effects that cannot render offline, support realtime export with progress and cancellation. Limit infinite tails using an export setting: default 10 seconds, adjustable from 0 to 30 seconds. Do not truncate silently.
- Use existing plugin authorization and licensing. Do not purchase or install plugins automatically or change OS security settings.

### Export and Audio Quality

Export completed sessions through a native save panel.

| Format | Settings | Required output |
| --- | --- | --- |
| WAV | 16/24-bit integer PCM or 32-bit IEEE float; 44.1/48 kHz; mono/stereo | A valid .wav with matching header and sample representation; default 24 bit / 48 kHz / mono |
| AAC/M4A | 44.1/48 kHz; mono/stereo; encoder-supported targets among 96/128/192/256 kbps | AAC in .m4a using AVEncoderBitRateKey; measured bitrate may vary with encoder behavior |

WAV quality is determined by sample rate, bit depth, and channel count; do not present an arbitrary compressed-audio kbps choice for WAV. Hide or disable AAC bitrate settings when WAV is selected. Apply settings consistently to subsequent recording/export and prevent recording-format changes during capture. Do not confuse 32-bit float with 32-bit integer PCM.

Use AVAudioConverter/AVAudioFile or suitable Apple APIs for WAV, and AVAssetReader/AVAssetWriter or AudioConverter for AAC. Verify the exact APIs in the installed SDK. Do not require ffmpeg. Export complete audio and the configured tail according to the chosen source and effect snapshot; never substitute transcript or UI data for audio.

Write a temporary file in the destination directory and finalize it only after success. Preserve original audio on cancellation, insufficient space, or encoding failure. Follow the save panel's explicit replacement choice for existing output. Detect the conventional RIFF size limit before exporting an oversized WAV and offer split WAV output rather than producing a corrupt file.

## Implementation Sequence

Begin only after P4 approval. P5 is complete: Swift + SwiftUI is confirmed. The steps below order construction of the complete requested behavior; they do not defer required features to an unspecified later release.

### I1 — Native App and Dependency Foundation

- **Outcome/location:** EasyPod.xcodeproj, a shared EasyPod scheme, Native/AudioPluginHost, native import modules, Resources, relevant missing repository convention files, script/build_and_run.sh, .codex/environments/environment.toml, and dist/EasyPod.app.
- **Action:** Configure an Xcode macOS application target named EasyPod for arm64/macOS 26 and Swift 6.3+. Link the installed NeMo C ABI. Pin an MIT-licensed VST3 SDK revision and integrate the CMake bridge and native embedding into the project build. Bundle required runtime libraries/resources and repair rpaths and signatures in copied files. Set NSMicrophoneUsageDescription, the stable bundle identifier `local.EasyPod`, and a Settings scene. Configure local ad-hoc signing without a development team or provisioning account; add only entitlements actually required by the chosen configuration. Add relevant missing repository conventions. Create the Codex Run script/configuration using the Xcode-project form of the bootstrap contract. Open the project in Xcode, discover its scheme/destination, and use MCP for the app build and diagnostics.
- **Dependencies:** P4 and P5.
- **Acceptance evidence:** Xcode MCP BuildProject succeeds for the EasyPod scheme without unresolved NeMo/VST3 symbols; inspect GetBuildLog and navigator diagnostics. Xcode MCP RunProject launches a normal main window with Dock presence. Inspect the built executable and bundled dylibs with `otool -L`; runtime dependencies must not point to the user's private installed SDK directory. Verify Info.plist, copied resources, and local ad-hoc signing. Validate the Run action's target script and wiring; execute its CLI fallback only when permitted by the preparation skill's conditions.
- **Risk/recovery:** Diagnose missing bundled dependencies without altering installed SDK files. Do not automatically terminate an app that is recording to replace its bundle. Follow environment restrictions for protected paths and GUI launch.

### I2 — UI, Settings, and Session Persistence

- **Outcome/location:** App, Views, Models, and Stores.
- **Action:** Implement approved v5: three panes, coral-red waveform, horizontal icon transport and timer, and full-width bottom quality controls. Use a separate detailed Settings window. Default to after-recording effects and 24-bit WAV. Persist preferences, sessions, and effect slots. Provide SF Symbols, tooltips, VoiceOver labels, and appropriate menu/keyboard actions.
- **Dependencies:** I1.
- **Acceptance evidence:** Light/dark layouts work; new sessions default to after-recording mode. Preferences survive relaunch. Disabled actions are clear during recording. Mock UI data does not appear as real stored recordings.

### I3 — Recording and Original Playback

- **Outcome/location:** AudioCaptureService, SessionFileService, PlaybackService, and RecordingStore.
- **Action:** Connect microphone discovery/selection, permission handling, original-audio storage, waveform/levels/timer, and record/pause/resume/stop. Default live speaker monitoring to off. Enable playback after completion.
- **Dependencies:** I2.
- **Acceptance evidence (satisfied by consolidated evidence above):** A roughly 30-second recording, five-second pause, and ten-second resumed recording establish that paused wall-clock time is excluded. Retained speech before/after pause, session persistence, and playback may be established by separate recordings using the same unchanged implementation. Exact wall-clock timing or repeating all observations in one take is not required.
- **Risk/recovery:** Detect missing/disconnected microphones and write failures, safely pause/finalize, and retain audio already saved.

### I4 — Nemotron Live Transcription

- **Outcome/location:** TranscriptionService, TranscriptStore, and CNeMoASR.
- **Action:** Open the installed GGUF by absolute local path and select Japanese language recognition. Prefer the available Metal backend using GPU index 0; allow CPU fallback if initialization fails. Do not download the model for each recording. Implement interim replacement, final-result append, sample-based timestamps, and pause/resume/stop flushing.
- **Dependencies:** I3.
- **Acceptance evidence:** Japanese text grows during V2 recording and retains the final utterance after stopping. It works without network access. Recording/export remain usable when ASR is disabled or its model location is invalid. Display and recover from recognition lag using stored audio.
- **Risk/recovery:** Respect handle/string lifetimes and close every stream. ASR failure must not be treated as recording failure.

### I5 — AU/VST3 Host and Effect Rack

- **Outcome/location:** PluginCatalogService, EffectChainService, native bridge, editor windows, and EffectRackView.
- **Action:** Implement AU discovery, isolated VST3 scanning, bus negotiation, mixed chains, add/remove/order/bypass, custom/generic editors, and saved state. Complete the plugin lifecycle according to the pinned official SDK's hosting examples.
- **Dependencies:** I1, I2, and I3.
- **Acceptance evidence:** Load one compatible installed AU and one VST3; open their custom or generic editors. Change parameters, save, and relaunch to verify restoration. Display reasons for incompatible or failed candidates.
- **Risk/recovery:** Limit scanner work to 20 seconds per candidate. Do not repeatedly rescan crashing candidates. In-process AUv2/VST3 crashes can terminate the host; preserve original audio with regular flushes and next-launch recovery. Do not claim complete crash isolation.

### I6 — Effects After and During Recording

- **Outcome/location:** EffectChainService, AudioCaptureService, PlaybackService, and processed session audio.
- **Action:** Preview original audio through the current chain in after-recording mode. Save separate original/processed branches in during-recording mode. Preserve chain ordering/parameters, compensate live latency, support bypass, and drain tails. Choose timing before capture and lock it during active recording.
- **Dependencies:** I3 and I5.
- **Acceptance evidence:** Default-mode original audio remains unprocessed; later chain edits change preview. In live mode, an obvious gain/EQ setting changes processed audio while the original stays intact. AU/VST3 can share a chain and change order; bypass and durations are correct.
- **Risk/recovery:** Continue original-audio storage during plugin errors/overload and report processed-output failure. Do not claim incomplete processed audio is complete. Reconfigure only at safe stopping points.

### I7 — WAV/AAC Export

- **Outcome/location:** ExportSheet, AudioExportService, and SettingsView.
- **Action:** Apply format, quality, effect inclusion, source, and destination to real files. Use a chain snapshot after recording; do not reapply the same chain to saved live processed audio. Implement 16/24-bit integer WAV, 32-bit IEEE float WAV, and AAC target bitrate. Convert internal float audio appropriately and handle integer range/clipping. Provide progress, cancellation, explicit replacement, and oversized-WAV splitting.
- **Dependencies:** I3 and I6.
- **Acceptance evidence:** Export one approximately 40-second session to all three WAV depths and AAC at two supported target bitrates. Play each in a standard player. Inspect representation, sample rate, channels, and duration with `/usr/bin/afinfo <file>` or an already installed ffprobe resolved by absolute path. Verify differences between original and processed exports and absence of double-applied live effects.
- **Risk/recovery:** Do not publish partial output as a successful file. Preserve the session and prior exports on cancellation or failure.

### I8 — Recovery and Integration Failures

- **Outcome/location:** Service error handling, SessionStore recovery, and only necessary targeted tests.
- **Action:** Handle microphone refusal/disconnection, missing models/plugins, scanner timeout, writes, ASR lag, and incomplete sessions. Provide orderly finalization on app termination and next-launch recovery after native crashes.
- **Dependencies:** I4 and I7.
- **Acceptance evidence:** Failures preserve existing recordings and relaunch distinguishes complete sessions from recovery candidates. Add tests only where needed to prove sample-count/pause offsets, plugin-state restoration, export-source selection/double-processing prevention, and manifest consistency under failure.

## Final Verification

The application and required service boundaries are implemented. Completed evidence and outstanding requirements are recorded in Progress Status above. The table below is the original acceptance reference, not an automatic execution queue. Current and Next govern resumption. A successful build or synthetic test alone does not complete device checks, and an unchecked audit does not invalidate already observed behavior.

### Bounded Resumption Rules

- No further testing is scheduled for the delivered build. A general continuation request must not restart completed V1/V2 flows or the entire V3/V4 matrix. Select only the concrete requested issue or expressly requested pending audit.
- Before a new verification action, identify the single unresolved claim, existing evidence, pass condition, and remaining attempt allowance. Reuse recordings and exports where they answer that claim; combine evidence across sessions when the relevant implementation is unchanged.
- A code change warrants a build and the directly affected check, not every downstream device flow. Documentation-only edits require a diff check, not a build or recording.
- Each existing unit allows at most one initial execution and two repair-driven reruns across all handoffs, subject to the consumed counts above. A rerun requires a concrete repair or a diagnosed test failure. At the limit, report the unresolved result and stop that unit. Do not subdivide or rename it to obtain more attempts; an extension requires a specific user request.
- Do not add another long recording to replace the configuration-interrupted run merely to obtain a clean finish. Its duration, alignment and memory observations remain valid; normal finalization has separate short-run evidence. If a specific long-run defect is reported, define a targeted check for it.
- Stop when the selected pass condition is observed or its attempt limit is reached. Record failed or unobserved claims accurately; do not add speculative plugin combinations, sample-rate matrices, stress tests, or a new E2E framework to this handoff.

For a specifically resumed check, allow approximately 15 minutes for an initial native dependency build, 5 minutes for an ordinary build, and 5 minutes for a short device flow. These are diagnostic time allowances, not reasons to rerun a completed command.

| Unit | Prerequisites and command/flow | Pass conditions |
| --- | --- | --- |
| V1 | Open EasyPod.xcodeproj; discover/select the shared EasyPod scheme and this Mac; `swift format lint --recursive Sources` with Tests included only if present; MCP BuildProject, GetBuildLog, and navigator issues; necessary RunSomeTests for an actual targeted test plan; RunProject; inspect Codex Run wiring | Native dependencies and the app build through Xcode, diagnostics are addressed, the signed app launches, and its main window appears |
| V1 signing | `codesign --verify --deep --strict --verbose=2 dist/EasyPod.app` and `codesign -dvvv dist/EasyPod.app` | Verification succeeds with Signature=adhoc and consistent nested-code signatures; no Developer ID or provisioning dependency |
| V2 | Microphone consent and installed GGUF; Japanese speech using I3's pause flow; stop, playback, all three WAV depths, AAC export, relaunch | All recorded speech and final transcription persist; pause offsets and audio content are correct; WAV integer/float representation and AAC quality changes match settings |
| V3 | One compatible AU and VST3; test individually, then mixed; after/live timing, order, bypass, editors/state, offline export; one 10-minute live recording | Audible effects, preserved original, no double processing, aligned branches, no dropouts, no continuing memory growth, and usable failure diagnostics |
| V3 recovery | Disposable sessions; invalid model path, scanner timeout/failure fixture, export cancellation/write failure, incomplete manifest; do not delete real plugins/models | Original audio survives, the UI explains failures, and recovery works on relaunch |
| V4 | 1280 × 900 and 1100 × 760; light/dark appearance, keyboard and VoiceOver; capture the app in the approved image's state | Three panes, red waveform, horizontal icon transport, bottom settings, and the 16/24/32-bit menu match the approved design; no clipped text or hidden actions; accessible export; after-recording mode and 24-bit default |

For a permitted CLI fallback, the proposed Debug build is `xcodebuild -project EasyPod.xcodeproj -scheme EasyPod -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build`, using project-configured ad-hoc signing. Release packaging uses the same Xcode project with Release configuration. The corresponding products are under build/DerivedData/Build/Products/Debug or Release before staging at dist/EasyPod.app. Do not use `swift build` or `swift test` as acceptance for the app target. Pure dependency-package checks remain permissible when relevant.

When device testing requires microphone consent or user speech, request only the needed interaction at that stage. Do not pass a feature whose model or compatible plugin cannot actually run. A displayed UI screenshot is not evidence that audio processing works.

## Permission Boundaries and Remaining Uncertainty

- Implementation is authorized by the 2026-10-04 request to execute this plan and start building. Use the latest v5 UI reference. Swift + SwiftUI is already approved and must not be asked again.
- UI approval covers the proposed new-app arrangement before creating its scaffold. Do not modify the installed SDK, plugins, or unrelated repositories.
- If the environment requires approval for protected configuration paths or GUI launch, explain the concrete operation and follow that restriction.
- Sign locally with `codesign --sign -`. Sign copied nested code from the inside out, then the app. Do not confuse this with Developer ID, Apple's Ad Hoc provisioning distribution, or notarization. Do not disable Gatekeeper.
- Japanese ASR, the tested Supercharger AU/DeepFilter VST3 combination, and measured capture alignment have the evidence recorded above. Compatibility and performance on other devices/plugins are not established and do not require an open-ended test matrix. Preserve implemented WAV, VST3, AU, and optional live processing; keep the remaining acceptance limits explicit.
- Allow model-location selection in Settings. Do not depend on a GUI process's PATH. Normalize pasted path quoting and escaped spaces according to the mandatory macOS reference.
- The 32-bit WAV choice currently means IEEE float as shown in v5. Keep that representation explicit in the approved UI and verify it in exported files.
- Application code, the Xcode project, repository conventions and build entry point are present. Keep progress in this plan; do not introduce a second checklist.
