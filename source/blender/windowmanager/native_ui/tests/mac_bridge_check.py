# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Check the bridge's views on a Mac, without an iPad: run a macOS build of Blender made with
`WITH_NATIVE_UI` (point `FLATBUFFERS_ROOT` at the iOS libraries' FlatBuffers), subscribe to views
through the C API as the shell does, pump the bridge, send commands, and print the report.

Needs FlatBuffers' `flatc` from Blender's libraries and FlatBuffers' Python runtime of the same
version (the `flatbuffers` package), for example:

    python3 mac_bridge_check.py --blender build/bin/Blender.app/Contents/MacOS/Blender \
        --flatc lib/ios_arm64/flatbuffers/bin/flatc --flatbuffers-python /path/with/flatbuffers
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))


# Every scenario of `mac_bridge_harness.py`, in the order `--all` runs them: the one list every run
# uses (ROUND7 U4d; a list kept outside the repository had fallen behind). The harness's SCENARIOS
# must name exactly these: `tests/python/bl_native_test_runners.py` checks it.
SCENARIOS = ("actions", "tabs", "menus", "mirror", "reveal", "knife", "precision", "material",
             "extensions", "keys", "insets", "touch", "numinput", "render", "fingers", "undo",
             "tolerance", "waiting", "touchstart", "jobs", "renderprogress", "busy", "renderkeep",
             "desk", "hold", "typing", "windows", "margins", "census", "stale", "header",
             "popups", "statuskeys", "answers", "animkeys", "nodegroups", "timelinekeys",
             "assettap", "renderimage")


# A scenario that walks every menu item of every mode needs longer than the others' five minutes.
SCENARIO_SECONDS = {"popups": 1200}
# What `--all` allows a scenario's own run of this script beyond its scenario's seconds (writing the
# FlatBuffers module, killing Blender) before it kills that run too.
RUN_MARGIN_SECONDS = 120
KILLED = "timeout: killed"


