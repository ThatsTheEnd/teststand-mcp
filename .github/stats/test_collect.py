"""Tests for collect.py (and, from step 9.2, the site builder).

From the repository root:  python -m unittest discover -s .github/stats
From .github/stats:        python -m unittest
"""

from __future__ import annotations

import http.server
import importlib.util
import io
import json
import re
import sys
import tempfile
import threading
import time
import unittest
from html.parser import HTMLParser
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from unittest import mock
import zipfile
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import collect

SITE_BUILDER = Path(__file__).resolve().parents[1] / "site" / "build.py"
_spec = importlib.util.spec_from_file_location("stats_site_build", SITE_BUILDER)
site = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = site  # dataclasses resolves annotations through sys.modules
_spec.loader.exec_module(site)

REPO_ROOT = Path(__file__).resolve().parents[2]
OWN_DOWNLOADS_FIXTURE = REPO_ROOT / "build" / "tests" / "fixtures" / "own-downloads.json"
REPO = "owner/name"
ZIP = "teststand-mcp.zip"


def d(text: str) -> date:
    return date.fromisoformat(text)


def own(run_id: str, day: str, asset: str, draft: int, published: int) -> collect.OwnRecord:
    return collect.OwnRecord(run_id, d(day), asset, draft, published)


def snapshots(*days: tuple[str, int]) -> dict:
    """Snapshots of one asset on one release, as (date, cumulative count)."""
    return {d(day): {("v1.9.0", ZIP): count} for day, count in days}


def release(tag: str, assets: dict[str, int], draft: bool = False) -> dict:
    return {"tag_name": tag, "draft": draft, "assets": [{"name": n, "download_count": c} for n, c in assets.items()]}


def artifact_zip(document: object, name: str = collect.OWN_DOWNLOADS_FILE) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as bundle:
        bundle.writestr(name, json.dumps(document))
    return buffer.getvalue()


def fixture_document() -> dict:
    return json.loads(OWN_DOWNLOADS_FIXTURE.read_text(encoding="utf-8"))


class NetInstalls(unittest.TestCase):
    def test_own_downloads_of_two_runs_are_subtracted_from_the_raw_delta(self):
        records = [own("1", "2026-08-21", ZIP, 3, 1), own("2", "2026-08-21", ZIP, 3, 1)]
        result = collect.installs_per_day(snapshots(("2026-08-20", 100), ("2026-08-21", 120)), records)
        self.assertEqual(result, {d("2026-08-21"): {ZIP: 12}})

    def test_ignoring_drafts_subtracts_only_published_downloads(self):
        records = [own("1", "2026-08-21", ZIP, 3, 1), own("2", "2026-08-21", ZIP, 3, 1)]
        result = collect.installs_per_day(snapshots(("2026-08-20", 100), ("2026-08-21", 120)), records, subtract_drafts=False)
        self.assertEqual(result[d("2026-08-21")][ZIP], 18)

    def test_the_committed_default_subtracts_drafts(self):
        self.assertTrue(collect.SUBTRACT_DRAFT_DOWNLOADS)
        records = [own("1", "2026-08-21", ZIP, 5, 0)]
        result = collect.installs_per_day(snapshots(("2026-08-20", 10), ("2026-08-21", 20)), records)
        self.assertEqual(result[d("2026-08-21")][ZIP], 5)

    def test_subtraction_never_goes_negative(self):
        records = [own("1", "2026-08-21", ZIP, 9, 9)]
        result = collect.installs_per_day(snapshots(("2026-08-20", 100), ("2026-08-21", 102)), records)
        self.assertEqual(result[d("2026-08-21")][ZIP], 0)

    def test_the_first_snapshot_is_only_a_baseline(self):
        self.assertEqual(collect.installs_per_day(snapshots(("2026-08-20", 100)), []), {})
        self.assertEqual(collect.installs_per_day({}, []), {})

    def test_own_downloads_dated_outside_the_snapshot_window_are_not_subtracted(self):
        records = [own("1", "2026-08-20", ZIP, 0, 4), own("2", "2026-08-22", ZIP, 0, 4)]
        result = collect.installs_per_day(snapshots(("2026-08-20", 100), ("2026-08-21", 110)), records)
        self.assertEqual(result[d("2026-08-21")][ZIP], 10)

    def test_a_gap_between_snapshots_subtracts_every_own_download_inside_it(self):
        records = [own("1", "2026-08-22", ZIP, 0, 2), own("2", "2026-08-24", ZIP, 0, 3)]
        result = collect.installs_per_day(snapshots(("2026-08-20", 100), ("2026-08-24", 130)), records)
        self.assertEqual(result, {d("2026-08-24"): {ZIP: 25}})

    def test_a_new_release_counts_in_full_and_releases_are_summed_per_asset_name(self):
        before = {("v1.8.0", ZIP): 50}
        after = {("v1.8.0", ZIP): 53, ("v1.9.0", ZIP): 7}
        result = collect.installs_per_day({d("2026-08-20"): before, d("2026-08-21"): after}, [])
        self.assertEqual(result[d("2026-08-21")][ZIP], 10)

    def test_a_release_that_disappeared_does_not_make_installs_negative(self):
        before = {("v1.8.0", ZIP): 50, ("v1.9.0", ZIP): 5}
        after = {("v1.9.0", ZIP): 8}
        result = collect.installs_per_day({d("2026-08-20"): before, d("2026-08-21"): after}, [])
        self.assertEqual(result[d("2026-08-21")][ZIP], 3)

    def test_a_recreated_release_with_a_lower_count_does_not_cancel_other_releases(self):
        before = {("v1.8.0", ZIP): 50, ("v1.9.0", ZIP): 5}
        after = {("v1.8.0", ZIP): 3, ("v1.9.0", ZIP): 8}
        result = collect.installs_per_day({d("2026-08-20"): before, d("2026-08-21"): after}, [])
        self.assertEqual(result[d("2026-08-21")][ZIP], 3)

    def test_the_shared_fixture_subtracts_exactly_the_recorded_counts_per_asset_and_date(self):
        records = collect.own_records_from_json(fixture_document())
        recorded = {(r.day.isoformat(), r.asset): (r.draft, r.published) for r in records}
        self.assertEqual(recorded[("2026-08-20", ZIP)], (2, 0))
        self.assertEqual(recorded[("2026-08-21", ZIP)], (0, 1))
        for subtract_drafts in (True, False):
            with self.subTest(subtract_drafts=subtract_drafts):
                grid = snapshots(("2026-08-19", 100), ("2026-08-20", 200), ("2026-08-21", 300))
                result = collect.installs_per_day(grid, records, subtract_drafts)
                expected = {
                    "2026-08-20": 100 - (2 if subtract_drafts else 0),
                    "2026-08-21": 100 - 1,
                }
                for day, installs in expected.items():
                    self.assertEqual(result[d(day)][ZIP], installs)

    def test_a_midnight_boundary_moment_belongs_to_its_utc_date(self):
        self.assertEqual(collect.utc_date(datetime(2026, 8, 20, 23, 59, 59, tzinfo=timezone.utc)), d("2026-08-20"))
        self.assertEqual(collect.utc_date(datetime(2026, 8, 21, 0, 0, 0, tzinfo=timezone.utc)), d("2026-08-21"))
        west = timezone(timedelta(hours=-2))
        self.assertEqual(collect.utc_date(datetime(2026, 8, 20, 23, 30, tzinfo=west)), d("2026-08-21"))

    def test_a_naive_datetime_is_refused(self):
        with self.assertRaises(ValueError):
            collect.utc_date(datetime(2026, 8, 20, 12, 0))


