# EasyPod development

- Use UTF-8 and English code comments describing behavior and rationale.
- Read `~/.codex/docs/library-notes.md` and `~/.codex/docs/macos-gotchas.md` before coding.
- `EasyPod.xcodeproj` with the shared EasyPod scheme is authoritative. `project.yml` is its reproducible XcodeGen specification; regenerate after adding sources. Use exposed Xcode MCP builds/diagnostics when the project is open. `script/build_and_run.sh` is the user Run action and CLI fallback. No SwiftPM app packaging.
- Swift 6 language mode with the installed Swift 6.4 toolchain, arm64, macOS 26+. App state/UI use MainActor; native handles stay with their serial owner.
- Use ad-hoc signing (`-`). Preserve installed SDK, GGUF models, plugins, licensing and system security settings. Sign only bundled copies.
- Realtime callbacks must not allocate, lock, perform I/O, infer, synchronously wait, or update UI. Preallocate buffers and communicate through bounded native queues. Overrun is a visible failure, never silent success.
- Create audio tap/completion callbacks in nonisolated Sendable factories. Read live effect latency after engine allocation, and align source/processed tap segments with the same sample clock boundary.
- Read export latency and tail after the export engine starts, for both offline rendering and realtime fallback. Preflight plugin allocation can report a different latency.
- Close ASR results/streams/recognizers and VST3 views/components/controllers in ownership order. Keep original audio intact and never apply a saved live chain twice.
- `PLANS.md` is the only progress checklist. Keep acceptance items pending until observed evidence exists. Device speech and long recording checks cannot be replaced by UI screenshots.
- Reuse passing evidence for unchanged behavior across related acceptance items. Preserve verification attempt counts across handoffs; do not reset budgets by renaming a check or restart broad device flows for a narrow change. Follow the plan's current resumption scope before running pending audits.
- Never automatically stop an active recording to rebuild or relaunch.
