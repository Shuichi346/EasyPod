#!/bin/bash
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
sdk_path="$repository_root/build/dependencies/vst3sdk"
revision="3cdf9ca5d1f5b1b21e0a86832aa4abe55607bd96"
if [[ ! -d "$sdk_path/.git" ]]; then
  /usr/bin/git clone --quiet --branch v3.8.1_build_84 --depth 1 https://github.com/steinbergmedia/vst3sdk.git "$sdk_path"
fi
actual_revision="$(/usr/bin/git -C "$sdk_path" rev-parse HEAD)"
if [[ "$actual_revision" != "$revision" ]]; then
  echo "VST3 SDK revision mismatch; preserve the existing checkout and inspect SDK-PIN.md." >&2
  exit 1
fi
/usr/bin/git -C "$sdk_path" submodule update --init --depth 1 base pluginterfaces public.sdk cmake
