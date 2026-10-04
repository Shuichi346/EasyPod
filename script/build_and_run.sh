#!/bin/bash
set -euo pipefail
TASK_MODE="${1:-run}"
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_APP="$TASK_ROOT/dist/EasyPod.app"
case "$TASK_MODE" in run|--debug|--logs|--telemetry|--verify|--build) ;; *) echo "usage: $0 [--debug|--logs|--telemetry|--verify|--build]" >&2; exit 2;; esac
if /usr/bin/pgrep -x EasyPod >/dev/null; then
  if test -f "$HOME/Library/Application Support/EasyPod/active-recording"; then
    echo "録音中です。アプリで録音を停止してから実行してください。" >&2
    exit 1
  fi
  /usr/bin/osascript -e 'tell application id "local.EasyPod" to quit'
  sleep 2
  if /usr/bin/pgrep -x EasyPod >/dev/null; then echo "EasyPod is still running; finish its current operation first." >&2; exit 1; fi
fi
mkdir -p "$TASK_ROOT/build" "$TASK_ROOT/dist"
/usr/bin/xcodebuild -quiet -project "$TASK_ROOT/EasyPod.xcodeproj" -scheme EasyPod -configuration "${EASYPOD_CONFIGURATION:-Debug}" -destination 'platform=macOS,arch=arm64' -derivedDataPath "$TASK_ROOT/build/DerivedData" build > "$TASK_ROOT/build/xcodebuild.log" 2>&1 || { tail -60 "$TASK_ROOT/build/xcodebuild.log"; exit 1; }
TASK_STAGE="$(mktemp -d "$TASK_ROOT/build/stage.XXXXXX")"
/usr/bin/ditto "$TASK_ROOT/build/DerivedData/Build/Products/${EASYPOD_CONFIGURATION:-Debug}/EasyPod.app" "$TASK_STAGE/EasyPod.app"
/usr/bin/codesign --verify --deep --strict "$TASK_STAGE/EasyPod.app"
if test -e "$TASK_APP"; then /bin/mv "$TASK_APP" "$TASK_STAGE/previous.app"; fi
/bin/mv "$TASK_STAGE/EasyPod.app" "$TASK_APP"
case "$TASK_MODE" in
  --build) exit 0;;
  --debug) /usr/bin/lldb -- "$TASK_APP/Contents/MacOS/EasyPod";;
  *) /usr/bin/open -n "$TASK_APP"
    case "$TASK_MODE" in
      --logs) /usr/bin/log stream --info --style compact --predicate 'process == "EasyPod"';;
      --telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.EasyPod"';;
      --verify) sleep 2; /usr/bin/pgrep -x EasyPod >/dev/null;;
    esac;;
esac
