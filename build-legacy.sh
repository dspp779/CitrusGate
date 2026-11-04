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

source "$project_dir/scripts/build-environment.zsh"

legacy_runtime="${LEGACY_SWIFT_RUNTIME_DIR:-${swift_bin:h:h}/lib/swift/macosx}"
cached_compat="$project_dir/.build/toolchains/swift-6.1.2-compat/macosx"
if [[ -z "${LEGACY_SWIFT_RUNTIME_DIR:-}" && -f "$cached_compat/libswiftCompatibility50.a" ]] && \
   ! lipo -archs "$legacy_runtime/libswiftCompatibility50.a" | grep -qw x86_64; then
    legacy_runtime="$cached_compat"
fi
if [[ ! -f "$legacy_runtime/libswiftCompatibility50.a" ]] ||    ! lipo -archs "$legacy_runtime/libswiftCompatibility50.a" | grep -qw x86_64; then
    print -u2 "Legacy requires x86_64 Swift back-deployment libraries. Run ./scripts/fetch-legacy-compat.sh, or set LEGACY_SWIFT_RUNTIME_DIR to a compatible official Swift toolchain's usr/lib/swift/macosx directory."
    exit 1
fi

compat_flags=()
if [[ "$legacy_runtime" != "${swift_bin:h:h}/lib/swift/macosx" ]]; then
    # Recent CLT distributions omit Intel back-deployment archives. Supply the
    # official archives explicitly; do not change the dynamic runtime search path.
    compat_flags=(-disable-autolinking-runtime-compatibility
        -disable-autolinking-runtime-compatibility-concurrency
        -disable-autolinking-runtime-compatibility-dynamic-replacements)
    for archive in "$legacy_runtime"/libswiftCompatibility*.a; do
        lipo -archs "$archive" | grep -qw x86_64 || continue
        compat_flags+=(-Xlinker -force_load -Xlinker "$archive")
    done
fi

export TMPDIR="$build_dir/tmp"
mkdir -p "$build_dir" "$module_cache" "$frameworks_dir" "$TMPDIR"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/GameImages"

sources=("$source_dir"/*.swift \
  "$project_dir/Sources/NxdlDownloader.swift" \
  "$project_dir/Sources/GameClientDiskGate.swift" \
  "$project_dir/Sources/ClientSupport.swift" \
    "$project_dir/Sources/GGMDataParam.swift" \
  "$project_dir/Sources/GGMManifest.swift" \
  "$project_dir/Sources/GGMManifestStore.swift" \
  "$project_dir/Sources/GGMManifestUpdater.swift")

"$swift_bin" -swift-version 5 \
    -sdk "$sdk" \
    -module-cache-path "$module_cache" \
    -target x86_64-apple-macosx10.12 \
    "${compat_flags[@]}" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$build_dir/BeanfunOTPLegacy" \
    "${sources[@]}"

cp "$resource_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$modern_resources/GameImages/"* "$app_dir/Contents/Resources/GameImages/"
cp "$modern_resources/ggm-manifest.json" "$app_dir/Contents/Resources/ggm-manifest.json"

# Native AppKit icon generator: no third-party Python packages or iconutil required.
"$swift_bin" -sdk "$sdk" -module-cache-path "$module_cache" \
    "$project_dir/Resources/generate_icon.swift" -o "$build_dir/generate-icon"
"$build_dir/generate-icon" "$project_dir/Resources/AppIcon.png" "$app_dir/Contents/Resources/AppIcon.icns"

cp "$build_dir/BeanfunOTPLegacy" "$app_dir/Contents/MacOS/BeanfunOTPLegacy"
chmod 755 "$app_dir/Contents/MacOS/BeanfunOTPLegacy"

# Embed Swift libs referenced via @rpath
swift_root="$swift_bin"
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
    codesign --force --deep --sign - "$app_dir"
fi

echo "Built: $app_dir"
echo "minos check:"
otool -l "$app_dir/Contents/MacOS/BeanfunOTPLegacy" | grep -E -A3 'LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION' | head -20
lipo -info "$app_dir/Contents/MacOS/BeanfunOTPLegacy"
echo "Code signature check:"
codesign --verify --deep --strict --verbose "$app_dir"
if [[ "$do_release_sign" == true ]]; then
    xcrun stapler validate "$app_dir"
    spctl --assess --type execute --verbose "$app_dir"
else
    echo "Development build: ad-hoc signed; Apple notarization is not requested."
fi
