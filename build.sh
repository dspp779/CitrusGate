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

preferred_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$preferred_sdk" ]]; then
    sdk="$preferred_sdk"
else
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$build_dir/arm64" "$build_dir/x86_64" "$module_cache"

sources=("$source_dir"/*.swift)
common_flags=(
    -swift-version 5
    -sdk "$sdk"
    -module-cache-path "$module_cache"
    -parse-as-library
)

echo "Building arm64…"
swiftc "${common_flags[@]}" -target arm64-apple-macosx13.0 \
    -o "$build_dir/arm64/BeanfunOTP" "${sources[@]}"

echo "Building x86_64…"
swiftc "${common_flags[@]}" -target x86_64-apple-macosx13.0 \
    -o "$build_dir/x86_64/BeanfunOTP" "${sources[@]}"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$resource_dir/Info.plist" "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources/GameImages"
cp "$resource_dir/GameImages"/* "$app_dir/Contents/Resources/GameImages/"

# Composite onto plate, apply squircle at ~82% canvas fill (Apple template sizing)
# so Dock silhouette matches neighbouring apps instead of looking one size larger.
icon_master="$build_dir/AppIcon-master.png"
python3 - "$icon_source" "$icon_master" <<'PY'
import sys
from pathlib import Path
import numpy as np
from PIL import Image

src_path, out_path = Path(sys.argv[1]), Path(sys.argv[2])
src = Image.open(src_path).convert("RGBA")
size = 1024
if src.size != (size, size):
    src = src.resize((size, size), Image.Resampling.LANCZOS)

arr = np.array(src)
rgb = arr[:, :, :3].astype(np.float64)
alpha = arr[:, :, 3].astype(np.float64) / 255.0

plate = np.array([250.0, 251.0, 253.0])
sample = arr[size // 5, size // 2]
if sample[3] > 200 and int(sample[0]) > 200:
    plate = sample[:3].astype(np.float64)

flat = rgb * alpha[:, :, None] + plate * (1.0 - alpha[:, :, None])

# Apple macOS template: artwork squircle ≈ 824/1024 (~80.5–82%) of canvas.
fill = 0.82
inner = int(round(size * fill))
pad = (size - inner) // 2

n = 5.0
c = np.linspace(-1.0, 1.0, inner)
x, y = np.meshgrid(c, c)
rr = np.abs(x) ** n + np.abs(y) ** n
inner_mask = np.clip(1.0 - (rr - 1.0) * (inner * 0.45), 0.0, 1.0)
inner_mask = np.where(rr <= 1.0, 1.0, inner_mask)
inner_mask = np.where(rr > 1.06, 0.0, inner_mask)

# Scale flattened art into the inner squircle bounds.
scaled = np.array(
    Image.fromarray(np.clip(flat, 0, 255).astype(np.uint8)).resize(
        (inner, inner), Image.Resampling.LANCZOS
    ),
    dtype=np.float64,
)
fringe = (inner_mask > 0.0) & (inner_mask < 1.0)
scaled[fringe] = plate

canvas_rgb = np.zeros((size, size, 3), dtype=np.float64)
canvas_a = np.zeros((size, size), dtype=np.float64)
y0, x0 = pad, pad
canvas_rgb[y0 : y0 + inner, x0 : x0 + inner] = scaled
canvas_a[y0 : y0 + inner, x0 : x0 + inner] = inner_mask

out = np.dstack(
    [
        np.clip(canvas_rgb, 0, 255).astype(np.uint8),
        np.clip(canvas_a * 255.0, 0, 255).astype(np.uint8),
    ]
)
Image.fromarray(out, "RGBA").save(out_path, format="PNG")
PY

rm -rf "$iconset_dir"
mkdir -p "$iconset_dir"
sips -z 16 16 "$icon_master" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_master" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$icon_master" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$icon_master" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon_master" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$icon_master" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$icon_master" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$icon_master" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$icon_master" --out "$iconset_dir/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$icon_master" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"

lipo -create \
    "$build_dir/arm64/BeanfunOTP" \
    "$build_dir/x86_64/BeanfunOTP" \
    -output "$app_dir/Contents/MacOS/BeanfunOTP"
chmod 755 "$app_dir/Contents/MacOS/BeanfunOTP"

codesign --force --sign - "$app_dir"
echo "Built: $app_dir"