def run_with_deadline(command, seconds, group, **kwargs):
    """Run `command`, kept awake, and kill it once `seconds` have passed on the wall clock. With
    `group` it runs in a process group of its own and the whole group is killed (`--all`'s run of a
    scenario, so its Blender goes too); without, only the process (Blender, run in this script's
    group). Returns (exit code, None) or (None, why it was killed).

    `subprocess.run(timeout=)` measures with `time.monotonic()`, which on macOS stands still while
    the Mac sleeps: on 2026-11-20 the Mac idle-slept on battery from 16:20 to 18:40 during `--all`,
    `popups` had used 228 of its 1200 seconds by that clock, and nothing killed it. So the run holds
    `caffeinate -i` (no idle sleep while it lives), the deadline is the wall clock's, and a run that
    passes it is killed with everything it started and said to be killed, with how long the Mac
    slept of it when it did (a sleep that `caffeinate` cannot stop: the lid, the power button)."""
    started_wall, started_mono = time.time(), time.monotonic()
    process = subprocess.Popen(command, start_new_session=group, **kwargs)
    awake = None
    if shutil.which("caffeinate"):
        awake = subprocess.Popen(["caffeinate", "-i", "-w", str(process.pid)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        while True:
            try:
                return process.wait(timeout=1.0), None
            except subprocess.TimeoutExpired:
                pass
            waited = time.time() - started_wall
            if waited < seconds:
                continue
            slept = waited - (time.monotonic() - started_mono)
            try:
                if group:
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
            except ProcessLookupError:
                pass
            process.wait()
            why = KILLED + " after %d s on the wall clock (limit %d s)" % (waited, seconds)
            if slept > 30:
                why += ", %d s of it with the Mac asleep" % slept
            return None, why
    finally:
        if awake:
            awake.kill()
            awake.wait()


def last_report(text):
    """The JSON report a run printed last, or None."""
    i = text.rfind("\n{\n")
    try:
        return json.loads(text[i + 1:] if i >= 0 else text[text.index("{"):])
    except ValueError:
        return None


def run_all(args, out):
    """Every scenario, one after another, each in its own run of this script; a run stopped by the
    clock (its Blender or the run itself killed at its deadline) is run once more alone before it
    counts. One line each, then the count. Exit 0 only when every scenario ended "done"."""
    os.makedirs(out, exist_ok=True)
    base = [sys.executable, os.path.abspath(__file__), "--blender", args.blender, "--flatc", args.flatc,
            "--flatbuffers-python", args.flatbuffers_python]
    outcome = {}
    for scenario in SCENARIOS:
        for attempt in (1, 2):
            started = time.time()
            load = [round(v, 1) for v in os.getloadavg()]
            path = os.path.join(out, "%s%s.out" % (scenario, "" if attempt == 1 else ".again"))
            with open(path, "w") as f:
                code, killed = run_with_deadline(
                    base + ["--scenario", scenario], SCENARIO_SECONDS.get(scenario, 300) + RUN_MARGIN_SECONDS, True,
                    stdout=f, stderr=subprocess.STDOUT)
            with open(path, errors="replace") as f:
                text = f.read()
            report = None if killed else last_report(text)
            status = killed or (report or {}).get("status") or "no report, exit %d" % code
            print("%-15s %s exit=%s secs=%d load=%s %s%s" % (
                scenario, "" if attempt == 1 else "(again, alone)", "-" if code is None else code,
                time.time() - started, load, status,
                (" problems: %s" % report["problems"]) if report and report.get("problems") else ""),
                flush=True)
            if not status.startswith(KILLED):
                break
        outcome[scenario] = status
    done = [s for s, status in outcome.items() if status == "done"]
    print("%d scenarios by the list: %d done%s" % (
        len(SCENARIOS), len(done), "".join(", %s: %s" % (s, st) for s, st in outcome.items() if st != "done")))
    print("outputs in %s" % out)
    return 0 if len(done) == len(SCENARIOS) else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true", help="Print every scenario's name, one a line, and end")
    parser.add_argument("--all", action="store_true", help="Run every scenario of the list (see run_all)")
    parser.add_argument("--out", help="With --all: the folder for each run's output (default: a new one)")
    parser.add_argument("--blender")
    parser.add_argument("--flatc")
    parser.add_argument("--flatbuffers-python",
                        help="A directory holding the `flatbuffers` Python package")
    parser.add_argument("--scenario", default="actions", choices=SCENARIOS,
                        help="`actions`: the palette, long press and radial. `tabs`: every Properties tab in every mode")
    args = parser.parse_args()
    if args.list:
        print("\n".join(SCENARIOS))
        return 0
    for needed in ("blender", "flatc", "flatbuffers_python"):
        if not getattr(args, needed):
            parser.error("--%s is needed to run a scenario" % needed.replace("_", "-"))
    if args.all:
        return run_all(args, args.out or tempfile.mkdtemp(prefix="mac_bridge_all_"))
    with tempfile.TemporaryDirectory() as directory:
        subprocess.run([args.flatc, "--python", "-o", directory, os.path.join(HERE, "..", "protocol.fbs")],
                       check=True)
        shutil.copytree(os.path.join(args.flatbuffers_python, "flatbuffers"), os.path.join(directory, "flatbuffers"))
        report = os.path.join(directory, "report.json")
        env, extra = dict(os.environ), []
        if args.scenario == "extensions":
            # As the iPad starts the engine (ROUND5 8E.1): offline, with the app's bundled extensions
            # as the system repository, and preferences of its own.
            root = os.path.join(directory, "extensions")
            os.makedirs(root)
            os.symlink(os.path.join(HERE, "..", "..", "..", "..", "..", "release", "ios", "extensions"),
                       os.path.join(root, "system"))
            env["BLENDER_SYSTEM_EXTENSIONS"] = root
            env["BLENDER_USER_RESOURCES"] = os.path.join(directory, "user")
            extra = ["--offline-mode"]
        if args.scenario in ("fingers", "undo", "tolerance", "waiting", "touchstart", "desk", "hold", "typing", "margins",
                             "popups", "statuskeys"):
            # Events made by the scenario, as a finger's would arrive (ROUND6 TOUCH).
            extra = ["--enable-event-simulate"]
        code, killed = run_with_deadline(
                       [args.blender, "--factory-startup", *extra, "--python", os.path.join(HERE, "mac_bridge_harness.py"),
                        "--", directory, report, args.scenario,
                        os.path.join(HERE, "..", "..", "..", "..", "..", "release", "ios", "branding_allowed.txt"),
                        os.path.join(HERE, "..", "..", "..", "..", "..", "release", "ios", "key_stand_ins.txt"),
                        # After Blender's own arguments, for AppKit: no "reopen windows?" alert after
                        # an earlier run crashed. That alert is modal and stalled every run at
                        # startup, before the first step (seen 2026-11-19 from about 16:15).
                        "-ApplePersistenceIgnoreState", "YES"],
                       SCENARIO_SECONDS.get(args.scenario, 300), False, env=env)
        if killed:
            # Said as a report, so `--all` and a person read the same thing: hung, and killed.
            result = {"scenario": args.scenario, "status": killed}
        else:
            result = {"scenario": args.scenario, "status": "no report"}
            if os.path.exists(report):
                with open(report) as f:
                    result = json.load(f)
            if code != 0:
                # Blender failing after its report (a crash at quit) fails the run, as it always did.
                result["status"] = "Blender exit %d%s, its report: %s" % (
                    code, " (%s)" % signal.Signals(-code).name if code < 0 else "", result.get("status"))
    print(json.dumps(result, indent=1))
    return 0 if result.get("status") == "done" else 1


if __name__ == "__main__":
    sys.exit(main())
