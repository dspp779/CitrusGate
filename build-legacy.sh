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

do_release_sign=false
for arg in "$@"; do
    case "$arg" in
        --release|--sign|--notarize|-s)
            do_release_sign=true
            ;;
    esac
done

preferred_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$preferred_sdk" ]]; then
    sdk="$preferred_sdk"
else
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi

export TMPDIR="$build_dir/tmp"
mkdir -p "$build_dir" "$module_cache" "$frameworks_dir" "$TMPDIR"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/GameImages"

sources=("$source_dir"/*.swift \
  "$project_dir/Sources/NxdlDownloader.swift" \
  "$project_dir/Sources/GameClientDiskGate.swift")

swiftc -swift-version 5 \
    -sdk "$sdk" \
    -module-cache-path "$module_cache" \
    -target x86_64-apple-macosx10.12 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$build_dir/BeanfunOTPLegacy" \
    "${sources[@]}"

cp "$resource_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$modern_resources/GameImages/"* "$app_dir/Contents/Resources/GameImages/"

# Icon: same squircle sizing as Modern build.sh so Dock silhouette matches neighbours.
icon_source="$modern_resources/AppIcon.png"
icon_master="$build_dir/AppIcon-master.png"
python3 "$modern_resources/generate_icon.py" "$icon_source" "$icon_master"


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

if [[ "$do_release_sign" == true ]]; then
    echo "Release signing and notarization requested."
    env_file="$project_dir/.env"
    if [[ -f "$env_file" ]]; then
        set -a
        source "$env_file"
        set +a
    fi

    p12_file="$project_dir/auth/cert.p12"
    p12_pass="${CYDER_P12_PASSWORD:-}"
    key_id="${CYDER_Key_ID:-}"
    issuer_id="${CYDER_Issuer_ID:-}"
    api_key_file="$project_dir/auth/AuthKey_${key_id}.p8"

    KEYCHAIN_PATH=""
    NOTARIZE_ZIP=""
    cleanup() {
        if [[ -n "$KEYCHAIN_PATH" && -f "$KEYCHAIN_PATH" ]]; then
            security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
        fi
        if [[ -n "$NOTARIZE_ZIP" && -f "$NOTARIZE_ZIP" ]]; then
            rm -f "$NOTARIZE_ZIP" 2>/dev/null || true
        fi
    }
    trap cleanup EXIT

    IDENTITY=""
    if [[ -f "$p12_file" && -n "$p12_pass" ]]; then
        echo "Setting up temporary keychain for Developer ID signing..."
        KEYCHAIN_PATH="$build_dir/release.keychain-db"
        KEYCHAIN_PASS="release_pass_$(date +%s)"
        
        security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
        security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
        security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
        security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_PATH"
        security import "$p12_file" -k "$KEYCHAIN_PATH" -P "$p12_pass" -T /usr/bin/codesign -T /usr/bin/security
        security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN_PATH" >/dev/null

        IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep "Developer ID Application" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
        if [[ -z "$IDENTITY" ]]; then
            IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
        fi
    fi

    if [[ -n "$IDENTITY" ]]; then
        echo "Signing with Developer ID identity: $IDENTITY"
        if [[ -d "$frameworks_dir" ]]; then
            find "$frameworks_dir" -type f \( -name "*.dylib" -o -name "*.framework" \) -exec codesign --force --timestamp --options runtime --sign "$IDENTITY" --keychain "$KEYCHAIN_PATH" {} +
        fi
        codesign --force --timestamp --options runtime --sign "$IDENTITY" --keychain "$KEYCHAIN_PATH" "$app_dir"
    else
        echo "Warning: Developer ID identity not found, falling back to ad-hoc signing."
        codesign --force --deep --sign - "$app_dir"
    fi

    if [[ -n "$IDENTITY" && -f "$api_key_file" && -n "$key_id" && -n "$issuer_id" ]]; then
        echo "Notarizing app bundle with Apple notarization service..."
        NOTARIZE_ZIP="$build_dir/notarize.zip"
        rm -f "$NOTARIZE_ZIP"
        ditto -c -k --keepParent "$app_dir" "$NOTARIZE_ZIP"
        
        xcrun notarytool submit "$NOTARIZE_ZIP" \
            --key "$api_key_file" \
            --key-id "$key_id" \
            --issuer "$issuer_id" \
            --wait

        echo "Stapling notarization ticket..."
        xcrun stapler staple "$app_dir"
    fi
else
    echo "Performing standard ad-hoc code signing..."
    codesign --force --deep --sign - "$app_dir"
fi

echo "Built: $app_dir"
echo "minos check:"
otool -l "$app_dir/Contents/MacOS/BeanfunOTPLegacy" | grep -E -A3 'LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION' | head -20
lipo -info "$app_dir/Contents/MacOS/BeanfunOTPLegacy"
echo "Code signature check:"
codesign --verify --deep --strict --verbose "$app_dir"
spctl --assess --type execute --verbose "$app_dir" || true
