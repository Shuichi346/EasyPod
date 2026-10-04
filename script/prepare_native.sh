#!/bin/bash
set -euo pipefail
TASK_ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TASK_SDK="${NEMO_SDK_ROOT:-$HOME/Library/Application Support/NeMoSpeech}"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
test -f "$TASK_SDK/lib/libnemo_speech_asr_c.1.dylib" || { echo "error: Installed NeMo SDK is missing: $TASK_SDK" >&2; exit 1; }
mkdir -p "$TASK_ROOT/build/runtime/lib"
cp -L "$TASK_SDK/lib/libnemo_speech_asr_c.1.dylib" "$TASK_ROOT/build/runtime/lib/"
bash "$TASK_ROOT/Native/AudioPluginHost/bootstrap_sdk.sh"
cmake -S "$TASK_ROOT/Native/AudioPluginHost" -B "$TASK_ROOT/build/native" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DVST3_SDK_ROOT="$TASK_ROOT/build/dependencies/vst3sdk" > "$TASK_ROOT/build/native-configure.log" 2>&1 || { tail -40 "$TASK_ROOT/build/native-configure.log"; exit 1; }
cmake --build "$TASK_ROOT/build/native" --config Release -j 4 > "$TASK_ROOT/build/native-build.log" 2>&1 || { tail -50 "$TASK_ROOT/build/native-build.log"; exit 1; }
