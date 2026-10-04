# VST3 SDK dependency

EasyPod uses the official Steinberg VST3 SDK under its MIT license.

- Repository: https://github.com/steinbergmedia/vst3sdk
- Tag: `v3.8.1_build_84`
- Commit: `3cdf9ca5d1f5b1b21e0a86832aa4abe55607bd96`
- Required submodules: `base`, `pluginterfaces`, `public.sdk`, `cmake` at the revisions recorded by this commit.
- Checkout: ignored `build/dependencies/vst3sdk`.

Only hosting libraries are built. Copy the SDK's `LICENSE.txt` into the app's third-party notices. Never modify or re-sign installed plugins.

VST3 and AUv2 processing remains in-process. The helper isolates discovery only. A processor crash can terminate the app, so session audio must be flushed regularly.