class RowsFromJson(unittest.TestCase):
    def test_draft_releases_are_not_counted_and_the_rows_are_sorted(self):
        releases = [release("v1.9.0", {"b.zip": 2, "a.zip": 1}), release("v2.0.0", {"c.zip": 9}, draft=True), release("v1.8.0", {"a.zip": 5})]
        counts, warnings = collect.asset_counts_from_releases(releases)
        self.assertEqual([(c.tag, c.asset, c.count) for c in counts], [("v1.8.0", "a.zip", 5), ("v1.9.0", "a.zip", 1), ("v1.9.0", "b.zip", 2)])
        self.assertEqual(warnings, [])

    def test_an_untrusted_asset_name_is_skipped_with_a_warning(self):
        counts, warnings = collect.asset_counts_from_releases([release("v1.9.0", {"=cmd|calc.zip": 3, "ok.zip": 1})])
        self.assertEqual([c.asset for c in counts], ["ok.zip"])
        self.assertEqual(len(warnings), 1)
        self.assertNotIn("calc", warnings[0])

    def test_an_unexpected_shape_is_an_error(self):
        for bad in ({"message": "rate limited"}, [{"tag_name": "v1", "assets": "x"}], [release("v1", {"a.zip": -1})]):
            with self.subTest(bad=bad), self.assertRaises(collect.CollectError):
                collect.asset_counts_from_releases(bad)

    def test_the_fixture_parses_into_one_record_per_asset_and_date(self):
        records = collect.own_records_from_json(fixture_document())
        self.assertEqual(len(records), 6)
        self.assertEqual({r.run_id for r in records}, {"1234567890"})

    def test_a_record_that_breaks_the_schema_is_rejected(self):
        good = fixture_document()
        broken = [
            [],
            {**good, "run_id": 7},
            {**good, "counts": []},
            {**good, "counts": {"20260820": {}}},
            {**good, "counts": {"2026-08-20": {ZIP: 4}}},
            {**good, "counts": {"2026-08-20": {ZIP: {"draft": 1}}}},
            {**good, "counts": {"2026-08-20": {"../x.zip": {"draft": 1, "published": 0}}}},
            {**good, "counts": {"2026-08-20": {ZIP: {"draft": True, "published": 0}}}},
        ]
        for document in broken:
            with self.subTest(document=document), self.assertRaises(collect.OwnRecordError):
                collect.own_records_from_json(document)

    def test_traffic_days_are_read_by_metric(self):
        response = {"count": 5, "views": [{"timestamp": "2026-08-14T00:00:00Z", "count": 5, "uniques": 2}]}
        days = collect.traffic_from_json("views", response)
        self.assertEqual(days, [collect.TrafficDay(d("2026-08-14"), "views", 5, 2)])
        with self.assertRaises(collect.CollectError):
            collect.traffic_from_json("clones", response)


