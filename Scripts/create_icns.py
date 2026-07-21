#!/usr/bin/env python3

import struct
import sys
from pathlib import Path


CHUNKS = (
    (b"icp4", "icon_16x16.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"icp5", "icon_32x32.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic14", "icon_256x256@2x.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: create_icns.py ICONSET_DIR OUTPUT.icns")

    iconset = Path(sys.argv[1])
    output = Path(sys.argv[2])
    chunks = []
    for chunk_type, filename in CHUNKS:
        data = (iconset / filename).read_bytes()
        chunks.append(chunk_type + struct.pack(">I", len(data) + 8) + data)

    body = b"".join(chunks)
    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    main()
