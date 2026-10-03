#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
build_cache="/tmp/tokenlens-build-cache"
preview_app="$build_cache/TokenLensIslandPreview.app"
preview_contents="$preview_app/Contents"
preview_arch="$(uname -m)"
mkdir -p "$build_cache/clang"
mkdir -p "$preview_contents/MacOS"
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
export CLANG_MODULE_CACHE_PATH="$build_cache/clang"
swiftc -D TOKENLENS_PREVIEW -swift-version 6 -strict-concurrency=complete -parse-as-library -target "$preview_arch-apple-macos14.0" \
  "$project_dir/Sources/UsageModels.swift" \
  "$project_dir/Sources/AssistantIdentity.swift" \
  "$project_dir/Sources/CodexLogScanner.swift" \
  "$project_dir/Sources/DeepSeekStatus.swift" \
  "$project_dir/Sources/DeepSeekActivity.swift" \
  "$project_dir/Sources/AdditionalAssistantReader.swift" \
  "$project_dir/Sources/UsageStore.swift" \
  "$project_dir/Sources/IslandGeometry.swift" \
  "$project_dir/Sources/CompletionNoticeQueue.swift" \
  "$project_dir/Sources/IslandExperience.swift" \
  "$project_dir/Sources/IslandCompactText.swift" \
  "$project_dir/Sources/MenuBarOccupancy.swift" \
  "$project_dir/Sources/DynamicIsland.swift" \
  "$project_dir/Tests/IslandPreview.swift" \
  -o "$build_cache/TokenLensIslandPreview"
cp "$build_cache/TokenLensIslandPreview" "$preview_contents/MacOS/TokenLensIslandPreview"
cat > "$preview_contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>TokenLensIslandPreview</string>
  <key>CFBundleIdentifier</key><string>cn.liuli.tokenlens.preview</string>
  <key>CFBundleName</key><string>TokenLens Island Preview</string>
  <key>CFBundleDisplayName</key><string>灵动岛动画预览（合成样例）</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$preview_contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$preview_app"
echo "$preview_app"