class MergeRules(unittest.TestCase):
    COUNTS = [collect.AssetCount("v1.9.0", ZIP, 5)]

    def rows(self, day: str, count: int) -> list[dict]:
        return [{"date": day, "tag": "v1.9.0", "asset": ZIP, "download_count": str(count)}]

    def test_the_first_snapshot_is_appended(self):
        self.assertEqual(collect.merge_snapshot([], self.COUNTS, d("2026-08-20")), self.rows("2026-08-20", 5))

    def test_equal_counts_append_nothing(self):
        existing = self.rows("2026-08-20", 5)
        self.assertEqual(collect.merge_snapshot(existing, self.COUNTS, d("2026-08-21")), existing)

    def test_a_changed_count_appends_a_full_snapshot(self):
        existing = self.rows("2026-08-20", 4)
        merged = collect.merge_snapshot(existing, self.COUNTS, d("2026-08-21"))
        self.assertEqual(merged, existing + self.rows("2026-08-21", 5))

    def test_a_second_run_on_the_same_date_replaces_that_dates_rows(self):
        merged = collect.merge_snapshot(self.rows("2026-08-20", 4), self.COUNTS, d("2026-08-20"))
        self.assertEqual(merged, self.rows("2026-08-20", 5))

    def test_no_assets_leave_the_rows_alone(self):
        self.assertEqual(collect.merge_snapshot([], [], d("2026-08-20")), [])

    def test_a_recorded_run_is_not_recorded_twice(self):
        records = collect.own_records_from_json(fixture_document())
        once = collect.merge_own_records([], records)
        self.assertEqual(len(once), 6)
        self.assertEqual(collect.merge_own_records(once, records), once)

    def test_the_newest_traffic_value_of_a_day_wins(self):
        existing = [{"date": "2026-08-14", "metric": "views", "count": "1", "uniques": "1"}]
        merged = collect.merge_traffic(existing, [collect.TrafficDay(d("2026-08-14"), "views", 4, 2), collect.TrafficDay(d("2026-08-13"), "clones", 3, 1)])
        self.assertEqual([(r["date"], r["metric"], r["count"]) for r in merged], [("2026-08-13", "clones", "3"), ("2026-08-14", "views", "4")])


class FakeApi:
    """Canned API JSON by path; artifacts by URL. A failing path raises like the real client."""

    def __init__(self, releases=(), artifacts=(), downloads=None, traffic=None, failing=()):
        self.responses = {
            f"/repos/{REPO}/releases": list(releases),
            f"/repos/{REPO}/actions/artifacts": {"total_count": len(artifacts), "artifacts": list(artifacts)},
        }
        for metric, document in (traffic or {}).items():
            self.responses[f"/repos/{REPO}/traffic/{metric}"] = document
        self.downloads = downloads or {}
        self.failing = set(failing)
        self.requested: list[str] = []

    def get_json(self, path, params=None):
        self.requested.append(path)
        if path in self.failing:
            raise collect.CollectError(f"GET {path}: HTTP 403 rate limit exceeded")
        return self.responses[path]

    def download(self, url):
        self.requested.append(url)
        return self.downloads[url]


def artifact(run_id: int, expired: bool = False) -> dict:
    return {"id": run_id, "name": "own-downloads", "expired": expired, "workflow_run": {"id": run_id},
            "archive_download_url": f"https://api.example/artifacts/{run_id}/zip"}


