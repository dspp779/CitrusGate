#!/usr/bin/env python3
"""Exercise cmsdl 0.2.9 against a same-major, independently changed EXE.

The altered EXE is a synthetic stand-in for a client-side update. It is never
executed and is not claimed to be an authentic newer game release.
"""
import hashlib
import pathlib
import shutil
import subprocess
import sys
import urllib.request

root, client, binary = map(lambda value: pathlib.Path(value).resolve(), sys.argv[1:4])
assert hashlib.sha256(binary.read_bytes()).hexdigest() == "9e39d11a4158e322762fef2e32740a064420eeb8c583edf4a1183fbde3c197ff"
root.mkdir(parents=True, exist_ok=True)
target = root / "same-major-changed-exe"
target.mkdir(exist_ok=True)
(target / "Data/Base").mkdir(parents=True, exist_ok=True)
shutil.copy2(client / "Data/Base/Base.wz", target / "Data/Base/Base.wz")
exe = target / "MapleStory.exe"
subprocess.run(["/bin/cp", "-c", str(client / "MapleStory.exe"), str(exe)], check=True)
with exe.open("r+b") as file:
    file.seek(-1, 2)
    byte = file.read(1)[0]
    file.seek(-1, 2)
    file.write(bytes([byte ^ 1]))

def digest():
    h = hashlib.sha256()
    with exe.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

changed = digest()
reference = hashlib.sha256()
with urllib.request.urlopen("http://tw.cdnpatch.maplestory.beanfun.com/maplestory/patch/patchdir/00283/ExePatch.dat", timeout=60) as response:
    for block in iter(lambda: response.read(1024 * 1024), b""):
        reference.update(block)
for name, arguments in [
    ("query", ["--upgrade-path-check", "latest", str(target), "-v"]),
    ("download-check", ["--download", str(target), "--filter=MapleStory.exe", "--no-gui"]),
    ("patch-latest", ["--patch", "latest", str(target), "--no-gui"]),
]:
    with (root / (name + ".log")).open("wb") as log:
        subprocess.run([str(binary), "tms"] + arguments, stdout=log, stderr=log, check=True, timeout=180)
    actual = digest()
    if name == "patch-latest":
        assert actual == reference.hexdigest()
        assert actual != changed
        print("CONFIRMED: --patch latest replaces an independently changed same-major EXE with published ExePatch.dat", flush=True)
    else:
        assert actual == changed
        print("PASS:", name, "preserves changed same-major EXE", flush=True)
