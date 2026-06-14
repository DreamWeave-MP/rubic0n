#!/usr/bin/env python3
"""Submit one release archive to VirusTotal and write TSV metadata.

This intentionally only reads the archive. The workflow submits the package after
packaging/validation and uploads that same path as the GitHub Actions artifact.
Recompressing after scanner submission would make the scanner result decorative,
which is not a useful security property.
"""

import argparse
import email.utils
import hashlib
import http.client
import json
import math
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Dict, List, NoReturn, Optional, Tuple


VT_FILES_URL = "https://www.virustotal.com/api/v3/files"
VT_ANALYSES_URL = "https://www.virustotal.com/api/v3/analyses/{analysis_id}"
TSV_HEADER = "archive\tsha256\tanalysis_id\tanalysis_url\n"
DEFAULT_ANALYSIS_TIMEOUT = 1800.0
DEFAULT_POLL_INTERVAL = 15.0
VT_STATS_KEYS = (
    "malicious",
    "suspicious",
    "harmless",
    "undetected",
    "timeout",
    "confirmed-timeout",
    "failure",
    "type-unsupported",
)
MAX_DETECTIONS_TO_LOG = 20
HTTP_TRANSIENT_RETRY_INITIAL_DELAY = 5.0
HTTP_RATE_LIMIT_RETRY_INITIAL_DELAY = DEFAULT_POLL_INTERVAL
HTTP_RETRY_MAX_DELAY = 20.0
RETRYABLE_RESPONSE_READ_EXCEPTIONS = (
    TimeoutError,
    socket.timeout,
    ConnectionError,
    http.client.HTTPException,
)


def fail(message: str) -> NoReturn:
    raise SystemExit(f"submit-virustotal: {message}")


def log(message: str) -> None:
    print(message, file=sys.stderr)


def parse_positive_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("expected a positive number")
    if not math.isfinite(parsed) or parsed <= 0.0:
        raise argparse.ArgumentTypeError("expected a positive number")
    return parsed


def parse_nonnegative_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("expected a non-negative integer")
    if parsed < 0:
        raise argparse.ArgumentTypeError("expected a non-negative integer")
    return parsed


def env_positive_float(name: str, default: float) -> float:
    value = os.environ.get(name, "")
    if not value:
        return default
    try:
        return parse_positive_float(value)
    except argparse.ArgumentTypeError as error:
        fail(f"{name} is invalid: {error}")


def env_nonnegative_int(name: str, default: int) -> int:
    value = os.environ.get(name, "")
    if not value:
        return default
    try:
        return parse_nonnegative_int(value)
    except argparse.ArgumentTypeError as error:
        fail(f"{name} is invalid: {error}")


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


def parse_retry_after(value: str) -> Optional[float]:
    stripped = value.strip()
    if not stripped:
        return None

    try:
        seconds = float(stripped)
    except ValueError:
        seconds = None
    if seconds is not None:
        if math.isfinite(seconds) and seconds >= 0.0:
            return seconds
        return None

    parsed_date = email.utils.parsedate_tz(stripped)
    if parsed_date is None:
        return None
    return max(0.0, email.utils.mktime_tz(parsed_date) - time.time())


def retry_after_from_headers(headers: Any) -> Optional[float]:
    if headers is None:
        return None
    value = headers.get("Retry-After")
    if value is None:
        return None
    return parse_retry_after(value)


def capped_backoff_delay(initial_delay: float, retry_number: int) -> float:
    exponent = min(retry_number, 10)
    return min(HTTP_RETRY_MAX_DELAY, initial_delay * (2.0 ** exponent))


def is_retryable_http_status(status: int) -> bool:
    return status == 429 or 500 <= status <= 599


def http_retry_delay(status: int, headers: Any, retry_number: int) -> float:
    retry_after = retry_after_from_headers(headers)
    if retry_after is not None:
        return min(HTTP_RETRY_MAX_DELAY, retry_after)
    if status == 429:
        return capped_backoff_delay(HTTP_RATE_LIMIT_RETRY_INITIAL_DELAY, retry_number)
    return capped_backoff_delay(HTTP_TRANSIENT_RETRY_INITIAL_DELAY, retry_number)


def describe_retryable_read_error(error: BaseException) -> str:
    if isinstance(error, http.client.IncompleteRead):
        try:
            partial_size = len(error.partial)
        except TypeError:
            partial_size = 0
        return (
            f"{error.__class__.__name__}: "
            f"{partial_size} byte(s) read, {error.expected!r} more expected"
        )
    return f"{error.__class__.__name__}: {error}"


