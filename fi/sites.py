#!/usr/bin/env python3
"""
sites.py - fault-site enumerator and injector-include generator.

A "site" is one bit of one register (or of one control / checker net).
Every site gets a fixed id. The list is written as
    fi/sites_<variant>_N<N>_K<K>.csv : id, path, bit, class, kind, dead, width
and a Verilog include (tb side ONLY, never synthesized)
    sim/fi/fi_sites_<variant>_N<N>_K<K>.vh
containing three tasks with one constant hierarchical reference per case arm:
    fi_force(id, val)  : force the bit to val (stuck-at)
    fi_release(id)     : release it
    fi_flip(id)        : regs: deposit the inverted value (register keeps it
                         until its next update = a bit flip / SEU);
                         nets: force the inverted current value (constant).
Paths start with the macro `ATOP (array_top instance) or `CHK (checker
instance), defined by tb/tb_fi.v, so the SAME ids address the same
array/skew/control bits in V0 and V1. Checker sites exist only in V1 and are
numbered after all shared sites.

Later variants (2026-10-06), all with the same array/skew/control ids first:
  v1p : V1-P, pipelined checker (`CHK = its checker)        - tb/tb_fi.v -DV1P
  v2  : V2, two checkers `CHK1 / `CHK2 + combiner nets      - tb/tb_fi.v -DV2
  v0d : V0-D, drain array (one more control net: shift)      - tb/tb_fi_d.v
  v1d : V1-D, drain checker                                  - tb/tb_fi_d.v -DV1D
  v2d : V2-D, two drain checkers + combiner nets             - tb/tb_fi_d.v -DV2D
Classes for the second checker of V2 / V2-D: chk2_reg, chk2_net; the combiner
outputs (alarm, chk_fault) are class comb_net.

Site classes:
  pe       : PE registers acc_out (32), a_out (8), b_out (8)
  skew     : skew shift registers in array_top
  ctrl_reg : controller state / counter registers
  ctrl_net : control nets clear_acc, in_ready (input gate), done
  chk_reg  : checker registers l_acc (32), alarm (1)
  chk_net  : checker nets sva, svb, out_sum, mismatch
"dead" = 1 marks registers whose output drives nothing (a_out of the last
column, b_out of the last row). They are real RTL flops but synthesis removes
them.
"""
import argparse
import csv
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DW, AW = 8, 32


def clog2(v):
    v -= 1
    r = 0
    while v > 0:
        r += 1
        v >>= 1
    return r


def ctrl_cw(n, k):
    cnt_max = max(k, 2 * n - 2)
    return max(1, clog2(cnt_max))


VARIANTS = ["v0", "v1", "v1p", "v2", "v0d", "v1d", "v2d", "w1", "w2", "w3", "w4", "v1dw"]
DRAIN = ("v0d", "v1d", "v2d", "v1dw")


def enumerate_sites_ws(n, k, two=False, weighted=False):
    """W1: the weight-stationary design (rtl/labft_top_ws.v), K = N.
    Classes as for the OS designs, plus `weight` (the stationary weights)."""
    sites = []

    def add(path, width, cls, kind, dead=0):
        sites.append((path, width, cls, kind, dead))

    for t in range(n):
        for j in range(n):
            pe = "`ATOP.u_array.g_row[{}].g_col[{}].u_pe".format(t, j)
            add(pe + ".psum_out", AW, "pe", "reg")
            add(pe + ".a_out", DW, "pe", "reg", int(j == n - 1))
            add(pe + ".w", DW, "weight", "reg")
    for t in range(1, n):
        add("`ATOP.g_skew[{}].u_skew_a.g_reg.sr".format(t), DW * t, "skew", "reg")
    cnt_max = max(k + n - 1, k)
    add("`ATOP.state", 3, "ctrl_reg", "reg")
    add("`ATOP.cnt", clog2(cnt_max + 1), "ctrl_reg", "reg")
    add("`ATOP.vld_sr", k + n - 1, "ctrl_reg", "reg")      # output-valid delay line
    for net in ("clear", "w_ready", "in_ready", "dot_en", "done"):
        add("`ATOP." + net, 1, "ctrl_net", "net")
    sw = DW + n if weighted else DW + clog2(n)      # W3: weighted sums need N extra bits
    tw = AW + 2 * n if weighted else AW             # W3: wide totals
    macs = (("`CHK1", "chk"), ("`CHK2", "chk2")) if two else (("`CHK", "chk"),)
    for mac, cls in macs:
        add(mac + ".svb_reg", k * sw, cls + "_reg", "reg")
        add(mac + ".sva_acc", k * sw, cls + "_reg", "reg")
        add(mac + ".l_acc", tw, cls + "_reg", "reg")
        add(mac + ".s_acc", tw, cls + "_reg", "reg")
        add(mac + ".alarm", 1, cls + "_reg", "reg")
        add(mac + ".row_b_sum", sw, cls + "_net", "net")
        add(mac + ".dot_prod", 2 * sw, cls + "_net", "net")
        add(mac + ".out_sum", tw, cls + "_net", "net")
        add(mac + ".mismatch", 1, cls + "_net", "net")
    if two:
        add("`TOP.alarm", 1, "comb_net", "net")
        add("`TOP.chk_fault", 1, "comb_net", "net")
    return sites


