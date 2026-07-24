#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
source_dir="$project_dir/Interceptor/Sources"
resource_dir="$project_dir/Interceptor/Resources"
build_dir="$project_dir/.build-nxl-interceptor"
app_dir="$project_dir/dist/NXL Interceptor.app"
module_cache="$build_dir/module-cache"

preferred_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$preferred_sdk" ]]; then
    sdk="$preferred_sdk"
else
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi

export TMPDIR="$build_dir/tmp"
mkdir -p "$build_dir" "$module_cache" "$TMPDIR"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

sources=("$source_dir"/*.swift)

echo "Building arm64 NXLInterceptor…"
swiftc \
    -swift-version 5 \
    -sdk "$sdk" \
    -module-cache-path "$module_cache" \
    -target arm64-apple-macosx13.0 \
    -o "$build_dir/NXLInterceptor" \
    "${sources[@]}"

cp "$resource_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$build_dir/NXLInterceptor" "$app_dir/Contents/MacOS/NXLInterceptor"
chmod +x "$app_dir/Contents/MacOS/NXLInterceptor"

echo "Built: $app_dir"