def wait_before_retry(
    *,
    failure_context: str,
    retry_deadline: float,
    delay: float,
    attempt_count: int,
    reason: str,
) -> None:
    remaining = retry_deadline - time.monotonic()
    if remaining <= 0.0:
        fail(
            f"{failure_context} failed after {attempt_count} attempt(s): "
            f"retry budget expired after retryable {reason}"
        )
    if delay > remaining:
        fail(
            f"{failure_context} failed after {attempt_count} attempt(s): "
            f"retryable {reason}; retry delay {delay:.1f}s exceeds "
            f"remaining retry budget {remaining:.1f}s"
        )

    log(
        f"{failure_context} got retryable {reason}; "
        f"retrying in {delay:.1f}s (attempt {attempt_count + 1})"
    )
    time.sleep(delay)


def read_json_response(
    request: urllib.request.Request,
    *,
    timeout: float,
    failure_context: str,
    retry_deadline: Optional[float] = None,
) -> Dict[str, Any]:
    if retry_deadline is None:
        retry_deadline = time.monotonic() + timeout

    retry_number = 0
    while True:
        remaining = retry_deadline - time.monotonic()
        if remaining <= 0.0:
            fail(f"{failure_context} retry budget expired before request")

        try:
            with urllib.request.urlopen(request, timeout=min(timeout, remaining)) as response:
                response_body = response.read().decode("utf-8")
            break
        except urllib.error.HTTPError as error:
            try:
                error_body = error.read().decode("utf-8", errors="replace")
            except RETRYABLE_RESPONSE_READ_EXCEPTIONS as read_error:
                read_error_reason = describe_retryable_read_error(read_error)
                if not is_retryable_http_status(error.code):
                    fail(
                        f"{failure_context} failed with HTTP {error.code}; "
                        f"also failed to read error body: {read_error_reason}"
                    )
                reason = (
                    f"HTTP {error.code}; failed to read error body: "
                    f"{read_error_reason}"
                )
            else:
                if not is_retryable_http_status(error.code):
                    fail(f"{failure_context} failed with HTTP {error.code}: {error_body}")
                reason = f"HTTP {error.code}: {error_body}"

            delay = http_retry_delay(error.code, error.headers, retry_number)
            wait_before_retry(
                failure_context=failure_context,
                retry_deadline=retry_deadline,
                delay=delay,
                attempt_count=retry_number + 1,
                reason=reason,
            )
        except urllib.error.URLError as error:
            delay = capped_backoff_delay(HTTP_TRANSIENT_RETRY_INITIAL_DELAY, retry_number)
            wait_before_retry(
                failure_context=failure_context,
                retry_deadline=retry_deadline,
                delay=delay,
                attempt_count=retry_number + 1,
                reason=str(error),
            )
        except RETRYABLE_RESPONSE_READ_EXCEPTIONS as error:
            delay = capped_backoff_delay(HTTP_TRANSIENT_RETRY_INITIAL_DELAY, retry_number)
            wait_before_retry(
                failure_context=failure_context,
                retry_deadline=retry_deadline,
                delay=delay,
                attempt_count=retry_number + 1,
                reason=describe_retryable_read_error(error),
            )
        retry_number += 1

    try:
        payload = json.loads(response_body)
    except json.JSONDecodeError as error:
        fail(f"{failure_context} response was not JSON: {error}: {response_body}")
    if not isinstance(payload, dict):
        fail(f"{failure_context} response was not a JSON object: {payload!r}")
    return payload


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

    payload = read_json_response(
        request, timeout=timeout, failure_context="VirusTotal upload"
    )

    data = payload.get("data")
    if not isinstance(data, dict):
        fail(f"VirusTotal response is missing data object: {payload!r}")
    analysis_id = data.get("id")
    if not isinstance(analysis_id, str) or not analysis_id:
        fail(f"VirusTotal response is missing data.id: {payload!r}")
    return analysis_id


def analysis_url(analysis_id: str) -> str:
    return f"https://www.virustotal.com/gui/file-analysis/{analysis_id}"


def fetch_analysis(
    analysis_id: str,
    *,
    api_key: str,
    timeout: float,
    retry_deadline: Optional[float] = None,
) -> Dict[str, Any]:
    quoted_id = urllib.parse.quote(analysis_id, safe="")
    request = urllib.request.Request(
        VT_ANALYSES_URL.format(analysis_id=quoted_id),
        method="GET",
        headers={
            "x-apikey": api_key,
            "User-Agent": "Dreamweave-LuaJIT-CI/1.0",
        },
    )
    return read_json_response(
        request,
        timeout=timeout,
        failure_context="VirusTotal analysis polling",
        retry_deadline=retry_deadline,
    )


def extract_stats(stats_payload: Any) -> Dict[str, int]:
    if stats_payload is None:
        return {}
    if not isinstance(stats_payload, dict):
        fail(f"VirusTotal analysis stats are not an object: {stats_payload!r}")

    stats = {}
    for key, value in stats_payload.items():
        if not isinstance(key, str):
            fail(f"VirusTotal analysis stats contain a non-string key: {stats_payload!r}")
        if type(value) is not int or value < 0:
            fail(
                f"VirusTotal analysis stat {key!r} is not a "
                f"non-negative integer: {value!r}"
            )
        stats[key] = value
    return stats


