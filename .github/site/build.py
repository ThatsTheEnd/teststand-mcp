"""Builds the static download-stats page from the stats branch CSV files.

    python3 .github/site/build.py --stats-dir <stats worktree> --out <site dir> [--traffic-skipped]

The page is one self-contained index.html: no script, no external CSS, JS, font or image.
Charts are inline SVG with a title, a description and a direct label per series (the series
also differ in line style and marker, so colour is not the only cue), each followed by a
visible table of the daily values. Net installs come from collect.installs_per_day().
Standard library only.
"""

from __future__ import annotations

import argparse
import html
import math
import re
import sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Iterable, Mapping

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "stats"))
import collect  # noqa: E402  (the CSV schema constants and installs_per_day live there)

# The asset names of build/ReleaseAssets.psm1; test_collect.py greps them out of it.
INSTALL_ASSET_NAME = "teststand-mcp.zip"
VERSIONED_ARCHIVE_FORMAT = "teststand-mcp-v{}.zip"
VERSIONED_ARCHIVE_PATTERN = re.compile(
    re.escape(VERSIONED_ARCHIVE_FORMAT.split("{}")[0]) + r"\d+\.\d+\.\d+" + re.escape(VERSIONED_ARCHIVE_FORMAT.split("{}")[1])
)

MAX_CHART_DAYS = 366
MAX_Y_TICKS = 5
MARKERS_UP_TO_DAYS = 45
LABEL_GAP = 16

WIDTH, HEIGHT = 760, 340
MARGIN_LEFT, MARGIN_RIGHT, MARGIN_TOP, MARGIN_BOTTOM = 44, 150, 16, 34
MARKER_RADIUS = 4


@dataclass(frozen=True)
class SeriesStyle:
    label: str
    color: str
    dash: str
    marker: str


@dataclass(frozen=True)
class Series:
    style: SeriesStyle
    values: Mapping[date, int]


@dataclass(frozen=True)
class Chart:
    figure_id: str
    title: str
    unit: str
    days: list[date]
    series: list[Series]


INSTALL_STYLES = {
    "latest": SeriesStyle(INSTALL_ASSET_NAME, "#00508a", "", "circle"),
    "versioned": SeriesStyle("Versioned archives", "#a64200", "8 4", "square"),
}
TRAFFIC_STYLES = {
    "views": SeriesStyle("Views", "#00704f", "2 3", "triangle"),
    "clones": SeriesStyle("Clones", "#8e3568", "10 3 2 3", "diamond"),
}


# --------------------------------------------------------------------------
#  Pure: CSV data -> series
# --------------------------------------------------------------------------

def install_series(installs: Mapping[date, Mapping[str, int]]) -> list[Series]:
    """Net installs per day: the latest-archive asset, and every versioned archive summed."""
    latest = {day: assets.get(INSTALL_ASSET_NAME, 0) for day, assets in installs.items()}
    versioned = {
        day: sum(count for asset, count in assets.items() if VERSIONED_ARCHIVE_PATTERN.fullmatch(asset))
        for day, assets in installs.items()
    }
    return [Series(INSTALL_STYLES["latest"], latest), Series(INSTALL_STYLES["versioned"], versioned)]


def traffic_series(rows: Iterable[Mapping[str, str]]) -> list[Series]:
    values: dict[str, dict[date, int]] = {metric: {} for metric in collect.TRAFFIC_METRICS}
    for row in rows:
        if row["metric"] in values:
            values[row["metric"]][collect.parse_day(row["date"], collect.CollectError)] = collect.csv_int(row["count"])
    return [Series(TRAFFIC_STYLES[metric], values[metric]) for metric in collect.TRAFFIC_METRICS]


def chart_days(series: list[Series], today: date) -> list[date]:
    """Every day from the first data point to today, bounded to the last MAX_CHART_DAYS."""
    recorded = [day for item in series for day in item.values]
    if not recorded:
        return []
    last = max(max(recorded), today)
    first = max(min(recorded), last - timedelta(days=MAX_CHART_DAYS - 1))
    return [first + timedelta(days=offset) for offset in range((last - first).days + 1)]


