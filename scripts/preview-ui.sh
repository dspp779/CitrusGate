#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source "$project_dir/scripts/build-environment.zsh"
build_dir="$project_dir/.build/ui-review"
app_dir="$build_dir/UIPreview.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp -R "$project_dir/Resources/GameImages" "$app_dir/Contents/Resources/"
sources=("$project_dir/Sources"/*.swift)
sources=("${(@)sources:#*/BeanfunOTPApp.swift}")
"$swift_bin" -swift-version 5 -D UI_PREVIEW -sdk "$sdk" \
  -module-cache-path "$project_dir/.build/module-cache" -target arm64-apple-macosx13.0 \
  -parse-as-library "${sources[@]}" "$project_dir/Tests/UIPreview.swift" -o "$app_dir/Contents/MacOS/UIPreview"
"$app_dir/Contents/MacOS/UIPreview" "$build_dir/screenshots"
