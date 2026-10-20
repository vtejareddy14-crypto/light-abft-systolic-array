#!/usr/bin/env python3
"""
campaign.py - build a fault list, run it in parallel Icarus shards, classify.

  python3 fi/campaign.py --variant v1 --n 4 --k 4 --kind persistent
  python3 fi/campaign.py --variant v1 --n 8 --k 8 --kind transient --sample 20000

Persistent (primary): every site x {stuck-0, stuck-1, held-inverted (regs only)}
x every campaign matrix, fault active for the whole multiply.
Transient (secondary): every site x every run cycle x every matrix, 1-cycle flip.
--sample S draws S injections uniformly (fixed --seed) from that full space.
Golden (no-fault) runs for every matrix are always included.

The fault list is saved (results/fi/<tag>/faults.txt) so every variant can be
run on the SAME list: shared array/skew/control site ids are identical in V0
and V1 (see fi/sites.py); --faults-from reuses a saved list.

Outcome per run:
  output wrong + alarm -> DETECTED        output wrong + no alarm -> SILENT
  output right + alarm -> FALSE_ALARM     output right + no alarm -> BENIGN
"""
import argparse
import collections
import csv
import math
import os
import random
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
sys.path.insert(0, os.path.join(ROOT, "fi"))
import golden  # noqa: E402
import sites as sitesmod  # noqa: E402

RTL_V0 = ["rtl/array_top.v", "rtl/skew_line.v", "rtl/systolic_array.v", "rtl/pe.v"]
RTL_V1 = ["rtl/labft_top.v", "rtl/labft_checker.v", "rtl/sum_tree.v"] + RTL_V0
RTL_W1 = ["rtl/labft_top_ws.v", "rtl/labft_checker_ws.v", "rtl/sum_tree.v", "rtl/ws_top.v",
          "rtl/skew_line.v", "rtl/systolic_array_ws.v", "rtl/pe_ws.v"]
RTL_V0D = ["rtl/array_top_d.v", "rtl/skew_line.v", "rtl/systolic_array_d.v", "rtl/pe_d.v"]

# variant -> (testbench, define, RTL files, extra cycles after done that the
# checker still needs). v0 / v1 are exactly as before.
VARIANTS = {
    "v0":  ("tb/tb_fi.v",   None,  RTL_V0, 0),
    "v1":  ("tb/tb_fi.v",   "V1",  RTL_V1, 0),
    "v2":  ("tb/tb_fi.v",   "V2",  ["rtl/labft_top_2.v", "rtl/labft_checker.v", "rtl/sum_tree.v"] + RTL_V0, 0),
    "v0d": ("tb/tb_fi_d.v", None,  RTL_V0D, 0),
    "v1d": ("tb/tb_fi_d.v", "V1D", ["rtl/labft_top_d.v", "rtl/labft_checker_d.v", "rtl/sum_tree.v"] + RTL_V0D, 0),
    "v2d": ("tb/tb_fi_d.v", "V2D", ["rtl/labft_top_d2.v", "rtl/labft_checker_d.v", "rtl/sum_tree.v"] + RTL_V0D, 0),
    "v1dw": ("tb/tb_fi_d.v", "V1DW", ["rtl/labft_top_dw.v", "rtl/labft_checker_dw.v", "rtl/sum_tree.v"] + RTL_V0D, 0),
    "w1":  ("tb/tb_fi_ws.v", None, RTL_W1, 0),
    "w2":  ("tb/tb_fi_ws.v", "W2", ["rtl/labft_top_ws2.v"] + RTL_W1[1:], 0),
    "w3":  ("tb/tb_fi_ws.v", "W3", ["rtl/labft_top_ws3.v", "rtl/labft_checker_ws_w.v"] + RTL_W1[2:], 0),
    "w4":  ("tb/tb_fi_ws.v", "W4", ["rtl/labft_top_ws4.v", "rtl/labft_checker_ws_w.v"] + RTL_W1[2:], 0),
}
MODE_NAME = {0: "none", 1: "stuck0", 2: "stuck1", 3: "inverted", 4: "flip1"}


