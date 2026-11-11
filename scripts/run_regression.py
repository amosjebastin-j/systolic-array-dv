#!/usr/bin/env python3
"""Multi-seed regression + bug-injection (mutation) runner for both tops.

    python3 scripts/run_regression.py --seeds 10 --iters 200
    python3 scripts/run_regression.py --seeds 3 --bugs      # also prove each injected bug is caught
    python3 scripts/run_regression.py --top mlp_top ...     # only the v2 MLP engine

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
    "sa_apb_top": {
        "BUG_SIGN": "B operand multiplied as unsigned",
        "BUG_NOCLR": "accumulators not cleared on START",
        "BUG_SKEW": "last row of A fed one cycle late",
        "BUG_PSLVERR": "no write protection while BUSY",
        "BUG_CTRANSPOSE": "C read-back address transposed",
    },
    "mlp_top": {
        "BUG_4K": "DMA burst crosses a 4 KB boundary",
        "BUG_ROUND": "requantization truncates instead of rounding",
        "BUG_RELU_ZP": "ReLU clamps at 0 instead of the zero-point",
        "BUG_WLAST": "WLAST asserted one beat early",
        "BUG_SIGN": "B operand multiplied as unsigned (shared PE)",
    },
}
ITER_SCALE = {"sa_apb_top": 1.0, "mlp_top": 0.5}


def run(top, tag, seed, iters, n, defines=""):
    tag = f"{top}_{tag}"
    xml = os.path.join(RES, f"res_{tag}.xml")
    cov = os.path.join(RES, f"cov_{tag}.json")
    for f in (xml, cov):
        if os.path.exists(f):
            os.remove(f)
    build = f"sim_build_{top}_n{n}" + (f"_{defines}" if defines else "")
    cmd = ["make", "-s", f"TOP={top}", f"SEED={seed}", f"NUM_ITERS={max(1, int(iters * ITER_SCALE[top]))}", f"N={n}",
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
    ap.add_argument("--top", choices=["both", "sa_apb_top", "mlp_top"], default="both")
    a = ap.parse_args()
    os.makedirs(RES, exist_ok=True)
    tops = ["sa_apb_top", "mlp_top"] if a.top == "both" else [a.top]

    lines = ["# Regression report", "", f"Array size N={a.n}, {a.iters} random ops per seed "
             "(v1 APB array) / half that for the v2 MLP engine", "",
             "## Seeds", "", "| top | seed | tests | failures | time (s) |", "|---|---|---|---|---|"]
    covs, total_fail = [], 0
    for s in [random.randint(1, 2**31 - 1) for _ in range(a.seeds)]:
        for top in tops:
            t, f, failed, dt, cov = run(top, f"seed{s}", s, a.iters, a.n)
            covs.append(cov)
            total_fail += abs(f)
            status = "PASS" if f == 0 else f"FAIL {failed}"
            print(f"{top:<11} seed {s:>10}: {t} tests, {status}  ({dt:.1f}s)")
            lines.append(f"| {top} | {s} | {t} | {f} | {dt:.1f} |")

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
                  "| top | bug | description | result | failing tests |", "|---|---|---|---|---|"]
        for top in tops:
            for bug, desc in BUGS[top].items():
                t, f, failed, _, _ = run(top, bug, 1, 20, a.n, bug)
                res = "CAUGHT" if f != 0 else "**ESCAPED**"
                if f == 0:
                    total_fail += 1
                print(f"{top:<11} {bug:<16} {res:<10} {failed}")
                lines.append(f"| {top} | `{bug}` | {desc} | {res} | {', '.join(failed)} |")

    open(os.path.join(RES, "regression_report.md"), "w").write("\n".join(lines) + "\n")
    print(f"report: results/regression_report.md")
    sys.exit(1 if total_fail else 0)


if __name__ == "__main__":
    main()
