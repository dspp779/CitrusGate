#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source "$project_dir/scripts/build-environment.zsh"
build_dir="$project_dir/.build/ui-review-legacy"
mkdir -p "$build_dir"
sources=("$project_dir/Legacy/Sources"/*.swift)
sources=("${(@)sources:#*/main.swift}")
"$swift_bin" -swift-version 5 -D UI_PREVIEW -sdk "$sdk" \
  -module-cache-path "$project_dir/.build/module-cache" -target arm64-apple-macosx13.0 \
  -parse-as-library "${sources[@]}" \
  "$project_dir/Sources/NxdlDownloader.swift" "$project_dir/Sources/GameClientDiskGate.swift" \
  "$project_dir/Sources/ClientSupport.swift" "$project_dir/Sources/GGMDataParam.swift" \
  "$project_dir/Sources/GGMManifest.swift" "$project_dir/Sources/GGMManifestStore.swift" \
  "$project_dir/Sources/GGMManifestUpdater.swift" "$project_dir/Tests/LegacyUIPreview.swift" \
  -o "$build_dir/LegacyUIPreview"
"$build_dir/LegacyUIPreview" "$build_dir/screenshots"
