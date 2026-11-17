#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Writes the files of interpolation_nncn runs into an Excel workbook with charts.

usage: metrics_to_excel.py RUN_TMP_DIR [RUN_TMP_DIR ...] OUTPUT.xlsx

Reads from each RUN_TMP_DIR (all "~"-separated, header first, each one optional):
  metrics.csv    - samples of metrics_sampling (.config): CPU, memory, disks, GPUs, tools
  timeline.csv   - one row per step and chunk (timeline_entry in .config_video)
  statistics.txt - one row per chunk, times as "12.3[s]"
  memory.csv     - one row per final encode: memory estimate and what was used (memory_entry)
Sheets: "charts" (line charts over time, steps per chunk), then one sheet per file.

With several directories (runs of one video, e.g. after a stop and a restart) the files are
combined into one report: the directories are ordered by name (the run's start time), and each
chunk comes from the latest run in which it is complete (has a statistics row), otherwise from
the latest run which has it. Only the runs which supply a chunk are used, metrics.csv samples
of the same time are taken once, the columns of all runs are kept, a "run" column names the
source of each row, and a "runs" sheet lists the runs.
"""

import sys
import os
import re
import xlsxwriter

CHUNK_STEPS = ["extracting_streams", "preparation", "extracting_frames", "interpolating",
               "merging_frames", "merging_streams"]
BACKGROUND_STEPS = ["encoding", "quality_check"]
# charts of metrics.csv: title, y axis, a column is drawn when its header matches
METRIC_CHARTS = [
    ("CPU", "%", re.compile(r"^cpu_")),
    ("Memory", "GB", re.compile(r"^(mem_|swap_|cgroup_mem|tools_rss)")),
    ("Memory per tool", "GB", re.compile(r"_rss \[GB\]$")),
    ("GPU busy", "%", re.compile(r"^card\d+_busy")),
    ("GPU memory (VRAM)", "GB", re.compile(r"^card\d+_vram")),
    ("GPU power", "W", re.compile(r"^card\d+_power")),
    ("GPU temperature", "°C", re.compile(r"^card\d+_temp")),
    ("GPU shader clock", "MHz", re.compile(r"^card\d+_sclk")),
    ("Disks", "MB/s", re.compile(r"^disk_")),
]


def number(value):
    """'12.3[s]' or '12.3' -> 12.3; anything else stays text, empty stays empty."""
    stripped = value.strip()
    if stripped.endswith("[s]"):
        stripped = stripped[:-3]
    try:
        return float(stripped)
    except ValueError:
        return value


def reading(path):
    """header and rows of a "~"-separated file; None when it does not exist or is empty."""
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return None
    with open(path, encoding="utf-8", errors="replace") as source:
        lines = [line.rstrip("\n") for line in source if line.strip()]
    header = lines[0].split("~")
    # the first column identifies the row (chunk "021", time) and stays text
    rows = []
    for line in lines[1:]:
        fields = line.split("~")
        # a header repeated inside the file (files of runs appended by hand)
        if fields == header:
            continue
        rows.append(fields[:1] + [number(field) for field in fields[1:]])
    return header, rows


def writing_sheet(workbook, name, data, bold):
    sheet = workbook.add_worksheet(name)
    header, rows = data
    sheet.write_row(0, 0, header, bold)
    for row_number, row in enumerate(rows, start=1):
        sheet.write_row(row_number, 0, row)
    sheet.freeze_panes(1, 0)
    sheet.set_column(0, len(header) - 1, 14)
    return sheet


def charting_metrics(workbook, charts, data, position):
    header, rows = data
    last_row = len(rows)
    for title, unit, pattern in METRIC_CHARTS:
        columns = [index for index, name in enumerate(header) if pattern.search(name)]
        if title == "Memory per tool":
            columns = [index for index in columns if not header[index].startswith("tools_rss")]
        if not columns or last_row == 0:
            continue
        chart = workbook.add_chart({"type": "line"})
        for index in columns:
            chart.add_series({
                "name": ["metrics", 0, index],
                "categories": ["metrics", 1, 0, last_row, 0],
                "values": ["metrics", 1, index, last_row, index],
                "line": {"width": 1.25},
            })
        chart.set_title({"name": title})
        chart.set_x_axis({"name": "time", "num_font": {"rotation": -45}, "interval_unit": max(1, last_row // 20)})
        chart.set_y_axis({"name": unit})
        chart.set_size({"width": 1100, "height": 360})
        charts.insert_chart(position, 0, chart)
        position += 19
    return position


def charting_steps(workbook, charts, data, position, bold):
    """stacked columns: the steps of each chunk, then the background encode and VMAF."""
    header, rows = data
    durations = {}
    for row in rows:
        record = dict(zip(header, row))
        chunk, step, duration = str(record.get("video_id", "")), record.get("step"), record.get("duration [s]")
        if chunk in ("", "all") or not isinstance(duration, float):
            continue
        durations.setdefault(chunk, {})[step] = duration
    if not durations:
        return position
    chunks = sorted(durations)
    steps = CHUNK_STEPS + BACKGROUND_STEPS
    sheet = workbook.add_worksheet("steps per chunk")
    sheet.write_row(0, 0, ["chunk"] + steps, bold)
    for row_number, chunk in enumerate(chunks, start=1):
        sheet.write(row_number, 0, chunk)
        for column, step in enumerate(steps, start=1):
            if step in durations[chunk]:
                sheet.write_number(row_number, column, durations[chunk][step])
    sheet.freeze_panes(1, 1)
    for title, step_group, chart_type in (("Steps per chunk [s]", CHUNK_STEPS, "column"),
                                          ("Final encode and VMAF per chunk (background) [s]", BACKGROUND_STEPS, "column")):
        chart = workbook.add_chart({"type": chart_type, "subtype": "stacked"})
        for step in step_group:
            column = steps.index(step) + 1
            chart.add_series({
                "name": ["steps per chunk", 0, column],
                "categories": ["steps per chunk", 1, 0, len(chunks), 0],
                "values": ["steps per chunk", 1, column, len(chunks), column],
                "gap": 30,
            })
        chart.set_title({"name": title})
        chart.set_x_axis({"name": "chunk"})
        chart.set_y_axis({"name": "s"})
        chart.set_size({"width": 1100, "height": 360})
        charts.insert_chart(position, 0, chart)
        position += 19
    return position


def charting_memory(workbook, charts, data, position):
    """columns per chunk: what the run could get and needed (estimate), what it used (reality)."""
    header, rows = data
    names = ["can get [GB]", "needed [GB]", "max tools_rss [GB]", "min available [GB]"]
    columns = [header.index(name) for name in names if name in header]
    if not columns or not rows:
        return position
    chart = workbook.add_chart({"type": "column"})
    for index in columns:
        chart.add_series({
            "name": ["memory", 0, index],
            "categories": ["memory", 1, 0, len(rows), 0],
            "values": ["memory", 1, index, len(rows), index],
        })
    chart.set_title({"name": "Memory: estimate (can get, needed) and reality per chunk"})
    chart.set_x_axis({"name": "chunk"})
    chart.set_y_axis({"name": "GB"})
    chart.set_size({"width": 1100, "height": 360})
    charts.insert_chart(position, 0, chart)
    return position + 19


FILES = {"metrics": "metrics.csv", "timeline": "timeline.csv", "statistics": "statistics.txt", "memory": "memory.csv"}
CHUNK_FILES = ["timeline", "statistics", "memory"]


def is_chunk(value):
    return isinstance(value, str) and value.isdigit()


def joining(parts):
    """[(run, (header, rows)), ...] -> one (header, rows): the columns of all, in order of first
    appearance, and a "run" column; a column a run does not have stays empty."""
    header = []
    for _, (part_header, _) in parts:
        header += [name for name in part_header if name not in header]
    rows = []
    for run, (part_header, part_rows) in parts:
        for row in part_rows:
            record = dict(zip(part_header, row))
            rows.append([record.get(name, "") for name in header] + [run])
    return header + ["run"], rows


def combining(run_dirs):
    """the files of several runs of one video as one set, see the module description."""
    run_dirs = sorted(run_dirs, key=lambda path: os.path.basename(os.path.normpath(path)))
    names = [os.path.basename(os.path.normpath(path)) for path in run_dirs]
    data = [{key: reading(os.path.join(path, file)) for key, file in FILES.items()} for path in run_dirs]
    complete = [{row[0] for row in (run["statistics"] or ([], []))[1] if is_chunk(row[0])} for run in data]
    present = [{row[0] for key in CHUNK_FILES for row in (run[key] or ([], []))[1] if is_chunk(row[0])}
               for run in data]
    chosen = {}
    for chunk in set().union(*present):
        candidates = [index for index in range(len(data)) if chunk in complete[index]] or \
                     [index for index in range(len(data)) if chunk in present[index]]
        chosen[chunk] = max(candidates)
    used = sorted(set(chosen.values()))
    combined = {}
    for key in CHUNK_FILES:
        # a chunk's rows come from its chosen run, or (memory.csv is written per encode) from
        # the latest run which has rows of that chunk in this file
        holders = {}
        for index, run in enumerate(data):
            for row in (run[key] or ([], []))[1]:
                if is_chunk(row[0]):
                    holders.setdefault(row[0], set()).add(index)
        source = {chunk: (chosen[chunk] if chosen[chunk] in runs else max(runs)) for chunk, runs in holders.items()}
        parts = []
        for index in used + [index for index in range(len(data)) if index not in used]:
            if not data[index][key]:
                continue
            header, rows = data[index][key]
            kept = [row for row in rows if (is_chunk(row[0]) and source[row[0]] == index)
                    or (not is_chunk(row[0]) and index in used)]
            if kept:
                parts.append((names[index], (header, kept)))
        if parts:
            header, rows = joining(parts)
            # chunks in order, rows of other kinds (the whole run, "all") after them; stable sort
            rows.sort(key=lambda row: (0, row[0]) if is_chunk(row[0]) else (1, ""))
            combined[key] = (header, rows)
        else:
            combined[key] = None
    parts = [(names[index], data[index]["metrics"]) for index in used if data[index]["metrics"]]
    if parts:
        header, rows = joining(parts)
        seen = set()
        unique = []
        for row in sorted(rows, key=lambda row: str(row[0])):
            if row[0] not in seen:
                seen.add(row[0])
                unique.append(row)
        combined["metrics"] = (header, unique)
    else:
        combined["metrics"] = None
    runs = []
    for index, path in enumerate(run_dirs):
        samples = (data[index]["metrics"] or ([], []))[1]
        own = sorted(chunk for chunk, run in chosen.items() if run == index)
        runs.append([names[index], "yes" if index in used else "no",
                     str(samples[0][0]) if samples else "", str(samples[-1][0]) if samples else "",
                     f"{min(present[index])}-{max(present[index])}" if present[index] else "",
                     len(own), " ".join(own), path])
    combined["runs"] = (["run", "used", "first sample", "last sample", "chunks in run",
                         "chunks used [count]", "chunks used", "directory"], runs)
    return combined


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    run_dirs, output = sys.argv[1:-1], sys.argv[-1]
    if len(run_dirs) == 1:
        files = {key: reading(os.path.join(run_dirs[0], file)) for key, file in FILES.items()}
    else:
        files = combining(run_dirs)
    metrics, timeline, statistics, memory = (files[key] for key in ("metrics", "timeline", "statistics", "memory"))
    if not (metrics or timeline or statistics or memory):
        print("nothing to report in " + " ".join(run_dirs), file=sys.stderr)
        return 1
    workbook = xlsxwriter.Workbook(output)
    bold = workbook.add_format({"bold": True})
    charts = workbook.add_worksheet("charts")
    position = 0
    if metrics:
        writing_sheet(workbook, "metrics", metrics, bold)
        position = charting_metrics(workbook, charts, metrics, position)
    if timeline:
        writing_sheet(workbook, "timeline", timeline, bold)
        position = charting_steps(workbook, charts, timeline, position, bold)
    if memory:
        writing_sheet(workbook, "memory", memory, bold)
        position = charting_memory(workbook, charts, memory, position)
    if statistics:
        writing_sheet(workbook, "statistics", statistics, bold)
    if "runs" in files:
        writing_sheet(workbook, "runs", files["runs"], bold)
    workbook.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