class CollectRun(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.stats = Path(directory.name) / "stats"

    def run_collect(self, api, traffic_api=None, today="2026-08-20"):
        return collect.collect(api, traffic_api, REPO, self.stats, d(today))

    def text(self, name: str) -> str:
        return (self.stats / name).read_text(encoding="utf-8")

    def test_the_first_run_without_releases_creates_header_only_files(self):
        result = self.run_collect(FakeApi())
        self.assertEqual(self.text("downloads.csv"), "date,tag,asset,download_count\n")
        self.assertEqual(self.text("own-downloads.csv"), "run_id,date,asset,draft,published\n")
        self.assertEqual(self.text("traffic.csv"), "date,metric,count,uniques\n")
        self.assertEqual(len(result.changed_files), 3)

    def test_the_first_run_with_releases_writes_one_row_per_asset(self):
        self.run_collect(FakeApi(releases=[release("v1.9.0", {ZIP: 4, "teststand-mcp.sha256": 1})]))
        self.assertEqual(self.text("downloads.csv").splitlines(), [
            "date,tag,asset,download_count",
            "2026-08-20,v1.9.0,teststand-mcp.sha256,1",
            f"2026-08-20,v1.9.0,{ZIP},4",
        ])

    def test_a_second_run_with_equal_counts_changes_nothing(self):
        api = FakeApi(releases=[release("v1.9.0", {ZIP: 4})])
        self.run_collect(api)
        before = {p.name: p.read_bytes() for p in self.stats.iterdir()}
        result = self.run_collect(api, today="2026-08-21")
        self.assertEqual(result.changed_files, [])
        self.assertEqual({p.name: p.read_bytes() for p in self.stats.iterdir()}, before)

    def test_an_api_error_writes_nothing(self):
        api = FakeApi(releases=[release("v1.9.0", {ZIP: 4})], failing=[f"/repos/{REPO}/actions/artifacts"])
        with self.assertRaisesRegex(collect.CollectError, "rate limit"):
            self.run_collect(api)
        self.assertFalse(self.stats.exists())

    def test_an_error_on_a_later_day_leaves_the_existing_files_untouched(self):
        self.run_collect(FakeApi(releases=[release("v1.9.0", {ZIP: 4})]))
        before = {p.name: p.read_bytes() for p in self.stats.iterdir()}
        with self.assertRaises(collect.CollectError):
            self.run_collect(FakeApi(releases=[release("v1.9.0", {ZIP: 9})], failing=[f"/repos/{REPO}/releases"]), today="2026-08-21")
        self.assertEqual({p.name: p.read_bytes() for p in self.stats.iterdir()}, before)

    def test_without_a_traffic_client_no_traffic_is_requested_or_recorded(self):
        api = FakeApi()
        self.run_collect(api, traffic_api=None)
        self.assertFalse([p for p in api.requested if "traffic" in p])
        self.assertEqual(self.text("traffic.csv"), "date,metric,count,uniques\n")

    def test_with_a_traffic_client_views_and_clones_are_recorded(self):
        views = {"views": [{"timestamp": "2026-08-19T00:00:00Z", "count": 7, "uniques": 3}]}
        clones = {"clones": [{"timestamp": "2026-08-19T00:00:00Z", "count": 2, "uniques": 1}]}
        traffic_api = FakeApi(traffic={"views": views, "clones": clones})
        self.run_collect(FakeApi(), traffic_api=traffic_api)
        self.assertEqual(self.text("traffic.csv").splitlines(), [
            "date,metric,count,uniques", "2026-08-19,clones,2,1", "2026-08-19,views,7,3"])

    def test_a_failing_traffic_call_fails_the_run_before_anything_is_written(self):
        traffic_api = FakeApi(failing=[f"/repos/{REPO}/traffic/views"])
        with self.assertRaises(collect.CollectError):
            self.run_collect(FakeApi(releases=[release("v1.9.0", {ZIP: 4})]), traffic_api=traffic_api)
        self.assertFalse(self.stats.exists())

    def test_own_downloads_artifacts_are_recorded_once_per_run(self):
        url = "https://api.example/artifacts/1234567890/zip"
        api = FakeApi(artifacts=[artifact(1234567890)], downloads={url: artifact_zip(fixture_document())})
        self.run_collect(api)
        self.assertEqual(len(self.text("own-downloads.csv").splitlines()), 7)
        again = FakeApi(artifacts=[artifact(1234567890)], downloads={})
        self.run_collect(again, today="2026-08-21")
        self.assertEqual(len(self.text("own-downloads.csv").splitlines()), 7)
        self.assertNotIn(url, again.requested)

    def test_zero_matching_runs_are_fine(self):
        result = self.run_collect(FakeApi(artifacts=[]))
        self.assertEqual(result.warnings, [])

    def test_an_expired_artifact_is_not_downloaded(self):
        api = FakeApi(artifacts=[artifact(5, expired=True)])
        self.run_collect(api)
        self.assertFalse([r for r in api.requested if r.startswith("https://")])

    def test_an_unusable_artifact_is_skipped_with_a_warning_and_the_run_goes_on(self):
        url = "https://api.example/artifacts/5/zip"
        for payload in (b"not a zip", artifact_zip({}, name="other.json"), artifact_zip({"run_id": "5", "counts": []})):
            with self.subTest(payload=payload[:12]):
                api = FakeApi(releases=[release("v1.9.0", {ZIP: 4})], artifacts=[artifact(5)], downloads={url: payload})
                result = self.run_collect(api)
                self.assertEqual(len(result.warnings), 1)
                self.assertEqual(self.text("own-downloads.csv"), "run_id,date,asset,draft,published\n")

    def test_a_corrupt_stats_file_is_an_error(self):
        self.stats.mkdir(parents=True)
        (self.stats / "downloads.csv").write_text("date,asset\n2026-08-20,x\n", encoding="utf-8")
        with self.assertRaisesRegex(collect.CollectError, "columns"):
            self.run_collect(FakeApi())

    def test_an_endless_listing_stops_at_the_page_bound(self):
        class Endless(FakeApi):
            def get_json(self, path, params=None):
                return [release("v1", {})] * collect.PAGE_SIZE

        with self.assertRaisesRegex(collect.CollectError, "MAX_PAGES"):
            self.run_collect(Endless())


class CommandLine(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.stats = Path(directory.name) / "stats"
        self.tokens: list[str] = []
        quiet = ExitStack()
        quiet.enter_context(redirect_stdout(io.StringIO()))
        quiet.enter_context(redirect_stderr(io.StringIO()))
        self.addCleanup(quiet.close)

    def factory(self, token):
        self.tokens.append(token)
        return FakeApi(releases=[release("v1.9.0", {ZIP: 4})])

    def run_main(self, env, clock=None, extra=()):
        args = ["--stats-dir", str(self.stats), *extra]
        kwargs = {"clock": clock} if clock else {}
        return collect.main(args, env=env, client_factory=self.factory, **kwargs)

    def test_a_run_dates_the_snapshot_by_the_injected_clock_at_the_midnight_boundary(self):
        env = {"GITHUB_TOKEN": "t", "GITHUB_REPOSITORY": REPO}
        before = datetime(2026, 8, 20, 23, 59, 59, tzinfo=timezone.utc)
        self.assertEqual(self.run_main(env, clock=lambda: before), 0)
        self.assertIn("2026-08-20,v1.9.0", (self.stats / "downloads.csv").read_text(encoding="utf-8"))
        (self.stats / "downloads.csv").unlink()
        self.assertEqual(self.run_main(env, clock=lambda: before + timedelta(seconds=1)), 0)
        self.assertIn("2026-08-21,v1.9.0", (self.stats / "downloads.csv").read_text(encoding="utf-8"))

    def test_only_a_set_traffic_token_creates_a_traffic_client(self):
        env = {"GITHUB_TOKEN": "main", "GITHUB_REPOSITORY": REPO, "STATS_TRAFFIC_TOKEN": "  "}
        self.assertEqual(self.run_main(env, extra=["--today", "2026-08-20"]), 0)
        self.assertEqual(self.tokens, ["main"])

    def test_a_missing_token_a_bad_repo_and_a_bad_date_exit_non_zero_without_files(self):
        cases = [({"GITHUB_REPOSITORY": REPO}, ()), ({"GITHUB_TOKEN": "t"}, ()),
                 ({"GITHUB_TOKEN": "t", "GITHUB_REPOSITORY": REPO}, ["--today", "20-08-2026"])]
        for env, extra in cases:
            with self.subTest(env=sorted(env), extra=extra):
                self.assertEqual(self.run_main(env, extra=extra), 1)
                self.assertFalse(self.stats.exists())


class _Handler(http.server.BaseHTTPRequestHandler):
    seen: list[tuple[str, str | None]] = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.seen.append((self.path, self.headers.get("Authorization")))
        if self.path.startswith("/limited"):
            self.send_response(403, "rate limit exceeded")
            self.end_headers()
        elif self.path.startswith("/artifact"):
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/blob")
            self.end_headers()
        elif self.path.startswith("/slow"):
            time.sleep(1.5)
            self.send_response(200)
            self.end_headers()
        elif self.path.startswith("/huge"):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"x" * (collect.MAX_ARTIFACT_BYTES + 10))
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok": true}' if self.path.startswith("/json") else b"payload")


class RealClient(unittest.TestCase):
    def setUp(self):
        _Handler.seen = []
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.root = f"http://127.0.0.1:{server.server_port}"
        self.client = collect.GitHubClient("SECRET-TOKEN", api_root=self.root)

    def test_the_token_goes_in_the_header_and_never_in_the_url(self):
        self.assertEqual(self.client.get_json("/json", {"per_page": "100"}), {"ok": True})
        path, header = _Handler.seen[0]
        self.assertEqual(header, "Bearer SECRET-TOKEN")
        self.assertNotIn("SECRET", path)

    def test_an_error_response_fails_without_leaking_the_token(self):
        with self.assertRaises(collect.CollectError) as raised:
            self.client.get_json("/limited")
        self.assertIn("403", str(raised.exception))
        self.assertNotIn("SECRET", str(raised.exception))

    def test_an_artifact_redirect_is_fetched_without_credentials(self):
        self.assertEqual(self.client.download(f"{self.root}/artifact/1/zip"), b"payload")
        self.assertEqual(_Handler.seen[0][1], "Bearer SECRET-TOKEN")
        self.assertEqual(_Handler.seen[1], ("/blob", None))

    def test_credentials_are_not_sent_to_a_url_outside_the_api(self):
        with self.assertRaises(collect.CollectError):
            self.client.download("https://evil.example/artifact/1/zip")
        self.assertEqual(_Handler.seen, [])

    def test_an_oversized_response_is_refused(self):
        with self.assertRaisesRegex(collect.CollectError, "larger"):
            self.client.download(f"{self.root}/huge")

    def test_a_non_json_body_is_an_error(self):
        with self.assertRaisesRegex(collect.CollectError, "not JSON"):
            self.client.get_json("/text")

    def test_an_unreachable_host_is_an_error_not_a_hang(self):
        dead = collect.GitHubClient("t", api_root="http://127.0.0.1:1")
        with self.assertRaises(collect.CollectError):
            dead.get_json("/json")

    def test_a_server_that_stops_answering_fails_at_the_timeout(self):
        with mock.patch.object(collect, "REQUEST_TIMEOUT_SECONDS", 0.3):
            started = time.monotonic()
            with self.assertRaises(collect.CollectError):
                self.client.get_json("/slow")
        self.assertLess(time.monotonic() - started, 3)


# --------------------------------------------------------------------------
#  Step 9.2: the site builder
# --------------------------------------------------------------------------

DOWNLOADS_HEADER = ",".join(collect.DOWNLOADS_COLUMNS) + "\n"
OWN_HEADER = ",".join(collect.OWN_DOWNLOADS_COLUMNS) + "\n"
TRAFFIC_HEADER = ",".join(collect.TRAFFIC_COLUMNS) + "\n"


class PageParts(HTMLParser):
    """Collects what the accessibility contract talks about, from the real markup."""

    def __init__(self, page: str):
        super().__init__()
        self.order: list[str] = []
        self.svgs: list[dict] = []
        self.texts: dict[str, str] = {}
        self.direct_labels: list[str] = []
        self.polylines: list[dict] = []
        self.table_rows: list[list[str]] = []
        self.column_headers: list[str] = []
        self.external: list[str] = []
        self._open: list[tuple[str, dict]] = []
        self._cell: list[str] | None = None
        self._cell_scope: str | None = None
        self.feed(page)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self._open.append((tag, attrs))
        if tag in ("svg", "table", "figure"):
            self.order.append(tag)
        if tag == "svg":
            self.svgs.append(attrs)
        if tag == "polyline":
            self.polylines.append(attrs)
        if tag == "tr":
            self.table_rows.append([])
        if tag in ("td", "th"):
            self._cell = []
            self._cell_scope = attrs.get("scope")
        for name in ("src", "href"):
            if name in attrs:
                self.external.append(attrs[name])
        if tag in ("script", "link", "img", "iframe"):
            self.external.append(f"<{tag}>")

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self._cell is not None:
            text = "".join(self._cell)
            self.table_rows[-1].append(text)
            if self._cell_scope == "col":
                self.column_headers.append(text)
            self._cell = None
        while self._open:
            if self._open.pop()[0] == tag:
                break

    def handle_data(self, data):
        if not self._open:
            return
        tag, attrs = self._open[-1]
        if self._cell is not None:
            self._cell.append(data)
        if tag in ("title", "desc") and "id" in attrs:
            self.texts[attrs["id"]] = self.texts.get(attrs["id"], "") + data
        if tag == "text" and attrs.get("class") == "label":
            self.direct_labels.append(data)


def csv_text(header: str, *rows: str) -> str:
    return header + "".join(row + "\n" for row in rows)


def write_stats(directory: Path, downloads="", own="", traffic="") -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "downloads.csv").write_text(downloads or DOWNLOADS_HEADER, encoding="utf-8")
    (directory / "own-downloads.csv").write_text(own or OWN_HEADER, encoding="utf-8")
    (directory / "traffic.csv").write_text(traffic or TRAFFIC_HEADER, encoding="utf-8")
    return directory


