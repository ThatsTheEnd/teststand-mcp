"""Tests for the download statistics: collect.py and its layers (stats_csv, net_installs,
github_api), the site builder (.github/site/build.py) and the contract of pages.yml.

From the repository root:  python -m unittest discover -s .github/stats
From .github/stats:        python -m unittest
"""

from __future__ import annotations

import http.client
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
import urllib.parse
import zipfile
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from datetime import date, datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path
from unittest import mock

import collect
import github_api
import net_installs
import stats_csv

SITE_BUILDER = Path(__file__).resolve().parents[1] / "site" / "build.py"
_spec = importlib.util.spec_from_file_location("stats_site_build", SITE_BUILDER)
site = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = site  # dataclasses resolves annotations through sys.modules
_spec.loader.exec_module(site)

REPO_ROOT = Path(__file__).resolve().parents[2]
OWN_DOWNLOADS_FIXTURE = REPO_ROOT / "build" / "tests" / "fixtures" / "own-downloads.json"
REPO = "owner/name"
ZIP = "teststand-mcp.zip"
HEADER = {name: ",".join(columns) + "\n" for name, columns in (
    ("downloads", stats_csv.DOWNLOADS_COLUMNS), ("own", stats_csv.OWN_DOWNLOADS_COLUMNS), ("traffic", stats_csv.TRAFFIC_COLUMNS))}


def d(text: str) -> date:
    return date.fromisoformat(text)


def own(run_id: str, day: str, asset: str, draft: int, published: int) -> net_installs.OwnRecord:
    return net_installs.OwnRecord(run_id, d(day), asset, draft, published)


def snapshots(*days: tuple[str, int]) -> dict:
    """Snapshots of one asset on one release, as (date, cumulative count)."""
    return {d(day): {("v1.9.0", ZIP): count} for day, count in days}


def release(tag: str, assets: dict[str, int], draft: bool = False) -> dict:
    return {"tag_name": tag, "draft": draft, "assets": [{"name": n, "download_count": c} for n, c in assets.items()]}


def artifact_zip(document: object, name: str = collect.OWN_DOWNLOADS_FILE) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as bundle:
        bundle.writestr(name, document if isinstance(document, str) else json.dumps(document))
    return buffer.getvalue()


def fixture_document() -> dict:
    return json.loads(OWN_DOWNLOADS_FIXTURE.read_text(encoding="utf-8"))


# --------------------------------------------------------------------------
#  The domain
# --------------------------------------------------------------------------

class NetInstalls(unittest.TestCase):
    def test_own_downloads_of_two_runs_are_subtracted_from_the_raw_delta(self):
        records = [own("1", "2026-08-21", ZIP, 3, 1), own("2", "2026-08-21", ZIP, 3, 1)]
        result = net_installs.installs_per_day(snapshots(("2026-08-20", 100), ("2026-08-21", 120)), records)
        self.assertEqual(result, {d("2026-08-21"): {ZIP: 12}})

    def test_ignoring_drafts_subtracts_only_published_downloads(self):
        records = [own("1", "2026-08-21", ZIP, 3, 1), own("2", "2026-08-21", ZIP, 3, 1)]
        result = net_installs.installs_per_day(snapshots(("2026-08-20", 100), ("2026-08-21", 120)), records, subtract_drafts=False)
        self.assertEqual(result[d("2026-08-21")][ZIP], 18)

    def test_the_provisional_default_subtracts_drafts_until_the_first_release_is_measured(self):
        """Pins the provisional default; the plan's draft-download measurement confirms or flips it."""
        self.assertTrue(net_installs.SUBTRACT_DRAFT_DOWNLOADS)
        records = [own("1", "2026-08-21", ZIP, 5, 0)]
        result = net_installs.installs_per_day(snapshots(("2026-08-20", 10), ("2026-08-21", 20)), records)
        self.assertEqual(result[d("2026-08-21")][ZIP], 5)

    def test_subtraction_never_goes_negative(self):
        records = [own("1", "2026-08-21", ZIP, 9, 9)]
        result = net_installs.installs_per_day(snapshots(("2026-08-20", 100), ("2026-08-21", 102)), records)
        self.assertEqual(result[d("2026-08-21")][ZIP], 0)

    def test_the_first_snapshot_is_only_a_baseline(self):
        self.assertEqual(net_installs.installs_per_day(snapshots(("2026-08-20", 100)), []), {})
        self.assertEqual(net_installs.installs_per_day({}, []), {})

    def test_own_downloads_dated_outside_the_snapshot_window_are_not_subtracted(self):
        records = [own("1", "2026-08-20", ZIP, 0, 4), own("2", "2026-08-22", ZIP, 0, 4)]
        result = net_installs.installs_per_day(snapshots(("2026-08-20", 100), ("2026-08-21", 110)), records)
        self.assertEqual(result[d("2026-08-21")][ZIP], 10)

    def test_a_release_run_late_on_a_day_is_subtracted_from_that_days_snapshot_and_not_counted_the_next_day(self):
        grid = snapshots(("2026-08-19", 100), ("2026-08-20", 105), ("2026-08-21", 108))
        result = net_installs.installs_per_day(grid, [own("1", "2026-08-20", ZIP, 0, 2)])
        self.assertEqual({day: assets[ZIP] for day, assets in result.items()}, {d("2026-08-20"): 3, d("2026-08-21"): 3})

    def test_a_draft_verified_on_one_day_and_published_two_days_later_nets_zero_installs(self):
        grid = snapshots(("2026-08-19", 100), ("2026-08-20", 102), ("2026-08-21", 102), ("2026-08-22", 103))
        records = [own("1", "2026-08-20", ZIP, 2, 0), own("1", "2026-08-22", ZIP, 0, 1)]
        result = net_installs.installs_per_day(grid, records)
        self.assertEqual({day: assets[ZIP] for day, assets in result.items()},
                         {d("2026-08-20"): 0, d("2026-08-21"): 0, d("2026-08-22"): 0})

    def test_a_gap_between_snapshots_books_the_whole_delta_on_the_later_date(self):
        records = [own("1", "2026-08-22", ZIP, 0, 2), own("2", "2026-08-24", ZIP, 0, 3)]
        grid = snapshots(("2026-08-20", 100), ("2026-08-24", 130))
        self.assertEqual(net_installs.installs_per_day(grid, records), {d("2026-08-24"): {ZIP: 25}})
        self.assertEqual(net_installs.snapshot_predecessors(grid), {d("2026-08-24"): d("2026-08-20")})

    def test_a_new_release_counts_in_full_and_releases_are_summed_per_asset_name(self):
        before = {("v1.8.0", ZIP): 50}
        after = {("v1.8.0", ZIP): 53, ("v1.9.0", ZIP): 7}
        result = net_installs.installs_per_day({d("2026-08-20"): before, d("2026-08-21"): after}, [])
        self.assertEqual(result[d("2026-08-21")][ZIP], 10)

    def test_a_release_that_disappeared_does_not_make_installs_negative(self):
        before = {("v1.8.0", ZIP): 50, ("v1.9.0", ZIP): 5}
        after = {("v1.9.0", ZIP): 8}
        result = net_installs.installs_per_day({d("2026-08-20"): before, d("2026-08-21"): after}, [])
        self.assertEqual(result[d("2026-08-21")][ZIP], 3)

    def test_a_recreated_release_with_a_lower_count_does_not_cancel_other_releases(self):
        before = {("v1.8.0", ZIP): 50, ("v1.9.0", ZIP): 5}
        after = {("v1.8.0", ZIP): 3, ("v1.9.0", ZIP): 8}
        result = net_installs.installs_per_day({d("2026-08-20"): before, d("2026-08-21"): after}, [])
        self.assertEqual(result[d("2026-08-21")][ZIP], 3)

    def test_the_shared_fixture_subtracts_exactly_the_recorded_counts_for_all_four_assets(self):
        records = net_installs.own_records_from_json(fixture_document())
        recorded = {(r.day.isoformat(), r.asset): (r.draft, r.published) for r in records}
        assets = sorted({asset for _, asset in recorded})
        self.assertEqual(len(assets), 4)
        self.assertEqual(recorded[("2026-08-20", ZIP)], (2, 0))
        self.assertEqual(recorded[("2026-08-21", ZIP)], (0, 1))
        for asset in assets:
            grid = {d(day): {("v1.9.0", asset): count} for day, count in (("2026-08-19", 100), ("2026-08-20", 200), ("2026-08-21", 300))}
            for subtract_drafts in (True, False):
                with self.subTest(asset=asset, subtract_drafts=subtract_drafts):
                    result = net_installs.installs_per_day(grid, records, subtract_drafts)
                    for day in ("2026-08-20", "2026-08-21"):
                        draft, published = recorded.get((day, asset), (0, 0))
                        self.assertEqual(result[d(day)][asset], 100 - published - (draft if subtract_drafts else 0))

    def test_a_midnight_boundary_moment_belongs_to_its_utc_date(self):
        self.assertEqual(net_installs.utc_date(datetime(2026, 8, 20, 23, 59, 59, tzinfo=timezone.utc)), d("2026-08-20"))
        self.assertEqual(net_installs.utc_date(datetime(2026, 8, 21, 0, 0, 0, tzinfo=timezone.utc)), d("2026-08-21"))
        west = timezone(timedelta(hours=-2))
        self.assertEqual(net_installs.utc_date(datetime(2026, 8, 20, 23, 30, tzinfo=west)), d("2026-08-21"))

    def test_a_naive_datetime_is_refused(self):
        with self.assertRaises(ValueError):
            net_installs.utc_date(datetime(2026, 8, 20, 12, 0))

    def test_the_snapshot_is_dated_the_previous_utc_day(self):
        self.assertEqual(net_installs.snapshot_date_for(d("2026-08-21")), d("2026-08-20"))
        self.assertEqual(net_installs.snapshot_date_for(d("2026-03-01")), d("2026-02-28"))