def enumerate_sites(variant, n, k):
    sites = []   # (path, width, class, kind, dead)

    def add(path, width, cls, kind, dead=0):
        sites.append((path, width, cls, kind, dead))

    if variant in ("w1", "w2", "w3", "w4"):
        sites = enumerate_sites_ws(n, k, two=(variant in ("w2", "w4")), weighted=(variant in ("w3", "w4")))

    # PE registers
    for i in (range(n) if variant not in ("w1", "w2", "w3", "w4") else []):
        for j in range(n):
            pe = "`ATOP.u_array.g_row[{}].g_col[{}].u_pe".format(i, j)
            add(pe + ".acc_out", AW, "pe", "reg")
            add(pe + ".a_out", DW, "pe", "reg", int(j == n - 1))
            add(pe + ".b_out", DW, "pe", "reg", int(i == n - 1))
    # skew registers (row/column i delayed i cycles -> i*8 bits)
    for i in (range(1, n) if variant not in ("w1", "w2", "w3", "w4") else []):
        add("`ATOP.g_skew[{}].u_skew_a.g_reg.sr".format(i), DW * i, "skew", "reg")
        add("`ATOP.g_skew[{}].u_skew_b.g_reg.sr".format(i), DW * i, "skew", "reg")
    # controller
    if variant not in ("w1", "w2", "w3", "w4"):
        add("`ATOP.state", 3, "ctrl_reg", "reg")
        add("`ATOP.cnt", ctrl_cw(n, k), "ctrl_reg", "reg")
        add("`ATOP.clear_acc", 1, "ctrl_net", "net")
        add("`ATOP.in_ready", 1, "ctrl_net", "net")
        add("`ATOP.done", 1, "ctrl_net", "net")
    if variant in DRAIN:
        add("`ATOP.shift", 1, "ctrl_net", "net")     # output phase of the drain
    sw = DW + clog2(n)
    # checker (V1 only)
    if variant == "v1":
        add("`CHK.l_acc", AW, "chk_reg", "reg")
        add("`CHK.alarm", 1, "chk_reg", "reg")
        add("`CHK.sva", sw, "chk_net", "net")
        add("`CHK.svb", sw, "chk_net", "net")
        add("`CHK.out_sum", AW, "chk_net", "net")
        add("`CHK.mismatch", 1, "chk_net", "net")
    # pipelined checker (V1-P)
    if variant == "v1p":
        for name, w in (("l_acc", AW), ("row_sum_r", n * AW), ("l_r1", AW), ("total_r", AW),
                        ("l_r2", AW), ("v1", 1), ("v2", 1), ("alarm", 1)):
            add("`CHK." + name, w, "chk_reg", "reg")
        for name, w in (("sva", sw), ("svb", sw), ("row_sum", n * AW), ("total", AW), ("mismatch", 1)):
            add("`CHK." + name, w, "chk_net", "net")
    # two parallel checkers (V2)
    if variant == "v2":
        for mac, cls in (("`CHK1", "chk"), ("`CHK2", "chk2")):
            add(mac + ".l_acc", AW, cls + "_reg", "reg")
            add(mac + ".alarm", 1, cls + "_reg", "reg")
            add(mac + ".sva", sw, cls + "_net", "net")
            add(mac + ".svb", sw, cls + "_net", "net")
            add(mac + ".out_sum", AW, cls + "_net", "net")
            add(mac + ".mismatch", 1, cls + "_net", "net")
    # drain checker(s) (V1-D, V2-D)
    if variant in ("v1d", "v2d", "v1dw"):
        macs = (("`CHK", "chk"),) if variant in ("v1d", "v1dw") else (("`CHK1", "chk"), ("`CHK2", "chk2"))
        tw = AW + n if variant == "v1dw" else AW            # V1-DW: wide totals
        wa = DW + n if variant == "v1dw" else sw            # V1-DW: weighted SV_A
        for mac, cls in macs:
            add(mac + ".l_acc", tw, cls + "_reg", "reg")
            add(mac + ".out_acc", tw, cls + "_reg", "reg")
            add(mac + ".alarm", 1, cls + "_reg", "reg")
            add(mac + ".sva", wa, cls + "_net", "net")
            add(mac + ".svb", sw, cls + "_net", "net")
            add(mac + ".row_sum", tw, cls + "_net", "net")
            add(mac + ".mismatch", 1, cls + "_net", "net")
    # combiner outputs of the two-checker variants
    if variant in ("v2", "v2d"):
        add("`TOP.alarm", 1, "comb_net", "net")
        add("`TOP.chk_fault", 1, "comb_net", "net")

    rows = []
    for path, width, cls, kind, dead in sites:
        for b in range(width):
            rows.append({"id": len(rows), "path": path, "bit": b, "class": cls,
                         "kind": kind, "dead": dead, "width": width})
    return rows


