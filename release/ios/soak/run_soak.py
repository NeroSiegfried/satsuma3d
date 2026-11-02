# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Run a long session of Blender on an iPad or the iPad simulator, and check that the native
interface stayed in step with Blender throughout.

Blender works through `soak.py`, a seeded series of everyday actions, while the app's soak probe
records what the interface believes, and with `--ui` drives Blender the way the interface does.
Afterwards the records are copied here and compared by `check_soak.py`.

The app must already be built: for the simulator, the build folder's `bin/Debug/Blender.app`,
installed by this script; for a device, the app installed from Xcode. Examples:

    python3 release/ios/soak/run_soak.py --bundle <ID> --simulator <UDID> \
        --app <build>/bin/Debug/Blender.app --minutes 60 --ui
    python3 release/ios/soak/run_soak.py --bundle <ID> --device <UDID> --minutes 240 --ui
"""

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# Blender runs the script from its temporary folder, where it was copied.
RUN_SCRIPT = ("import os, runpy, tempfile; "
              "runpy.run_path(os.path.join(tempfile.gettempdir(), 'soak', 'soak.py'))")


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True).stdout


def environment(args):
    variables = {"BLENDER_SOAK": "1", "BLENDER_SOAK_MINUTES": str(args.minutes), "BLENDER_SOAK_SEED": str(args.seed),
                 # Snapshots for the schema check, see `native_ui.fbs`.
                 "BLENDER_NATIVE_UI_RECORD": "1"}
    if args.ui:
        variables["BLENDER_SOAK_UI"] = "1"
    return variables


class Simulator:
    def __init__(self, udid, app, bundle):
        self.udid = udid
        self.app = app
        self.bundle = bundle

    def start(self, args):
        run("xcrun", "simctl", "boot", self.udid, check=False)
        # The app only runs its loop while shown: in DeviceHub, which replaces the Simulator app
        # from Xcode 27.
        developer = os.environ.get("DEVELOPER_DIR") or run("xcode-select", "-p", check=False).strip()
        for app in (os.path.join(developer, "..", "Applications", "DeviceHub.app"),
                    os.path.join(developer, "Applications", "Simulator.app")):
            if os.path.exists(app):
                subprocess.run(["open", "-a", app, "--args", "-CurrentDeviceUDID", self.udid], check=False)
                break
        run("xcrun", "simctl", "install", self.udid, self.app)
        self.container = run("xcrun", "simctl", "get_app_container", self.udid, self.bundle, "data").strip()
        soak = os.path.join(self.container, "tmp", "soak")
        shutil.rmtree(soak, ignore_errors=True)
        shutil.rmtree(os.path.join(self.container, "tmp", "native_ui_record"), ignore_errors=True)
        os.makedirs(soak)
        shutil.copy(os.path.join(HERE, "soak.py"), soak)
        run("xcrun", "simctl", "terminate", self.udid, self.bundle, check=False)
        env = dict(os.environ, **{"SIMCTL_CHILD_" + key: value for key, value in environment(args).items()})
        subprocess.run(["xcrun", "simctl", "launch", self.udid, self.bundle, "--python-expr", RUN_SCRIPT],
                       env=env, check=True, capture_output=True)

    def running(self):
        return "UIKitApplication:" + self.bundle in run("xcrun", "simctl", "spawn", self.udid, "launchctl", "list",
                                                  check=False)

    def collect(self, destination):
        shutil.copytree(os.path.join(self.container, "tmp", "soak"), destination, dirs_exist_ok=True)
        record = os.path.join(self.container, "tmp", "native_ui_record")
        if os.path.isdir(record):
            shutil.copytree(record, os.path.join(destination, "native_ui_record"), dirs_exist_ok=True)

    def crashes(self, since):
        reports = glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/Blender-*.ips"))
        return [report for report in reports if os.path.getmtime(report) > since]


class Device:
    def __init__(self, udid, bundle):
        self.udid = udid
        self.bundle = bundle

    def devicectl(self, *args, check=True):
        return run("xcrun", "devicectl", "device", *args, "--device", self.udid, check=check)

    def start(self, args):
        staging = tempfile.mkdtemp()
        shutil.copy(os.path.join(HERE, "soak.py"), staging)
        self.devicectl("copy", "to", "--domain-type", "appDataContainer", "--domain-identifier", self.bundle,
                       "--source", os.path.join(staging, "soak.py"), "--destination", "tmp/soak/soak.py")
        self.devicectl("process", "launch", "--terminate-existing", "--environment-variables",
                       json.dumps(environment(args)), self.bundle, "--python-expr", RUN_SCRIPT)

    def running(self):
        return "Blender.app/Blender\n" in self.devicectl("info", "processes", check=False).replace(" ", "")

    def collect(self, destination):
        self.devicectl("copy", "from", "--domain-type", "appDataContainer", "--domain-identifier", self.bundle,
                       "--source", "tmp/soak", "--destination", destination)
        self.devicectl("copy", "from", "--domain-type", "appDataContainer", "--domain-identifier", self.bundle,
                       "--source", "tmp/native_ui_record", "--destination",
                       os.path.join(destination, "native_ui_record"), check=False)

    def crashes(self, since):
        folder = tempfile.mkdtemp()
        self.devicectl("copy", "from", "--domain-type", "systemCrashLogs", "--source", "/", "--destination",
                       folder, check=False)
        reports = glob.glob(os.path.join(folder, "**", "*Blender*.ips"), recursive=True)
        return [report for report in reports if os.path.getmtime(report) > since]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--simulator", metavar="UDID", help="Run in this simulator")
    target.add_argument("--device", metavar="UDID", help="Run on this iPad, with the app installed from Xcode")
    parser.add_argument("--bundle", required=True, help="The app's bundle identifier, as configured")
    parser.add_argument("--app", help="The simulator build's Blender.app, installed before running")
    parser.add_argument("--minutes", type=float, default=10, help="How long Blender acts for")
    parser.add_argument("--seed", type=int, default=1, help="Replays the same session for the same seed")
    parser.add_argument("--ui", action="store_true", help="Drive Blender through the interface's calls too")
    parser.add_argument("--output", default="soak_results", help="Where the records are copied to")
    args = parser.parse_args()
    if args.simulator and not args.app:
        parser.error("--simulator needs --app")

    target = Simulator(args.simulator, args.app, args.bundle) if args.simulator else Device(args.device, args.bundle)
    began = time.time()
    target.start(args)
    print("Running for %.0f minutes, seed %d%s." % (args.minutes, args.seed, ", driving the interface" if args.ui else ""))
    # Blender starts acting ten seconds in; a little more for the last records.
    deadline = began + args.minutes * 60 + 40
    alive = True
    while time.time() < deadline:
        time.sleep(30)
        if not target.running():
            alive = False
            print("The app stopped %.0f minutes in." % ((time.time() - began) / 60))
            break
    os.makedirs(args.output, exist_ok=True)
    target.collect(args.output)
    crashes = target.crashes(began)
    for crash in crashes:
        shutil.copy(crash, args.output)

    sys.path.insert(0, HERE)
    import check_soak
    problems, lines = check_soak.check(args.output)
    if not alive:
        problems.insert(0, "The app stopped before the session ended.")
    if crashes:
        problems.insert(0, "The app crashed: %s" % ", ".join(os.path.basename(crash) for crash in crashes))
    print("\n".join(lines))
    if problems:
        print("\n%d problems:" % len(problems))
        for problem in problems:
            print("- " + problem)
    else:
        print("\nThe interface kept in step with Blender throughout.")
    print("Records in %s" % os.path.abspath(args.output))
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