# --------------------------------------------------------------------------
#  Pure: SVG
# --------------------------------------------------------------------------

def esc(text: object) -> str:
    return html.escape(str(text), quote=True)


def y_ticks(maximum: int) -> list[int]:
    """Integer ticks from 0 with at most MAX_Y_TICKS steps (a 1-2-5 progression)."""
    top = max(maximum, 1)
    for magnitude in (10 ** power for power in range(0, 12)):
        for factor in (1, 2, 5):
            step = factor * magnitude
            if math.ceil(top / step) <= MAX_Y_TICKS:
                return list(range(0, math.ceil(top / step) * step + 1, step))
    raise ValueError("count too large for the chart")


def spread_labels(wanted: list[float], low: float, high: float) -> list[float]:
    """Moves label baselines apart so that no two are closer than LABEL_GAP."""
    order = sorted(range(len(wanted)), key=lambda index: wanted[index])
    placed = [0.0] * len(wanted)
    previous = low - LABEL_GAP
    for index in order:
        previous = max(wanted[index], previous + LABEL_GAP)
        placed[index] = previous
    overflow = max(placed, default=low) - high
    return [position - overflow for position in placed] if overflow > 0 else placed


def marker_svg(shape: str, x: float, y: float, color: str) -> str:
    r = MARKER_RADIUS
    common = f'fill="{color}" stroke="#ffffff" stroke-width="1"'
    if shape == "circle":
        return f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" {common}/>'
    if shape == "square":
        return f'<rect x="{x - r:.1f}" y="{y - r:.1f}" width="{2 * r}" height="{2 * r}" {common}/>'
    outline = {
        "triangle": [(x, y - r - 1), (x + r + 1, y + r), (x - r - 1, y + r)],
        "diamond": [(x, y - r - 1), (x + r + 1, y), (x, y + r + 1), (x - r - 1, y)],
    }[shape]
    points = " ".join(f"{px:.1f},{py:.1f}" for px, py in outline)
    return f'<polygon points="{points}" {common}/>'


def describe(chart: Chart) -> str:
    """The text alternative of the chart: range, per-series totals and peaks."""
    parts = [f"Line chart of {chart.unit} from {chart.days[0]} to {chart.days[-1]}."]
    for item in chart.series:
        total = sum(item.values.values())
        peak_day = max(item.values, key=lambda day: (item.values[day], day), default=None)
        peak = f", highest {item.values[peak_day]} on {peak_day}" if peak_day and item.values[peak_day] else ""
        parts.append(f"{item.style.label}: {total} in total{peak}.")
    parts.append("A table with every daily value follows the chart.")
    return " ".join(parts)


