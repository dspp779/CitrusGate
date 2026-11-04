#!/usr/bin/env python3
"""Rebuild a historical TMS client; authenticate every file with its manifest.

The manifest must be an archived official productInfo.json. Only HTTPS official
CDN URLs are accepted. Downloaded executable files are never executed.
"""
import concurrent.futures
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

manifest_path, current, destination = map(pathlib.Path, sys.argv[1:4])
allowed_missing = set(sys.argv[5:]) if sys.argv[4:5] == ["--allow-missing"] else set()
manifest = json.loads(manifest_path.read_text())
base = manifest["baseUrl"] + manifest["executionPath"].rsplit("/", 1)[0] + "/"
parsed = urllib.parse.urlsplit(base)
assert parsed.scheme == "https" and parsed.hostname == "maplestory-download.beanfun.com"
destination.mkdir(parents=True, exist_ok=True)
lock = threading.Lock()
started = time.monotonic()
stats = {"version": manifest["version"], "verified": 0, "reused": 0, "downloaded": 0, "network_bytes": 0, "unavailable": []}
progress = destination.parent / (destination.name + "-progress.json")

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def publish():
    with lock:
        snapshot = dict(stats, elapsed_seconds=round(time.monotonic() - started))
        tmp = progress.with_suffix(".tmp")
        tmp.write_text(json.dumps(snapshot))
        tmp.replace(progress)

def install(entry):
    name, size, expected = entry["path"], entry["sizeInBytes"], entry["sha256"].lower()
    relative = pathlib.PurePosixPath(name.replace("\\", "/"))
    assert not relative.is_absolute() and all(p not in ("..", ".") for p in relative.parts)
    file = destination / relative
    file.parent.mkdir(parents=True, exist_ok=True)
    if file.is_file() and file.stat().st_size == size and digest(file) == expected:
        with lock:
            stats["verified"] += 1
        publish()
        return
    source = current / relative
    if source.is_file() and source.stat().st_size == size and digest(source) == expected:
        if file.exists():
            file.unlink()
        # APFS clone only; a different volume falls back to ordinary copying.
        result = subprocess.run(["/bin/cp", "-c", str(source), str(file)], capture_output=True)
        if result.returncode:
            import shutil
            shutil.copy2(source, file)
        with lock:
            stats["reused"] += 1
            stats["verified"] += 1
        publish()
        return
    partial = file.with_name(file.name + ".history-download")
    receipt = partial.with_name(partial.name + ".json")
    segment_size = 16 * 1024 * 1024
    count = (size + segment_size - 1) // segment_size
    completed = set()
    if partial.exists() and receipt.exists():
        record = json.loads(receipt.read_text())
        if record.get("sha256") == expected and partial.stat().st_size == size:
            completed = set(record["completed"])
    fd = os.open(partial, os.O_CREAT | os.O_RDWR, 0o600)
    os.ftruncate(fd, size)
    segment_lock = threading.Lock()
    url = base + urllib.parse.quote(str(relative), safe="/")

    def segment(index):
        start = index * segment_size
        end = min(size, start + segment_size) - 1
        offset = start
        for attempt in range(6):
            try:
                req = urllib.request.Request(url, headers={"Range": f"bytes={offset}-{end}", "Accept-Encoding": "identity"})
                with urllib.request.urlopen(req, timeout=60) as response:
                    assert response.status == 206 and response.headers.get("Content-Range", "").startswith(f"bytes {offset}-"), "range response mismatch"
                    while offset <= end:
                        data = response.read(min(1024 * 1024, end - offset + 1))
                        if not data:
                            raise IOError("truncated segment")
                        written = 0
                        while written < len(data):
                            written += os.pwrite(fd, data[written:], offset + written)
                        offset += len(data)
                        with lock:
                            stats["network_bytes"] += len(data)
                with segment_lock:
                    completed.add(index)
                    tmp = receipt.with_suffix(".tmp")
                    tmp.write_text(json.dumps({"sha256": expected, "completed": sorted(completed)}))
                    tmp.replace(receipt)
                publish()
                return
            except Exception:
                if attempt == 5:
                    raise
                time.sleep(min(attempt + 1, 5))
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(segment, (i for i in range(count) if i not in completed)))
    finally:
        os.close(fd)
    actual = digest(partial)
    if actual != expected and name in allowed_missing:
        evidence = destination.parent / (destination.name + "-unavailable-" + name.replace("/", "_"))
        partial.replace(evidence)
        receipt.unlink(missing_ok=True)
        with lock:
            stats["unavailable"].append({"path": name, "expected": expected, "actual": actual})
        publish()
        print("UNAVAILABLE (excluded from client):", name, actual, flush=True)
        return
    assert actual == expected, "historical digest mismatch: " + name
    partial.replace(file)
    receipt.unlink(missing_ok=True)
    with lock:
        stats["downloaded"] += 1
        stats["verified"] += 1
    publish()
    print("verified", name, size, flush=True)

publish()
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    list(pool.map(install, manifest["files"]))
assert stats["verified"] + len(stats["unavailable"]) == len(manifest["files"])
print("AUTHENTICATED historical files; explicit missing files recorded" if stats["unavailable"] else "PASS authentic historical client", json.dumps(stats), flush=True)
