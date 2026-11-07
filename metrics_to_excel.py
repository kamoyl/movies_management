#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Writes the files of one interpolation_nncn run into an Excel workbook with charts.

usage: metrics_to_excel.py RUN_TMP_DIR OUTPUT.xlsx

Reads from RUN_TMP_DIR (all "~"-separated, header first, each one optional):
  metrics.csv    - samples of metrics_sampling (.config): CPU, memory, disks, GPUs, tools
  timeline.csv   - one row per step and chunk (timeline_entry in .config_video)
  statistics.txt - one row per chunk, times as "12.3[s]"
  memory.csv     - one row per final encode: memory estimate and what was used (memory_entry)
Sheets: "charts" (line charts over time, steps per chunk), then one sheet per file.
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


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    run_dir, output = sys.argv[1], sys.argv[2]
    metrics = reading(os.path.join(run_dir, "metrics.csv"))
    timeline = reading(os.path.join(run_dir, "timeline.csv"))
    statistics = reading(os.path.join(run_dir, "statistics.txt"))
    memory = reading(os.path.join(run_dir, "memory.csv"))
    if not (metrics or timeline or statistics or memory):
        print("nothing to report in " + run_dir, file=sys.stderr)
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
    workbook.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
