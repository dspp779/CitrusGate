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

do_release_sign=false
for arg in "$@"; do
    case "$arg" in
        --release|--sign|--notarize|-s)
            do_release_sign=true
            ;;
    esac
done

source "$project_dir/scripts/build-environment.zsh"

export TMPDIR="$build_dir/tmp"
mkdir -p "$build_dir/arm64" "$build_dir/x86_64" "$module_cache" "$TMPDIR"

sources=("$source_dir"/*.swift)
common_flags=(
    -swift-version 5
    -sdk "$sdk"
    -module-cache-path "$module_cache"
    -parse-as-library
)

echo "Building arm64…"
"$swift_bin" "${common_flags[@]}" -target arm64-apple-macosx13.0 \
    -o "$build_dir/arm64/BeanfunOTP" "${sources[@]}"

echo "Building x86_64…"
"$swift_bin" "${common_flags[@]}" -target x86_64-apple-macosx13.0 \
    -o "$build_dir/x86_64/BeanfunOTP" "${sources[@]}"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$resource_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$resource_dir/ggm-manifest.json" "$app_dir/Contents/Resources/ggm-manifest.json"
mkdir -p "$app_dir/Contents/Resources/GameImages"
cp "$resource_dir/GameImages"/* "$app_dir/Contents/Resources/GameImages/"

# Native AppKit icon generator: no third-party Python packages or iconutil required.
"$swift_bin" -sdk "$sdk" -module-cache-path "$module_cache" \
    "$project_dir/Resources/generate_icon.swift" -o "$build_dir/generate-icon"
"$build_dir/generate-icon" "$project_dir/Resources/AppIcon.png" "$app_dir/Contents/Resources/AppIcon.icns"

lipo -create \
    "$build_dir/arm64/BeanfunOTP" \
    "$build_dir/x86_64/BeanfunOTP" \
    -output "$app_dir/Contents/MacOS/BeanfunOTP"
chmod 755 "$app_dir/Contents/MacOS/BeanfunOTP"

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
        codesign --force --timestamp --options runtime --sign "$IDENTITY" --keychain "$KEYCHAIN_PATH" "$app_dir"
    else
        print -u2 "Release requires a Developer ID identity; refusing ad-hoc fallback."
        exit 1
    fi

    [[ -f "$api_key_file" && -n "$key_id" && -n "$issuer_id" ]] || { print -u2 "Release requires Apple notarization credentials."; exit 1; }
    if [[ -n "$IDENTITY" ]]; then
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
    codesign --force --sign - "$app_dir"
fi

echo "Built: $app_dir"
echo "minos check:"
otool -l "$app_dir/Contents/MacOS/BeanfunOTP" | grep -E -A3 'LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION' | head -20
lipo -info "$app_dir/Contents/MacOS/BeanfunOTP"
echo "Code signature check:"
codesign --verify --deep --strict --verbose "$app_dir"
if [[ "$do_release_sign" == true ]]; then
    xcrun stapler validate "$app_dir"
    spctl --assess --type execute --verbose "$app_dir"
else
    echo "Development build: ad-hoc signed; Apple notarization is not requested."
fi