def page_of(downloads="", own="", traffic="", today="2026-08-21", traffic_skipped=False, subtract_drafts=True) -> str:
    with tempfile.TemporaryDirectory() as directory:
        stats = write_stats(Path(directory), downloads, own, traffic)
        return site.build_page(
            collect.read_csv(stats / "downloads.csv", collect.DOWNLOADS_COLUMNS),
            collect.read_csv(stats / "own-downloads.csv", collect.OWN_DOWNLOADS_COLUMNS),
            collect.read_csv(stats / "traffic.csv", collect.TRAFFIC_COLUMNS),
            d(today), traffic_skipped, subtract_drafts,
        )


TWO_SNAPSHOTS = csv_text(DOWNLOADS_HEADER, f"2026-08-20,v1.9.0,{ZIP},100", f"2026-08-21,v1.9.0,{ZIP},120")
TWO_RUNS_OF_FOUR = csv_text(OWN_HEADER, f"1,2026-08-21,{ZIP},3,1", f"2,2026-08-21,{ZIP},3,1")


class SiteSeries(unittest.TestCase):
    def test_the_asset_names_match_the_release_asset_module(self):
        module = (REPO_ROOT / "build" / "ReleaseAssets.psm1").read_text(encoding="utf-8")
        archive = re.search(r"-Name ReleaseArchiveName -Value '([^']+)'", module).group(1)
        versioned = re.search(r"\$script:VersionedArchiveFormat = '([^']+)'", module).group(1)
        self.assertEqual(site.INSTALL_ASSET_NAME, archive)
        self.assertEqual(site.VERSIONED_ARCHIVE_FORMAT.replace("{}", "{0}"), versioned)

    def test_only_a_versioned_archive_name_joins_the_versioned_series(self):
        pattern = site.VERSIONED_ARCHIVE_PATTERN
        self.assertTrue(pattern.fullmatch("teststand-mcp-v1.9.0.zip"))
        for name in (ZIP, "teststand-mcp-v1.9.0.zip.sha", "teststand-mcp-vX.zip", "xteststand-mcp-v1.9.0.zip", "teststand-mcp.sha256"):
            self.assertFalse(pattern.fullmatch(name), name)

    def test_install_series_sum_versioned_archives_and_ignore_other_assets(self):
        installs = {d("2026-08-21"): {ZIP: 4, "teststand-mcp-v1.9.0.zip": 2, "teststand-mcp-v1.9.1.zip": 1, "teststand-mcp.sha256": 9}}
        latest, versioned = site.install_series(installs)
        self.assertEqual(dict(latest.values), {d("2026-08-21"): 4})
        self.assertEqual(dict(versioned.values), {d("2026-08-21"): 3})

    def test_the_chart_runs_from_the_first_data_point_to_today_and_is_bounded(self):
        series = [site.Series(site.INSTALL_STYLES["latest"], {d("2026-08-20"): 1})]
        self.assertEqual(site.chart_days(series, d("2026-08-22")), [d("2026-08-20"), d("2026-08-21"), d("2026-08-22")])
        self.assertEqual(site.chart_days(series, d("2026-08-19")), [d("2026-08-20")])
        self.assertEqual(site.chart_days([], d("2026-08-22")), [])
        self.assertEqual(len(site.chart_days(series, d("2030-01-01"))), site.MAX_CHART_DAYS)

    def test_the_y_axis_uses_integer_ticks_with_at_most_five_steps(self):
        self.assertEqual(site.y_ticks(0), [0, 1])
        self.assertEqual(site.y_ticks(3), [0, 1, 2, 3])
        self.assertEqual(site.y_ticks(12), [0, 5, 10, 15])
        self.assertEqual(site.y_ticks(100), [0, 20, 40, 60, 80, 100])

    def test_direct_labels_that_would_overlap_are_pushed_apart_and_kept_inside_the_plot(self):
        placed = site.spread_labels([100.0, 100.0, 101.0], 10, 300)
        ordered = sorted(placed)
        self.assertTrue(all(b - a >= site.LABEL_GAP for a, b in zip(ordered, ordered[1:])))
        low = sorted(site.spread_labels([298.0, 299.0, 300.0], 10, 300))
        self.assertLessEqual(max(low), 300)
        self.assertTrue(all(b - a >= site.LABEL_GAP for a, b in zip(low, low[1:])))

    def test_the_series_differ_in_line_style_and_marker_not_only_in_colour(self):
        styles = [*site.INSTALL_STYLES.values(), *site.TRAFFIC_STYLES.values()]
        self.assertEqual(len({s.dash for s in styles}), len(styles))
        self.assertEqual(len({s.marker for s in styles}), len(styles))


