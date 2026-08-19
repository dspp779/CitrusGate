#!/usr/bin/env python3
"""Check the official GGM setup and refresh repo manifests when CV/Hash change."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urljoin, urlparse

REDIRECT_URL = (
    "https://tw.beanfun.com/beanfunCommon/Redirect/Redirect.aspx?ID=B258"
)
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138 Safari/537.36"
)
SETUP_NAME_RE = re.compile(r"GGMSetup_(\d+\.\d+\.\d+\.\d+)\.exe", re.IGNORECASE)
MANIFEST_PATHS = (
    Path("metadata/ggm-manifest.json"),
    Path("Resources/ggm-manifest.json"),
)


def version_from_setup_url(url: str) -> str:
    path = urlparse(url).path
    name = Path(path).name
    match = SETUP_NAME_RE.fullmatch(name)
    if not match:
        raise ValueError(f"unexpected GGM setup URL: {url}")
    return match.group(1)


def needs_update(current_version: str, remote_version: str) -> bool:
    return current_version != remote_version


def build_manifest(version: str, sha256: str, updated_at: str) -> dict[str, Any]:
    digest = sha256.lower()
    if len(digest) != 64 or any(ch not in "0123456789abcdef" for ch in digest):
        raise ValueError(f"invalid GGMWebStart.dll sha256: {sha256}")
    return {
        "schemaVersion": 1,
        "updatedAt": updated_at,
        "maplestory": {
            "ggmClientVersion": version,
            "ggmWebStartDllSha256": digest,
        },
    }


def load_manifest(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_manifest(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    path.write_text(text, encoding="utf-8")


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

    def http_error_302(self, req, fp, code, msg, headers):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)

    http_error_301 = http_error_302
    http_error_303 = http_error_302
    http_error_307 = http_error_302
    http_error_308 = http_error_302


def resolve_setup_url(redirect_url: str = REDIRECT_URL) -> str:
    request = urllib.request.Request(
        redirect_url,
        method="GET",
        headers={"User-Agent": USER_AGENT},
    )
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=30) as response:
            location = response.headers.get("Location")
            status = response.status
    except urllib.error.HTTPError as exc:
        location = exc.headers.get("Location")
        status = exc.code
        if not location:
            raise RuntimeError(f"GGM redirect had no Location: HTTP {status}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"failed to resolve GGM setup URL: {exc}") from exc
    if not location:
        raise RuntimeError(f"GGM redirect had no Location: HTTP {status}")
    return urljoin(redirect_url, location)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def download_file(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response, destination.open("wb") as out:
        shutil.copyfileobj(response, out)


def find_webstart_dll(extract_root: Path) -> Path:
    matches = [
        path
        for path in extract_root.rglob("*")
        if path.is_file() and path.name.lower() == "ggmwebstart.dll"
    ]
    if not matches:
        raise RuntimeError("innoextract did not produce GGMWebStart.dll")
    if len(matches) > 1:
        names = ", ".join(str(path.relative_to(extract_root)) for path in matches)
        raise RuntimeError(f"multiple GGMWebStart.dll files: {names}")
    return matches[0]


def extract_webstart_dll(setup_path: Path, workdir: Path) -> Path:
    extract_dir = workdir / "extracted"
    extract_dir.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(
            ["innoextract", "--quiet", "-d", str(extract_dir), str(setup_path)],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("innoextract is not installed") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        raise RuntimeError(f"innoextract failed: {detail}") from exc
    return find_webstart_dll(extract_dir)


def emit_github_output(path: Path, values: dict[str, str]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        for key, value in values.items():
            handle.write(f"{key}={value}\n")


def apply_update(repo_root: Path, github_output: Path | None) -> int:
    manifest_path = repo_root / MANIFEST_PATHS[0]
    current = load_manifest(manifest_path)
    current_version = current["maplestory"]["ggmClientVersion"]
    setup_url = resolve_setup_url()
    remote_version = version_from_setup_url(setup_url)
    print(f"current CV={current_version}")
    print(f"remote setup={setup_url}")
    print(f"remote CV={remote_version}")

    if not needs_update(current_version, remote_version):
        print("GGM manifest already matches the official setup.")
        if github_output is not None:
            emit_github_output(
                github_output,
                {"updated": "false", "version": remote_version},
            )
        return 0

    with tempfile.TemporaryDirectory(prefix="ggm-setup-") as tmp:
        workdir = Path(tmp)
        setup_path = workdir / Path(urlparse(setup_url).path).name
        print(f"downloading {setup_url}")
        download_file(setup_url, setup_path)
        dll_path = extract_webstart_dll(setup_path, workdir)
        digest = sha256_file(dll_path)
        print(f"GGMWebStart.dll sha256={digest}")

    payload = build_manifest(
        version=remote_version,
        sha256=digest,
        updated_at=utc_now(),
    )
    for relative in MANIFEST_PATHS:
        write_manifest(repo_root / relative, payload)
        print(f"updated {relative}")

    if github_output is not None:
        emit_github_output(
            github_output,
            {
                "updated": "true",
                "version": remote_version,
                "hash": digest,
            },
        )
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Download the official setup when CV changed and rewrite manifests.",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path("."),
        help="Repository root containing metadata/ggm-manifest.json",
    )
    parser.add_argument(
        "--github-output",
        type=Path,
        default=None,
        help="Append GitHub Actions outputs to this file",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if not args.apply:
        raise SystemExit("pass --apply to check and update GGM manifests")
    return apply_update(args.repo_root.resolve(), args.github_output)


if __name__ == "__main__":
    raise SystemExit(main())
