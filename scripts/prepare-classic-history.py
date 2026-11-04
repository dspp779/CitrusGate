#!/usr/bin/env python3
"""Rebuild an authentic historical client from retained official NGM objects.

Run explicitly, never as a unit test. Every object and completed file is checked
against the historical manifest. No version marker is forged on current files.
"""
import base64
import concurrent.futures
import hashlib
import json
import pathlib
import shutil
import sys
import urllib.request
import zlib

manifest, current, destination = map(pathlib.Path, sys.argv[1:4])
version = manifest.stem
document = json.loads(manifest.read_text())
entries = document["files"]
chunk_size = document["chunk_size"]
base = "https://tw-ngm.maplestoryclassic.games.gamania.com/"

def matches(path, info):
    if not path.is_file() or path.stat().st_size != info["uncompressed_size"]:
        return False
    with path.open("rb") as f:
        for _, checksum in sorted(info["objects"].items(), key=lambda x: int(x[0])):
            if hashlib.sha1(f.read(chunk_size)).hexdigest() != checksum.lower():
                return False
        return f.read(1) == b""

def install(item):
    encoded, info = item
    name = base64.b64decode(encoded).decode().replace("\\", "/")
    relative = pathlib.PurePosixPath(name)
    assert not relative.is_absolute() and ".." not in relative.parts
    target = destination / relative
    if not info["objects"] or "__DIR__" in info["objects"].values():
        target.mkdir(parents=True, exist_ok=True)
        return "directory"
    if matches(target, info):
        return "verified"
    target.parent.mkdir(parents=True, exist_ok=True)
    source = current / relative
    if matches(source, info):
        shutil.copy2(source, target)
        return "reused"
    with target.with_suffix(target.suffix + ".history-part").open("wb") as f:
        for index, checksum in sorted(info["objects"].items(), key=lambda x: int(x[0])):
            url = f"{base}{encoded}.{index}.{checksum}.nxgz"
            for attempt in range(3):
                try:
                    raw = urllib.request.urlopen(url, timeout=90).read()
                    block = zlib.decompress(raw)
                    assert hashlib.sha1(block).hexdigest() == checksum.lower()
                    break
                except Exception:
                    if attempt == 2:
                        raise
            f.write(block)
    partial = target.with_suffix(target.suffix + ".history-part")
    assert partial.stat().st_size == info["uncompressed_size"]
    assert matches(partial, info), name
    partial.replace(target)
    print("downloaded and verified", name, flush=True)
    return "downloaded"

destination.mkdir(parents=True, exist_ok=True)
counts = {}
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    for result in pool.map(install, entries.items()):
        counts[result] = counts.get(result, 0) + 1
(destination / "2982.manifest.hash").write_text(version)
print(json.dumps({"manifest": version, "files": len(entries), "results": counts}), flush=True)
