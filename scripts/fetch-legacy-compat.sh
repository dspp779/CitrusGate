#!/bin/zsh
# Optional build-only bootstrap for CLT distributions lacking Intel compatibility archives.
# Downloads the official signed package into .build, extracts only needed archives,
# then removes the temporary package and payload. No system installation occurs.
set -euo pipefail
project_dir="${0:A:h:h}"
output="$project_dir/.build/toolchains/swift-6.1.2-compat/macosx"
if [[ -f "$output/libswiftCompatibility50.a" ]] && lipo -archs "$output/libswiftCompatibility50.a" | grep -qw x86_64; then
    print "Intel compatibility archives already available: $output"
    exit 0
fi
mkdir -p "$project_dir/.build"
temp_dir="$(mktemp -d "$project_dir/.build/swift-compat.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
package="$temp_dir/swift-6.1.2.pkg"
print "Downloading the official Swift 6.1.2 package (about 1.5 GB); nothing will be installed system-wide."
curl --fail --location --silent --show-error --connect-timeout 30 --max-time 600 \
    https://download.swift.org/swift-6.1.2-release/xcode/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-osx.pkg \
    --output "$package"
expected=46cd71f0ee4d80e389494c1237335a0a4f43a8ada04fcd97b22953d6f2a14d67
actual="$(shasum -a 256 "$package")"
[[ "${actual%% *}" == "$expected" ]] || { print -u2 "Swift package checksum mismatch"; exit 1; }
pkgutil --check-signature "$package"
pkgutil --expand-full "$package" "$temp_dir/expanded"
source_dir="$temp_dir/expanded/swift-6.1.2-RELEASE-osx-package.pkg/Payload/usr/lib/swift/macosx"
lipo -archs "$source_dir/libswiftCompatibility50.a" | grep -qw x86_64
mkdir -p "$output"
cp "$source_dir"/libswiftCompatibility*.a "$output/"
print "Ready: $output"
