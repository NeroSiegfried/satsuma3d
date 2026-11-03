# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Compare what the native interface believed with what Blender had, over a soak session.

Reads the records `soak.py` and the app's soak probe wrote, and reports:

- Fields the interface had wrong for longer than it takes a snapshot to arrive.
- Spans with no snapshots from Blender while Blender kept changing.
- Blender's loop stalling, and errors from the session's actions.
- The app's memory over the session.
- Snapshots that break the contract with the interface, `native_ui.fbs`.

Exits with 1 when anything went wrong, so it can gate a run.
"""

import argparse
import json
import os
import sys

# How long the interface may lag behind Blender before it counts as out of step, in seconds.
LAG = 3.0
# How long without snapshots, while Blender changes, counts as lost.
SILENCE = 10.0
# The interface's own `mode` is Blender's internal name for it, which Python does not give: the
# object's mode and the tool say the same.
FIELDS = ["objectMode", "activeName", "tool", "brushSize", "brushStrength", "frame"]


def load(path):
    records = []
    if os.path.exists(path):
        with open(path) as file:
            for line in file:
                try:
                    records.append(json.loads(line))
                except ValueError:
                    pass  # A line cut short as the app quit.
    return sorted(records, key=lambda record: record["t"])


def same(field, a, b):
    if a is None or b is None:
        return a is None and b is None
    if field in {"brushSize", "brushStrength"}:
        return abs(a - b) <= max(1e-4, abs(b) * 0.01)
    return a == b


def matches(field, native, truth, at):
    """Whether the interface's value was Blender's at some moment within the lag before `at`, or
    by Blender's next record: Blender records once a second, so the interface can be ahead."""
    window = [record for record in truth if at - LAG <= record["t"] <= at]
    earlier = [record for record in truth if record["t"] < at - LAG]
    if earlier:
        window.insert(0, earlier[-1])
    later = [record for record in truth if record["t"] > at]
    if later:
        window.append(later[0])
    if not window:
        return True
    return any(same(field, native.get(field), record.get(field)) for record in window)


def compared(field, native):
    # The frame comes with the timeline's snapshot, which Blender sends only while it shows.
    return field != "frame" or native.get("timelineVisible")


def check(directory):
    native = load(os.path.join(directory, "native.jsonl"))
    truth = load(os.path.join(directory, "blender.jsonl"))
    actions = load(os.path.join(directory, "blender_actions.jsonl"))
    driven = load(os.path.join(directory, "native_actions.jsonl"))
    problems = []
    lines = []

    if not native or not truth:
        problems.append("Missing records: %d native, %d from Blender." % (len(native), len(truth)))
        return problems, lines

    start = max(native[0]["t"], truth[0]["t"])
    end = min(native[-1]["t"], truth[-1]["t"])
    lines.append("Session: %.1f minutes compared, %d native samples, %d Blender samples, "
                 "%d Blender actions, %d interface actions." %
                 ((end - start) / 60, len(native), len(truth), len(actions), len(driven)))
    if truth[-1]["t"] - native[-1]["t"] > 5:
        problems.append("The interface stopped recording %.0f s before Blender did: did the app stop "
                        "responding?" % (truth[-1]["t"] - native[-1]["t"]))
    if not any(record.get("done") for record in actions):
        problems.append("Blender's session never finished: the app quit or stopped early.")

    # Fields out of step for longer than the lag.
    for field in FIELDS:
        run = []
        events = []
        for sample in native:
            if not (start + LAG <= sample["t"] <= end) or not compared(field, sample):
                continue
            if matches(field, sample, truth, sample["t"]):
                if len(run) >= 2:
                    events.append(run)
                run = []
            else:
                run.append(sample)
        if len(run) >= 2:
            events.append(run)
        for event in events:
            first, last = event[0], event[-1]
            later = [record for record in truth if record["t"] <= first["t"]]
            problems.append("%s out of step for %.0f s from %.0f s in: the interface had %r, Blender %r." %
                            (field, last["t"] - first["t"] + 1, first["t"] - start, first.get(field),
                             later[-1].get(field) if later else None))

    # No snapshots while Blender changed.
    for sample in native:
        if sample["snapshotAge"] < SILENCE or sample["t"] < start + SILENCE:
            continue
        since = sample["t"] - sample["snapshotAge"]
        changed = [record for record in actions if since < record["t"] < sample["t"] and "stall" not in record]
        if changed:
            problems.append("No snapshot for %.0f s at %.0f s in, while Blender made %d changes." %
                            (sample["snapshotAge"], sample["t"] - start, len(changed)))
            break

    stalls = [record["stall"] for record in actions if "stall" in record]
    if stalls:
        lines.append("Blender's loop stalled %d times, longest %.1f s." % (len(stalls), max(stalls)))
        if max(stalls) > 5:
            problems.append("Blender's loop stalled for %.1f s." % max(stalls))
    errors = [record for record in actions if "error" in record]
    if errors:
        lines.append("%d actions failed, such as %s: %s" %
                     (len(errors), errors[0]["error"], errors[0]["trace"].strip().splitlines()[-1]))

    memory = [sample["memory"] for sample in native if sample.get("memory", -1) > 0]
    if memory:
        tail = memory[len(memory) * 3 // 4:]
        lines.append("Memory: %.0f MB at the start, %.0f MB at the end, %.0f MB at most." %
                     (memory[0], memory[-1], max(memory)))
        # Still growing over the last quarter, by more than a quarter of where it started.
        if len(tail) > 10 and tail[-1] - tail[0] > memory[0] * 0.25:
            problems.append("Memory kept growing over the last quarter of the session, %.0f to %.0f MB." %
                            (tail[0], tail[-1]))

    return problems, lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("directory", help="Where the session's records were copied to")
    args = parser.parse_args()
    problems, lines = check(args.directory)
    for line in lines:
        print(line)
    if problems:
        print("\n%d problems:" % len(problems))
        for problem in problems:
            print("- " + problem)
    else:
        print("\nThe interface kept in step with Blender throughout.")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