def extract_detection_summaries(results_payload: Any) -> List[str]:
    if results_payload is None:
        return []
    if not isinstance(results_payload, dict):
        return []

    detections = []
    for engine_name in sorted(results_payload):
        result = results_payload[engine_name]
        if not isinstance(result, dict):
            continue
        category = result.get("category")
        if category not in {"malicious", "suspicious"}:
            continue

        details = []
        engine_result = result.get("result")
        method = result.get("method")
        engine_update = result.get("engine_update")
        if isinstance(engine_result, str) and engine_result:
            details.append(engine_result)
        if isinstance(method, str) and method:
            details.append(f"method={method}")
        if isinstance(engine_update, str) and engine_update:
            details.append(f"update={engine_update}")

        summary = f"{engine_name}: {category}"
        if details:
            summary += f" ({', '.join(details)})"
        detections.append(summary)
    return detections


def extract_analysis_verdict(payload: Dict[str, Any]) -> Dict[str, Any]:
    data = payload.get("data")
    if not isinstance(data, dict):
        fail(f"VirusTotal analysis response is missing data object: {payload!r}")
    attributes = data.get("attributes")
    if not isinstance(attributes, dict):
        fail(f"VirusTotal analysis response is missing data.attributes: {payload!r}")
    status = attributes.get("status")
    if not isinstance(status, str) or not status:
        fail(f"VirusTotal analysis response is missing status: {payload!r}")

    meaningful_name = attributes.get("meaningful_name")
    if not isinstance(meaningful_name, str):
        meaningful_name = ""

    return {
        "status": status,
        "stats": extract_stats(attributes.get("stats")),
        "meaningful_name": meaningful_name,
        "detections": extract_detection_summaries(attributes.get("results")),
    }


def wait_for_analysis(
    analysis_id: str,
    *,
    api_key: str,
    request_timeout: float,
    analysis_timeout: float,
    poll_interval: float,
) -> Dict[str, Any]:
    deadline = time.monotonic() + analysis_timeout
    last_status = "unknown"

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0.0:
            fail(
                f"VirusTotal analysis {analysis_id} did not complete within "
                f"{analysis_timeout:.1f}s; last status was {last_status!r}"
            )

        verdict = extract_analysis_verdict(
            fetch_analysis(
                analysis_id,
                api_key=api_key,
                timeout=request_timeout,
                retry_deadline=deadline,
            )
        )
        last_status = verdict["status"]
        if last_status == "completed":
            if not verdict["stats"]:
                fail(f"VirusTotal completed analysis has no verdict stats: {analysis_id}")
            return verdict

        remaining = deadline - time.monotonic()
        if remaining <= 0.0:
            fail(
                f"VirusTotal analysis {analysis_id} did not complete within "
                f"{analysis_timeout:.1f}s; last status was {last_status!r}"
            )
        sleep_for = min(poll_interval, remaining)
        log(
            f"VirusTotal analysis {analysis_id} status is {last_status!r}; "
            f"polling again in {sleep_for:.1f}s"
        )
        time.sleep(sleep_for)


def format_stats(stats: Dict[str, int]) -> str:
    parts = []
    seen = set()
    for key in VT_STATS_KEYS:
        if key in stats:
            parts.append(f"{key}={stats[key]}")
            seen.add(key)
    for key in sorted(key for key in stats if key not in seen):
        parts.append(f"{key}={stats[key]}")
    return ", ".join(parts) if parts else "(no stats)"


def log_verdict(
    *,
    archive_name: str,
    analysis_id: str,
    verdict: Dict[str, Any],
    max_malicious: int,
    max_suspicious: int,
) -> None:
    stats = verdict["stats"]
    detections = verdict["detections"]
    log(f"VirusTotal analysis completed for {archive_name}: {analysis_url(analysis_id)}")
    if verdict["meaningful_name"]:
        log(f"VirusTotal meaningful name: {verdict['meaningful_name']}")
    log(f"VirusTotal stats: {format_stats(stats)}")
    log(
        "VirusTotal policy thresholds: "
        f"malicious <= {max_malicious}, suspicious <= {max_suspicious}"
    )
    if detections:
        for detection in detections[:MAX_DETECTIONS_TO_LOG]:
            log(f"VirusTotal detection: {detection}")
        omitted = len(detections) - MAX_DETECTIONS_TO_LOG
        if omitted > 0:
            log(f"VirusTotal detections omitted from log: {omitted}")
    else:
        log("VirusTotal detections: none categorized as malicious or suspicious")


