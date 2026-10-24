"""Tests for collect.py (and, from step 9.2, the site builder).

From the repository root:  python -m unittest discover -s .github/stats
From .github/stats:        python -m unittest
"""

from __future__ import annotations

import http.server
import io
import json
import tempfile
import threading
import time
import unittest
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from unittest import mock
import zipfile
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import collect

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


if __name__ == "__main__":
    unittest.main()
