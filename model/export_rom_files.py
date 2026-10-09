"""
export_rom_files.py
Turns ecg_cnn_weights_fixedpoint.pkl into the two files the ROM modules load:

    weights.hex : 32,488 lines, one 16-bit weight per line (4 hex digits)
    biases.hex  :     58 lines, one 16-bit bias   per line (4 hex digits)

The weights are written in the exact order addr_gen walks them:
    for each filter -> for each channel -> for each tap   (row-major)
so   weight_addr = layer_offset + filt*(C*K) + ch*K + k

Run:  python export_rom_files.py
(needs ecg_cnn_weights_fixedpoint.pkl in the same folder)
"""
import pickle
import sys
import numpy as np

PKL = "ecg_cnn_weights_fixedpoint.pkl"

# name, filters, positions, channels, kernel   (same numbers addr_gen is given)
LAYERS = [
    ("conv1", 8, 256, 1, 5),
    ("conv2", 16, 124, 8, 5),
    ("fc1", 32, 1, 1, 992),
    ("fc2", 2, 1, 1, 32),
]

with open(PKL, "rb") as f:
    qw = pickle.load(f)

weights = []          # flat list of python ints
biases = []
w_off, b_off = {}, {}

for name, F, P, C, K in LAYERS:
    w = qw[name + ".weight"]
    b = qw[name + ".bias"]
    assert w.dtype == np.int16 and b.dtype == np.int16, f"{name}: not int16"
    assert w.size == F * C * K, f"{name}: weight count {w.size} != {F*C*K}"
    assert b.size == F, f"{name}: bias count {b.size} != {F}"

    w_off[name] = len(weights)
    b_off[name] = len(biases)
    weights.extend(int(v) for v in w.reshape(-1))     # C-order = filter, channel, tap
    biases.extend(int(v) for v in b.reshape(-1))

assert len(weights) == 32488, len(weights)
assert len(biases) == 58, len(biases)

# ---- self-check: addr_gen's own address rule must reproduce every weight ----
# For every multiply step of every layer, weight_addr = offset + filt*(C*K) + ch*K + k
# must point at the same number the .pkl holds at [filt, ch, k].
steps_checked = 0
for name, F, P, C, K in LAYERS:
    w = qw[name + ".weight"].reshape(F, C, K)
    off = w_off[name]
    for filt in range(F):
        for pos in range(P):                  # weights repeat for every position
            for ch in range(C):
                for k in range(K):
                    addr = off + filt * (C * K) + ch * K + k
                    if weights[addr] != int(w[filt, ch, k]):
                        sys.exit(f"MISMATCH {name} f={filt} ch={ch} k={k} addr={addr}")
                    steps_checked += 1
assert steps_checked == 121408, steps_checked    # total multiplies per beat


def hex16(v):
    return "%04x" % (v & 0xFFFF)               # two's complement, 4 hex digits


with open("weights.hex", "w") as f:
    for v in weights:
        f.write(hex16(v) + "\n")
with open("biases.hex", "w") as f:
    for v in biases:
        f.write(hex16(v) + "\n")

print(f"weights.hex : {len(weights)} lines")
print(f"biases.hex  : {len(biases)} lines")
print(f"self-check  : {steps_checked} multiply steps, every weight address matches the .pkl")
print()
print("layer   weight_offset  weights   bias_offset  biases")
for name, F, P, C, K in LAYERS:
    print(f"{name:6}  {w_off[name]:13}  {F*C*K:7}   {b_off[name]:11}  {F:6}")
