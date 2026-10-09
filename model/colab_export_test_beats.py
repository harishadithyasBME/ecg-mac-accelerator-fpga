# ===== Answer-key export: paste into ONE Colab cell and run =====
# Run it in the notebook session that still has `test_beats` and `test_labels_bin`.
# It saves all 24,526 test beats in the exact Q4.12 form the hardware will receive,
# so the answer key can be built (and the beats chosen) on the other side.

import os
import numpy as np

# 1) the two variables must exist (they vanish after a Colab runtime reset)
for name in ("test_beats", "test_labels_bin"):
    if name not in globals():
        raise NameError(name + " is missing. Re-run the setup / extraction / labels cells "
                        "first, then run this cell again.")

beats  = np.asarray(test_beats, dtype=np.float64)
labels = np.asarray(test_labels_bin).astype(np.int8)
assert beats.ndim == 2 and beats.shape[1] == 260, "expected beats of 260 samples, got " + str(beats.shape)
assert len(beats) == len(labels), "beats and labels differ in length"
if len(beats) != 24526:
    print("WARNING: expected 24,526 test beats, found", len(beats))

# 2) quantize exactly like fixed_point_forward_v2 does: Q4.12, saturating at 16 bits
q_raw   = np.round(beats * 4096)
clipped = int(((q_raw > 32767) | (q_raw < -32768)).sum())
beats_q = np.clip(q_raw, -32768, 32767).astype(np.int16)
print("beats        :", beats_q.shape)
print("Q4.12 min/max:", int(beats_q.min()), int(beats_q.max()), "(limit -32768 .. 32767)")
print("samples that hit the 16-bit limit:", clipped)
print("Normal:", int((labels == 0).sum()), "  Abnormal:", int((labels == 1).sum()))

# 3) cross-check data: your own validated function's scores on 40 beats
#    (lets the answer key be proven identical to the model that scored 98.51%)
rng = np.random.RandomState(7)
check_idx    = np.sort(rng.choice(len(beats), 40, replace=False))
check_scores = np.zeros((0, 2), dtype=np.int64)
if "fixed_point_forward_v2" in globals():
    saved_counts = dict(overflow_count) if "overflow_count" in globals() else None
    check_scores = np.array([fixed_point_forward_v2(test_beats[i]) for i in check_idx],
                            dtype=np.int64)
    if saved_counts is not None:
        overflow_count.update(saved_counts)      # leave your saturation counters untouched
    print("saved fixed_point_forward_v2 scores for", len(check_idx), "beats")
else:
    print("fixed_point_forward_v2 is not defined in this session: skipping the cross-check scores")

# 4) save and download
np.savez_compressed("test_beats_q412.npz", beats_q412=beats_q, labels=labels,
                    check_idx=check_idx, check_scores=check_scores)
print("file test_beats_q412.npz:", round(os.path.getsize("test_beats_q412.npz") / 1e6, 1), "MB")
from google.colab import files
files.download("test_beats_q412.npz")
