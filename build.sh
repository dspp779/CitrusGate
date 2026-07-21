#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
source_dir="$project_dir/Sources"
resource_dir="$project_dir/Resources"
build_dir="$project_dir/.build"
app_dir="$project_dir/dist/Beanfun OTP.app"
module_cache="$build_dir/module-cache"
icon_source="$resource_dir/AppIcon.png"
iconset_dir="$build_dir/AppIcon.iconset"

preferred_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$preferred_sdk" ]]; then
    sdk="$preferred_sdk"
else
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$build_dir/arm64" "$build_dir/x86_64" "$module_cache"

sources=("$source_dir"/*.swift)
common_flags=(
    -swift-version 5
    -sdk "$sdk"
    -module-cache-path "$module_cache"
    -parse-as-library
)

echo "Building arm64…"
swiftc "${common_flags[@]}" -target arm64-apple-macosx13.0 \
    -o "$build_dir/arm64/BeanfunOTP" "${sources[@]}"

echo "Building x86_64…"
swiftc "${common_flags[@]}" -target x86_64-apple-macosx13.0 \
    -o "$build_dir/x86_64/BeanfunOTP" "${sources[@]}"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$resource_dir/Info.plist" "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources/GameImages"
cp "$resource_dir/GameImages"/* "$app_dir/Contents/Resources/GameImages/"

mkdir -p "$iconset_dir"
sips -z 16 16 "$icon_source" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$icon_source" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon_source" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$icon_source" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
python3 "$project_dir/Scripts/create_icns.py" \
    "$iconset_dir" "$app_dir/Contents/Resources/AppIcon.icns"

lipo -create \
    "$build_dir/arm64/BeanfunOTP" \
    "$build_dir/x86_64/BeanfunOTP" \
    -output "$app_dir/Contents/MacOS/BeanfunOTP"
chmod 755 "$app_dir/Contents/MacOS/BeanfunOTP"

codesign --force --sign - "$app_dir"
echo "Built: $app_dir"