class RowsFromJson(unittest.TestCase):
    def test_the_assets_of_draft_releases_are_counted_and_the_rows_are_sorted(self):
        releases = [release("v1.9.0", {"b.zip": 2, "a.zip": 1}), release("v2.0.0", {"c.zip": 9}, draft=True), release("v1.8.0", {"a.zip": 5})]
        counts, warnings = net_installs.asset_counts_from_releases(releases)
        self.assertEqual([(c.tag, c.asset, c.count) for c in counts],
                         [("v1.8.0", "a.zip", 5), ("v1.9.0", "a.zip", 1), ("v1.9.0", "b.zip", 2), ("v2.0.0", "c.zip", 9)])
        self.assertEqual(warnings, [])

    def test_an_untrusted_asset_name_is_skipped_with_a_warning(self):
        bad_names = ["=cmd|calc.zip", "a.zip\n", ".hidden.zip", "-flag.zip", "x" * 201, "../x.zip", "a b.zip"]
        for name in bad_names:
            with self.subTest(name=name):
                counts, warnings = net_installs.asset_counts_from_releases([release("v1.9.0", {name: 3, "ok.zip": 1})])
                self.assertEqual([c.asset for c in counts], ["ok.zip"])
                self.assertEqual(len(warnings), 1)
                self.assertNotIn("calc", warnings[0])

    def test_an_untrusted_tag_name_skips_the_whole_release(self):
        counts, warnings = net_installs.asset_counts_from_releases([release("v1\n::error::x", {"ok.zip": 1})])
        self.assertEqual((counts, len(warnings)), ([], 1))

    def test_an_unexpected_shape_is_an_error(self):
        for bad in ({"message": "rate limited"}, [{"tag_name": "v1", "assets": "x"}], [release("v1", {"a.zip": -1})]):
            with self.subTest(bad=bad), self.assertRaises(stats_csv.CollectError):
                net_installs.asset_counts_from_releases(bad)

    def test_the_fixture_parses_into_one_record_per_asset_and_date(self):
        records = net_installs.own_records_from_json(fixture_document())
        self.assertEqual(len(records), 6)
        self.assertEqual({r.run_id for r in records}, {"1234567890"})

    def test_a_record_that_breaks_the_schema_is_rejected(self):
        good = fixture_document()
        broken = [
            [],
            {**good, "run_id": 7},
            {**good, "run_id": "1\n"},
            {**good, "counts": []},
            {**good, "counts": {"20260820": {}}},
            {**good, "counts": {"2026-08-20": {ZIP: 4}}},
            {**good, "counts": {"2026-08-20": {ZIP: {"draft": 1}}}},
            {**good, "counts": {"2026-08-20": {"../x.zip": {"draft": 1, "published": 0}}}},
            {**good, "counts": {"2026-08-20": {ZIP: {"draft": True, "published": 0}}}},
        ]
        for document in broken:
            with self.subTest(document=document), self.assertRaises(net_installs.OwnRecordError):
                net_installs.own_records_from_json(document)

    def test_a_record_must_name_the_run_that_uploaded_it(self):
        with self.assertRaisesRegex(net_installs.OwnRecordError, "run_id"):
            net_installs.own_records_from_json(fixture_document(), expected_run_id="42")
        self.assertEqual(len(net_installs.own_records_from_json(fixture_document(), expected_run_id="1234567890")), 6)

    def test_an_error_message_never_carries_a_raw_untrusted_value(self):
        hostile = "\n::error::injected"
        document = {"run_id": "1", "counts": {"2026-08-20": {"ok.zip": {"draft": hostile, "published": 0}}}}
        with self.assertRaises(net_installs.OwnRecordError) as raised:
            net_installs.own_records_from_json({**document, "counts": {hostile: {}}})
        self.assertNotIn("\n", str(raised.exception))
        with self.assertRaises(stats_csv.CollectError) as raised_csv:
            stats_csv.csv_int(hostile)
        self.assertNotIn("\n", str(raised_csv.exception))

    def test_traffic_days_are_read_by_metric(self):
        response = {"count": 5, "views": [{"timestamp": "2026-08-14T00:00:00Z", "count": 5, "uniques": 2}]}
        days = net_installs.traffic_from_json("views", response)
        self.assertEqual(days, [net_installs.TrafficDay(d("2026-08-14"), "views", 5, 2)])
        with self.assertRaises(stats_csv.CollectError):
            net_installs.traffic_from_json("clones", response)