def render_chart(chart: Chart) -> str:
    plot_w = WIDTH - MARGIN_LEFT - MARGIN_RIGHT
    plot_h = HEIGHT - MARGIN_TOP - MARGIN_BOTTOM
    ticks = y_ticks(max((v for s in chart.series for v in s.values.values()), default=0))
    top = ticks[-1]
    count = len(chart.days)

    def x_of(index: int) -> float:
        return MARGIN_LEFT + (plot_w * index / (count - 1) if count > 1 else plot_w / 2)

    def y_of(value: int) -> float:
        return MARGIN_TOP + plot_h * (1 - value / top)

    ident = esc(chart.figure_id)
    out = [
        f'<svg role="img" aria-labelledby="{ident}-title {ident}-desc" viewBox="0 0 {WIDTH} {HEIGHT}" width="{WIDTH}" height="{HEIGHT}" class="chart">',
        f'<title id="{ident}-title">{esc(chart.title)}</title>',
        f'<desc id="{ident}-desc">{esc(describe(chart))}</desc>',
    ]
    for tick in ticks:
        y = y_of(tick)
        out.append(f'<line x1="{MARGIN_LEFT}" x2="{WIDTH - MARGIN_RIGHT}" y1="{y:.1f}" y2="{y:.1f}" class="grid"/>')
        out.append(f'<text x="{MARGIN_LEFT - 6}" y="{y + 4:.1f}" text-anchor="end" class="tick">{tick}</text>')
    for index in sorted({0, (count - 1) // 2, count - 1}):
        anchor = "start" if index == 0 and count > 1 else "end" if index == count - 1 and count > 1 else "middle"
        out.append(f'<text x="{x_of(index):.1f}" y="{HEIGHT - 10}" text-anchor="{anchor}" class="tick">{chart.days[index]}</text>')

    label_wanted = [y_of(item.values.get(chart.days[-1], 0)) + 4 for item in chart.series]
    label_y = spread_labels(label_wanted, MARGIN_TOP + 10, HEIGHT - MARGIN_BOTTOM)
    for item, text_y in zip(chart.series, label_y):
        style = item.style
        points = [(x_of(i), y_of(item.values.get(day, 0))) for i, day in enumerate(chart.days)]
        dash = f' stroke-dasharray="{style.dash}"' if style.dash else ""
        path = " ".join(f"{x:.1f},{y:.1f}" for x, y in points)
        out.append(f'<polyline points="{path}" fill="none" stroke="{style.color}" stroke-width="2"{dash}/>')
        shown = points if count <= MARKERS_UP_TO_DAYS else points[-1:]
        out.extend(marker_svg(style.marker, x, y, style.color) for x, y in shown)
        out.append(f'<text x="{x_of(count - 1) + 10:.1f}" y="{text_y:.1f}" fill="{style.color}" class="label">{esc(style.label)}</text>')
    out.append("</svg>")
    return "\n".join(out)


def render_table(chart: Chart) -> str:
    head = "".join(f'<th scope="col">{esc(item.style.label)}</th>' for item in chart.series)
    rows = "\n".join(
        f'<tr><th scope="row">{day}</th>' + "".join(f"<td>{item.values.get(day, 0)}</td>" for item in chart.series) + "</tr>"
        for day in chart.days
    )
    return (
        f"<table>\n<caption>{esc(chart.title)}: daily values</caption>\n"
        f'<thead><tr><th scope="col">Date (UTC)</th>{head}</tr></thead>\n<tbody>\n{rows}\n</tbody>\n</table>'
    )


# --------------------------------------------------------------------------
#  Pure: the page
# --------------------------------------------------------------------------

STYLE = """
:root { color-scheme: light; }
body { margin: 0; background: #ffffff; color: #1a1a1a; font: 16px/1.5 system-ui, sans-serif; }
main { max-width: 52rem; margin: 0 auto; padding: 1rem; }
h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
figure { margin: 0; }
.chart { max-width: 100%; height: auto; }
.grid { stroke: #c8c8c8; stroke-width: 1; }
.tick { font-size: 11px; fill: #404040; }
.label { font-size: 12px; font-weight: 600; }
.note { border-left: 4px solid #595959; padding: 0.25rem 0.75rem; background: #f3f3f3; }
table { border-collapse: collapse; margin-top: 1rem; }
caption { text-align: left; font-weight: 600; padding-bottom: 0.25rem; }
th, td { border: 1px solid #8a8a8a; padding: 0.15rem 0.6rem; text-align: right; }
th[scope=row], thead th:first-child { text-align: left; }
footer { margin-top: 2rem; font-size: 0.9rem; color: #404040; }
"""


def render_section(heading: str, chart: Chart | None, empty_message: str) -> str:
    if chart is None:
        return f'<section>\n<h2>{esc(heading)}</h2>\n<p class="note">{esc(empty_message)}</p>\n</section>'
    return (
        f"<section>\n<h2>{esc(heading)}</h2>\n<figure>\n{render_chart(chart)}\n"
        f"<figcaption>{esc(chart.unit.capitalize())}.</figcaption>\n</figure>\n{render_table(chart)}\n</section>"
    )


def render_page(installs: Chart | None, traffic: Chart | None, traffic_skipped: bool, data_through: date | None,
                installs_empty: str, subtract_drafts: bool) -> str:
    if traffic_skipped:
        traffic_section = render_section(
            "Repository traffic", None,
            "Traffic (views and clones) is not recorded: the optional STATS_TRAFFIC_TOKEN secret is not set, so GitHub's traffic API was skipped.")
    else:
        traffic_section = render_section("Repository traffic", traffic, "No views or clones have been recorded yet.")
    drafts = "including" if subtract_drafts else "excluding"
    through = f"Data through {data_through} (UTC)." if data_through else "No data has been collected yet."
    return (
        '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">\n'
        f"<title>TestStand MCP plugin: download statistics</title>\n<style>{STYLE}</style>\n</head>\n<body>\n<main>\n"
        "<h1>TestStand MCP plugin: download statistics</h1>\n"
        f"<p>Installs per day are the growth of the release assets' cumulative download counts between two snapshots, "
        f"minus the downloads made by this repository's own release workflow ({drafts} its verification downloads of the draft release). {esc(through)}</p>\n"
        f'{render_section("Installs per day", installs, installs_empty)}\n{traffic_section}\n'
        "<footer>Generated from the <code>stats</code> branch by the pages workflow.</footer>\n</main>\n</body>\n</html>\n"
    )


def build_page(downloads: list[dict[str, str]], own: list[dict[str, str]], traffic: list[dict[str, str]],
               today: date, traffic_skipped: bool, subtract_drafts: bool) -> str:
    snapshots = collect.snapshots_from_rows(downloads)
    installs = collect.installs_per_day(snapshots, collect.own_records_from_rows(own), subtract_drafts)
    install_items = install_series(installs)
    install_days = chart_days(install_items, today)
    traffic_items = traffic_series(traffic)
    traffic_days = chart_days(traffic_items, today)

    if not snapshots:
        installs_empty = "No download snapshot has been recorded yet. The first daily run creates it."
    else:
        installs_empty = "The first snapshot is only a baseline. Installs per day appear once a later snapshot differs from it."
    installs_chart = Chart("installs", "Installs per day", "net installs per day", install_days, install_items) if install_days else None
    traffic_chart = Chart("traffic", "Repository traffic per day", "views and clones per day", traffic_days, traffic_items) if traffic_days else None
    through = max([*snapshots, *(day for item in traffic_items for day in item.values)], default=None)
    return render_page(installs_chart, traffic_chart, traffic_skipped, through, installs_empty, subtract_drafts)


# --------------------------------------------------------------------------
#  I/O
# --------------------------------------------------------------------------

def build_site(stats_dir: Path, out_dir: Path, today: date, traffic_skipped: bool, subtract_drafts: bool) -> Path:
    page = build_page(
        collect.read_csv(stats_dir / collect.DOWNLOADS_FILE, collect.DOWNLOADS_COLUMNS),
        collect.read_csv(stats_dir / collect.OWN_DOWNLOADS_CSV, collect.OWN_DOWNLOADS_COLUMNS),
        collect.read_csv(stats_dir / collect.TRAFFIC_FILE, collect.TRAFFIC_COLUMNS),
        today, traffic_skipped, subtract_drafts,
    )
    target = out_dir / "index.html"
    collect.write_text_atomically(target, page)
    return target


def main(argv: list[str] | None = None, clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> int:
    parser = argparse.ArgumentParser(description="Build the download-stats page.")
    parser.add_argument("--stats-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--traffic-skipped", action="store_true", help="say on the page that traffic is not recorded")
    parser.add_argument("--subtract-drafts", action=argparse.BooleanOptionalAction, default=collect.SUBTRACT_DRAFT_DOWNLOADS,
                        help="subtract the workflow's draft downloads as well as the published ones")
    parser.add_argument("--today", help="override the current date (YYYY-MM-DD)")
    args = parser.parse_args(argv)
    try:
        today = collect.parse_day(args.today, collect.CollectError) if args.today else collect.utc_date(clock())
        target = build_site(args.stats_dir, args.out, today, args.traffic_skipped, args.subtract_drafts)
    except collect.CollectError as error:
        print(f"build failed: {error}", file=sys.stderr)
        return 1
    print(f"wrote {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
