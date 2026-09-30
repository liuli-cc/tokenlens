#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
cd "$project_dir"

build_cache="/tmp/tokenlens-build-cache"
mkdir -p "$build_cache/clang" "$build_cache/swiftpm"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
# CLT SDK 27 currently lacks the matching SwiftUI macro plugin; use the
# installed SDK 26 when available. CI falls back to its supported system SDK.
if [[ "$(xcrun --sdk macosx --show-sdk-version)" == 27* && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi
export CLANG_MODULE_CACHE_PATH="$build_cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_cache/swiftpm"

self_test="$build_cache/TokenLensScannerSelfTest"
swiftc -sdk "$SDKROOT" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$project_dir/Sources/AssistantIdentity.swift" \
  "$project_dir/Sources/UsageModels.swift" \
  "$project_dir/Sources/CodexLogScanner.swift" \
  "$project_dir/Tests/ScannerSelfTest.swift" \
  -o "$self_test"
"$self_test"

island_test="$build_cache/TokenLensIslandSelfTest"
swiftc -sdk "$SDKROOT" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$project_dir/Sources/AssistantIdentity.swift" \
  "$project_dir/Sources/UsageModels.swift" \
  "$project_dir/Sources/IslandGeometry.swift" \
  "$project_dir/Sources/IslandCompactText.swift" \
  "$project_dir/Sources/MenuBarOccupancy.swift" \
  "$project_dir/Sources/DeepSeekActivity.swift" \
  "$project_dir/Tests/IslandSelfTest.swift" \
  -o "$island_test"
"$island_test"

additional_test="$build_cache/TokenLensAdditionalSelfTest"
swiftc -sdk "$SDKROOT" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$project_dir/Sources/AssistantIdentity.swift" \
  "$project_dir/Sources/UsageModels.swift" \
  "$project_dir/Sources/AdditionalAssistantReader.swift" \
  "$project_dir/Tests/AdditionalTelemetrySelfTest.swift" \
  -o "$additional_test"
"$additional_test"

dsh_metrics_test="$build_cache/TokenLensDeepSeekMetricsSelfTest"
swiftc -sdk "$SDKROOT" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$project_dir/Sources/AssistantIdentity.swift" \
  "$project_dir/Sources/UsageModels.swift" \
  "$project_dir/Sources/DeepSeekActivity.swift" \
  "$project_dir/Sources/DeepSeekStatus.swift" \
  "$project_dir/Tests/DeepSeekMetricsSelfTest.swift" \
  -o "$dsh_metrics_test"
"$dsh_metrics_test"

swift build --build-system native --sdk "$SDKROOT" -c release --disable-sandbox \
  --cache-path "$build_cache/package-cache" \
  --config-path "$build_cache/config" \
  --security-path "$build_cache/security"

app_dir="$project_dir/dist/TokenLens.app"
contents_dir="$app_dir/Contents"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$contents_dir/Helpers"

cp "$project_dir/.build/release/TokenLens" "$contents_dir/MacOS/TokenLens"
cp "$project_dir/.build/release/TokenLensBridge" "$contents_dir/Helpers/TokenLensBridge"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
chmod +x "$contents_dir/MacOS/TokenLens" "$contents_dir/Helpers/TokenLensBridge"

/usr/bin/codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
