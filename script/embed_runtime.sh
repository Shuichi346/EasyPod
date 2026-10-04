#!/bin/bash
set -euo pipefail
TASK_ROOT="${SRCROOT:?}"
TASK_SDK="${NEMO_SDK_ROOT:-$HOME/Library/Application Support/NeMoSpeech}"
TASK_APP="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
TASK_FRAMEWORKS="$TASK_APP/Contents/Frameworks"
TASK_RESOURCES="$TASK_APP/Contents/Resources"
mkdir -p "$TASK_FRAMEWORKS" "$TASK_RESOURCES/ThirdParty" "$TASK_APP/Contents/Helpers"
for TASK_LIB in libnemo_speech_asr_c.1.dylib libnemo_speech_asr.dylib libggml.0.dylib libggml-base.0.dylib libggml-blas.0.dylib libggml-cpu.0.dylib libggml-metal.0.dylib libnemo_speech_text_normalization.dylib libllama.0.dylib; do
  cp -L "$TASK_SDK/lib/$TASK_LIB" "$TASK_FRAMEWORKS/$TASK_LIB"
  /usr/bin/codesign --force --sign - "$TASK_FRAMEWORKS/$TASK_LIB"
done
/usr/bin/ditto "$TASK_SDK/share/licenses/nemo-speech" "$TASK_RESOURCES/ThirdParty/NeMoSpeech"
if test -d "$TASK_SDK/share/nemo-speech"; then
  /usr/bin/ditto "$TASK_SDK/share/nemo-speech" "$TASK_RESOURCES/nemo-speech"
fi
cp "$TASK_ROOT/build/dependencies/vst3sdk/LICENSE.txt" "$TASK_RESOURCES/ThirdParty/VST3-LICENSE.txt"
cp "$TASK_ROOT/build/native/EasyPodPluginScanner" "$TASK_APP/Contents/Helpers/"
/usr/bin/codesign --force --sign - "$TASK_APP/Contents/Helpers/EasyPodPluginScanner"
