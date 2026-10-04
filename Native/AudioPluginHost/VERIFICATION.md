# Native plugin verification evidence

Date: 2026-10-04 (Asia/Tokyo). This is evidence and recovery context, not a second progress checklist. PLANS.md remains authoritative.

The pinned SDK, CMake static archive and scanner currently build successfully. The three Swift plugin services pass Swift 6 type checking and `swift format lint`.

Installed discovery established compatible DeepFilter Noise Reduction 0.7.0 and Supercharger 1.4.11 VST3 modules. Ozone 12 Equalizer 12.1.0 rejected `setProcessing(true)` and is represented with an unavailable reason. System AU component registration is inaccessible in the restricted command sandbox; an approved unsandboxed `auval -a` lists Supercharger AU and Apple effects. No installed plugin was modified.

DeepFilter's initial processor/state smoke rendered 51,200 frames, restored component/controller state, and reported 110 ms latency. Its second smoke included persisted normalized edits. The third attempt tested bypass but queried latency too early, obtaining zero; that latency/bypass evidence was invalidated. Final code caches latency after activation, allocates delay storage before rendering, resets borrowed input pointers every render, and honors output silence flags. No fourth DeepFilter execution was attempted. The final latency and bypass behavior remains pending in V3 or an explicitly authorized additional smoke execution.

Supercharger's processor-only smoke exited successfully, restored 3,375 bytes of state, rendered 51,200 finite frames, and reported an infinite tail. Export must cap such a tail using the selected setting and explain truncation.

The mixed CLI fixture used three executions: sandbox-hidden AU discovery, a GUI-lifetime wait, and a bounded diagnostic run. The diagnostic reached 61,440 rendered frames, nonzero finite output, normalized parameter restoration, and both custom editor objects. Its background watchdog invoked process finalizers while AppKit/plugin teardown was waiting, so it did not establish clean GUI lifetime. The fixture now covers audio/state only and avoids background-thread finalizers. Do not rerun that unit beyond its exhausted budget without user authorization.

Actual-app V3 remains the correct editor verification: add Supercharger AU and DeepFilter VST3; separately add Supercharger VST3 to exercise a custom VST3 NSView. Open, change parameters, close, reopen, remove the effect, and close the session. `PluginEditorService` explicitly calls SDK `removed`/`setFrame(nullptr)` before releasing the window content, retains each AVAudioUnit until its window closes, and closes owned windows when the service is destroyed. The native host releases processor/controller/component references before the official provider, then releases the module last. Final editor closure needs observation in the running app's NSApplication event loop.

Actual-app evidence subsequently established clean opening/closing of Supercharger AU and DeepFilter VST3 custom editors, changing DeepFilter Mix to 50%, and state restoration after Release relaunch. Reordering and live bypass operated in the app. The earlier 19:29 mixed live run preserved original audio and Japanese text, but processed audio led by 80 ms and was 483 frames short.

After capture was armed from a common sample boundary following actual engine allocation, session 811ACCF3-D98E-411B-9425-C8B289E8072B saved both CAFs at 3,982,720 frames (82.973333 s). Every measured interval before and after pause had zero-frame lag, no nonfinite/full-scale-exceeding values, and no missing processed samples. Completion and warning fields agreed with the files. This actual-app evidence establishes the repaired short live synchronization without resetting the exhausted CLI budgets.

The repaired 760.088-second live run maintained zero measured lag across seven intervals and no continuing memory growth. An audio-device configuration change interrupted latency drain, leaving processed output 1,443 frames short; the app correctly retained original audio and transcript and displayed the warning. The user's effects-applied 24-bit WAV retained the original's complete frame count and had zero lag against the processed branch throughout measured intervals.

The scanner timeout/failure-cache/forced-rescan fixture passed. It is a distinct process-supervision check and did not rerun an exhausted plugin audio/editor smoke. Remaining acceptance, including after-recording preview/offline export and live bypass after the timing repair, is recorded only in PLANS.md.
