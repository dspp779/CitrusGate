#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/.build/tests"
module_cache="$project_dir/.build/module-cache"
preferred_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$preferred_sdk" ]]; then
    sdk="$preferred_sdk"
else
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$build_dir" "$module_cache"
swiftc -swift-version 5 -sdk "$sdk" -module-cache-path "$module_cache" \
    -target arm64-apple-macosx13.0 -parse-as-library \
    "$project_dir/Sources/Models.swift" \
    "$project_dir/Sources/DESCipher.swift" \
    "$project_dir/Sources/NexonPlugURLParser.swift" \
    "$project_dir/Sources/MapleStoryWineLauncher.swift" \
    "$project_dir/Sources/GGMManifest.swift" \
    "$project_dir/Sources/GGMManifestStore.swift" \
    "$project_dir/Sources/GGMManifestUpdater.swift" \
    "$project_dir/Sources/GGMDataParam.swift" \
    "$project_dir/Sources/BeanfunClient.swift" \
    "$project_dir/Sources/NxdlDownloader.swift" \
    "$project_dir/Sources/GameClientDiskGate.swift" \
    "$project_dir/Sources/AppModel.swift" \
    "$project_dir/Tests/CoreTests.swift" \
    -o "$build_dir/CoreTests"
"$build_dir/CoreTests"
