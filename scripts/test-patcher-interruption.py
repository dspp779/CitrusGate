#!/usr/bin/env python3
"""Fault injection against the pinned *real* patcher binaries.

These are synthetic protocol fixtures, not historical-client certification.
All network responses are served on loopback; the test certificate is trusted
only by the child nxdl invocation using --allow-insecure.
"""
import base64
import hashlib
import http.server
import json
import pathlib
import shutil
import signal
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import zlib

root = pathlib.Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
upstream = pathlib.Path(sys.argv[2]).resolve()
for name, expected in {
    "nxdl_darwin": "e200004877ce629a1f3103da2bbb1c3235c15dafcfe7996ac0907e09f481e34e",
    "cmsdl_darwin": "9e39d11a4158e322762fef2e32740a064420eeb8c583edf4a1183fbde3c197ff",
}.items():
    assert hashlib.sha256((upstream / name).read_bytes()).hexdigest() == expected, "unexpected patcher binary"
old_hash, new_hash = "1" * 32, "2" * 32
half = 16 * 1024 * 1024
old_data = b"A" * half + b"B" * half
new_data = b"B" * half + b"A" * half
patch = b"\x28" + struct.pack("<II", half, half) + b"\x28" + struct.pack("<II", 0, half) + b"\0"
patch_hash = hashlib.sha1(patch).hexdigest()
names = [f"Data/file-{i:03d}.wz" for i in range(64)]
manifest = {"version": "1.0", "files": {}}
for name in names:
    encoded = base64.b64encode(name.encode()).decode()
    manifest["files"][encoded] = {"objects": {"0": patch_hash}, "hash": patch_hash,
        "object_sizes": {"0": len(zlib.compress(patch))},
        "uncompressed_size": len(patch), "compressed_size": len(zlib.compress(patch))}

cert, key = root / "test-cert.pem", root / "test-key.pem"
config = root / "test-cert.cnf"
config.write_text("[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=v3\n[dn]\nCN=ngmapi.nexon.com\n[v3]\nsubjectAltName=DNS:ngmapi.nexon.com\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
    "-config", str(config), "-keyout", str(key), "-out", str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(cert, key)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_CONNECT(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.flush()
        try:
            connection = tls.wrap_socket(self.connection, server_side=True)
            Handler(connection, self.client_address, self.server)
        except ssl.SSLError:
            pass
        self.close_connection = True

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path.startswith("/game-info/"):
            body = json.dumps({"game_name": "synthetic fault fixture", "setup_file_url": "http://fixture.invalid", "manifest_name": new_hash}).encode()
        elif path == f"/{new_hash}-{old_hash}":
            body = json.dumps(manifest).encode()
        elif path.endswith(".nxdelta"):
            body = zlib.compress(patch)
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()

def populate(directory):
    directory.mkdir(parents=True)
    for name in names:
        file = directory / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(old_data)
    (directory / "2982.manifest.hash").write_text(old_hash)

def start_nx(directory, log):
    return subprocess.Popen([str(upstream / "nxdl_darwin"), "tms_cw", "--patch", str(directory),
        "--proxy", f"http://127.0.0.1:{server.server_port}", "--allow-insecure"], stdout=log, stderr=log)

def first_changed(directory):
    for name in names:
        file = directory / name
        if file.exists():
            with file.open("rb") as f:
                if f.read(1) == b"B":
                    return name

nx = root / "nx-unprotected"
if nx.exists():
    shutil.rmtree(nx)
populate(nx)
with (root / "nx-interrupted.log").open("wb") as log:
    process = start_nx(nx, log)
    deadline = time.monotonic() + 60
    changed = None
    while time.monotonic() < deadline and process.poll() is None:
        changed = first_changed(nx)
        if changed:
            process.send_signal(signal.SIGSTOP)
            break
        time.sleep(0.001)
    if not changed:
        process.kill()
        process.wait()
        raise RuntimeError("nx fixture did not reach partial apply; inspect nx-interrupted.log")
    marker = (nx / "2982.manifest.hash").read_text()
    process.kill()
    process.wait()
assert marker == old_hash, "missed partial-apply boundary"
with (root / "nx-retry.log").open("wb") as log:
    process = start_nx(nx, log)
    assert process.wait(timeout=120) == 0
with (nx / changed).open("rb") as f:
    assert f.read(1) == b"A", "fixture did not reproduce unsafe reapplication"
print("CONFIRMED nxdl prerelease9: killed after file replacement; direct retry exits 0 with incorrect output", flush=True)

# Recreate a clean old tree. An isolated transaction retry starts here rather
# than reusing nx-unprotected's partially applied client.
safe = root / "nx-clean-retry"
if safe.exists():
    shutil.rmtree(safe)
populate(safe)
with (root / "nx-clean-retry.log").open("wb") as log:
    assert start_nx(safe, log).wait(timeout=120) == 0
expected = hashlib.sha256(new_data).hexdigest()
for name in names:
    assert hashlib.sha256((safe / name).read_bytes()).hexdigest() == expected
print("PASS nxdl: fresh-source retry produces all 64 expected file hashes", flush=True)

# The published cmsdl patch-file entry point exercises its actual parser,
# checksum handling, staged application, and retry after partial application.
reverse = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))
def ms_crc(data):
    reflected = zlib.crc32(data.translate(reverse), 0xFFFFFFFF) ^ 0xFFFFFFFF
    return int(f"{reflected:032b}"[::-1], 2)

cms = root / "cms-partial"
if cms.exists():
    shutil.rmtree(cms)
populate(cms)
payload = b"C" * (32 * 1024 * 1024)
checksum = ms_crc(payload)
patch_file = root / "synthetic.patch"
compressor = zlib.compressobj(1)
with patch_file.open("wb") as f:
    f.write(b"WzPatch\x1a" + struct.pack("<II", 1, 0))
    for name in names:
        f.write(compressor.compress(name.encode() + b"\0" + struct.pack("<II", len(payload), checksum)))
        f.write(compressor.compress(payload))
    f.write(compressor.flush())

def start_cms(log):
    return subprocess.Popen([str(upstream / "cmsdl_darwin"), "tms", "--patch-file", str(patch_file), str(cms), "--no-gui"], stdout=log, stderr=log)

with (root / "cms-interrupted.log").open("wb") as log:
    process = start_cms(log)
    deadline = time.monotonic() + 60
    changed = None
    while time.monotonic() < deadline and process.poll() is None:
        for name in names:
            with (cms / name).open("rb") as f:
                if f.read(1) == b"C":
                    changed = name
                    process.send_signal(signal.SIGSTOP)
                    break
        if changed:
            break
        time.sleep(0.001)
    if not changed:
        process.kill()
        process.wait()
        raise RuntimeError("cms fixture did not reach partial apply; inspect cms-interrupted.log")
    process.kill()
    process.wait()
with (root / "cms-retry.log").open("wb") as log:
    assert start_cms(log).wait(timeout=120) == 0
expected = hashlib.sha256(payload).hexdigest()
for name in names:
    assert hashlib.sha256((cms / name).read_bytes()).hexdigest() == expected
print("PASS cmsdl 0.2.9: actual patch-file apply killed mid-commit; retry produces all 64 expected file hashes (synthetic create records)", flush=True)
server.shutdown()
