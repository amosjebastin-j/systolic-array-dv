"""Lightweight functional coverage collector (bins + hit counts, JSON dump)."""
import json
import os


class Coverage:
    def __init__(self):
        self.points = {}

    def define(self, point, bins):
        self.points.setdefault(point, {b: 0 for b in bins})

    def hit(self, point, b):
        if b not in self.points[point]:
            raise KeyError(f"unknown bin {point}.{b}")
        self.points[point][b] += 1

    def summary(self):
        total = sum(len(v) for v in self.points.values())
        hit = sum(1 for v in self.points.values() for c in v.values() if c)
        return hit, total

    def dump(self, path):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w") as f:
            json.dump(self.points, f, indent=2)


cov = Coverage()
cov.define("matrix_kind", ["random", "zero", "identity", "all_max", "all_min",
                           "alt_sign", "sparse", "corner_mix"])
cov.define("c_value", ["neg_large", "neg", "zero", "pos", "pos_large", "max_pos", "max_neg"])
cov.define("operand_pair", ["min_x_min", "min_x_max", "max_x_max", "zero_x_any"])
cov.define("apb_error", ["unmapped", "ro_write", "write_A_busy", "write_B_busy"])
cov.define("sequencing", ["start_while_busy", "back_to_back", "read_C_while_busy",
                          "read_C_wait_state"])
