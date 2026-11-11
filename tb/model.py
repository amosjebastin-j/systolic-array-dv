"""Golden reference model for the systolic-array matrix multiplier."""


def to_s8(x):
    x &= 0xFF
    return x - 256 if x & 0x80 else x


def to_s32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


def matmul(a, b):
    n = len(a)
    return [[sum(a[i][k] * b[k][j] for k in range(n)) for j in range(n)] for i in range(n)]