class MergeRules(unittest.TestCase):
    COUNTS = [net_installs.AssetCount("v1.9.0", ZIP, 5)]

    def rows(self, day: str, count: int) -> list[dict]:
        return [{"date": day, "tag": "v1.9.0", "asset": ZIP, "download_count": str(count)}]

    def test_the_first_snapshot_is_appended(self):
        self.assertEqual(net_installs.merge_snapshot([], self.COUNTS, d("2026-08-20")), self.rows("2026-08-20", 5))

    def test_equal_counts_append_nothing(self):
        existing = self.rows("2026-08-20", 5)
        self.assertEqual(net_installs.merge_snapshot(existing, self.COUNTS, d("2026-08-21")), existing)

    def test_a_changed_count_appends_a_full_snapshot(self):
        existing = self.rows("2026-08-20", 4)
        merged = net_installs.merge_snapshot(existing, self.COUNTS, d("2026-08-21"))
        self.assertEqual(merged, existing + self.rows("2026-08-21", 5))

    def test_a_second_run_for_the_same_snapshot_date_replaces_that_dates_rows(self):
        merged = net_installs.merge_snapshot(self.rows("2026-08-20", 4), self.COUNTS, d("2026-08-20"))
        self.assertEqual(merged, self.rows("2026-08-20", 5))

    def test_no_assets_leave_the_rows_alone(self):
        self.assertEqual(net_installs.merge_snapshot([], [], d("2026-08-20")), [])

    def test_a_recorded_run_is_not_recorded_twice(self):
        records = net_installs.own_records_from_json(fixture_document())
        once = net_installs.merge_own_records([], records)
        self.assertEqual(len(once), 6)
        self.assertEqual(net_installs.merge_own_records(once, records), once)

    def test_the_newest_traffic_value_of_a_day_wins(self):
        existing = [{"date": "2026-08-14", "metric": "views", "count": "1", "uniques": "1"}]
        merged = net_installs.merge_traffic(existing, [net_installs.TrafficDay(d("2026-08-14"), "views", 4, 2), net_installs.TrafficDay(d("2026-08-13"), "clones", 3, 1)])
        self.assertEqual([(r["date"], r["metric"], r["count"]) for r in merged], [("2026-08-13", "clones", "3"), ("2026-08-14", "views", "4")])


# --------------------------------------------------------------------------
#  The collector
# --------------------------------------------------------------------------

GOOD_RUN = {"path": ".github/workflows/release.yml", "event": "push"}


def artifact(run_id: int, expired: bool = False, **run_fields) -> dict:
    run = {"id": run_id, "repository_id": 7, "head_repository_id": 7, **run_fields}
    return {"id": run_id, "name": "own-downloads", "expired": expired, "workflow_run": run,
            "archive_download_url": f"https://api.example/artifacts/{run_id}/zip"}


def artifact_url(run_id: int) -> str:
    return f"https://api.example/artifacts/{run_id}/zip"


class FakeApi:
    """Canned API JSON by path and artifacts by URL. A failing path raises like the real client."""

    def __init__(self, releases=(), artifacts=(), downloads=None, traffic=None, failing=(), runs=None):
        self.responses = {
            f"/repos/{REPO}/releases": list(releases),
            f"/repos/{REPO}/actions/artifacts": {"total_count": len(artifacts), "artifacts": list(artifacts)},
        }
        for item in artifacts:
            run_id = (item.get("workflow_run") or {}).get("id")
            self.responses[f"/repos/{REPO}/actions/runs/{run_id}"] = (runs or {}).get(run_id, GOOD_RUN)
        for metric, document in (traffic or {}).items():
            self.responses[f"/repos/{REPO}/traffic/{metric}"] = document
        self.downloads = downloads or {}
        self.failing = set(failing)
        self.requested: list[str] = []

    def get_json(self, path, params=None):
        self.requested.append(path)
        if path in self.failing:
            raise stats_csv.CollectError(f"GET {path}: HTTP 403 rate limit exceeded")
        return self.responses[path]

    def download(self, url):
        self.requested.append(url)
        result = self.downloads[url]
        if isinstance(result, Exception):
            raise result
        return result


