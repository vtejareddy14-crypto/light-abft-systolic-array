#!/usr/bin/env python3
"""
golden.py - reference model and test-vector writer for the OS systolic array.

The golden model is deliberately NOT a copy of the RTL: it is plain matrix
multiplication in int64 (numpy), then wrapped to ACC_WIDTH-bit two's
complement, which is what a 32-bit accumulator that silently overflows gives.

Vector files (read by tb/tb_gemm.v with $readmemh), for T tests of size
A: N x K, B: K x N:
  a.hex : T*K lines, line m*K+t = column t of A_m, element i in bits [8i+7:8i]
  b.hex : T*K lines, line m*K+t = row    t of B_m, element j in bits [8j+7:8j]
  c.hex : T*N*N lines, line m*N*N + i*N + j = C_m[i][j] (32-bit two's compl.)
  meta.txt : N K T seed dist
"""
import argparse
import os

import numpy as np

DATA_WIDTH = 8
ACC_WIDTH = 32


def wrap(x, bits=ACC_WIDTH):
    """Wrap int64 array to signed `bits`-bit two's complement."""
    x = np.asarray(x, dtype=np.int64)
    m = np.int64(1) << bits
    x = x & (m - 1)
    return np.where(x >= (m >> 1), x - m, x)


def gemm(a, b):
    """Golden C = A @ B in int64, wrapped to 32 bits."""
    return wrap(np.asarray(a, np.int64) @ np.asarray(b, np.int64))


def light_abft_L(a, b):
    """Libano Theorem VI.1 check value: sum_t SV_A[t]*SV_B[t], wrapped to 32 bits.
    SV_A[t] = sum_i A[i][t] (column sum), SV_B[t] = sum_j B[t][j] (row sum)."""
    a = np.asarray(a, np.int64)
    b = np.asarray(b, np.int64)
    return int(wrap(np.sum(a.sum(axis=0) * b.sum(axis=1))))


def directed_cases(n, k, rng):
    """Directed corner cases (all zeros, -128 extremes, identity-like)."""
    cases = []
    z_a = np.zeros((n, k), np.int64)
    z_b = np.zeros((k, n), np.int64)
    # 1. all zeros
    cases.append(("zeros", z_a.copy(), z_b.copy()))
    # 2. all -128 (worst-case magnitude: every product is +16384)
    cases.append(("all_m128", np.full((n, k), -128), np.full((k, n), -128)))
    # 3. -128 times 127 (largest negative products)
    cases.append(("m128_x_127", np.full((n, k), -128), np.full((k, n), 127)))
    # 4. identity-like A (A[i][t] = 1 when i == t), random B -> C = first rows of B
    ident = z_a.copy()
    for i in range(min(n, k)):
        ident[i][i] = 1
    cases.append(("identity_like", ident, rng.integers(-128, 128, (k, n))))
    # 5. one nonzero element in A and one in B that meet -> exactly one nonzero C
    a1 = z_a.copy()
    b1 = z_b.copy()
    i, t, j = rng.integers(0, n), rng.integers(0, k), rng.integers(0, n)
    a1[i][t] = -128
    b1[t][j] = -128
    cases.append(("one_nonzero", a1, b1))
    return cases


def make_tests(n, k, count, seed, dist):
    rng = np.random.default_rng(seed)
    tests = directed_cases(n, k, rng) if dist in ("random", "small") else []
    lo, hi = (-128, 128) if dist == "random" else (-4, 5)   # hi is exclusive
    while len(tests) < count + (5 if dist in ("random", "small") else 0):
        tests.append((dist, rng.integers(lo, hi, (n, k)), rng.integers(lo, hi, (k, n))))
    return tests


def to_hex_vec(vals, width=DATA_WIDTH):
    """Pack a list of signed ints, element 0 in the LOW bits, into one hex word."""
    word = 0
    for idx, v in enumerate(vals):
        word |= (int(v) & ((1 << width) - 1)) << (idx * width)
    digits = (len(vals) * width + 3) // 4
    return format(word, "0{}x".format(digits))


def write_vectors(outdir, n, k, tests, seed=0, dist="?"):
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "a.hex"), "w") as fa, \
         open(os.path.join(outdir, "b.hex"), "w") as fb, \
         open(os.path.join(outdir, "c.hex"), "w") as fc, \
         open(os.path.join(outdir, "names.txt"), "w") as fn:
        for name, a, b in tests:
            a = np.asarray(a, np.int64)
            b = np.asarray(b, np.int64)
            assert a.shape == (n, k) and b.shape == (k, n)
            assert a.min() >= -128 and a.max() <= 127 and b.min() >= -128 and b.max() <= 127
            for t in range(k):
                fa.write(to_hex_vec(a[:, t]) + "\n")
                fb.write(to_hex_vec(b[t, :]) + "\n")
            c = gemm(a, b)
            for i in range(n):
                for j in range(n):
                    fc.write(format(int(c[i][j]) & 0xFFFFFFFF, "08x") + "\n")
            fn.write(name + "\n")
    with open(os.path.join(outdir, "meta.txt"), "w") as fm:
        fm.write("{} {} {} {} {}\n".format(n, k, len(tests), seed, dist))
    return len(tests)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, required=True)
    ap.add_argument("--k", type=int, required=True)
    ap.add_argument("--count", type=int, default=1000, help="random pairs (directed cases are extra)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--dist", choices=["random", "small"], default="random")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    tests = make_tests(args.n, args.k, args.count, args.seed, args.dist)
    total = write_vectors(args.out, args.n, args.k, tests, args.seed, args.dist)
    print("wrote {} tests (N={} K={} dist={}) to {}".format(total, args.n, args.k, args.dist, args.out))


if __name__ == "__main__":
    main()
