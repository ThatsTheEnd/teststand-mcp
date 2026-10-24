"""Collects release download counts, own-download records and repository traffic.

Run daily by .github/workflows/pages.yml. It appends to three CSV files in the `stats`
branch worktree:

    downloads.csv      cumulative download_count of every release asset, one snapshot per
                       date, appended only when a count changed
    own-downloads.csv  downloads made by the repository's own release workflow, taken from
                       the `own-downloads` artifacts of its runs (see OWN_DOWNLOADS_ARTIFACT)
    traffic.csv        daily views and clones; only with the optional traffic token

Net installs are derived from these files by installs_per_day(), which build.py calls.
Standard library only. Any API error exits non-zero before a file is written.

Run the tests from the repository root with
    python -m unittest discover -s .github/stats
or from .github/stats with
    python -m unittest
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Callable, Iterable, Mapping, Protocol

API_ROOT = "https://api.github.com"
API_VERSION = "2022-11-28"
REQUEST_TIMEOUT_SECONDS = 30
PAGE_SIZE = 100
MAX_PAGES = 10
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_ARTIFACT_BYTES = 1024 * 1024
REDIRECT_STATUSES = (301, 302, 303, 307, 308)

# The artifact contract with release.yml: an artifact of this name holds this file,
# whose schema is documented in docs/specs/plugin-install-and-release-workflow.md (AC-18).
OWN_DOWNLOADS_ARTIFACT = "own-downloads"
OWN_DOWNLOADS_FILE = "own-downloads.json"

# Whether downloads of a DRAFT release raise download_count is measured on the first release
# (plan, PR A checklist). Until then drafts are assumed to count, so they are subtracted
# together with the published ones; installs_per_day() clamps at zero if they do not.
SUBTRACT_DRAFT_DOWNLOADS = True

DOWNLOADS_FILE = "downloads.csv"
DOWNLOADS_COLUMNS = ("date", "tag", "asset", "download_count")
OWN_DOWNLOADS_CSV = "own-downloads.csv"
OWN_DOWNLOADS_COLUMNS = ("run_id", "date", "asset", "draft", "published")
TRAFFIC_FILE = "traffic.csv"
TRAFFIC_COLUMNS = ("date", "metric", "count", "uniques")
TRAFFIC_METRICS = ("views", "clones")

REPO_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SAFE_NAME_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,200}$")
TIMESTAMP_DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T")


class CollectError(Exception):
    """The run must fail: an API error, a corrupt stats file or an unusable response."""


class OwnRecordError(ValueError):
    """One own-downloads record does not follow the documented schema."""


@dataclass(frozen=True)
class AssetCount:
    tag: str
    asset: str
    count: int


@dataclass(frozen=True)
class OwnRecord:
    run_id: str
    day: date
    asset: str
    draft: int
    published: int


@dataclass(frozen=True)
class TrafficDay:
    day: date
    metric: str
    count: int
    uniques: int


@dataclass
class CollectResult:
    changed_files: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


# --------------------------------------------------------------------------
#  Pure: JSON -> typed rows
# --------------------------------------------------------------------------

def utc_date(moment: datetime) -> date:
    """The UTC calendar date of an aware moment; a naive one is ambiguous, so it is refused."""
    if moment.tzinfo is None:
        raise ValueError("a naive datetime has no time zone; pass an aware one")
    return moment.astimezone(timezone.utc).date()


def _is_count(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def asset_counts_from_releases(releases: object) -> tuple[list[AssetCount], list[str]]:
    """Cumulative counts of the assets of published releases, plus warnings for skipped names."""
    if not isinstance(releases, list):
        raise CollectError("the releases response is not a list")
    counts: list[AssetCount] = []
    warnings: list[str] = []
    for release in releases:
        if not isinstance(release, dict) or release.get("draft") is True:
            continue
        tag = release.get("tag_name")
        assets = release.get("assets")
        if not isinstance(tag, str) or not isinstance(assets, list):
            raise CollectError("a release lacks tag_name or assets")
        if not SAFE_NAME_PATTERN.match(tag):
            warnings.append("skipped a release with an unexpected tag name")
            continue
        for asset in assets:
            name = asset.get("name") if isinstance(asset, dict) else None
            count = asset.get("download_count") if isinstance(asset, dict) else None
            if not isinstance(name, str) or not _is_count(count):
                raise CollectError(f"an asset of release {tag} lacks name or download_count")
            if not SAFE_NAME_PATTERN.match(name):
                warnings.append(f"skipped an asset of release {tag} with an unexpected name")
                continue
            counts.append(AssetCount(tag, name, count))
    return sorted(counts, key=lambda c: (c.tag, c.asset)), warnings


def own_records_from_json(document: object) -> list[OwnRecord]:
    """Parses one own-downloads.json: {run_id, counts: {date: {asset: {draft, published}}}}."""
    if not isinstance(document, dict):
        raise OwnRecordError("the record is not an object")
    run_id = document.get("run_id")
    counts = document.get("counts")
    if not isinstance(run_id, str) or not SAFE_NAME_PATTERN.match(run_id):
        raise OwnRecordError("run_id is missing or not a plain string")
    if not isinstance(counts, dict):
        raise OwnRecordError("counts is not an object")
    records: list[OwnRecord] = []
    for day_text, assets in counts.items():
        day = parse_day(day_text, OwnRecordError)
        if not isinstance(assets, dict):
            raise OwnRecordError(f"counts for {day_text} is not an object")
        for asset, phases in assets.items():
            if not SAFE_NAME_PATTERN.match(asset):
                raise OwnRecordError("an asset name is not a plain file name")
            if not isinstance(phases, dict) or not _is_count(phases.get("draft")) or not _is_count(phases.get("published")):
                raise OwnRecordError(f"{asset} on {day_text} needs integer draft and published counts")
            records.append(OwnRecord(run_id, day, asset, phases["draft"], phases["published"]))
    return sorted(records, key=lambda r: (r.day, r.asset))


def traffic_from_json(metric: str, document: object) -> list[TrafficDay]:
    """Daily rows of a /traffic/views or /traffic/clones response."""
    entries = document.get(metric) if isinstance(document, dict) else None
    if not isinstance(entries, list):
        raise CollectError(f"the {metric} traffic response has no '{metric}' list")
    rows = []
    for entry in entries:
        timestamp = entry.get("timestamp") if isinstance(entry, dict) else None
        if not isinstance(timestamp, str) or not TIMESTAMP_DATE_PATTERN.match(timestamp):
            raise CollectError(f"a {metric} entry has no usable timestamp")
        count, uniques = entry.get("count"), entry.get("uniques")
        if not _is_count(count) or not _is_count(uniques):
            raise CollectError(f"a {metric} entry has no integer count and uniques")
        rows.append(TrafficDay(parse_day(timestamp[:10], CollectError), metric, count, uniques))
    return rows


def parse_day(text: object, error: type[Exception]) -> date:
    try:
        if not isinstance(text, str) or len(text) != 10:
            raise ValueError(text)
        return date.fromisoformat(text)
    except ValueError:
        raise error(f"'{text}' is not a YYYY-MM-DD date") from None


# --------------------------------------------------------------------------
#  Pure: CSV rows <-> typed rows
# --------------------------------------------------------------------------

def snapshots_from_rows(rows: Iterable[Mapping[str, str]]) -> dict[date, dict[tuple[str, str], int]]:
    """downloads.csv rows grouped as {date: {(tag, asset): cumulative count}}."""
    snapshots: dict[date, dict[tuple[str, str], int]] = {}
    for row in rows:
        day = parse_day(row["date"], CollectError)
        snapshots.setdefault(day, {})[(row["tag"], row["asset"])] = csv_int(row["download_count"])
    return snapshots


def own_records_from_rows(rows: Iterable[Mapping[str, str]]) -> list[OwnRecord]:
    return [
        OwnRecord(row["run_id"], parse_day(row["date"], CollectError), row["asset"], csv_int(row["draft"]), csv_int(row["published"]))
        for row in rows
    ]


def csv_int(text: str) -> int:
    try:
        value = int(text)
    except ValueError:
        raise CollectError(f"'{text}' in a stats CSV is not an integer") from None
    if value < 0:
        raise CollectError(f"'{text}' in a stats CSV is negative")
    return value


# --------------------------------------------------------------------------
#  Pure: merging into the stored rows
# --------------------------------------------------------------------------

def merge_snapshot(
    existing: list[dict[str, str]], counts: list[AssetCount], today: date
) -> list[dict[str, str]]:
    """Appends today's snapshot only when a count differs from the latest one.

    A second run on the same date replaces that date's rows instead of duplicating them.
    """
    if not counts:
        return existing
    snapshots = snapshots_from_rows(existing)
    new_snapshot = {(c.tag, c.asset): c.count for c in counts}
    if snapshots and new_snapshot == snapshots[max(snapshots)]:
        return existing
    kept = [row for row in existing if row["date"] != today.isoformat()]
    added = [
        {"date": today.isoformat(), "tag": c.tag, "asset": c.asset, "download_count": str(c.count)}
        for c in counts
    ]
    return kept + added


def merge_own_records(existing: list[dict[str, str]], records: list[OwnRecord]) -> list[dict[str, str]]:
    """Appends records of runs not seen before; a run is recorded once."""
    seen = {row["run_id"] for row in existing}
    added = [
        {"run_id": r.run_id, "date": r.day.isoformat(), "asset": r.asset, "draft": str(r.draft), "published": str(r.published)}
        for r in records
        if r.run_id not in seen
    ]
    return existing + added


def merge_traffic(existing: list[dict[str, str]], days: list[TrafficDay]) -> list[dict[str, str]]:
    """The API repeats the last 14 days on every call; the newest value of a day wins."""
    merged = {(row["date"], row["metric"]): row for row in existing}
    for item in days:
        merged[(item.day.isoformat(), item.metric)] = {
            "date": item.day.isoformat(), "metric": item.metric, "count": str(item.count), "uniques": str(item.uniques),
        }
    return [merged[key] for key in sorted(merged)]


# --------------------------------------------------------------------------
#  Pure: net installs
# --------------------------------------------------------------------------

def installs_per_day(
    snapshots: Mapping[date, Mapping[tuple[str, str], int]],
    own_records: Iterable[OwnRecord],
    subtract_drafts: bool = SUBTRACT_DRAFT_DOWNLOADS,
) -> dict[date, dict[str, int]]:
    """Net installs per snapshot date and asset name.

    The raw delta of a snapshot is its cumulative counts minus the previous snapshot's,
    summed over all releases carrying the asset. The workflow's own downloads dated after
    the previous snapshot up to this one are subtracted, clamped at zero. The first snapshot
    is the baseline and yields nothing.
    """
    records = list(own_records)
    dates = sorted(snapshots)
    return {
        current: _net_installs(snapshots[previous], snapshots[current], records, previous, current, subtract_drafts)
        for previous, current in zip(dates, dates[1:])
    }


def _net_installs(previous_counts, current_counts, records, previous, current, subtract_drafts) -> dict[str, int]:
    raw: dict[str, int] = {}
    for (tag, asset), count in current_counts.items():
        raw[asset] = raw.get(asset, 0) + max(0, count - previous_counts.get((tag, asset), 0))
    own = own_downloads_between(records, previous, current, subtract_drafts)
    return {asset: max(0, delta - own.get(asset, 0)) for asset, delta in raw.items()}


def own_downloads_between(
    records: Iterable[OwnRecord], after: date, until: date, subtract_drafts: bool
) -> dict[str, int]:
    """Own downloads per asset dated in (after, until]."""
    totals: dict[str, int] = {}
    for record in records:
        if after < record.day <= until:
            counted = record.published + (record.draft if subtract_drafts else 0)
            totals[record.asset] = totals.get(record.asset, 0) + counted
    return totals


# --------------------------------------------------------------------------
#  I/O: CSV files
# --------------------------------------------------------------------------

def read_csv(path: Path, columns: tuple[str, ...]) -> list[dict[str, str]]:
    """The rows of a stats CSV; a missing file is empty, a foreign header is an error."""
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if tuple(reader.fieldnames or ()) != columns:
            raise CollectError(f"{path.name} does not have the columns {', '.join(columns)}")
        rows = list(reader)
    if any(None in row or None in row.values() for row in rows):
        raise CollectError(f"{path.name} has a malformed row")
    return rows


def write_csv_if_changed(path: Path, columns: tuple[str, ...], rows: list[dict[str, str]]) -> bool:
    """Writes atomically and reports whether the file's content changed."""
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=columns, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    text = buffer.getvalue()
    if path.exists() and path.read_text(encoding="utf-8") == text:
        return False
    write_text_atomically(path, text)
    return True


