<table>
  <thead>
    <tr>
      <th style="text-align:center"><a href="README_ja.md">日本語</a></th>
      <th style="text-align:center"><a href="README.md">English</a></th>
    </tr>
  </thead>
</table>

# EasyPod

EasyPod is a local podcast recorder for creators using Apple Silicon Macs running macOS 26 or later. Its Japanese interface brings recording, playback, audio effects, and transcription into one app. Original audio is kept in float32 CAF, and finished recordings can be exported as WAV or AAC/M4A.

Transcription runs on this Mac using a local Nemotron 3.5 GGUF model through the NeMo-Speech.cpp C ABI. Audio is not sent to an external transcription service.

<img src="githubreadme/easypod-recording.png" alt="EasyPod recording with a live waveform and timestamped Japanese transcription" width="480">

*Recording with local transcription in the Japanese interface.*

## Features

- Select a microphone, record with pause/resume, and optionally monitor through headphones.
- Play saved recordings with a waveform playhead, seeking, an output meter, and 15-second skip controls.
- Add AUv2 and VST3 effects, open their editors, reorder or bypass them, and save their settings.
- Apply effects after recording, or retain separate original and processed audio during recording.
- View timestamped live transcription, copy text, and refine a stopped recording offline while retaining the earlier transcript.
- Organize recordings in folders, move one or multiple recordings to reversible Trash, and restore them.
- Recover interrupted sessions from their saved original audio.

Some effect-processing acceptance checks remain open; see [Verification status](#verification-status).

## Requirements

- **Mac:** Apple Silicon (arm64), macOS 26 or later.
- **Build tools:** Xcode 27 with Swift 6.4, Git, and CMake. The build scripts use Homebrew tools under `/opt/homebrew/bin`.
- **ASR runtime:** a compatible NeMo-Speech.cpp installation, including its C ABI library, runtime dependencies, and license notices. The default location is `~/Library/Application Support/NeMoSpeech`.
- **Transcription model:** a local Nemotron 3.5 ASR Streaming 0.6B GGUF file. The model is not bundled or downloaded by EasyPod.
- **Optional effects:** compatible arm64 AUv2 or VST3 plugins installed on the Mac.

XcodeGen 2.46 or later is needed only to regenerate the project from [project.yml](project.yml). The checked-in [EasyPod.xcodeproj](EasyPod.xcodeproj) and shared **EasyPod** scheme are the normal build entry point.

The NeMo runtime is an external prerequisite. See NVIDIA's [installation documentation](https://github.com/NVIDIA/NeMo-Speech.cpp#installation) and [ASR model guide](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/asr/models.md). EasyPod expects the library and notice layout used by [prepare_native.sh](script/prepare_native.sh) and [embed_runtime.sh](script/embed_runtime.sh); installing only a CLI executable is insufficient. For a different SDK location, set `NEMO_SDK_ROOT` to the installation directory when building.

## Build and launch

With the prerequisites installed, run this from the repository root:

```sh
./script/build_and_run.sh
```

The script builds the app, verifies its ad-hoc signature, stages it at `dist/EasyPod.app`, and launches it. It quits an idle EasyPod instance before building and refuses to replace an active recording. The Codex **Run** action uses the same script. No Apple Developer account is required for this local build.

The first native build fetches the pinned VST3 SDK and its required submodules, so it needs network access. The SDK revision is documented in [SDK-PIN.md](Native/AudioPluginHost/SDK-PIN.md). Runtime libraries and third-party notices are copied into the app; installed models and plugins are left intact, and only bundled copies are signed.

To stage a Release build without launching it:

```sh
EASYPOD_CONFIGURATION=Release ./script/build_and_run.sh --build
```

Build diagnostics are written to `build/xcodebuild.log`, `build/native-configure.log`, and `build/native-build.log`. You can also open `EasyPod.xcodeproj` in Xcode and run the shared **EasyPod** scheme.

## Record your first episode

1. Open **Settings → 文字起こし** (transcription). Select your local GGUF model and leave transcription enabled if you want live text.
2. In **認識言語** (recognition language), choose **オート** (automatic detection), **日本語**, or **英語**. Japanese is the default. The saved choice applies to subsequent live transcription and offline refinement; settings are disabled during recording and refinement.
3. Select the microphone, name the recording, and press the red record button. Allow microphone access when macOS asks.
4. Pause/resume as needed, then press Stop. Play the saved recording and use its seek slider or 15-second controls to review it.
5. Optionally run **清書** (refinement) to recognize the saved original audio again with the configured local model. You can cancel or restore the transcript from before refinement.
6. Press **⌘E** to choose export settings and a destination, then export the audio.

Effects default to **録音後** (after recording), so you can adjust the chain for playback and export while keeping the original audio. Add effects with **VST3 / AU を追加**. Select **録音中** (during recording) before starting if you want a separate processed recording as well. When exporting completed processed audio, EasyPod uses the saved processing without applying the chain again.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New recording |
| ⌘R | Start/stop recording |
| Space | Pause/resume recording |
| ⌘P | Play/pause playback |
| ⌘← / ⌘→ | Skip backward/forward 15 seconds |
| ⌘E | Export |
| ⌘Delete | Move selected recordings to Trash after confirmation |

### Export settings

<img src="githubreadme/easypod-export.png" alt="EasyPod export dialog with WAV, bit depth, sample rate, channel, and effect options" width="480">

*Choose the audio source, format, quality, and effect tail before exporting.*

| Setting | Available choices |
| --- | --- |
| WAV | 16-bit PCM, 24-bit PCM, or 32-bit float |
| AAC/M4A | 96, 128, 192, or 256 kbps |
| Sample rate | 44.1 or 48 kHz |
| Channels | Mono or stereo |
| Effect tail limit | 0–30 seconds; default 10 seconds |

The default settings are WAV, 24-bit, 48 kHz, and mono. Export can use the original audio with or without the current effects, or completed audio processed during recording. WAV output exceeding 4 GB can be split into multiple files. Export writes temporary output before committing a finished file.

## Storage and recovery

Sessions live under `~/Library/Application Support/EasyPod/Sessions`, with one stable UUID directory per recording:

- `source.caf` — original float32 audio.
- `processed.caf` — separate audio when processing during recording.
- `session.json` — recording metadata, effect settings, and transcript state.
- `transcript.json` — transcript recovery copy.

Folder assignments are persisted in `.library-index.json`. Trash moves whole sessions to `.Trash/<UUID>` inside the session library. Use **ごみ箱** (Trash) and **録音を戻す** (restore recording) to restore them. Deleting a folder leaves its recordings unfiled.

Interrupted sessions retain their original audio and show a recovery action. Incomplete processed audio is not offered as a completed processed export.

## Verification status

[PLANS.md](PLANS.md) records the acceptance evidence and remaining checks. Recorded evidence includes actual Japanese speech, advancing transcript timestamps, timed pause/resume, aligned original/processed audio in repaired short mixed recordings, and exports of real recordings to 16/24/32-bit-float WAV and 96/192 kbps AAC. Focused saved-audio tests cover Japanese, English, and automatic language selection in both live-stream and offline recognition paths.

Effect-processing acceptance items **I6/V3** remain open, including broader mixed-plugin processing and failure combinations. Full visual and VoiceOver operation checks remain unperformed recommendations. Plugin processing runs inside the app process; the scanner helper isolates VST3 discovery only. A processor crash can terminate the app.

For implementation details and change history, see [NOTES.md](NOTES.md) and [CHANGELOG.md](CHANGELOG.md).
