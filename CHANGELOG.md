# Changelog

## DATE UNKNOWN

### Fixed

- Prevented delayed effect preparation from replacing another recording's chain, refreshed VST3 bulk preset values before saving, and preserved effect tails when stopping a paused recording.
- Cleared stale transcript presentation for recordings with transcription disabled and made export cancellation cover effect preparation.
- Kept resampler padding out of recorded audio and rechecked fresh audio clocks after delayed UI scheduling before reporting startup failure.
- Fixed Product > Archive linking by restricting the app and test targets to Apple Silicon, matching the bundled native libraries.
- Corrected Swift actor isolation in microphone taps and playback completion callbacks.
- Corrected live capture timing to use the actual engine latency and a shared sample boundary; preserved finalization errors and missing processed-audio diagnostics.
- Corrected export latency and tail measurements after audio-engine allocation, including realtime export fallback.
- Fixed microphone selection and recording-start errors for Apple earphone microphones used as the macOS default input, including switching to and from US-2x2HR. Kept system audio defaults and physical sample rates unchanged.
- Separated microphone capture from Bluetooth playback using input-only AUHAL, preserving native microphone rates, live effects, and optional monitoring without requiring a combined input/output route.

### Added

- Added saved Auto/Japanese/English language selection in transcription settings for both live recognition and offline refinement; retained Japanese as the default.
- Added the selected flat purple recording/waveform app icon.
- Built the Japanese macOS recorder with local Nemotron transcription, original CAF storage, AU/VST3 effects, and WAV/AAC export.
- Added recognized start/end time ranges and silence-based utterance finalization to live transcription.
- Added playback position/duration, an output meter, waveform progress, scrubbing, pause/resume, and 15-second backward/forward controls.
- Added persisted recording folders, folder assignment, reversible app-local Trash, and restoration compatible with existing session directories.
- Added deletion confirmation and multiple-selection Trash, preserving failed items when only part of a batch moved successfully.
- Added stopped-recording offline transcript refinement with the configured local model, progress/cancellation, and original-transcript restoration.

### Changed

- Removed machine-specific home paths from the plugin smoke fixture and development documents; excluded personal editor settings, credentials, signing material, recordings and downloaded models from Git while retaining shared Xcode configuration and test audio.
- Coalesced recording checkpoints on a serial persistence owner, bounded transcript update delivery, cached/cancelled waveform scans, reused worker audio buffers, and removed quadratic VST3 parameter transfer.
- Persisted microphone selection by CoreAudio UID and validated the verified NeMo 0.2.0 version/header during native preparation.
- Set Music as the app category and version 1.0.0/build 1 through editable Xcode target settings; skipped unused App Intents metadata extraction to clear archive warnings.
- Refined the three-pane layout with pale gray surfaces, compact spacing, and lightly rounded rectangular settings controls.
- Clarified plugin-add accessibility labels with effect name and AU/VST3 format.
- Updated icon controls, pane toolbar alignment and spacing, centered/enlarged seek actions, full-frame control hit areas, and collapsible recording/export settings.
- Changed the recording waveform to fixed-width recent bars flowing from right to left, with motion frozen during pause.
- Made live recognition catch-up and finalization status visible while queued audio was still being processed.

Acceptance verification and remaining device checks are tracked in PLANS.md.
