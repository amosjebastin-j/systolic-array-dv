"""Golden model for mlp_top: int8 GEMM + int8 requantization (round-half-up, zero-point, ReLU)."""
from model import matmul


def requant(acc, mult, shift, zp, relu):
    p = acc * mult
    if shift:
        p += 1 << (shift - 1)
    y = (p >> shift) + zp            # Python >> on ints is an arithmetic (floor) shift
    lo = zp if relu else -128
    return max(lo, min(127, y))


def mlp_layer(a, b, mult, shift, zp, relu):
    c = matmul(a, b)
    return c, [[requant(v, mult, shift, zp, relu) for v in row] for row in c]


def to_s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x
