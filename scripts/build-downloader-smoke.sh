#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
source "$project_dir/scripts/build-environment.zsh"
mkdir -p "$project_dir/.build/tests"
"$swift_bin" -swift-version 5 -sdk "$sdk" -module-cache-path "$project_dir/.build/module-cache" \
  -target arm64-apple-macosx13.0 -parse-as-library \
  "$project_dir/Sources/BeanfunClient.swift" "$project_dir/Sources/DESCipher.swift" \
  "$project_dir/Sources/GGMManifest.swift" "$project_dir/Sources/GGMDataParam.swift" \
  "$project_dir/Sources/Models.swift" "$project_dir/Sources/MapleStoryWineLauncher.swift" \
  "$project_dir/Sources/NxdlDownloader.swift" "$project_dir/Sources/ClientSupport.swift" \
  "$project_dir/Sources/GameClientDiskGate.swift" "$project_dir/Tests/DownloaderSmoke.swift" \
  -o "$project_dir/.build/tests/DownloaderSmoke"
echo "Built .build/tests/DownloaderSmoke. Run only with an isolated upstream test directory."