def wilson(k, n, z=1.96):
    if n == 0:
        return (float("nan"), float("nan"))
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def outcome(correct, alarm):
    if not correct:
        return "DETECTED" if alarm else "SILENT"
    return "FALSE_ALARM" if alarm else "BENIGN"


def build_faults(rows, kind, n, k, nmat, sample, seed, variant="v0"):
    runcycles = k + 2 * n          # rc = 0 .. K+2N-1 (done cycle included)
    if variant in sitesmod.DRAIN:
        runcycles += n             # N more cycles: the rows leave the array
    runcycles += VARIANTS[variant][3]   # V1-P: the 2 extra checker cycles
    space = []
    for r in rows:
        if kind == "persistent":
            modes = [1, 2, 3] if r["kind"] == "reg" else [1, 2]
            for m in modes:
                for mat in range(nmat):
                    space.append((r["id"], m, 0, mat))
        else:
            for c in range(runcycles):
                for mat in range(nmat):
                    space.append((r["id"], 4, c, mat))
    total = len(space)
    if sample and sample < total:
        rnd = random.Random(seed)
        space = rnd.sample(space, sample)
    # Golden (no-fault) runs at the start AND after every 200 injections: if a
    # fault ever leaked into the next run (e.g. a force not released), a later
    # golden run would come out wrong and the sanity line would say so.
    faults = [(-1, 0, 0, mat) for mat in range(nmat)]
    for idx, f in enumerate(space):
        faults.append(f)
        if (idx + 1) % 200 == 0:
            faults.append((-1, 0, 0, (idx // 200) % nmat))
    faults += [(-1, 0, 0, mat) for mat in range(nmat)]
    return faults, total


def compile_tb(variant, n, k, vh_name, out):
    tb, define, rtl, _ = VARIANTS[variant]
    tbname = os.path.basename(tb)[:-2]
    cmd = ["iverilog", "-g2005", "-I", "sim/fi", '-DFI_SITES="{}"'.format(vh_name),
           "-P{}.N={}".format(tbname, n), "-P{}.K={}".format(tbname, k), "-o", out, tb] + rtl
    if define:
        cmd.insert(1, "-D" + define)
    p = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    errs = [l for l in p.stdout.splitlines() if "sorry: procedural continuous" not in l and l.strip()]
    if p.returncode != 0:
        sys.exit("compile failed:\n" + "\n".join(errs[:40]))
    return " ".join(cmd)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", choices=sorted(VARIANTS), required=True)
    ap.add_argument("--n", type=int, required=True)
    ap.add_argument("--k", type=int, default=None)
    ap.add_argument("--kind", choices=["persistent", "transient"], default="persistent")
    ap.add_argument("--nmat", type=int, default=3, help="campaign input matrices")
    ap.add_argument("--dist", choices=["random", "small"], default="random")
    ap.add_argument("--sample", type=int, default=0)
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--faults-from", default=None, help="reuse a saved faults.txt")
    ap.add_argument("--path-filter", default=None,
                    help="only inject into sites whose path ends with this text (e.g. .acc_out)")
    ap.add_argument("--tag", default=None)
    a = ap.parse_args()
    n = a.n
    k = a.k or n
    tag = a.tag or "{}_N{}_K{}_{}_{}{}".format(a.variant, n, k, a.kind, a.dist,
                                               "_s{}".format(a.sample) if a.sample else "")
    outdir = os.path.join(ROOT, "results", "fi", tag)
    simdir = os.path.join(ROOT, "sim", "fi", tag)
    os.makedirs(outdir, exist_ok=True)
    os.makedirs(simdir, exist_ok=True)

    rows, csv_fn, vh = sitesmod.generate(a.variant, n, k)
    site_by_id = {r["id"]: r for r in rows}

    # campaign matrices (fixed seed, saved with the results)
    rng_seed = 777 + n + (1 if a.dist == "small" else 0)
    tests = golden.make_tests(n, k, a.nmat, rng_seed, a.dist)
    tests = [t for t in tests if t[0] == a.dist][:a.nmat]     # campaign uses random pairs only
    vdir = os.path.join(simdir, "vec")
    golden.write_vectors(vdir, n, k, tests, rng_seed, a.dist)

    if a.faults_from:
        faults = []
        for line in open(a.faults_from):
            f = line.split()
            faults.append((int(f[1]), int(f[2]), int(f[3]), int(f[4])))
        total_space = None
        ids = set(site_by_id)
        faults = [f for f in faults if f[0] == -1 or f[0] in ids]
    else:
        pick = [r for r in rows if a.path_filter is None or r["path"].endswith(a.path_filter)]
        faults, total_space = build_faults(pick, a.kind, n, k, a.nmat, a.sample, a.seed, a.variant)
    with open(os.path.join(outdir, "faults.txt"), "w") as f:
        for i, (s, m, c, mat) in enumerate(faults):
            f.write("{} {} {} {} {}\n".format(i, s, m, c, mat))

    vvp = os.path.join(simdir, "tb_fi.vvp")
    cmdline = compile_tb(a.variant, n, k, os.path.basename(vh), vvp)

    # shard and run
    jobs = max(1, min(a.jobs, len(faults)))
    shards = [faults[i::jobs] for i in range(jobs)]
    ids = [list(range(len(faults)))[i::jobs] for i in range(jobs)]
    procs = []
    t0 = time.time()
    for j in range(jobs):
        ff = os.path.join(simdir, "faults_{}.txt".format(j))
        with open(ff, "w") as f:
            for fid, (s, m, c, mat) in zip(ids[j], shards[j]):
                f.write("{} {} {} {} {}\n".format(fid, s, m, c, mat))
        of = os.path.join(simdir, "out_{}.txt".format(j))
        procs.append((subprocess.Popen(["vvp", "-n", vvp, "+vec=" + vdir, "+faults=" + ff, "+out=" + of],
                                       cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True), of))
    for p, _ in procs:
        p.wait()
    wall = time.time() - t0

    results = []
    for _, of in procs:
        for line in open(of):
            f = line.split()
            if f[0] == "C":
                continue
            results.append(dict(fid=int(f[0]), site=int(f[1]), mode=int(f[2]), cycle=int(f[3]),
                                mat=int(f[4]), correct=int(f[5]), nwrong=int(f[6]), alarm=int(f[7]),
                                hang=int(f[8]), done_rc=int(f[9]), mask=f[10],
                                chkf=int(f[11]) if len(f) > 11 else 0))
    results.sort(key=lambda r: r["fid"])
    if len(results) != len(faults):
        sys.exit("ERROR: {} results for {} faults".format(len(results), len(faults)))

    # write per-run CSV
    with open(os.path.join(outdir, "runs.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["fid", "site", "class", "path", "bit", "dead", "mode", "cycle", "mat",
                    "correct", "n_wrong", "alarm", "hang", "done_rc", "mask", "outcome", "chk_fault"])
        for r in results:
            s = site_by_id.get(r["site"], {"class": "none", "path": "-", "bit": "-", "dead": 0})
            w.writerow([r["fid"], r["site"], s["class"], s["path"], s["bit"], s["dead"],
                        MODE_NAME[r["mode"]], r["cycle"], r["mat"], r["correct"], r["nwrong"],
                        r["alarm"], r["hang"], r["done_rc"], r["mask"], outcome(r["correct"], r["alarm"]),
                        r["chkf"]])

    # summary
    golden_runs = [r for r in results if r["site"] == -1]
    gold_ok = all(r["correct"] == 1 and r["alarm"] == 0 and r["chkf"] == 0 for r in golden_runs)
    inj = [r for r in results if r["site"] != -1]
    by = collections.defaultdict(collections.Counter)
    for r in inj:
        s = site_by_id[r["site"]]
        cls = s["class"] + ("(dead)" if s["dead"] else "")
        o = outcome(r["correct"], r["alarm"])
        by[cls][o] += 1
        by["ALL"][o] += 1
        by[cls]["HANG"] += r["hang"]
        by["ALL"]["HANG"] += r["hang"]
        by[cls]["CHKF"] += r["chkf"]
        by["ALL"]["CHKF"] += r["chkf"]
    sampled = bool(a.sample) and total_space is not None and a.sample < total_space
    L = ["# Fault-injection campaign `{}`".format(tag), "",
         "- variant {}, N={}, K={}, kind {}, input distribution {}, {} campaign matrices".format(
             a.variant.upper(), n, k, a.kind, a.dist, a.nmat),
         "- sites: {} ({}), fault space {} injections, run {}{}".format(
             len(rows), os.path.relpath(csv_fn, ROOT), total_space if total_space else "(reused list)",
             len(inj), " (uniform random sample, seed {})".format(a.seed) if sampled else " (exhaustive)"),
         "- golden (no-fault) runs: {} / {} correct with no alarm -> {}".format(
             sum(1 for r in golden_runs if r["correct"] and not r["alarm"]), len(golden_runs),
             "OK" if gold_ok else "**SANITY FAILURE**"),
         "- wall time {:.1f} s on {} parallel Icarus processes -> {:.0f} injections/s".format(
             wall, jobs, len(results) / wall),
         "- compile: `{}`".format(cmdline), "",
         "| site class | runs | DETECTED | SILENT | FALSE_ALARM | BENIGN | hang | detection rate | false-alarm rate (given correct) | false alarms / total |",
         "|---|---|---|---|---|---|---|---|---|---|"]
    order = ["pe", "pe(dead)", "skew", "ctrl_reg", "ctrl_net", "chk_reg", "chk_net",
             "chk2_reg", "chk2_net", "comb_net", "ALL"]
    for cls in [c for c in order if c in by] + sorted(c for c in by if c not in order):
        c = by[cls]
        tot = sum(c[o] for o in ("DETECTED", "SILENT", "FALSE_ALARM", "BENIGN"))
        wrong = c["DETECTED"] + c["SILENT"]
        right = c["FALSE_ALARM"] + c["BENIGN"]

        def rate(num, den):
            if den == 0:
                return "n/a"
            s = "{:.2f}%".format(100.0 * num / den)
            if sampled:
                lo, hi = wilson(num, den)
                s += " [{:.2f}, {:.2f}]".format(100 * lo, 100 * hi)
            return s
        L.append("| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            cls, tot, c["DETECTED"], c["SILENT"], c["FALSE_ALARM"], c["BENIGN"], c["HANG"],
            rate(c["DETECTED"], wrong), rate(c["FALSE_ALARM"], right), rate(c["FALSE_ALARM"], tot)))
    if a.variant in ("v2", "v2d"):
        L += ["", "Two-checker variant: `alarm` (both checkers agree) decides the outcome above.",
              "Runs where the checkers disagreed (chk_fault = 1), per site class:", "",
              "| site class | runs | chk_fault raised |", "|---|---|---|"]
        for cls in [c for c in order if c in by] + sorted(c for c in by if c not in order):
            c = by[cls]
            tot = sum(c[o] for o in ("DETECTED", "SILENT", "FALSE_ALARM", "BENIGN"))
            L.append("| {} | {} | {} |".format(cls, tot, c["CHKF"]))
    if sampled:
        L.append("")
        L.append("Rates in brackets: 95% Wilson confidence interval (sampled campaign).")
    L.append("")
    open(os.path.join(outdir, "summary.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))
    return 0 if gold_ok else 1


if __name__ == "__main__":
    sys.exit(main())
