#!/usr/bin/env python3
"""Submit one release archive to VirusTotal and write TSV metadata.

This intentionally only reads the archive. The workflow submits the package after
packaging/validation and uploads that same path as the GitHub Actions artifact.
Recompressing after scanner submission would make the scanner result decorative,
which is not a useful security property.
"""

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Tuple


VT_FILES_URL = "https://www.virustotal.com/api/v3/files"
TSV_HEADER = "archive\tsha256\tanalysis_id\tanalysis_url\n"


def fail(message: str) -> None:
    raise SystemExit(f"submit-virustotal: {message}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def multipart_file_body(path: Path) -> Tuple[bytes, str]:
    # The LuaJIT release zips are small. Keeping this standard-library-only is
    # more useful than adding per-shell curl fragments that then disagree on
    # quoting rules for Windows paths. Delightful though those are.
    boundary = f"----luajit-vt-{uuid.uuid4().hex}"
    header = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{path.name}"\r\n'
        "Content-Type: application/zip\r\n"
        "\r\n"
    ).encode("utf-8")
    footer = f"\r\n--{boundary}--\r\n".encode("utf-8")
    return header + path.read_bytes() + footer, boundary


def submit_to_virustotal(path: Path, *, api_key: str, timeout: float) -> str:
    body, boundary = multipart_file_body(path)
    request = urllib.request.Request(
        VT_FILES_URL,
        data=body,
        method="POST",
        headers={
            "x-apikey": api_key,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "User-Agent": "Dreamweave-LuaJIT-CI/1.0",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response_body = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        error_body = error.read().decode("utf-8", errors="replace")
        fail(f"VirusTotal upload failed with HTTP {error.code}: {error_body}")
    except urllib.error.URLError as error:
        fail(f"VirusTotal upload failed: {error}")

    try:
        payload = json.loads(response_body)
    except json.JSONDecodeError as error:
        fail(f"VirusTotal response was not JSON: {error}: {response_body}")

    data = payload.get("data")
    if not isinstance(data, dict):
        fail(f"VirusTotal response is missing data object: {payload!r}")
    analysis_id = data.get("id")
    if not isinstance(analysis_id, str) or not analysis_id:
        fail(f"VirusTotal response is missing data.id: {payload!r}")
    return analysis_id


def write_tsv(output: Path, *, archive_name: str, sha256: str, analysis_id: str) -> None:
    analysis_url = f"https://www.virustotal.com/gui/file-analysis/{analysis_id}"
    row = f"{archive_name}\t{sha256}\t{analysis_id}\t{analysis_url}\n"
    if str(output) == "-":
        sys.stdout.write(TSV_HEADER)
        sys.stdout.write(row)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(TSV_HEADER + row, encoding="utf-8")
    print(row.rstrip("\n"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path, help="zip archive to submit")
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="TSV metadata output path, or '-' for stdout",
    )
    parser.add_argument(
        "--api-key-env",
        default="VT_API_KEY",
        help="environment variable containing the VirusTotal API key",
    )
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()

    archive = args.archive.resolve()
    if not archive.is_file():
        fail(f"archive is missing: {archive}")
    if archive.suffix.lower() != ".zip":
        fail(f"expected a .zip archive, got: {archive}")

    api_key = os.environ.get(args.api_key_env, "")
    if not api_key:
        fail(f"{args.api_key_env} is required for release-publishing VirusTotal submission")

    sha256 = sha256_file(archive)
    analysis_id = submit_to_virustotal(archive, api_key=api_key, timeout=args.timeout)
    write_tsv(args.output, archive_name=archive.name, sha256=sha256, analysis_id=analysis_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
