#!/usr/bin/env python3
"""Measuring a build of Henge on an attached iPad or iPhone, with nobody holding it.

Henge's autopilot (ios/Henge/Autopilot.swift) follows Documents/henge-autopilot.txt when the app is launched
with HENGE_AUTOPILOT set. This drives it over devicectl: it puts a Mac called Test back to a kept state (its disk
and a saved, running Mac: "baseline"), picks it up there, lets it run, and reads the numbers out of henge.log.
Every run starts from the same instant, so two builds can be compared.

  ipad_bench.py launch                 start Henge with the autopilot (ends a running Henge)
  ipad_bench.py do LINE [LINE...]      add commands to the running autopilot's plan
  ipad_bench.py pull [FILE...]         henge.log (and other Documents files) into the run folder
  ipad_bench.py run NAME [--minutes N] [--baseline B] [--keys "cmd r"]
                                       a whole measuring run from baseline B (default yt); its log is NAME.log
  ipad_bench.py summary LOG [LOG...]   the numbers of one or more logs, side by side

The device has to be unlocked, with LocalDevVPN connected and "Turn on JIT when Henge opens" on.
HENGE_DEVICE and HENGE_BUNDLE name the device (a devicectl identifier) and the app.
"""
import argparse
import os
import re
import subprocess
import sys
import time

DEVICE = os.environ.get("HENGE_DEVICE", "00008142-000851913E2BC01C")
BUNDLE = os.environ.get("HENGE_BUNDLE", "com.jc32m95wlz.henge")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNS = os.path.join(ROOT, "ios", "build", "prof", "runs")
PLAN = os.path.join(RUNS, "plan.txt")


def ctl(*args):
    return subprocess.run(["xcrun", "devicectl", "device", *args], capture_output=True, text=True)


def container(*args):
    return ["--device", DEVICE, "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE, *args]


def push(local, remote):
    r = ctl("copy", "to", *container("--source", local, "--destination", "Documents/" + remote))
    if r.returncode:
        sys.exit("could not copy %s to the device: %s" % (remote, (r.stderr or r.stdout).strip()[-300:]))


def pull(remote, local):
    if os.path.exists(local):
        os.remove(local)
    r = ctl("copy", "from", *container("--source", "Documents/" + remote, "--destination", local))
    return r.returncode == 0 and os.path.exists(local)


def set_plan(lines):
    os.makedirs(RUNS, exist_ok=True)
    with open(PLAN, "w") as f:
        f.write("".join(line + "\n" for line in lines))
    push(PLAN, "henge-autopilot.txt")


def plan_lines():
    if not os.path.exists(PLAN):
        return []
    return open(PLAN).read().split("\n")[:-1]


def launch():
    r = subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", DEVICE, "--terminate-existing",
                        "-e", '{"HENGE_AUTOPILOT":"1"}', BUNDLE], capture_output=True, text=True)
    if r.returncode:
        sys.exit("could not launch Henge (is the device unlocked?): %s" % (r.stderr or r.stdout).strip()[-300:])


def log_text(local):
    if not pull("henge.log", local):
        return ""
    return "".join(l for l in open(local, errors="replace") if "[prev]" not in l)


def wait_for(marker, timeout, local):
    """Until the autopilot has logged MARKER (a "log MARKER" line it ran)."""
    end = time.time() + timeout
    while time.time() < end:
        if re.search(r"\[autopilot\] log %s\b" % re.escape(marker), log_text(local)):
            return True
        time.sleep(10)
    return False


def summary(path):
    drops, translate, frames, gaps, spans = 0, [], 0, [0] * 7, []
    stats_at = 0
    busy, jit = 0.0, 0.0
    for l in open(path, errors="replace"):
        if "[prev]" in l:
            continue
        if "code cache dropped" in l and " 0 blocks" not in l:
            drops += 1
        m = re.match(r"stats +(\d+)s:.*; (\d+)% of time", l)
        if m:
            stats_at = int(m[1])
            translate.append(int(m[2]))
        m = re.search(r"pvg-mon \S+ (\d+) frames; gaps <20ms (\d+), <33 (\d+), <50 (\d+), <100 (\d+), <250 (\d+), <1s (\d+), pauses (\d+)", l)
        if m:
            v = list(map(int, m.groups()))
            frames += v[0]
            for i in range(7):
                gaps[i] += v[1 + i]
        m = re.match(r"hvprof: (\d+) samples, idle ([\d.]+)%, of busy: jit ([\d.]+)%", l)
        if m:
            b = int(m[1]) * (1 - float(m[2]) / 100)
            busy += b
            jit += b * float(m[3]) / 100
    shown = sum(gaps[:6]) or 1
    return {
        "seconds": stats_at,
        "cache drops": drops,
        "translating, % of time (mean)": round(sum(translate) / len(translate), 1) if translate else None,
        "translating, % of time (worst)": max(translate) if translate else None,
        "frames": frames,
        "frames <20 ms apart, %": round(100 * gaps[0] / shown, 1),
        "frames 20-50 ms apart, %": round(100 * (gaps[1] + gaps[2]) / shown, 1),
        "frames 50-250 ms apart, %": round(100 * (gaps[3] + gaps[4]) / shown, 1),
        "gaps of 250 ms to 1 s": gaps[5],
        "busy time in translated code, %": round(100 * jit / busy, 1) if busy else None,
    }


def print_summaries(paths):
    rows = [summary(p) for p in paths]
    names = [os.path.splitext(os.path.basename(p))[0] for p in paths]
    width = max(len(k) for k in rows[0]) + 2
    print(" " * width + "".join("%16s" % n[:15] for n in names))
    for k in rows[0]:
        print(k.ljust(width) + "".join("%16s" % ("-" if r[k] is None else r[k]) for r in rows))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("launch")
    d = sub.add_parser("do")
    d.add_argument("lines", nargs="+")
    p = sub.add_parser("pull")
    p.add_argument("files", nargs="*")
    r = sub.add_parser("run")
    r.add_argument("name")
    r.add_argument("--minutes", type=float, default=3)
    r.add_argument("--baseline", default="yt")
    r.add_argument("--keys", action="append", default=[], help='an autopilot line run once the Mac is back, e.g. "cmd r"')
    s = sub.add_parser("summary")
    s.add_argument("logs", nargs="+")
    a = ap.parse_args()
    os.makedirs(RUNS, exist_ok=True)

    if a.cmd == "launch":
        set_plan(["log launched"])
        launch()
    elif a.cmd == "do":
        set_plan(plan_lines() + a.lines)
    elif a.cmd == "pull":
        for f in ["henge.log"] + a.files:
            print(f, "ok" if pull(f, os.path.join(RUNS, f)) else "not there")
    elif a.cmd == "run":
        log = os.path.join(RUNS, a.name + ".log")
        set_plan(["log run %s" % a.name, "env HV_RESUME_TEST 1", "baseline load %s" % a.baseline, "mac Test", "wait 12",
                  *a.keys, "log running", "wait %d" % int(a.minutes * 60), "snap %s" % a.name, "log finished", "wait 2", "exit"])
        launch()
        if not wait_for("finished", a.minutes * 60 + 240, log):
            print("the run did not finish in time; what the log has is in", log)
        time.sleep(4)
        text = log_text(log)
        open(log, "w").write(text)
        pull(a.name + ".jpg", os.path.join(RUNS, a.name + ".jpg"))
        for line in text.split("\n"):
            if re.search(r"\[(autopilot|resume)\]", line):
                print(line[:150])
        print_summaries([log])
    elif a.cmd == "summary":
        print_summaries(a.logs)


if __name__ == "__main__":
    main()
