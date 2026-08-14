#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
cd "$project_dir"

build_cache="/tmp/tokenlens-build-cache"
mkdir -p "$build_cache/clang" "$build_cache/swiftpm"
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
export CLANG_MODULE_CACHE_PATH="$build_cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_cache/swiftpm"

self_test="$build_cache/TokenLensScannerSelfTest"
swiftc -parse-as-library \
  "$project_dir/Sources/UsageModels.swift" \
  "$project_dir/Sources/CodexLogScanner.swift" \
  "$project_dir/Tests/ScannerSelfTest.swift" \
  -o "$self_test"
"$self_test"

swift build -c release --disable-sandbox \
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