class CollectRun(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.stats = Path(directory.name) / "stats"

    def run_collect(self, api, traffic_api=None, run_date="2026-08-21"):
        return collect.collect(api, traffic_api, REPO, self.stats, d(run_date))

    def text(self, name: str) -> str:
        return (self.stats / name).read_text(encoding="utf-8")

    def snapshot(self):
        return {p.name: p.read_bytes() for p in self.stats.iterdir()}

    def test_the_first_run_without_releases_creates_header_only_files(self):
        result = self.run_collect(FakeApi())
        self.assertEqual(self.text("downloads.csv"), "date,tag,asset,download_count\n")
        self.assertEqual(self.text("own-downloads.csv"), "run_id,date,asset,draft,published\n")
        self.assertEqual(self.text("traffic.csv"), "date,metric,count,uniques\n")
        self.assertEqual(len(result.changed_files), 3)

    def test_the_snapshot_is_dated_the_previous_utc_day(self):
        self.run_collect(FakeApi(releases=[release("v1.9.0", {ZIP: 4, "teststand-mcp.sha256": 1})]), run_date="2026-08-21")
        self.assertEqual(self.text("downloads.csv").splitlines(), [
            "date,tag,asset,download_count",
            "2026-08-20,v1.9.0,teststand-mcp.sha256,1",
            f"2026-08-20,v1.9.0,{ZIP},4",
        ])

    def test_the_assets_of_a_draft_release_are_in_the_snapshot(self):
        self.run_collect(FakeApi(releases=[release("v1.9.0", {ZIP: 2}, draft=True)]))
        self.assertIn(f"2026-08-20,v1.9.0,{ZIP},2", self.text("downloads.csv"))

    def test_a_second_run_with_equal_counts_changes_nothing(self):
        api = FakeApi(releases=[release("v1.9.0", {ZIP: 4})])
        self.run_collect(api)
        before = self.snapshot()
        result = self.run_collect(api, run_date="2026-08-22")
        self.assertEqual(result.changed_files, [])
        self.assertEqual(self.snapshot(), before)

    def test_an_api_error_on_the_artifact_listing_writes_nothing(self):
        api = FakeApi(releases=[release("v1.9.0", {ZIP: 4})], failing=[f"/repos/{REPO}/actions/artifacts"])
        with self.assertRaisesRegex(stats_csv.CollectError, "rate limit"):
            self.run_collect(api)
        self.assertFalse(self.stats.exists())

    def test_an_error_on_a_later_day_leaves_the_existing_files_untouched(self):
        self.run_collect(FakeApi(releases=[release("v1.9.0", {ZIP: 4})]))
        before = self.snapshot()
        with self.assertRaises(stats_csv.CollectError):
            self.run_collect(FakeApi(releases=[release("v1.9.0", {ZIP: 9})], failing=[f"/repos/{REPO}/releases"]), run_date="2026-08-22")
        self.assertEqual(self.snapshot(), before)

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
        with self.assertRaises(stats_csv.CollectError):
            self.run_collect(FakeApi(releases=[release("v1.9.0", {ZIP: 4})]), traffic_api=traffic_api)
        self.assertFalse(self.stats.exists())

    def test_a_corrupt_stats_file_is_an_error(self):
        self.stats.mkdir(parents=True)
        (self.stats / "downloads.csv").write_text("date,asset\n2026-08-20,x\n", encoding="utf-8")
        with self.assertRaisesRegex(stats_csv.CollectError, "columns"):
            self.run_collect(FakeApi())

    def test_an_endless_listing_stops_at_the_page_bound(self):
        class Endless(FakeApi):
            def get_json(self, path, params=None):
                return [release("v1", {})] * collect.PAGE_SIZE

        with self.assertRaisesRegex(stats_csv.CollectError, "MAX_PAGES"):
            self.run_collect(Endless())


class OwnDownloadArtifacts(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.stats = Path(directory.name) / "stats"

    def run_collect(self, api, run_date="2026-08-21"):
        return collect.collect(api, None, REPO, self.stats, d(run_date))

    def own_rows(self) -> list[str]:
        return (self.stats / "own-downloads.csv").read_text(encoding="utf-8").splitlines()[1:]

    def api(self, *artifacts, payloads=None, **kwargs):
        downloads = {artifact_url(a["workflow_run"]["id"]): (payloads or {}).get(a["workflow_run"]["id"], artifact_zip(fixture_document()))
                     for a in artifacts if a.get("workflow_run")}
        return FakeApi(releases=[release("v1.9.0", {ZIP: 4})], artifacts=list(artifacts), downloads=downloads, **kwargs)

    def test_an_artifact_of_a_release_run_is_recorded(self):
        result = self.run_collect(self.api(artifact(1234567890)))
        self.assertEqual(len(self.own_rows()), 6)
        self.assertEqual(result.warnings, [])

    def test_a_run_is_recorded_once_and_not_downloaded_again(self):
        self.run_collect(self.api(artifact(1234567890)))
        again = self.api(artifact(1234567890), payloads={1234567890: b"must not be read"})
        self.run_collect(again, run_date="2026-08-22")
        self.assertEqual(len(self.own_rows()), 6)
        self.assertNotIn(artifact_url(1234567890), again.requested)

    def test_two_artifacts_naming_one_run_count_once_and_the_run_is_looked_up_once(self):
        first, second = artifact(1234567890), {**artifact(1234567890), "id": 999}
        api = self.api(first, second)
        self.run_collect(api)
        self.assertEqual(len(self.own_rows()), 6)
        self.assertEqual(api.requested.count(f"/repos/{REPO}/actions/runs/1234567890"), 1)
        self.assertEqual(api.requested.count(artifact_url(1234567890)), 1)

    def test_a_record_without_any_download_still_marks_its_run_as_known(self):
        empty = {"run_id": "55", "counts": {}}
        self.run_collect(self.api(artifact(55), payloads={55: artifact_zip(empty)}))
        self.assertEqual(self.own_rows(), ["55,2026-08-21,,0,0"])
        again = self.api(artifact(55), payloads={55: artifact_zip(empty)})
        self.run_collect(again, run_date="2026-08-22")
        self.assertNotIn(artifact_url(55), again.requested)
        self.assertEqual(len(self.own_rows()), 1)

    def test_zero_matching_runs_are_fine(self):
        result = self.run_collect(FakeApi(artifacts=[]))
        self.assertEqual(result.warnings, [])

    def test_an_expired_artifact_is_not_downloaded(self):
        api = self.api(artifact(5, expired=True))
        self.run_collect(api)
        self.assertFalse([r for r in api.requested if r.startswith("https://") or "/runs/" in r])

    def test_a_record_naming_another_run_is_rejected(self):
        api = self.api(artifact(5), payloads={5: artifact_zip(fixture_document())})
        result = self.run_collect(api)
        self.assertEqual((len(result.warnings), self.own_rows()), (1, []))

    def test_each_failed_provenance_check_rejects_the_artifact_without_downloading_it(self):
        cases = {
            "from a fork": (artifact(5, head_repository_id=8), {}),
            "without repository ids": ({**artifact(5), "workflow_run": {"id": 5}}, {}),
            "another workflow": (artifact(5), {5: {"path": ".github/workflows/ci.yml", "event": "push"}}),
            "a look-alike path": (artifact(5), {5: {"path": "x.github/workflows/release.yml", "event": "push"}}),
            "a pull request": (artifact(5), {5: {"path": ".github/workflows/release.yml", "event": "pull_request"}}),
            "a schedule": (artifact(5), {5: {"path": ".github/workflows/release.yml", "event": "schedule"}}),
            "an unreadable run": (artifact(5), {5: ["not", "a", "run"]}),
        }
        for name, (item, runs) in cases.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as directory:
                self.stats = Path(directory) / "stats"
                api = self.api(item, runs=runs)
                result = self.run_collect(api)
                self.assertEqual(len(result.warnings), 1, name)
                self.assertEqual(self.own_rows(), [], name)
                self.assertNotIn(artifact_url(5), api.requested, name)

    def test_a_rejected_run_is_looked_up_once_however_many_artifacts_name_it(self):
        first, second = artifact(5), {**artifact(5), "id": 999}
        api = self.api(first, second, runs={5: {"path": ".github/workflows/ci.yml", "event": "push"}})
        result = self.run_collect(api)
        self.assertEqual(len(result.warnings), 2)
        self.assertEqual(api.requested.count(f"/repos/{REPO}/actions/runs/5"), 1)

    def test_a_run_path_with_a_ref_suffix_and_a_manual_start_are_accepted(self):
        runs = {5: {"path": ".github/workflows/release.yml@refs/tags/v1.9.0", "event": "workflow_dispatch"}}
        record = artifact_zip({"run_id": "5", "counts": {"2026-08-20": {ZIP: {"draft": 1, "published": 0}}}})
        self.run_collect(self.api(artifact(5), runs=runs, payloads={5: record}))
        self.assertEqual(self.own_rows(), [f"5,2026-08-20,{ZIP},1,0"])

    def test_a_tag_push_run_is_accepted_whatever_its_branch_name(self):
        item = artifact(5, head_branch="v1.9.0")
        record = artifact_zip({"run_id": "5", "counts": {"2026-08-20": {ZIP: {"draft": 1, "published": 0}}}})
        self.run_collect(self.api(item, payloads={5: record}))
        self.assertEqual(len(self.own_rows()), 1)

    def test_an_artifact_without_a_workflow_run_is_skipped_with_a_warning(self):
        result = self.run_collect(self.api({**artifact(5), "workflow_run": None}, payloads={}))
        self.assertEqual(len(result.warnings), 1)

    def test_one_bad_artifact_never_fails_the_run_or_hides_a_good_one(self):
        deep = artifact_zip("[" * 100000)
        broken = {
            5: b"not a zip",
            6: artifact_zip({}, name="other.json"),
            7: artifact_zip({"run_id": "7", "counts": []}),
            8: deep,
            9: stats_csv.CollectError("GET /x: the response is larger than 1048576 bytes"),
            10: artifact_zip({"run_id": "10", "counts": {"2026-08-20": {ZIP: {"draft": 1, "published": 0}}}}),
        }
        api = self.api(*[artifact(n) for n in broken], payloads=broken)
        result = self.run_collect(api)
        self.assertEqual(len(result.warnings), 5)
        self.assertEqual(self.own_rows(), [f"10,2026-08-20,{ZIP},1,0"])
        self.assertIn(f"2026-08-20,v1.9.0,{ZIP},4", (self.stats / "downloads.csv").read_text(encoding="utf-8"))

    def test_a_failing_run_lookup_is_a_warning_for_that_artifact_only(self):
        api = self.api(artifact(5), failing=[f"/repos/{REPO}/actions/runs/5"])
        result = self.run_collect(api)
        self.assertEqual(len(result.warnings), 1)
        self.assertEqual(len(self.stats.joinpath("downloads.csv").read_text(encoding="utf-8").splitlines()), 2)

    def test_a_warning_never_carries_a_raw_untrusted_value(self):
        hostile = {"run_id": "5", "counts": {"2026-08-20": {"bad\n::error::x": {"draft": 1, "published": 0}}}}
        result = self.run_collect(self.api(artifact(5), payloads={5: artifact_zip(hostile)}))
        self.assertEqual(len(result.warnings), 1)
        self.assertNotIn("\n", result.warnings[0])


class CommandLine(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.stats = Path(directory.name) / "stats"
        self.tokens: list[str] = []
        self.failing: list[str] = []
        quiet = ExitStack()
        quiet.enter_context(redirect_stdout(io.StringIO()))
        quiet.enter_context(redirect_stderr(io.StringIO()))
        self.addCleanup(quiet.close)

    def factory(self, token):
        self.tokens.append(token)
        empty_traffic = {"views": {"views": []}, "clones": {"clones": []}}
        return FakeApi(releases=[release("v1.9.0", {ZIP: 4})], traffic=empty_traffic, failing=self.failing)

    def run_main(self, env, clock=None, extra=()):
        args = ["--stats-dir", str(self.stats), *extra]
        kwargs = {"clock": clock} if clock else {}
        return collect.main(args, env=env, client_factory=self.factory, **kwargs)

    def test_the_snapshot_is_dated_the_previous_utc_day_across_the_midnight_boundary(self):
        env = {"GITHUB_TOKEN": "t", "GITHUB_REPOSITORY": REPO}
        before = datetime(2026, 8, 20, 23, 59, 59, tzinfo=timezone.utc)
        self.assertEqual(self.run_main(env, clock=lambda: before), 0)
        self.assertIn("2026-08-19,v1.9.0", (self.stats / "downloads.csv").read_text(encoding="utf-8"))
        (self.stats / "downloads.csv").unlink()
        self.assertEqual(self.run_main(env, clock=lambda: before + timedelta(seconds=1)), 0)
        self.assertIn("2026-08-20,v1.9.0", (self.stats / "downloads.csv").read_text(encoding="utf-8"))

    def test_today_names_the_run_date_and_the_snapshot_is_the_day_before(self):
        self.assertEqual(self.run_main({"GITHUB_TOKEN": "t", "GITHUB_REPOSITORY": REPO}, extra=["--today", "2026-08-21"]), 0)
        self.assertIn("2026-08-20,v1.9.0", (self.stats / "downloads.csv").read_text(encoding="utf-8"))

    def test_only_a_set_traffic_token_creates_a_traffic_client(self):
        env = {"GITHUB_TOKEN": "main", "GITHUB_REPOSITORY": REPO, "STATS_TRAFFIC_TOKEN": "  "}
        self.assertEqual(self.run_main(env, extra=["--today", "2026-08-21"]), 0)
        self.assertEqual(self.tokens, ["main"])

    def test_a_set_traffic_token_creates_the_main_client_first_and_a_traffic_client(self):
        env = {"GITHUB_TOKEN": "main", "GITHUB_REPOSITORY": REPO, "STATS_TRAFFIC_TOKEN": "traffic"}
        self.assertEqual(self.run_main(env, extra=["--today", "2026-08-21"]), 0)
        self.assertEqual(self.tokens, ["main", "traffic"])

    def test_an_api_failure_returns_one_and_leaves_no_stats_directory(self):
        self.failing = [f"/repos/{REPO}/releases"]
        self.assertEqual(self.run_main({"GITHUB_TOKEN": "t", "GITHUB_REPOSITORY": REPO}, extra=["--today", "2026-08-21"]), 1)
        self.assertFalse(self.stats.exists())

    def test_a_missing_token_a_bad_repo_and_a_bad_date_exit_non_zero_without_files(self):
        cases = [({"GITHUB_REPOSITORY": REPO}, ()), ({"GITHUB_TOKEN": "t"}, ()),
                 ({"GITHUB_TOKEN": "t", "GITHUB_REPOSITORY": REPO + "\n"}, ()),
                 ({"GITHUB_TOKEN": "t", "GITHUB_REPOSITORY": "-owner/name"}, ()),
                 ({"GITHUB_TOKEN": "t", "GITHUB_REPOSITORY": REPO}, ["--today", "20-08-2026"])]
        for env, extra in cases:
            with self.subTest(env=sorted(env.items()), extra=extra):
                self.assertEqual(self.run_main(env, extra=extra), 1)
                self.assertFalse(self.stats.exists())


# --------------------------------------------------------------------------
#  The HTTP client, against a local server
# --------------------------------------------------------------------------

class _Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.seen.append((self.path, self.headers.get("Authorization")))
        port = self.server.server_port
        if self.path.startswith("/limited"):
            self.send_response(429, "rate limit exceeded")
            self.end_headers()
        elif self.path.startswith("/forbidden"):
            self.send_response(403, "forbidden")
            self.end_headers()
        elif self.path.startswith("/redirect"):
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{port}/blob")
            self.end_headers()
        elif self.path.startswith("/artifact-to-http"):
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{port}/blob")
            self.end_headers()
        elif self.path.startswith("/artifact-to-ftp"):
            self.send_response(302)
            self.send_header("Location", "ftp://files.invalid/blob")
            self.end_headers()
        elif self.path.startswith("/slow"):
            self.server.release.wait(timeout=10)
            self.send_response(200)
            self.end_headers()
        elif self.path.startswith("/huge"):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"x" * (github_api.MAX_ARTIFACT_BYTES + 10))
        elif self.path.startswith("/deep"):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"[" * 100000)
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok": true}' if self.path.startswith("/json") else b"payload")


def loopback_http(target) -> bool:
    return target.scheme == "http" and target.hostname == "127.0.0.1"


class RealClient(unittest.TestCase):
    def setUp(self):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        server.seen = []
        server.release = threading.Event()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.addCleanup(server.release.set)  # runs first: frees a handler that is still waiting
        self.server = server
        self.root = f"http://127.0.0.1:{server.server_port}"
        self.client = github_api.GitHubClient("SECRET-TOKEN", api_root=self.root, redirect_allowed=loopback_http)
        self.strict_client = github_api.GitHubClient("SECRET-TOKEN", api_root=self.root)

    def test_the_token_goes_in_the_header_and_never_in_the_url(self):
        self.assertEqual(self.client.get_json("/json", {"per_page": "100"}), {"ok": True})
        path, header = self.server.seen[0]
        self.assertEqual(header, "Bearer SECRET-TOKEN")
        self.assertNotIn("SECRET", path)

    def test_an_error_response_fails_without_leaking_the_token(self):
        with self.assertRaises(stats_csv.CollectError) as raised:
            self.client.get_json("/forbidden")
        self.assertIn("403", str(raised.exception))
        self.assertNotIn("SECRET", str(raised.exception))

    def test_a_rate_limit_response_is_an_error_naming_the_status(self):
        with self.assertRaisesRegex(stats_csv.CollectError, "429"):
            self.client.get_json("/limited")

    def test_a_redirect_from_a_json_call_is_an_error_and_is_not_followed(self):
        with self.assertRaisesRegex(stats_csv.CollectError, "redirect"):
            self.client.get_json("/redirect")
        self.assertEqual([path for path, _ in self.server.seen], ["/redirect"])

    def test_an_artifact_redirect_is_fetched_without_credentials(self):
        self.assertEqual(self.client.download(f"{self.root}/artifact-to-http/1/zip"), b"payload")
        self.assertEqual(self.server.seen[0][1], "Bearer SECRET-TOKEN")
        self.assertEqual(self.server.seen[1], ("/blob", None))

    def test_production_accepts_only_an_https_redirect_target(self):
        for path in ("/artifact-to-http/1/zip", "/artifact-to-ftp/1/zip"):
            with self.subTest(path), self.assertRaisesRegex(stats_csv.CollectError, "not an https URL"):
                self.strict_client.download(f"{self.root}{path}")
        self.assertNotIn("/blob", [seen for seen, _ in self.server.seen])

    def test_the_https_rule_judges_the_scheme_and_a_host(self):
        for url, expected in (("https://pipelines.example.invalid/blob?sig=1", True), ("http://x.example.invalid/", False),
                              ("https:///nohost", False), ("javascript:alert(1)", False), ("//host.invalid/x", False)):
            with self.subTest(url):
                self.assertEqual(github_api.https_only(urllib.parse.urlsplit(url)), expected)

    def test_credentials_are_never_sent_to_a_url_outside_the_api(self):
        with mock.patch.object(self.client._opener, "open", side_effect=AssertionError("the network must not be touched")):
            for url in ("https://evil.invalid/artifact/1/zip", f"{self.root}.evil.invalid/x", "http://127.0.0.1:1/x",
                        f"{self.root.replace('http', 'https')}/x"):
                with self.subTest(url), self.assertRaisesRegex(stats_csv.CollectError, "outside the API"):
                    self.client.download(url)
        self.assertEqual(self.server.seen, [])

    def test_an_oversized_response_is_refused(self):
        with self.assertRaisesRegex(stats_csv.CollectError, "larger"):
            self.client.download(f"{self.root}/huge")

    def test_a_non_json_body_and_a_deeply_nested_one_are_errors(self):
        for path in ("/text", "/deep"):
            with self.subTest(path), self.assertRaisesRegex(stats_csv.CollectError, "not JSON"):
                self.client.get_json(path)

    def test_a_broken_http_exchange_is_an_error(self):
        with mock.patch.object(self.client._opener, "open", side_effect=http.client.IncompleteRead(b"")):
            with self.assertRaises(stats_csv.CollectError):
                self.client.get_json("/json")

    def test_a_server_that_stops_answering_fails_at_the_timeout(self):
        with mock.patch.object(github_api, "REQUEST_TIMEOUT_SECONDS", 0.3):
            started = time.monotonic()
            with self.assertRaises(stats_csv.CollectError):
                self.client.get_json("/slow")
        self.assertLess(time.monotonic() - started, 5)


# --------------------------------------------------------------------------
#  The site builder
# --------------------------------------------------------------------------

class PageParts(HTMLParser):
    """Collects what the accessibility contract talks about, from the real markup."""

    def __init__(self, page: str):
        super().__init__()
        self.order: list[str] = []
        self.svgs: list[dict] = []
        self.texts: dict[str, str] = {}
        self.direct_labels: list[str] = []
        self.polylines: list[dict] = []
        self.markers: list[str] = []
        self.regions: list[dict] = []
        self.tags: set[str] = set()
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
        self.tags.add(tag)
        if tag in ("svg", "table", "figure"):
            self.order.append(tag)
        if tag == "svg":
            self.svgs.append(attrs)
        if tag == "polyline":
            self.polylines.append(attrs)
        if tag in ("circle", "rect", "polygon") and "marker" in attrs.get("class", "").split():
            self.markers.append(attrs["class"])
        if tag == "div" and attrs.get("class") == "scroll":
            self.regions.append(attrs)
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
        if tag == "text" and "label" in attrs.get("class", "").split():
            self.direct_labels.append(data)


def csv_text(header: str, *rows: str) -> str:
    return header + "".join(row + "\n" for row in rows)


def write_stats(directory: Path, downloads="", own="", traffic="") -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "downloads.csv").write_text(downloads or HEADER["downloads"], encoding="utf-8")
    (directory / "own-downloads.csv").write_text(own or HEADER["own"], encoding="utf-8")
    (directory / "traffic.csv").write_text(traffic or HEADER["traffic"], encoding="utf-8")
    return directory


