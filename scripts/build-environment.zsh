swift_bin="${SWIFTC:-$(xcrun --find swiftc)}"
# Shared SDK selection. Respect SDKROOT; avoid an SDK requiring an absent SwiftUI macro plugin.
if [[ -n "${SDKROOT:-}" ]]; then
    sdk="$SDKROOT"
    [[ -d "$sdk" ]] || { print -u2 "SDKROOT does not exist: $sdk"; exit 1; }
else
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    swift_host="${swift_bin:h:h}/lib/swift/host/plugins"
    if [[ ! -e "$swift_host/libSwiftUIMacros.dylib" ]] && \
        grep -R -q 'type: "StateMacro"' "$sdk/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules" 2>/dev/null; then
        sdk_candidates=(/Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk(NOn))
        sdk=""
        for candidate in "${sdk_candidates[@]}"; do
            if ! grep -R -q 'type: "StateMacro"' "$candidate/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules" 2>/dev/null; then
                sdk="$candidate"
                break
            fi
        done
        [[ -n "$sdk" ]] || { print -u2 "No compatible macOS SDK found. Install matching Command Line Tools or set SDKROOT."; exit 1; }
    fi
fi
print "Using SDK: $sdk"
