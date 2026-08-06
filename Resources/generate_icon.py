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
