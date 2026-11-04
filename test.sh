#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
python3 "$project_dir/scripts/test_update_ggm_manifest.py"
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

# Compile and run identical offline WebToken fixtures against both implementations.
for implementation in Modern Legacy; do
    if [[ "$implementation" == Modern ]]; then
        client_sources="$project_dir/Sources"
    else
        client_sources="$project_dir/Legacy/Sources"
    fi
    swiftc -swift-version 5 -sdk "$sdk" -module-cache-path "$module_cache" \
        -target arm64-apple-macosx13.0 -parse-as-library \
        "$client_sources/Models.swift" \
        "$client_sources/DESCipher.swift" \
        "$client_sources/MapleStoryWineLauncher.swift" \
        "$client_sources/BeanfunClient.swift" \
        "$project_dir/Sources/GGMManifest.swift" \
        "$project_dir/Sources/GGMDataParam.swift" \
        "$project_dir/Tests/WebTokenTests.swift" \
        -o "$build_dir/WebTokenTests-$implementation"
    "$build_dir/WebTokenTests-$implementation" "$project_dir/Tests/Fixtures/web-token" "$implementation"
done