def page_of(downloads="", own="", traffic="", run_date="2026-08-22", traffic_skipped=False, subtract_drafts=True) -> str:
    with tempfile.TemporaryDirectory() as directory:
        stats = write_stats(Path(directory), downloads, own, traffic)
        return site.build_page(
            stats_csv.read_csv(stats / "downloads.csv", stats_csv.DOWNLOADS_COLUMNS),
            stats_csv.read_csv(stats / "own-downloads.csv", stats_csv.OWN_DOWNLOADS_COLUMNS),
            stats_csv.read_csv(stats / "traffic.csv", stats_csv.TRAFFIC_COLUMNS),
            d(run_date), traffic_skipped, subtract_drafts,
        )


TWO_SNAPSHOTS = csv_text(HEADER["downloads"], f"2026-08-20,v1.9.0,{ZIP},100", f"2026-08-21,v1.9.0,{ZIP},120")
TWO_RUNS_OF_FOUR = csv_text(HEADER["own"], f"1,2026-08-21,{ZIP},3,1", f"2,2026-08-21,{ZIP},3,1")
TRAFFIC_ROWS = csv_text(HEADER["traffic"], "2026-08-20,views,7,3", "2026-08-20,clones,2,1", "2026-08-21,views,4,2")


def contrast(foreground: str, background: str) -> float:
    def luminance(color: str) -> float:
        channels = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        linear = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

    lighter, darker = sorted((luminance(foreground), luminance(background)), reverse=True)
    return (lighter + 0.05) / (darker + 0.05)