def write_text_atomically(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="", dir=path.parent, delete=False, suffix=".tmp")
    try:
        with handle:
            handle.write(text)
        os.replace(handle.name, path)
    except BaseException:
        Path(handle.name).unlink(missing_ok=True)
        raise


# --------------------------------------------------------------------------
#  I/O: the GitHub API
# --------------------------------------------------------------------------

class GitHubApi(Protocol):
    def get_json(self, path: str, params: Mapping[str, str] | None = None) -> object: ...

    def download(self, url: str) -> bytes: ...


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Surfaces a redirect as an HTTPError so the caller decides whether credentials follow."""

    def redirect_request(self, *args, **kwargs):
        return None


class GitHubClient:
    """A minimal GitHub REST client. The token travels only in the Authorization header,
    only to api_root, and never follows a redirect to another host."""

    def __init__(self, token: str, api_root: str = API_ROOT):
        self._token = token
        self._api_root = api_root.rstrip("/")
        self._opener = urllib.request.build_opener(_NoRedirect)

    def get_json(self, path: str, params: Mapping[str, str] | None = None) -> object:
        query = f"?{urllib.parse.urlencode(params)}" if params else ""
        body = self._fetch(f"{self._api_root}{path}{query}", authorised=True, limit=MAX_JSON_BYTES)
        try:
            return json.loads(body)
        except ValueError:
            raise CollectError(f"GET {path}: the response is not JSON") from None

    def download(self, url: str) -> bytes:
        if not url.startswith(self._api_root + "/"):
            raise CollectError("refusing to send credentials to a URL outside the API")
        try:
            return self._fetch(url, authorised=True, limit=MAX_ARTIFACT_BYTES)
        except _Redirect as redirect:
            if not redirect.location.startswith(("https://", "http://127.0.0.1")):
                raise CollectError("the artifact redirect is not an https URL") from None
            return self._fetch(redirect.location, authorised=False, limit=MAX_ARTIFACT_BYTES)

    def _fetch(self, url: str, authorised: bool, limit: int) -> bytes:
        headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": API_VERSION, "User-Agent": "teststand-mcp-stats"}
        if authorised:
            headers["Authorization"] = f"Bearer {self._token}"
        label = urllib.parse.urlsplit(url).path
        try:
            with self._opener.open(urllib.request.Request(url, headers=headers), timeout=REQUEST_TIMEOUT_SECONDS) as response:
                body = response.read(limit + 1)
        except urllib.error.HTTPError as error:
            error.close()
            if error.code in REDIRECT_STATUSES and error.headers.get("Location"):
                raise _Redirect(error.headers["Location"]) from None
            raise CollectError(f"GET {label}: HTTP {error.code} {error.reason}") from None
        except (urllib.error.URLError, OSError) as error:
            raise CollectError(f"GET {label}: {getattr(error, 'reason', error)}") from None
        if len(body) > limit:
            raise CollectError(f"GET {label}: the response is larger than {limit} bytes")
        return body


class _Redirect(Exception):
    def __init__(self, location: str):
        super().__init__(location)
        self.location = location


# --------------------------------------------------------------------------
#  Orchestration
# --------------------------------------------------------------------------

def fetch_pages(api: GitHubApi, path: str, extract: Callable[[object], list], params: Mapping[str, str] | None = None) -> list:
    """All items of a paginated list endpoint, bounded by MAX_PAGES."""
    items: list = []
    for page in range(1, MAX_PAGES + 1):
        query = {**(params or {}), "per_page": str(PAGE_SIZE), "page": str(page)}
        batch = extract(api.get_json(path, query))
        items.extend(batch)
        if len(batch) < PAGE_SIZE:
            return items
    raise CollectError(f"{path} has more than {MAX_PAGES * PAGE_SIZE} entries; raise MAX_PAGES")


def _release_list(response: object) -> list:
    if not isinstance(response, list):
        raise CollectError("the releases response is not a list")
    return response


def _artifact_list(response: object) -> list:
    artifacts = response.get("artifacts") if isinstance(response, dict) else None
    if not isinstance(artifacts, list):
        raise CollectError("the artifacts response has no 'artifacts' list")
    return artifacts


def fetch_own_records(api: GitHubApi, repo: str, known_run_ids: set[str], warnings: list[str]) -> list[OwnRecord]:
    """Records of the own-downloads artifacts of runs not recorded yet. Zero artifacts is fine."""
    artifacts = fetch_pages(api, f"/repos/{repo}/actions/artifacts", _artifact_list, {"name": OWN_DOWNLOADS_ARTIFACT})
    records: list[OwnRecord] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict) or artifact.get("expired") is True:
            continue
        run = artifact.get("workflow_run")
        if isinstance(run, dict) and str(run.get("id")) in known_run_ids:
            continue
        url = artifact.get("archive_download_url")
        if not isinstance(url, str):
            raise CollectError("an artifact has no archive_download_url")
        try:
            records.extend(own_records_from_json(_read_record(api.download(url))))
        except OwnRecordError as error:
            warnings.append(f"skipped an unusable {OWN_DOWNLOADS_ARTIFACT} artifact: {error}")
    return records


def _read_record(archive: bytes) -> object:
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
            info = bundle.getinfo(OWN_DOWNLOADS_FILE)
            if info.file_size > MAX_ARTIFACT_BYTES:
                raise OwnRecordError(f"{OWN_DOWNLOADS_FILE} is too large")
            return json.loads(bundle.read(info))
    except (zipfile.BadZipFile, KeyError, ValueError) as error:
        if isinstance(error, OwnRecordError):
            raise
        raise OwnRecordError(f"the artifact does not hold a readable {OWN_DOWNLOADS_FILE}") from None


def fetch_traffic(api: GitHubApi, repo: str) -> list[TrafficDay]:
    days: list[TrafficDay] = []
    for metric in TRAFFIC_METRICS:
        days.extend(traffic_from_json(metric, api.get_json(f"/repos/{repo}/traffic/{metric}")))
    return days


def collect(
    api: GitHubApi, traffic_api: GitHubApi | None, repo: str, stats_dir: Path, today: date
) -> CollectResult:
    """Fetches everything first, then writes; any error leaves the stats files untouched."""
    result = CollectResult()
    downloads = read_csv(stats_dir / DOWNLOADS_FILE, DOWNLOADS_COLUMNS)
    own = read_csv(stats_dir / OWN_DOWNLOADS_CSV, OWN_DOWNLOADS_COLUMNS)
    traffic = read_csv(stats_dir / TRAFFIC_FILE, TRAFFIC_COLUMNS)

    releases = fetch_pages(api, f"/repos/{repo}/releases", _release_list)
    counts, warnings = asset_counts_from_releases(releases)
    result.warnings.extend(warnings)
    new_own = fetch_own_records(api, repo, {row["run_id"] for row in own}, result.warnings)
    new_traffic = fetch_traffic(traffic_api, repo) if traffic_api else []

    outputs = [
        (DOWNLOADS_FILE, DOWNLOADS_COLUMNS, merge_snapshot(downloads, counts, today)),
        (OWN_DOWNLOADS_CSV, OWN_DOWNLOADS_COLUMNS, merge_own_records(own, new_own)),
        (TRAFFIC_FILE, TRAFFIC_COLUMNS, merge_traffic(traffic, new_traffic)),
    ]
    for name, columns, rows in outputs:
        if write_csv_if_changed(stats_dir / name, columns, rows):
            result.changed_files.append(name)
    return result


def main(argv: list[str] | None = None, env: Mapping[str, str] | None = None,
         clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
         client_factory: Callable[[str], GitHubApi] = GitHubClient) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description="Collect release download counts into the stats CSV files.")
    parser.add_argument("--stats-dir", type=Path, required=True, help="the checked-out stats branch")
    parser.add_argument("--repo", default=env.get("GITHUB_REPOSITORY", ""), help="owner/name; default $GITHUB_REPOSITORY")
    parser.add_argument("--today", help="override the snapshot date (YYYY-MM-DD), for tests and backfills")
    args = parser.parse_args(argv)

    token = env.get("GITHUB_TOKEN", "").strip()
    traffic_token = env.get("STATS_TRAFFIC_TOKEN", "").strip()
    try:
        if not REPO_PATTERN.match(args.repo):
            raise CollectError("--repo or GITHUB_REPOSITORY must look like owner/name")
        if not token:
            raise CollectError("GITHUB_TOKEN is not set")
        today = parse_day(args.today, CollectError) if args.today else utc_date(clock())
        traffic_api = client_factory(traffic_token) if traffic_token else None
        result = collect(client_factory(token), traffic_api, args.repo, args.stats_dir, today)
    except CollectError as error:
        print(f"collect failed: {error}", file=sys.stderr)
        return 1

    for warning in result.warnings:
        print(f"warning: {warning}", file=sys.stderr)
    if not traffic_token:
        print("traffic skipped: STATS_TRAFFIC_TOKEN is not set")
    print(f"changed: {', '.join(result.changed_files) or 'nothing'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
