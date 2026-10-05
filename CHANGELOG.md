# Changelog

## Unreleased

- Built the Japanese macOS recorder with local Nemotron transcription, original CAF storage, AU/VST3 effects, and WAV/AAC export.
- Refined the three-pane layout with pale gray surfaces, compact spacing, and lightly rounded rectangular settings controls.
- Corrected Swift actor isolation in microphone taps and playback completion callbacks.
- Added recognized start/end time ranges and silence-based utterance finalization to live transcription.
- Corrected live capture timing to use the actual engine latency and a shared sample boundary; preserved finalization errors and missing processed-audio diagnostics.
- Corrected export latency and tail measurements after audio-engine allocation, including realtime export fallback.
- Clarified plugin-add accessibility labels with effect name and AU/VST3 format.
- Added playback position/duration, an output meter, waveform progress, scrubbing, pause/resume, and 15-second backward/forward controls.
- Added persisted recording folders, folder assignment, reversible app-local Trash, and restoration compatible with existing session directories.
- Added deletion confirmation and multiple-selection Trash, preserving failed items when only part of a batch moved successfully.
- Added stopped-recording offline transcript refinement with the configured local model, progress/cancellation, and original-transcript restoration.
- Updated icon controls, pane toolbar alignment and spacing, centered/enlarged seek actions, full-frame control hit areas, and collapsible recording/export settings.
- Changed the recording waveform to fixed-width recent bars flowing from right to left, with motion frozen during pause.
- Made live recognition catch-up and finalization status visible while queued audio was still being processed.
- Reworked selected-microphone routing and tap-clock normalization, and prepared bounded route-readiness and failure-cleanup repairs. The latest microphone repair has not yet been built or verified on the reported devices.

Acceptance verification and remaining device checks are tracked in PLANS.md.