class SitePage(unittest.TestCase):
    def test_own_downloads_are_subtracted_on_the_page_by_the_contract(self):
        parts = PageParts(page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR))
        row = next(r for r in parts.table_rows if r and r[0] == "2026-08-21")
        self.assertEqual(row, ["2026-08-21", "12", "0"])

    def test_the_draft_switch_changes_what_is_subtracted(self):
        page = page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR, subtract_drafts=False)
        row = next(r for r in PageParts(page).table_rows if r and r[0] == "2026-08-21")
        self.assertEqual(row[1], "18")

    def test_a_negative_result_is_plotted_as_zero(self):
        own = csv_text(OWN_HEADER, f"1,2026-08-21,{ZIP},30,30")
        row = next(r for r in PageParts(page_of(TWO_SNAPSHOTS, own)).table_rows if r and r[0] == "2026-08-21")
        self.assertEqual(row[1], "0")

    def test_the_chart_has_a_title_a_description_and_direct_labels(self):
        parts = PageParts(page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR))
        svg = parts.svgs[0]
        self.assertEqual(svg["role"], "img")
        title_id, desc_id = svg["aria-labelledby"].split()
        self.assertEqual(parts.texts[title_id], "Installs per day")
        self.assertIn("2026-08-21", parts.texts[desc_id])
        self.assertIn("12 in total", parts.texts[desc_id])
        self.assertEqual(parts.direct_labels[:2], [ZIP, "Versioned archives"])

    def test_a_visible_table_of_the_daily_counts_follows_the_chart(self):
        parts = PageParts(page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR))
        self.assertEqual(parts.order[:3], ["figure", "svg", "table"])
        self.assertEqual(parts.column_headers, ["Date (UTC)", ZIP, "Versioned archives"])

    def test_each_series_is_drawn_with_its_own_dash_pattern(self):
        parts = PageParts(page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR))
        dashes = [line.get("stroke-dasharray", "") for line in parts.polylines]
        self.assertEqual(len(dashes), 2)
        self.assertEqual(len(set(dashes)), len(dashes))

    def test_no_data_shows_an_empty_state_instead_of_an_empty_chart(self):
        page = page_of()
        self.assertNotIn("<svg", page)
        self.assertIn("No download snapshot has been recorded yet", page)

    def test_a_baseline_only_page_says_so_instead_of_drawing_a_chart(self):
        page = page_of(csv_text(DOWNLOADS_HEADER, f"2026-08-20,v1.9.0,{ZIP},100"))
        self.assertNotIn("<svg", page)
        self.assertIn("only a baseline", page)

    def test_a_skipped_traffic_collection_is_stated_in_visible_text(self):
        page = page_of(TWO_SNAPSHOTS, traffic_skipped=True)
        self.assertIn("STATS_TRAFFIC_TOKEN secret is not set", page)
        self.assertEqual(len(PageParts(page).svgs), 1)

    def test_recorded_traffic_is_charted_with_views_and_clones_labelled(self):
        traffic = csv_text(TRAFFIC_HEADER, "2026-08-20,views,7,3", "2026-08-20,clones,2,1", "2026-08-21,views,4,2")
        page = page_of(TWO_SNAPSHOTS, traffic=traffic)
        parts = PageParts(page)
        self.assertEqual(len(parts.svgs), 2)
        self.assertEqual(parts.direct_labels[-2:], ["Views", "Clones"])
        self.assertNotIn("STATS_TRAFFIC_TOKEN", page)

    def test_a_present_token_without_data_says_nothing_was_recorded_yet(self):
        self.assertIn("No views or clones have been recorded yet", page_of(TWO_SNAPSHOTS))

    def test_the_page_loads_nothing_from_outside_and_runs_no_script(self):
        page = page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR, traffic=csv_text(TRAFFIC_HEADER, "2026-08-21,views,4,2"))
        self.assertEqual(PageParts(page).external, [])
        self.assertNotRegex(page, r"https?://")
        self.assertIn("default-src 'none'", page)

    def test_series_labels_are_escaped_in_the_chart_and_the_table(self):
        hostile = site.SeriesStyle("<img src=x onerror=alert(1)>&", "#000000", "", "circle")
        chart = site.Chart("c", "t<script>", "u", [d("2026-08-21")], [site.Series(hostile, {d("2026-08-21"): 1})])
        markup = site.render_chart(chart) + site.render_table(chart)
        self.assertNotIn("<img", markup)
        self.assertNotIn("<script", markup)
        self.assertIn("&lt;img src=x onerror=alert(1)&gt;&amp;", markup)

    def test_a_single_day_chart_still_renders(self):
        chart = site.Chart("c", "t", "u", [d("2026-08-21")], [site.Series(site.INSTALL_STYLES["latest"], {d("2026-08-21"): 3})])
        self.assertIn("<polyline", site.render_chart(chart))


