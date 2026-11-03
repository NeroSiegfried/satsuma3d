# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Summarize how long the bridge took, from a session recorded with `BLENDER_NATIVE_UI_RECORD`.

Reads `timings.jsonl` (Blender building what it sends) and `interface_timings.jsonl` (the
interface reading and showing it) from a recording's folder. Given a second recording, compares
the two part by part: an area moves to a new path only when it is no slower on any of them.

    python3 timings.py RECORDING
    python3 timings.py BASELINE CANDIDATE
"""

import argparse
import json
import os
import sys

FILES = ("timings.jsonl", "interface_timings.jsonl")
# Below this, differences are noise.
NOISE_MS = 0.05


def load(directory):
    parts = {}
    for name in FILES:
        path = os.path.join(directory, name)
        if not os.path.exists(path):
            continue
        with open(path) as file:
            for line in file:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue  # A line cut short as the app quit.
                part = parts.setdefault(record["part"], {"ms": [], "bytes": []})
                part["ms"].append(record["ms"])
                if record.get("bytes"):
                    part["bytes"].append(record["bytes"])
    return parts


def summary(values):
    values = sorted(values)
    if not values:
        return None
    return {
        "count": len(values),
        "median": values[len(values) // 2],
        "p95": values[min(len(values) - 1, int(len(values) * 0.95))],
        "max": values[-1],
        "total": sum(values),
    }


def summarize(parts):
    return {name: {"ms": summary(part["ms"]), "bytes": summary(part["bytes"])} for name, part in parts.items()}


def print_summary(summaries):
    print("%-26s %7s %9s %9s %9s %10s %10s" % ("part", "count", "median ms", "p95 ms", "max ms", "total ms",
                                              "median B"))
    for name, part in sorted(summaries.items(), key=lambda item: -item[1]["ms"]["total"]):
        ms = part["ms"]
        size = part["bytes"]["median"] if part["bytes"] else 0
        print("%-26s %7d %9.3f %9.3f %9.3f %10.1f %10d" % (name, ms["count"], ms["median"], ms["p95"], ms["max"],
                                                            ms["total"], size))


def compare(baseline, candidate):
    """Parts slower in the candidate, by median or 95th percentile, beyond noise."""
    slower = []
    for name, part in candidate.items():
        before = baseline.get(name)
        if before is None:
            continue
        for statistic in ("median", "p95"):
            old, new = before["ms"][statistic], part["ms"][statistic]
            if new > old + NOISE_MS and new > old * 1.05:
                slower.append("%s %s: %.3f ms, was %.3f ms" % (name, statistic, new, old))
    return slower


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("recording", help="A recording's folder")
    parser.add_argument("candidate", nargs="?", help="Another recording, to compare with the first")
    args = parser.parse_args()
    baseline = summarize(load(args.recording))
    if not args.candidate:
        print_summary(baseline)
        return
    candidate = summarize(load(args.candidate))
    print_summary(candidate)
    slower = compare(baseline, candidate)
    print()
    if slower:
        print("Slower than the baseline:")
        for line in slower:
            print("- " + line)
        sys.exit(1)
    print("No part is slower than the baseline.")


if __name__ == "__main__":
    main()