class SiteSeries(unittest.TestCase):
    def test_the_asset_names_match_the_release_asset_module(self):
        module = (REPO_ROOT / "build" / "ReleaseAssets.psm1").read_text(encoding="utf-8")
        prefix = re.search(r"-Name ReleaseAssetPrefix -Value '([^']+)'", module).group(1)
        archive = re.search(r'-Name ReleaseArchiveName -Value "\$ReleaseAssetPrefix([^"]+)"', module).group(1)
        versioned = re.search(r'\$script:VersionedArchiveFormat = "\$ReleaseAssetPrefix([^"]+)"', module).group(1)
        self.assertEqual(site.INSTALL_ASSET_NAME, prefix + archive)
        self.assertEqual(site.VERSIONED_ARCHIVE_FORMAT.replace("{}", "{0}"), prefix + versioned)

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

    def test_the_chart_runs_from_the_first_data_point_to_the_last_day_and_is_bounded(self):
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

    def test_every_text_and_series_colour_has_a_contrast_of_at_least_4_5_in_both_schemes(self):
        self.assertEqual(set(site.PALETTE["light"]), set(site.PALETTE["dark"]))
        for scheme, colors in site.PALETTE.items():
            for foreground, background in site.TEXT_PAIRS:
                with self.subTest(scheme=scheme, pair=f"{foreground}/{background}"):
                    self.assertGreaterEqual(contrast(colors[foreground], colors[background]), 4.5)

    def test_the_page_follows_the_preferred_colour_scheme(self):
        self.assertIn("color-scheme: light dark", site.STYLE)
        self.assertIn("@media (prefers-color-scheme: dark)", site.STYLE)
        self.assertIn(site.PALETTE["dark"]["bg"], site.STYLE)


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
        own_rows = csv_text(HEADER["own"], f"1,2026-08-21,{ZIP},30,30")
        row = next(r for r in PageParts(page_of(TWO_SNAPSHOTS, own_rows)).table_rows if r and r[0] == "2026-08-21")
        self.assertEqual(row[1], "0")

    def test_a_value_that_covers_several_days_says_since_when_in_the_table_and_the_description(self):
        gap = csv_text(HEADER["downloads"], f"2026-08-20,v1.9.0,{ZIP},100", f"2026-08-24,v1.9.0,{ZIP},130")
        parts = PageParts(page_of(gap, run_date="2026-08-25"))
        rows = {r[0]: r[1] for r in parts.table_rows if r and r[0].startswith("2026-08")}
        self.assertEqual(rows["2026-08-24 (since 2026-08-20)"], "30")
        desc = parts.texts[parts.svgs[0]["aria-labelledby"].split()[1]]
        self.assertIn("2026-08-24 since 2026-08-20", desc)

    def test_consecutive_days_do_not_claim_to_cover_several_days(self):
        parts = PageParts(page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR))
        self.assertFalse([r for r in parts.table_rows if r and "since" in r[0]])
        self.assertNotIn("since", parts.texts[parts.svgs[0]["aria-labelledby"].split()[1]])

    def test_every_chart_has_a_title_a_description_and_direct_labels(self):
        parts = PageParts(page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR, traffic=TRAFFIC_ROWS))
        self.assertEqual(len(parts.svgs), 2)
        for svg in parts.svgs:
            self.assertEqual(svg["role"], "img")
            title_id, desc_id = svg["aria-labelledby"].split()
            self.assertTrue(parts.texts[title_id].strip())
            self.assertTrue(parts.texts[desc_id].strip())
        installs_desc = parts.texts[parts.svgs[0]["aria-labelledby"].split()[1]]
        self.assertIn("12 in total", installs_desc)
        self.assertEqual(parts.direct_labels, [ZIP, "Versioned archives", "Views", "Clones"])

    def test_every_series_has_a_marker_element_in_the_markup(self):
        parts = PageParts(page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR, traffic=TRAFFIC_ROWS))
        for key in ("latest", "versioned", "views", "clones"):
            with self.subTest(key):
                self.assertTrue([m for m in parts.markers if f"s-{key}" in m.split()])

    def test_a_visible_table_of_the_daily_counts_follows_each_chart(self):
        parts = PageParts(page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR, traffic=TRAFFIC_ROWS))
        self.assertEqual(parts.order, ["figure", "svg", "table", "figure", "svg", "table"])
        self.assertEqual(parts.column_headers[:3], ["Date (UTC)", ZIP, "Versioned archives"])

    def test_no_table_or_chart_is_hidden_from_sighted_users(self):
        page = page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR, traffic=TRAFFIC_ROWS)
        self.assertNotRegex(page, r"(?i)display\s*:\s*none|visibility\s*:\s*hidden|sr-only|visually-hidden|clip\s*:|clip-path")
        self.assertNotRegex(page, r"(?i)\shidden[\s>=]|aria-hidden")

    def test_charts_and_tables_sit_in_focusable_labelled_scroll_regions(self):
        parts = PageParts(page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR, traffic=TRAFFIC_ROWS))
        self.assertEqual(len(parts.regions), 4)
        for region in parts.regions:
            self.assertEqual((region["tabindex"], region["role"]), ("0", "region"))
            self.assertTrue(region["aria-label"].strip())
        self.assertIn(".scroll { overflow-x: auto; }", site.STYLE)

    def test_the_chart_keeps_its_natural_width_so_the_labels_stay_legible_on_a_narrow_screen(self):
        svg = PageParts(page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR)).svgs[0]
        self.assertEqual(svg["width"], str(site.WIDTH))
        self.assertNotRegex(site.STYLE, r"\.chart[^}]*max-width")

    def test_a_chart_is_not_followed_by_a_caption_that_repeats_the_heading(self):
        self.assertNotIn("figcaption", page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR, traffic=TRAFFIC_ROWS))

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
        page = page_of(csv_text(HEADER["downloads"], f"2026-08-20,v1.9.0,{ZIP},100"))
        self.assertNotIn("<svg", page)
        self.assertIn("only a baseline", page)

    def test_a_skipped_traffic_collection_is_stated_in_visible_text(self):
        page = page_of(TWO_SNAPSHOTS, traffic_skipped=True)
        self.assertIn("STATS_TRAFFIC_TOKEN secret is not set", page)
        self.assertEqual(len(PageParts(page).svgs), 1)

    def test_recorded_traffic_is_charted_and_the_token_is_not_mentioned(self):
        page = page_of(TWO_SNAPSHOTS, traffic=TRAFFIC_ROWS)
        self.assertEqual(len(PageParts(page).svgs), 2)
        self.assertNotIn("STATS_TRAFFIC_TOKEN", page)

    def test_a_present_token_without_data_says_nothing_was_recorded_yet(self):
        self.assertIn("No views or clones have been recorded yet", page_of(TWO_SNAPSHOTS))

    def test_the_page_loads_nothing_from_outside_and_runs_no_script(self):
        page = page_of(TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR, traffic=TRAFFIC_ROWS)
        self.assertEqual(PageParts(page).external, [])
        self.assertNotRegex(page, r"https?://")
        self.assertIn("default-src 'none'", page)

    def test_series_labels_are_escaped_in_the_chart_and_the_table(self):
        hostile = site.SeriesStyle("<img src=x onerror=alert(1)>&", "latest", "", "circle")
        chart = site.Chart("c", "t<script>", "u", [d("2026-08-21")], [site.Series(hostile, {d("2026-08-21"): 1})])
        markup = site.render_chart(chart) + site.render_table(chart) + site.render_section("h<b>", chart, "")
        self.assertNotIn("<img", markup)
        self.assertNotIn("<script", markup)
        self.assertNotIn("<b>", markup)
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
        self.assertEqual(self.run_build("--today", "2026-08-22"), 0)
        self.assertIn("<td>12</td>", self.page())

    def test_an_empty_stats_directory_builds_the_empty_state(self):
        self.assertEqual(self.run_build("--today", "2026-08-22"), 0)
        self.assertIn("No download snapshot", self.page())

    def test_the_no_subtract_drafts_flag_reaches_the_calculation(self):
        write_stats(self.root / "stats", TWO_SNAPSHOTS, TWO_RUNS_OF_FOUR)
        self.assertEqual(self.run_build("--today", "2026-08-22", "--no-subtract-drafts"), 0)
        self.assertIn("<td>18</td>", self.page())

    def test_the_traffic_skipped_flag_reaches_the_page(self):
        self.assertEqual(self.run_build("--today", "2026-08-22", "--traffic-skipped"), 0)
        self.assertIn("STATS_TRAFFIC_TOKEN", self.page())

    def test_a_corrupt_csv_fails_the_build_without_writing_a_page(self):
        write_stats(self.root / "stats", csv_text(HEADER["downloads"], f"2026-08-21,v1.9.0,{ZIP},lots"))
        self.assertEqual(self.run_build("--today", "2026-08-22"), 1)
        self.assertFalse((self.out / "index.html").exists())

    def test_the_chart_ends_on_the_day_before_the_run_date_across_midnight(self):
        write_stats(self.root / "stats", TWO_SNAPSHOTS)
        before = datetime(2026, 8, 22, 23, 59, 59, tzinfo=timezone.utc)
        self.assertEqual(self.run_build(clock=lambda: before), 0)
        self.assertNotIn('<th scope="row">2026-08-22', self.page())
        self.assertEqual(self.run_build(clock=lambda: before + timedelta(seconds=1)), 0)
        self.assertIn('<th scope="row">2026-08-22', self.page())


