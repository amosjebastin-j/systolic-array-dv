#!/usr/bin/env python3
"""Multi-seed regression + bug-injection (mutation) runner.

    python3 scripts/run_regression.py --seeds 10 --iters 200
    python3 scripts/run_regression.py --seeds 3 --bugs      # also prove each injected bug is caught

Writes results/regression_report.md and results/coverage_merged.json.
"""
import argparse
import json
import os
import random
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "results")
BUGS = {
    "BUG_SIGN": "B operand multiplied as unsigned",
    "BUG_NOCLR": "accumulators not cleared on START",
    "BUG_SKEW": "last row of A fed one cycle late",
    "BUG_PSLVERR": "no write protection while BUSY",
    "BUG_CTRANSPOSE": "C read-back address transposed",
}


def run(tag, seed, iters, n, defines=""):
    xml = os.path.join(RES, f"res_{tag}.xml")
    cov = os.path.join(RES, f"cov_{tag}.json")
    for f in (xml, cov):
        if os.path.exists(f):
            os.remove(f)
    build = f"sim_build_{defines}" if defines else f"sim_build_n{n}"
    cmd = ["make", "-s", f"SEED={seed}", f"NUM_ITERS={iters}", f"N={n}",
           f"DEFINES={defines}", f"SIM_BUILD={build}", f"COCOTB_RESULTS_FILE={xml}"]
    env = dict(os.environ, COV_FILE=cov)
    t0 = time.time()
    p = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    with open(os.path.join(RES, f"log_{tag}.txt"), "w") as f:
        f.write(p.stdout + p.stderr)
    tests = fails = 0
    failed = []
    if os.path.exists(xml):
        for tc in ET.parse(xml).getroot().iter("testcase"):
            tests += 1
            if tc.find("failure") is not None or tc.find("error") is not None:
                fails += 1
                failed.append(tc.get("name"))
    else:
        fails = -1  # build/elaboration failure
    return tests, fails, failed, time.time() - t0, cov


def merge(cov_files):
    merged = {}
    for f in cov_files:
        if not os.path.exists(f):
            continue
        for pt, bins in json.load(open(f)).items():
            m = merged.setdefault(pt, {})
            for b, c in bins.items():
                m[b] = m.get(b, 0) + c
    return merged


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=5)
    ap.add_argument("--iters", type=int, default=100)
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--bugs", action="store_true", help="run bug-injection campaign")
    a = ap.parse_args()
    os.makedirs(RES, exist_ok=True)

    lines = ["# Regression report", "", f"Array size N={a.n}, {a.iters} random ops per seed", "",
             "## Seeds", "", "| seed | tests | failures | time (s) |", "|---|---|---|---|"]
    covs, total_fail = [], 0
    for s in [random.randint(1, 2**31 - 1) for _ in range(a.seeds)]:
        t, f, failed, dt, cov = run(f"seed{s}", s, a.iters, a.n)
        covs.append(cov)
        total_fail += abs(f)
        status = "PASS" if f == 0 else f"FAIL {failed}"
        print(f"seed {s:>10}: {t} tests, {status}  ({dt:.1f}s)")
        lines.append(f"| {s} | {t} | {f} | {dt:.1f} |")

    merged = merge(covs)
    json.dump(merged, open(os.path.join(RES, "coverage_merged.json"), "w"), indent=2)
    hit = sum(1 for b in merged.values() for c in b.values() if c)
    tot = sum(len(b) for b in merged.values())
    lines += ["", "## Functional coverage (merged)", "",
              f"**{hit}/{tot} bins hit ({100.0 * hit / max(tot, 1):.1f}%)**", "",
              "| coverpoint | bin | hits |", "|---|---|---|"]
    for pt, bins in merged.items():
        for b, c in bins.items():
            lines.append(f"| {pt} | {b} | {c}{'' if c else '  **HOLE**'} |")
    print(f"coverage: {hit}/{tot} bins")

    if a.bugs:
        lines += ["", "## Bug-injection campaign", "",
                  "Each bug is compiled in with `+define+`; the testbench must FAIL.", "",
                  "| bug | description | result | failing tests |", "|---|---|---|---|"]
        for bug, desc in BUGS.items():
            t, f, failed, _, _ = run(bug, 1, 20, a.n, bug)
            res = "CAUGHT" if f != 0 else "**ESCAPED**"
            if f == 0:
                total_fail += 1
            print(f"{bug:<16} {res:<10} {failed}")
            lines.append(f"| `{bug}` | {desc} | {res} | {', '.join(failed)} |")

    open(os.path.join(RES, "regression_report.md"), "w").write("\n".join(lines) + "\n")
    print(f"report: results/regression_report.md")
    sys.exit(1 if total_fail else 0)


if __name__ == "__main__":
    main()