def bitref(r):
    # 1-bit signals are referenced without a bit select
    return r["path"] if r["width"] == 1 else "{}[{}]".format(r["path"], r["bit"])


def write_include(rows, fn):
    # Icarus only supports force on a bit-select with a CONSTANT right-hand
    # side, so stuck-at-0 and stuck-at-1 get separate case arms.
    L = ["// GENERATED by fi/sites.py - do not edit. Testbench-only (never synthesized).",
         "task fi_force;", "    input integer id;", "    input v;", "    begin",
         "        if (v) begin", "        case (id)"]
    for r in rows:
        L.append("            {}: force {} = 1'b1;".format(r["id"], bitref(r)))
    L += ["            default: ;", "        endcase", "        end else begin", "        case (id)"]
    for r in rows:
        L.append("            {}: force {} = 1'b0;".format(r["id"], bitref(r)))
    L += ["            default: ;", "        endcase", "        end", "    end", "endtask", "",
          "task fi_release;", "    input integer id;", "    begin", "        case (id)"]
    for r in rows:
        L.append("            {}: release {};".format(r["id"], bitref(r)))
    L += ["            default: ;", "        endcase", "    end", "endtask", "",
          "task fi_flip;", "    input integer id;", "    begin", "        case (id)"]
    for r in rows:
        ref = bitref(r)
        if r["kind"] == "reg":
            L.append("            {}: {} = ~{};".format(r["id"], ref, ref))
        else:
            # net: read the current value, force the constant opposite
            L.append("            {}: if ({}) force {} = 1'b0; else force {} = 1'b1;".format(
                r["id"], ref, ref, ref))
    L += ["            default: ;", "        endcase", "    end", "endtask", "",
          "function fi_is_net;", "    input integer id;", "    begin", "        case (id)"]
    nets = [str(r["id"]) for r in rows if r["kind"] == "net"]
    if nets:
        L.append("            {}: fi_is_net = 1'b1;".format(", ".join(nets)))
    L += ["            default: fi_is_net = 1'b0;", "        endcase", "    end", "endfunction", ""]
    open(fn, "w").write("\n".join(L))


def generate(variant, n, k):
    rows = enumerate_sites(variant, n, k)
    tag = "{}_N{}_K{}".format(variant, n, k)
    csv_fn = os.path.join(ROOT, "fi", "sites", "sites_{}.csv".format(tag))
    os.makedirs(os.path.dirname(csv_fn), exist_ok=True)
    with open(csv_fn, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["id", "path", "bit", "class", "kind", "dead", "width"])
        w.writeheader()
        w.writerows(rows)
    vh = os.path.join(ROOT, "sim", "fi", "fi_sites_{}.vh".format(tag))
    os.makedirs(os.path.dirname(vh), exist_ok=True)
    write_include(rows, vh)
    return rows, csv_fn, vh


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", choices=VARIANTS, required=True)
    ap.add_argument("--n", type=int, required=True)
    ap.add_argument("--k", type=int, required=True)
    a = ap.parse_args()
    rows, csv_fn, vh = generate(a.variant, a.n, a.k)
    from collections import Counter
    c = Counter(r["class"] for r in rows)
    print("{} sites -> {} and {}".format(len(rows), csv_fn, vh))
    print("by class:", dict(c), " dead:", sum(r["dead"] for r in rows),
          " reg bits:", sum(1 for r in rows if r["kind"] == "reg"))


if __name__ == "__main__":
    main()