# --------------------------------------------------------------------------
#  The workflow, checked on its text (the standard library has no YAML parser)
# --------------------------------------------------------------------------

class PagesWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = (REPO_ROOT / ".github" / "workflows" / "pages.yml").read_text(encoding="utf-8")
        body = cls.text.split("\njobs:\n", 1)[1]
        cls.jobs = {name: chunk for name, chunk in re.findall(r"(?ms)^  (\w+):\n(.*?)(?=^  \w+:\n|\Z)", body)}
        cls.triggers = cls.text.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]

    def step(self, name: str) -> str:
        match = re.search(rf"(?ms)^      - name: {re.escape(name)}\n(.*?)(?=^      - name: |\Z)", self.jobs["collect"])
        self.assertIsNotNone(match, name)
        return match.group(1)

    def test_it_runs_daily_just_after_midnight_utc_and_by_hand_and_nothing_else_starts_it(self):
        self.assertIn("cron: '17 0 * * *'", self.triggers)
        self.assertRegex(self.triggers, r"(?m)^  workflow_dispatch:")
        self.assertEqual(re.findall(r"(?m)^  (\w+):", self.triggers), ["schedule", "workflow_dispatch"])
        self.assertNotIn("workflow_run", self.triggers)
        self.assertNotIn("workflow_call", self.triggers)

    def test_no_other_workflow_refers_to_it(self):
        for other in (REPO_ROOT / ".github" / "workflows").glob("*.yml"):
            if other.name != "pages.yml":
                self.assertNotIn("pages.yml", other.read_text(encoding="utf-8"), other.name)

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

        self.assertEqual(permissions("collect"), [("contents", "write"), ("actions", "read")])
        self.assertEqual(permissions("deploy"), [("pages", "write"), ("id-token", "write")])

    def test_deploying_is_a_separate_job_that_waits_for_collecting(self):
        self.assertIn("needs: collect", self.jobs["deploy"])
        self.assertIn("actions/deploy-pages@", self.jobs["deploy"])
        self.assertNotIn("deploy-pages", self.jobs["collect"])
        self.assertNotIn("collect.py", self.jobs["deploy"])

    def test_the_checkout_does_not_persist_the_token_and_git_gets_it_through_an_extra_header(self):
        self.assertIn("persist-credentials: false", self.text)
        self.assertNotIn("persist-credentials: true", self.text)
        for name in ("Check out the stats branch as a worktree", "Commit the statistics when they changed"):
            chunk = self.step(name)
            with self.subTest(name):
                self.assertIn("GH_TOKEN: ${{ github.token }}", chunk)
                self.assertIn("extraheader=AUTHORIZATION: basic", chunk)
                self.assertIn("::add-mask::", chunk)
        self.assertNotRegex(self.text, r"git config[^\n]*(extraheader|token)")

    def test_the_token_is_only_ever_given_to_steps_as_environment_variables(self):
        for line in self.text.splitlines():
            if "github.token" in line or "secrets." in line:
                with self.subTest(line=line.strip()):
                    self.assertRegex(line, r"^\s+(GH_TOKEN|GITHUB_TOKEN|STATS_TRAFFIC_TOKEN|HAS_TRAFFIC_TOKEN): \$\{\{ [\w. !=']+ \}\}|^\s*#")
        self.assertNotRegex(self.text, r"(?m)^\s+run:.*\$\{\{")

    def test_the_traffic_token_reaches_only_the_collector_and_the_build_only_learns_whether_it_exists(self):
        lines = [line for line in self.text.splitlines() if "STATS_TRAFFIC_TOKEN" in line and not line.lstrip().startswith("#")]
        self.assertEqual(len(lines), 2)
        self.assertIn("STATS_TRAFFIC_TOKEN: ${{ secrets.STATS_TRAFFIC_TOKEN }}", self.step("Collect download counts"))
        self.assertIn("HAS_TRAFFIC_TOKEN: ${{ secrets.STATS_TRAFFIC_TOKEN != '' }}", self.step("Build the page"))
        self.assertNotIn("echo", "".join(lines))

    def test_the_build_passes_traffic_skipped_exactly_when_the_token_is_absent(self):
        build = self.step("Build the page")
        self.assertRegex(build, r'if \[ "\$HAS_TRAFFIC_TOKEN" != "true" \]; then args\+=\(--traffic-skipped\); fi')
        self.assertIn('"${args[@]}"', build)

    def test_the_scripts_it_runs_exist_and_the_page_is_built_before_the_push_and_the_upload(self):
        for script in re.findall(r"python3 (\.github/\S+\.py)", self.text):
            self.assertTrue((REPO_ROOT / script).is_file(), script)
        steps = [self.text.index(marker) for marker in ("stats/collect.py", "site/build.py", "git -c \"http.https", "upload-pages-artifact@")]
        self.assertEqual(steps, sorted(steps))

    def test_the_commit_step_checks_for_changes_before_it_commits_and_pushes(self):
        commit = self.step("Commit the statistics when they changed")
        positions = [commit.index(marker) for marker in ("diff --cached --quiet", "exit 0", "commit --quiet", "push origin")]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(len(set(positions)), 4)

    def test_a_missing_stats_branch_creates_an_orphan_and_any_other_git_failure_fails(self):
        chunk = self.step("Check out the stats branch as a worktree")
        self.assertIn('case "$status" in', chunk)
        self.assertRegex(chunk, r"(?m)^\s+0\)")
        self.assertRegex(chunk, r"(?ms)^\s+2\)\n.*checkout --orphan stats.*;;")
        self.assertRegex(chunk, r"(?ms)^\s+\*\)\n.*exit 1\n\s+;;")

    def test_nothing_in_the_collecting_job_can_swallow_a_failure(self):
        for forbidden in ("continue-on-error", "if: always()", "if: failure()", "|| true", "|| :"):
            self.assertNotIn(forbidden, self.jobs["collect"], forbidden)
        self.assertEqual(len(re.findall(r"set -euo pipefail", self.jobs["collect"])), 3)


if __name__ == "__main__":
    unittest.main()
