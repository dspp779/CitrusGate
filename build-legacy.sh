#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
source_dir="$project_dir/Legacy/Sources"
resource_dir="$project_dir/Legacy/Resources"
modern_resources="$project_dir/Resources"
build_dir="$project_dir/.build/legacy"
app_dir="$project_dir/dist/Beanfun OTP Legacy.app"
module_cache="$build_dir/module-cache"
frameworks_dir="$app_dir/Contents/Frameworks"

preferred_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$preferred_sdk" ]]; then
    sdk="$preferred_sdk"
else
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$build_dir" "$module_cache"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/GameImages" "$frameworks_dir"

sources=("$source_dir"/*.swift)

swiftc -swift-version 5 \
    -sdk "$sdk" \
    -module-cache-path "$module_cache" \
    -target x86_64-apple-macosx10.12 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$build_dir/BeanfunOTPLegacy" \
    "${sources[@]}"

cp "$resource_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$modern_resources/GameImages/"* "$app_dir/Contents/Resources/GameImages/"

# Icon: reuse Modern PNG via sips/iconutil (same pattern as build.sh, simplified)
icon_master="$modern_resources/AppIcon.png"
iconset_dir="$build_dir/AppIcon.iconset"
rm -rf "$iconset_dir"
mkdir -p "$iconset_dir"
sips -z 16 16 "$icon_master" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_master" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$icon_master" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$icon_master" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon_master" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$icon_master" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$icon_master" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$icon_master" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$icon_master" --out "$iconset_dir/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$icon_master" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"

cp "$build_dir/BeanfunOTPLegacy" "$app_dir/Contents/MacOS/BeanfunOTPLegacy"
chmod 755 "$app_dir/Contents/MacOS/BeanfunOTPLegacy"

# Embed Swift libs referenced via @rpath
embedded=0
while IFS= read -r lib; do
    base="$(basename "$lib")"
    # Resolve absolute path of linked @rpath libs from the just-built binary's load commands
    true
done < <(otool -L "$app_dir/Contents/MacOS/BeanfunOTPLegacy" | awk '/@rpath\/libswift/{print $1}')

swift_root="$(xcrun --find swiftc)"
swift_root="$(cd "$(dirname "$swift_root")/.." && pwd)"
# Common locations for toolchain macosx swift libs:
for candidate in \
    "$swift_root/lib/swift-5.0/macosx" \
    "$swift_root/lib/swift/macosx" \
    "/Library/Developer/CommandLineTools/usr/lib/swift/macosx" \
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
do
    if [[ -d "$candidate" ]]; then
        SWIFT_LIB_DIR="$candidate"
        break
    fi
done

if [[ -z "${SWIFT_LIB_DIR:-}" ]]; then
    echo "error: could not locate Swift macosx stdlib directory" >&2
    exit 1
fi

otool -L "$app_dir/Contents/MacOS/BeanfunOTPLegacy" | awk '/@rpath\/libswift/{print $1}' | while read -r ref; do
    base="${ref#@rpath/}"
    if [[ -f "$SWIFT_LIB_DIR/$base" ]]; then
        cp "$SWIFT_LIB_DIR/$base" "$frameworks_dir/$base"
        embedded=1
    fi
done

# Also copy transitive libswift deps that appear only after first copy (one extra pass)
for pass in 1 2 3; do
    for f in "$frameworks_dir"/libswift*.dylib; do
        [[ -e "$f" ]] || continue
        otool -L "$f" | awk '/libswift/{print $1}' | while read -r ref; do
            base="$(basename "$ref")"
            if [[ -f "$SWIFT_LIB_DIR/$base" && ! -f "$frameworks_dir/$base" ]]; then
                cp "$SWIFT_LIB_DIR/$base" "$frameworks_dir/$base"
            fi
        done
    done
done

codesign --force --deep --sign - "$app_dir"
echo "Built: $app_dir"
echo "minos check:"
otool -l "$app_dir/Contents/MacOS/BeanfunOTPLegacy" | rg -A3 "LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION" | head -20
lipo -info "$app_dir/Contents/MacOS/BeanfunOTPLegacy"
