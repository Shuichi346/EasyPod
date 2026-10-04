# EasyPod

A local podcast recorder for Apple Silicon Macs running macOS 26 or later. The interface is Japanese. EasyPod keeps original audio in float32 CAF, supports AU/VST3 effect chains, and exports WAV or AAC/M4A. Transcription uses the installed Nemotron 3.5 model through the NeMo-Speech.cpp C ABI.

Open `EasyPod.xcodeproj` and run the shared **EasyPod** scheme, or use the Codex **Run** action. Its entry point is `./script/build_and_run.sh`. The script refuses to replace an active recording, builds the Xcode app, verifies its ad-hoc signature, and stages it at `dist/EasyPod.app`. Use `EASYPOD_CONFIGURATION=Release ./script/build_and_run.sh --build` to stage a Release build without launching it.

The project requires Xcode 27, Swift 6.4, XcodeGen 2.46, CMake, and the existing NeMoSpeech installation under `~/Library/Application Support/NeMoSpeech`. `project.yml` is the reproducible XcodeGen specification. The native build pins the official MIT-licensed VST3 SDK; installed plugins and models are left intact. Runtime libraries and notices are copied into the app and signed locally. No Apple Developer account is required.

Select a microphone, name the recording, and press the red button. Use Space to pause/resume, ⌘R to start/stop, ⌘P to play/stop, and ⌘E to export. Effects default to processing after recording. During-recording mode retains separate original and processed audio. The Settings window provides the local model path and transcription preference.

Sessions are stored under `~/Library/Application Support/EasyPod/Sessions`. Interrupted sessions retain their original audio and appear with a recovery action. Export writes temporary output before committing a finished file.

Current implementation and verification status is recorded in [PLANS.md](PLANS.md). Capture/export/recovery, Japanese endpointing and scanner supervision tests pass. Actual Japanese live speech has advancing time ranges, and repaired short mixed recordings have aligned source/processed audio. The exact timed device flow, full real-format export checks, after-recording preview and final accessibility checks remain pending. This repository does not claim they pass solely from a successful build.
