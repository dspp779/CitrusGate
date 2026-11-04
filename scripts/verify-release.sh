#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
app_dir="${1:-$project_dir/dist/Beanfun OTP.app}"
mode="${2:---release}"
[[ -d "$app_dir/Contents" ]] || { print -u2 "App bundle not found: $app_dir"; exit 1; }
plutil -lint "$app_dir/Contents/Info.plist"
name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_dir/Contents/Info.plist")
lipo -info "$app_dir/Contents/MacOS/$name"
codesign --verify --deep --strict --verbose=2 "$app_dir"
if [[ "$mode" == --development ]]; then
    echo "Development signature verified. This does not establish Apple notarization."
else
    signature="$(codesign --display --verbose=2 "$app_dir" 2>&1)"
    [[ "$signature" == *"Authority=Developer ID Application:"* ]]
    xcrun stapler validate "$app_dir"
    spctl --assess --type execute --verbose "$app_dir"
    echo "Developer ID signature, stapled ticket and Gatekeeper assessment passed."
fi