class SiteCommand(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.out = self.root / "site"

    def run_build(self, *extra, clock=None) -> int:
        kwargs = {"clock": clock} if clock else {}
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return site.main(["--stats-dir", str(self.root / "stats"), "--out", str(self.out), *extra], **kwargs)

    def page(self) -> str:
        return (self.out / "index.html").read_text(encoding="utf-8")

    def test_a_build_from_csv_files_writes_the_page(self):
        write_stats(self.root / "stats", TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR)
        self.assertEqual(self.run_build("--today", "2026-08-21"), 0)
        self.assertIn("<td>12</td>", self.page())

    def test_an_empty_stats_directory_builds_the_empty_state(self):
        self.assertEqual(self.run_build("--today", "2026-08-21"), 0)
        self.assertIn("No download snapshot", self.page())

    def test_the_no_subtract_drafts_flag_reaches_the_calculation(self):
        write_stats(self.root / "stats", TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR)
        self.assertEqual(self.run_build("--today", "2026-08-21", "--no-subtract-drafts"), 0)
        self.assertIn("<td>18</td>", self.page())

    def test_the_traffic_skipped_flag_reaches_the_page(self):
        self.assertEqual(self.run_build("--today", "2026-08-21", "--traffic-skipped"), 0)
        self.assertIn("STATS_TRAFFIC_TOKEN", self.page())

    def test_a_corrupt_csv_fails_the_build_without_writing_a_page(self):
        write_stats(self.root / "stats", csv_text(DOWNLOADS_HEADER, f"2026-08-21,v1.9.0,{ZIP},lots"))
        self.assertEqual(self.run_build("--today", "2026-08-21"), 1)
        self.assertFalse((self.out / "index.html").exists())

    def test_the_page_extends_to_the_clocks_utc_date_across_midnight(self):
        write_stats(self.root / "stats", TWO_SNAPSHOTS)
        before = datetime(2026, 8, 21, 23, 59, 59, tzinfo=timezone.utc)
        self.assertEqual(self.run_build(clock=lambda: before), 0)
        self.assertNotIn('<th scope="row">2026-08-22', self.page())
        self.assertEqual(self.run_build(clock=lambda: before + timedelta(seconds=1)), 0)
        self.assertIn('<th scope="row">2026-08-22', self.page())


class PagesWorkflow(unittest.TestCase):
    """The workflow contract, checked on the text: there is no YAML parser in the standard library."""

    @classmethod
    def setUpClass(cls):
        cls.text = (REPO_ROOT / ".github" / "workflows" / "pages.yml").read_text(encoding="utf-8")
        body = cls.text.split("\njobs:\n", 1)[1]
        cls.jobs = {name: chunk for name, chunk in re.findall(r"(?ms)^  (\w+):\n(.*?)(?=^  \w+:\n|\Z)", body)}

    def test_it_runs_daily_and_by_hand(self):
        self.assertIn("cron: '41 8 * * *'", self.text)
        self.assertRegex(self.text, r"(?m)^  workflow_dispatch:")

    def test_every_action_is_pinned_to_a_full_commit_sha_with_its_version_in_a_comment(self):
        uses = re.findall(r"(?m)^\s*(?:- )?uses: (\S+)(.*)$", self.text)
        self.assertEqual(len(uses), 3)
        for reference, rest in uses:
            with self.subTest(reference=reference):
                self.assertRegex(reference, r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$")
                self.assertRegex(rest, r"^\s+# v\d+\.\d+\.\d+$")

    def test_permissions_are_granted_per_job_and_nowhere_else(self):
        self.assertRegex(self.text, r"(?m)^permissions: \{\}$")
        self.assertEqual(set(self.jobs), {"collect", "deploy"})

        def permissions(job: str) -> list[tuple[str, str]]:
            block = re.search(r"(?m)^    permissions:\n((?:      .*\n)+)", self.jobs[job]).group(1)
            return re.findall(r"(?m)^      ([\w-]+): (\w+)", block)

        collect_permissions, deploy_permissions = permissions("collect"), permissions("deploy")
        self.assertEqual(collect_permissions, [("contents", "write"), ("actions", "read")])
        self.assertEqual(deploy_permissions, [("pages", "write"), ("id-token", "write")])

    def test_deploying_is_a_separate_job_that_waits_for_collecting(self):
        self.assertIn("needs: collect", self.jobs["deploy"])
        self.assertIn("actions/deploy-pages@", self.jobs["deploy"])
        self.assertNotIn("deploy-pages", self.jobs["collect"])
        self.assertNotIn("collect.py", self.jobs["deploy"])

    def test_the_traffic_token_reaches_only_the_collector_through_an_environment_variable(self):
        lines = [line for line in self.text.splitlines() if "STATS_TRAFFIC_TOKEN" in line and not line.lstrip().startswith("#")]
        self.assertEqual(len(lines), 2)
        self.assertTrue(any(line.strip().startswith("STATS_TRAFFIC_TOKEN: ${{ secrets.STATS_TRAFFIC_TOKEN }}") for line in lines))
        self.assertTrue(any("HAS_TRAFFIC_TOKEN: ${{ secrets.STATS_TRAFFIC_TOKEN != '' }}" in line for line in lines))
        self.assertNotIn("echo", "".join(lines))

    def test_the_scripts_it_runs_exist_and_the_page_is_built_before_the_push_and_the_upload(self):
        for script in re.findall(r"python3 (\.github/\S+\.py)", self.text):
            self.assertTrue((REPO_ROOT / script).is_file(), script)
        steps = [self.text.index(marker) for marker in ("stats/collect.py", "site/build.py", "git push origin", "upload-pages-artifact@")]
        self.assertEqual(steps, sorted(steps))

    def test_the_stats_branch_is_only_committed_to_when_something_changed(self):
        self.assertIn("git diff --cached --quiet", self.text)


if __name__ == "__main__":
    unittest.main()