def append_step_summary(
    *,
    summary_path: str,
    archive_name: str,
    sha256: str,
    analysis_id: str,
    verdict: Dict[str, Any],
    max_malicious: int,
    max_suspicious: int,
) -> None:
    if not summary_path:
        return

    detections = verdict["detections"]
    with Path(summary_path).open("a", encoding="utf-8") as handle:
        handle.write(f"### VirusTotal verdict: `{archive_name}`\n\n")
        handle.write(f"- SHA256: `{sha256}`\n")
        handle.write(f"- Analysis: [{analysis_id}]({analysis_url(analysis_id)})\n")
        if verdict["meaningful_name"]:
            handle.write(f"- Meaningful name: `{verdict['meaningful_name']}`\n")
        handle.write(f"- Stats: `{format_stats(verdict['stats'])}`\n")
        handle.write(
            "- Policy thresholds: "
            f"malicious <= `{max_malicious}`, suspicious <= `{max_suspicious}`\n"
        )
        if detections:
            handle.write("- Malicious/suspicious engine results:\n")
            for detection in detections[:MAX_DETECTIONS_TO_LOG]:
                handle.write(f"  - `{detection}`\n")
            omitted = len(detections) - MAX_DETECTIONS_TO_LOG
            if omitted > 0:
                handle.write(f"  - _{omitted} additional results omitted._\n")
        else:
            handle.write("- Malicious/suspicious engine results: none\n")
        handle.write("\n")


def enforce_verdict_policy(
    verdict: Dict[str, Any], *, max_malicious: int, max_suspicious: int
) -> None:
    stats = verdict["stats"]
    malicious = require_policy_stat(stats, "malicious")
    suspicious = require_policy_stat(stats, "suspicious")
    failures = []
    if malicious > max_malicious:
        failures.append(f"malicious={malicious} > {max_malicious}")
    if suspicious > max_suspicious:
        failures.append(f"suspicious={suspicious} > {max_suspicious}")
    if failures:
        fail("VirusTotal verdict exceeds policy: " + "; ".join(failures))


def require_policy_stat(stats: Dict[str, Any], key: str) -> int:
    if key not in stats:
        fail(f"VirusTotal verdict is missing required stat {key!r}: {format_stats(stats)}")
    value = stats[key]
    if type(value) is not int or value < 0:
        fail(f"VirusTotal verdict stat {key!r} is not a non-negative integer: {value!r}")
    return value


def write_tsv(output: Path, *, archive_name: str, sha256: str, analysis_id: str) -> None:
    row = f"{archive_name}\t{sha256}\t{analysis_id}\t{analysis_url(analysis_id)}\n"
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
    parser.add_argument("--timeout", type=parse_positive_float, default=120.0)
    parser.add_argument(
        "--analysis-timeout",
        type=parse_positive_float,
        default=env_positive_float("VT_ANALYSIS_TIMEOUT", DEFAULT_ANALYSIS_TIMEOUT),
        help="seconds to wait for VirusTotal analysis completion; default from VT_ANALYSIS_TIMEOUT or 1800",
    )
    parser.add_argument(
        "--poll-interval",
        type=parse_positive_float,
        default=env_positive_float("VT_POLL_INTERVAL", DEFAULT_POLL_INTERVAL),
        help="seconds between VirusTotal analysis polling requests; default from VT_POLL_INTERVAL or 15",
    )
    parser.add_argument(
        "--max-malicious",
        type=parse_nonnegative_int,
        default=env_nonnegative_int("VT_MAX_MALICIOUS", 0),
        help="maximum allowed malicious verdict count; default from VT_MAX_MALICIOUS or 0",
    )
    parser.add_argument(
        "--max-suspicious",
        type=parse_nonnegative_int,
        default=env_nonnegative_int("VT_MAX_SUSPICIOUS", 0),
        help="maximum allowed suspicious verdict count; default from VT_MAX_SUSPICIOUS or 0",
    )
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
    verdict = wait_for_analysis(
        analysis_id,
        api_key=api_key,
        request_timeout=args.timeout,
        analysis_timeout=args.analysis_timeout,
        poll_interval=args.poll_interval,
    )
    log_verdict(
        archive_name=archive.name,
        analysis_id=analysis_id,
        verdict=verdict,
        max_malicious=args.max_malicious,
        max_suspicious=args.max_suspicious,
    )
    append_step_summary(
        summary_path=os.environ.get("GITHUB_STEP_SUMMARY", ""),
        archive_name=archive.name,
        sha256=sha256,
        analysis_id=analysis_id,
        verdict=verdict,
        max_malicious=args.max_malicious,
        max_suspicious=args.max_suspicious,
    )
    enforce_verdict_policy(
        verdict,
        max_malicious=args.max_malicious,
        max_suspicious=args.max_suspicious,
    )
    write_tsv(args.output, archive_name=archive.name, sha256=sha256, analysis_id=analysis_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
