# Changelog

## Unreleased

- Built the Japanese macOS recorder with local Nemotron transcription, original CAF storage, AU/VST3 effects, and WAV/AAC export.
- Refined the three-pane layout with pale gray surfaces, compact spacing, and lightly rounded rectangular settings controls.
- Corrected Swift actor isolation in microphone taps and playback completion callbacks.
- Added recognized start/end time ranges and silence-based utterance finalization to live transcription.
- Corrected live capture timing to use the actual engine latency and a shared sample boundary; preserved finalization errors and missing processed-audio diagnostics.
- Corrected export latency and tail measurements after audio-engine allocation, including realtime export fallback.
- Clarified plugin-add accessibility labels with effect name and AU/VST3 format.

Acceptance verification and remaining device checks are tracked in PLANS.md.
