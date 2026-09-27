#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
release_arch="${1:-$(uname -m)}"
case "$release_arch" in arm64|x86_64) ;; *) echo 'Supported architectures: arm64, x86_64' >&2; exit 1;; esac
release_version="$(cat "$project_dir/VERSION")"
release_root="$project_dir/release-out/macos-$release_arch"
release_package="$release_root/TokenLens"
release_app="$release_package/TokenLens.app"
release_build="$project_dir/.build/release-$release_arch"
release_cache="$project_dir/.build/release-cache-$release_arch"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p "$release_cache/clang" "$release_cache/swiftpm" "$release_package"
export CLANG_MODULE_CACHE_PATH="$release_cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$release_cache/swiftpm"

cd "$project_dir"
swift build --configuration release --disable-sandbox --scratch-path "$release_build" \
  --triple "$release_arch-apple-macosx14.0"
release_bin="$(swift build --configuration release --scratch-path "$release_build" \
  --triple "$release_arch-apple-macosx14.0" --show-bin-path)"
mkdir -p "$release_app/Contents/MacOS" "$release_app/Contents/Helpers" "$release_app/Contents/Resources"
cp "$release_bin/TokenLens" "$release_app/Contents/MacOS/TokenLens"
cp "$release_bin/TokenLensBridge" "$release_app/Contents/Helpers/TokenLensBridge"
cp "$project_dir/Resources/Info.plist" "$release_app/Contents/Info.plist"

# A static official zstd CLI makes compressed Harness logs work on a clean Mac.
zstd_root="$release_cache/zstd-1.5.7"
if [[ ! -f "$zstd_root/Makefile" ]]; then
  curl --fail --location --retry 3 'https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7' -o "$release_cache/zstd.tar.gz"
  tar -xzf "$release_cache/zstd.tar.gz" -C "$release_cache"
fi
make -C "$zstd_root/programs" -j2 zstd \
  CC="$(xcrun -f clang) -arch $release_arch" \
  CFLAGS='-O2 -mmacosx-version-min=14.0' \
  HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 ZSTD_LEGACY_SUPPORT=0
cp "$zstd_root/programs/zstd" "$release_app/Contents/Helpers/zstd"
cp "$zstd_root/LICENSE" "$release_app/Contents/Resources/ZSTD-LICENSE.txt"
cp "$project_dir/Integration/tokenlens-dsh-status.mjs" "$release_app/Contents/Resources/tokenlens-dsh-status.mjs"
cp "$project_dir/Integration/cn.liuli.tokenlens.chatgpt-bridge.plist" "$release_app/Contents/Resources/bridge.plist"
cp "$project_dir/Release/install-macos.command" "$release_package/安装.command"
cp "$project_dir/Release/uninstall-macos.command" "$release_package/卸载.command"
cp "$project_dir/Release/connect-dsh.command" "$release_package/连接DSH.command"
cp "$project_dir/Release/使用说明.txt" "$release_package/使用说明.txt"
cp "$project_dir/LICENSE" "$release_package/LICENSE.txt"
chmod +x "$release_app/Contents/MacOS/TokenLens" "$release_app/Contents/Helpers/"* "$release_package/"*.command
codesign --force --deep --sign - "$release_app"
codesign --verify --deep --strict "$release_app"

# The binaries must be the requested architecture and have no Homebrew links.
for binary in "$release_app/Contents/MacOS/TokenLens" "$release_app/Contents/Helpers/TokenLensBridge" "$release_app/Contents/Helpers/zstd"; do
  lipo "$binary" -verify_arch "$release_arch"
  if otool -L "$binary" | tail -n +2 | grep -E '/opt/homebrew|/usr/local' >/dev/null; then
    echo "Non-portable dependency in $binary" >&2; exit 1
  fi
done
output="$project_dir/release-out/TokenLens-macOS-$release_arch-$release_version.zip"
ditto -c -k --keepParent "$release_package" "$output"
shasum -a 256 "$output"
