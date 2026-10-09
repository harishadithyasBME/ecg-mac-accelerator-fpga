#!/usr/bin/env python3
"""
make_answer_key.py  -  builds the Verilog "answer key" from the exported test beats.

    python3 make_answer_key.py test_beats_q412.npz --out answer_key --rom-dir <folder with weights.hex, biases.hex>

What it does
  1. Re-runs the validated fixed-point model (same integer arithmetic as
     fixed_point_forward_v2) on ALL beats, layer by layer, in a fast vectorised form.
  2. Proves that copy is the real model:
       - it must match a verbatim, loop-for-loop copy of the model on the chosen beats,
       - it must match the scores your Colab session saved (check_scores),
       - on the full 24,526-beat test set it must give 98.51 % accuracy and the
         documented saturation counts (fc1: 7, every other layer: 0).
  3. Picks 16 beats on purpose (typical, extreme, saturating, misclassified, borderline).
  4. Writes one hex file per stage, laid out exactly like the hardware memories.
  5. Replays the whole network from the written hex files + weights.hex + biases.hex using
     addr_gen's address formulas, and checks every stage against the key.
"""
import argparse
import os
import pickle
import sys

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

K_BEATS = 16


def sat16(x):
    return np.clip(x, -32768, 32767)


# --------------------------------------------------------------------------- weights
def load_weights(path):
    qw = pickle.load(open(path, "rb"))
    return dict(
        w1=qw["conv1.weight"].reshape(8, 5).astype(np.int64),
        b1=qw["conv1.bias"].astype(np.int64),
        w2=qw["conv2.weight"].astype(np.int64),          # (16, 8, 5)
        b2=qw["conv2.bias"].astype(np.int64),
        wf1=qw["fc1.weight"].astype(np.int64),           # (32, 992)
        bf1=qw["fc1.bias"].astype(np.int64),
        wf2=qw["fc2.weight"].astype(np.int64),           # (2, 32)
        bf2=qw["fc2.bias"].astype(np.int64),
    )


# --------------------------------------------------------------------------- reference model
def ref_beat(xq, W):
    """Loop-for-loop copy of fixed_point_forward_v2, returning every stage."""
    x = xq.astype(np.int64)
    conv1 = np.zeros((8, 256), dtype=np.int64)
    for f in range(8):
        for i in range(256):
            acc = np.sum(x[i:i + 5] * W["w1"][f])
            acc = acc + (W["b1"][f] << 12)
            acc = acc >> 16
            conv1[f, i] = acc
    ovf1 = int(((conv1 > 32767) | (conv1 < -32768)).sum())
    conv1 = sat16(conv1)
    conv1 = np.maximum(conv1, 0)
    pool1 = conv1[:, 0::2][:, :conv1.shape[1] // 2]
    pool1 = np.maximum(pool1, conv1[:, 1::2][:, :pool1.shape[1]])

    out_len2 = pool1.shape[1] - 5 + 1
    conv2 = np.zeros((16, out_len2), dtype=np.int64)
    for f in range(16):
        for i in range(out_len2):
            acc = np.sum(pool1[:, i:i + 5] * W["w2"][f])
            acc = acc + (W["b2"][f] << 10)
            acc = acc >> 15
            conv2[f, i] = acc
    ovf2 = int(((conv2 > 32767) | (conv2 < -32768)).sum())
    conv2 = sat16(conv2)
    conv2 = np.maximum(conv2, 0)
    pool2 = conv2[:, 0::2][:, :conv2.shape[1] // 2]
    pool2 = np.maximum(pool2, conv2[:, 1::2][:, :pool2.shape[1]])

    flat = pool2.flatten()
    fc1 = W["wf1"] @ flat
    fc1 = fc1 + (W["bf1"] << 10)
    fc1 = fc1 >> 16
    ovf3 = int(((fc1 > 32767) | (fc1 < -32768)).sum())
    fc1 = sat16(fc1)
    fc1 = np.maximum(fc1, 0)

    fc2 = W["wf2"] @ fc1
    fc2 = fc2 + (W["bf2"] << 9)
    fc2 = fc2 >> 14
    ovf4 = int(((fc2 > 32767) | (fc2 < -32768)).sum())
    fc2 = sat16(fc2)
    return dict(conv1=conv1, pool1=pool1, conv2=conv2, pool2=pool2, fc1=fc1, fc2=fc2,
                ovf=np.array([ovf1, ovf2, ovf3, ovf4]))


# --------------------------------------------------------------------------- vectorised model
def vec_chunk(Xq, W):
    """Same arithmetic for a batch of beats (B, 260). Every sum is exact integer arithmetic."""
    X = Xq.astype(np.int64)
    B = X.shape[0]
    a1 = (sliding_window_view(X, 5, axis=1) @ W["w1"].T + (W["b1"] << 12)) >> 16    # (B,256,8)
    a1 = a1.transpose(0, 2, 1)                                                      # (B,8,256)
    ovf1 = ((a1 > 32767) | (a1 < -32768)).sum(axis=(1, 2))
    c1 = np.maximum(sat16(a1), 0)
    p1 = np.maximum(c1[:, :, 0::2], c1[:, :, 1::2])                                  # (B,8,128)

    win2 = sliding_window_view(p1, 5, axis=2).transpose(0, 2, 1, 3).reshape(B, 124, 40)
    a2 = (win2 @ W["w2"].reshape(16, 40).T + (W["b2"] << 10)) >> 15                 # (B,124,16)
    a2 = a2.transpose(0, 2, 1)                                                      # (B,16,124)
    ovf2 = ((a2 > 32767) | (a2 < -32768)).sum(axis=(1, 2))
    c2 = np.maximum(sat16(a2), 0)
    p2 = np.maximum(c2[:, :, 0::2], c2[:, :, 1::2])                                  # (B,16,62)

    flat = p2.reshape(B, 992)                                                       # channel by channel
    a3 = (flat @ W["wf1"].T + (W["bf1"] << 10)) >> 16                               # (B,32)
    ovf3 = ((a3 > 32767) | (a3 < -32768)).sum(axis=1)
    f1 = np.maximum(sat16(a3), 0)

    a4 = (f1 @ W["wf2"].T + (W["bf2"] << 9)) >> 14                                  # (B,2)
    ovf4 = ((a4 > 32767) | (a4 < -32768)).sum(axis=1)
    f2 = sat16(a4)
    return dict(conv1=c1, pool1=p1, conv2=c2, pool2=p2, fc1=f1, fc2=f2,
                ovf=np.stack([ovf1, ovf2, ovf3, ovf4], axis=1),
                c1max=c1.max(axis=(1, 2)), c2max=c2.max(axis=(1, 2)), a3max=a3.max(axis=1))


def run_all(X, W, chunk=1024):
    parts = []
    for s in range(0, len(X), chunk):
        r = vec_chunk(X[s:s + chunk], W)
        parts.append({k: r[k] for k in ("fc2", "ovf", "c1max", "c2max", "a3max")})
    return {k: np.concatenate([p[k] for p in parts]) for k in parts[0]}


# --------------------------------------------------------------------------- checks
class Checker:
    def __init__(self):
        self.hard_fail = 0

    def hard(self, ok, msg):
        print(("  PASS  " if ok else "  FAIL  ") + msg)
        if not ok:
            self.hard_fail += 1

    def info(self, msg):
        print("  info  " + msg)


# --------------------------------------------------------------------------- selection
def select_beats(res, labels, K, seed=2026):
    rng = np.random.RandomState(seed)
    scores = res["fc2"]
    preds = (scores[:, 1] > scores[:, 0]).astype(np.int8)       # hardware rule: score1 > score0 = Abnormal
    margin = scores[:, 1].astype(np.int64) - scores[:, 0]
    correct = preds == labels
    order, tags = [], {}

    def add(i, tag):
        i = int(i)
        if i in tags:
            tags[i] += " + " + tag
            return False
        if len(order) >= K:
            return False
        order.append(i)
        tags[i] = tag
        return True

    def first_new(cands, tag):
        for i in cands:
            if int(i) not in tags:
                return add(i, tag)
        return False

    def typical(cls, tag):
        pool = np.flatnonzero(correct & (labels == cls) & (np.abs(margin) > 2048))   # clear-cut beats
        pool = [i for i in rng.permutation(pool) if int(i) not in tags]
        return add(pool[0], tag) if pool else False

    typical(0, "typical Normal")
    typical(1, "typical Abnormal")
    # beats where fc1 really saturates (the clamp is exercised end to end)
    sat_beats = np.flatnonzero(res["ovf"][:, 2] > 0)
    sat_sorted = sat_beats[np.argsort(-res["ovf"][sat_beats, 2], kind="stable")]
    for i in sat_sorted[:2]:
        add(i, "fc1 saturates (%d value(s))" % res["ovf"][i, 2])
    first_new(np.argsort(-res["c1max"], kind="stable"), "largest conv1 activation")
    first_new(np.argsort(-res["c2max"], kind="stable"), "largest conv2 activation")
    first_new(np.argsort(-res["a3max"], kind="stable"), "largest fc1 value before clamp")
    fp = np.flatnonzero((preds == 1) & (labels == 0))
    fn = np.flatnonzero((preds == 0) & (labels == 1))
    if len(fp):
        first_new(rng.permutation(fp), "false positive (model is wrong, hardware must be wrong the same way)")
    if len(fn):
        first_new(rng.permutation(fn), "false negative (model is wrong, hardware must be wrong the same way)")
    close = np.flatnonzero(correct)
    close = close[np.argsort(np.abs(margin[close]), kind="stable")]
    first_new(close, "closest correct call to the decision boundary")
    first_new(close, "second closest correct call to the boundary")
    cls = 0
    while len(order) < K:                                        # top up with typical beats, N / A alternating
        if not typical(cls, "typical " + ("Normal" if cls == 0 else "Abnormal")):
            if not typical(1 - cls, "typical " + ("Normal" if cls == 1 else "Abnormal")):
                break
        cls = 1 - cls
    return order, tags, preds, margin


# --------------------------------------------------------------------------- hex helpers
def write_hex(path, arr2d):
    flat = np.asarray(arr2d, dtype=np.int64).reshape(-1)
    with open(path, "w") as f:
        for v in flat:
            f.write("%04x\n" % (int(v) & 0xFFFF))
    return len(flat)


def read_hex(path):
    v = np.array([int(l.strip(), 16) for l in open(path) if l.strip()], dtype=np.int64)
    return np.where(v >= 0x8000, v - 0x10000, v)


# --------------------------------------------------------------------------- hardware replay (hex files only)
#            name   F   P   C   K    row_len w_off b_off bshift oshift relu
LAYERS = [("conv1", 8, 256, 1, 5, 0, 0, 0, 12, 16, True),
          ("conv2", 16, 124, 8, 5, 128, 40, 8, 10, 15, True),
          ("fc1", 32, 1, 1, 992, 0, 680, 24, 10, 16, True),
          ("fc2", 2, 1, 1, 32, 0, 32424, 56, 9, 14, False)]


def hw_layer(buf, rom_w, rom_b, L):
    _, F, P, C, Kk, row_len, w_off, b_off, bshift, oshift, relu = L
    T = C * Kk
    f = np.arange(F)[:, None, None]
    p = np.arange(P)[None, :, None]
    t = np.arange(T)[None, None, :]
    ch, k = t // Kk, t % Kk
    data_addr = ch * row_len + p + k                       # addr_gen: data_addr   = ch*row_len + pos + k
    weight_addr = f * T + t                                # addr_gen: weight_addr = filt*(C*K) + tap
    acc = (buf[data_addr] * rom_w[w_off + weight_addr]).sum(axis=2)
    acc = acc + (rom_b[b_off + np.arange(F)][:, None] << bshift)
    res = sat16(acc >> oshift)
    return np.maximum(res, 0) if relu else res            # (F, P)


def pool_pairs(x):                                        # (F, P) -> (F, P/2)
    return np.maximum(x[:, 0::2], x[:, 1::2])


def replay_from_hex(out_dir, rom_dir, n_beats, chk):
    rom_w = read_hex(os.path.join(rom_dir, "weights.hex"))
    rom_b = read_hex(os.path.join(rom_dir, "biases.hex"))
    chk.hard(len(rom_w) == 32488 and len(rom_b) == 58, "weights.hex has %d lines, biases.hex has %d" % (len(rom_w), len(rom_b)))
    rd = lambda n: read_hex(os.path.join(out_dir, n))
    beats = rd("beats_in.hex").reshape(n_beats, 260)
    e = dict(c1=rd("exp_conv1_relu.hex").reshape(n_beats, 8, 256), p1=rd("exp_conv1_pool.hex").reshape(n_beats, 1024),
             c2=rd("exp_conv2_relu.hex").reshape(n_beats, 16, 124), p2=rd("exp_conv2_pool.hex").reshape(n_beats, 992),
             f1=rd("exp_fc1.hex").reshape(n_beats, 32), f2=rd("exp_fc2.hex").reshape(n_beats, 2),
             dec=rd("exp_decision.hex"))
    bad = {k: 0 for k in ("conv1", "pool1", "conv2", "pool2", "fc1", "fc2", "decision")}
    for b in range(n_beats):
        r1 = hw_layer(beats[b], rom_w, rom_b, LAYERS[0])
        bad["conv1"] += int(not np.array_equal(r1, e["c1"][b]))
        bad["pool1"] += int(not np.array_equal(pool_pairs(e["c1"][b]).reshape(-1), e["p1"][b]))
        r2 = hw_layer(e["p1"][b], rom_w, rom_b, LAYERS[1])                  # conv2 reads the stored pooled buffer
        bad["conv2"] += int(not np.array_equal(r2, e["c2"][b]))
        bad["pool2"] += int(not np.array_equal(pool_pairs(e["c2"][b]).reshape(-1), e["p2"][b]))
        r3 = hw_layer(e["p2"][b], rom_w, rom_b, LAYERS[2])[:, 0]            # fc1 reads boxes 0..991 in order
        bad["fc1"] += int(not np.array_equal(r3, e["f1"][b]))
        r4 = hw_layer(e["f1"][b], rom_w, rom_b, LAYERS[3])[:, 0]
        bad["fc2"] += int(not np.array_equal(r4, e["f2"][b]))
        bad["decision"] += int(int(r4[1] > r4[0]) != int(e["dec"][b]))
    for k, v in bad.items():
        chk.hard(v == 0, "hex-only replay, %-8s: %d of %d beats differ" % (k, v, n_beats))


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("npz")
    ap.add_argument("--out", default="answer_key")
    ap.add_argument("--pkl", default="ecg_cnn_weights_fixedpoint.pkl")
    ap.add_argument("--rom-dir", default=".")
    ap.add_argument("--beats", type=int, default=K_BEATS)
    ap.add_argument("--force", action="store_true", help="write the key even if a hard check fails")
    a = ap.parse_args()

    d = np.load(a.npz)
    X = d["beats_q412"].astype(np.int64)
    labels = d["labels"].astype(np.int8)
    W = load_weights(a.pkl)
    chk = Checker()
    N = len(X)
    print("loaded %d beats (%d Normal, %d Abnormal)" % (N, (labels == 0).sum(), (labels == 1).sum()))

    print("\n[1] running the model on every beat ...")
    res = run_all(X, W)
    preds = (res["fc2"][:, 1] > res["fc2"][:, 0]).astype(np.int8)
    pred_argmax = np.argmax(res["fc2"], axis=1)
    chk.hard(np.array_equal(preds, pred_argmax), "decision rule 'score1 > score0' equals argmax on every beat (ties included)")

    print("\n[2] is this really the validated model?")
    if len(d["check_idx"]) and len(d["check_scores"]):
        ci = d["check_idx"]
        same = np.array_equal(res["fc2"][ci], d["check_scores"])
        chk.hard(same, "scores match your Colab fixed_point_forward_v2 output on %d beats, exactly" % len(ci))
    else:
        chk.info("no Colab cross-check scores in the file (fixed_point_forward_v2 was not defined there)")
    tot = res["ovf"].sum(axis=0)
    acc = (preds == labels).mean() * 100
    tp = int(((preds == 1) & (labels == 1)).sum()); fp = int(((preds == 1) & (labels == 0)).sum()); fn = int(((preds == 0) & (labels == 1)).sum())
    prec = tp / max(tp + fp, 1); rec = tp / max(tp + fn, 1)
    print("  accuracy %.3f %%, Abnormal precision %.3f, recall %.3f, saturation events per layer %s" % (acc, prec, rec, tot.tolist()))
    if N == 24526:
        chk.hard(round(acc, 2) == 98.51, "accuracy %.2f %% equals the documented 98.51 %%" % acc)
        chk.hard(round(prec, 2) == 0.98 and round(rec, 2) == 0.93, "Abnormal precision/recall %.2f/%.2f equal the documented 0.98/0.93" % (prec, rec))
        chk.hard(tot.tolist() == [0, 0, 7, 0], "saturation events [conv1, conv2, fc1, fc2] = %s equal the documented [0, 0, 7, 0]" % tot.tolist())
        chk.info("largest post-ReLU values: conv1 %.2f, conv2 %.2f (documented 13.26, 16.44); fc1 before clamp %.2f (documented 27.32 max); fc2 range %.2f .. %.2f (documented -12.09 .. 14.13)" %
                 (res["c1max"].max() / 1024, res["c2max"].max() / 1024, res["a3max"].max() / 512, res["fc2"].min() / 1024, res["fc2"].max() / 1024))
    else:
        chk.info("%d beats, not the full 24,526: skipping the documented-totals checks" % N)

    print("\n[3] choosing %d beats" % a.beats)
    order, tags, preds, margin = select_beats(res, labels, a.beats)
    for k, i in enumerate(order):
        print("  beat %2d = test beat #%-6d true=%s pred=%s  %s" % (k, i, "Abn" if labels[i] else "Nor", "Abn" if preds[i] else "Nor", tags[i]))
    sel = np.array(order)
    full = vec_chunk(X[sel], W)

    print("\n[4] vectorised model vs the verbatim loop model, on the chosen beats")
    mism = 0
    for k, i in enumerate(sel):
        r = ref_beat(X[i], W)
        ok = (np.array_equal(r["conv1"], full["conv1"][k]) and np.array_equal(r["pool1"], full["pool1"][k]) and
              np.array_equal(r["conv2"], full["conv2"][k]) and np.array_equal(r["pool2"], full["pool2"][k].reshape(16, 62)) and
              np.array_equal(r["fc1"], full["fc1"][k]) and np.array_equal(r["fc2"], full["fc2"][k]) and
              np.array_equal(r["ovf"], full["ovf"][k]))
        mism += int(not ok)
    chk.hard(mism == 0, "every stage identical on %d beats (%d differ)" % (len(sel), mism))

    if chk.hard_fail and not a.force:
        print("\nA hard check failed: NOT writing the answer key (use --force only to investigate).")
        sys.exit(1)

    print("\n[5] writing files to", a.out)
    os.makedirs(a.out, exist_ok=True)
    K = len(sel)
    p = lambda n: os.path.join(a.out, n)
    sizes = {
        "beats_in.hex": write_hex(p("beats_in.hex"), X[sel]),
        "exp_conv1_relu.hex": write_hex(p("exp_conv1_relu.hex"), full["conv1"]),
        "exp_conv1_pool.hex": write_hex(p("exp_conv1_pool.hex"), full["pool1"]),
        "exp_conv2_relu.hex": write_hex(p("exp_conv2_relu.hex"), full["conv2"]),
        "exp_conv2_pool.hex": write_hex(p("exp_conv2_pool.hex"), full["pool2"]),
        "exp_fc1.hex": write_hex(p("exp_fc1.hex"), full["fc1"]),
        "exp_fc2.hex": write_hex(p("exp_fc2.hex"), full["fc2"]),
    }
    dec = (full["fc2"][:, 1] > full["fc2"][:, 0]).astype(np.int64)
    with open(p("exp_decision.hex"), "w") as f:
        f.writelines("%x\n" % v for v in dec)
    with open(p("beat_labels.hex"), "w") as f:
        f.writelines("%x\n" % int(labels[i]) for i in sel)
    sizes["exp_decision.hex"] = K
    sizes["beat_labels.hex"] = K

    per = {"beats_in.hex": 260, "exp_conv1_relu.hex": 2048, "exp_conv1_pool.hex": 1024, "exp_conv2_relu.hex": 1984,
           "exp_conv2_pool.hex": 992, "exp_fc1.hex": 32, "exp_fc2.hex": 2, "exp_decision.hex": 1, "beat_labels.hex": 1}
    for n, c in sizes.items():
        assert c == per[n] * K, (n, c)

    with open(p("answer_key_info.txt"), "w") as f:
        f.write("ANSWER KEY - %d real test beats, expected outputs of the validated fixed-point model\n\n" % K)
        f.write("One value per line, 4 hex digits (16-bit two's complement); decision and label files: 1 hex digit.\n")
        f.write("Beat k's block starts at line k * (values per beat) of each file.\n\n")
        f.write("file                 values/beat  layout inside one beat\n")
        lay = {"beats_in.hex": "sample number 0..259, Q4.12 (the input buffer)",
               "exp_conv1_relu.hex": "filter*256 + position, after ReLU, before pooling (the order conv1 results come out)",
               "exp_conv1_pool.hex": "channel*128 + pooled position, Q6.10 (activation buffer A)",
               "exp_conv2_relu.hex": "filter*124 + position, after ReLU, before pooling",
               "exp_conv2_pool.hex": "channel*62 + pooled position, Q6.10 = the flattened 992 values (activation buffer B)",
               "exp_fc1.hex": "neuron 0..31, Q7.9, after ReLU (activation buffer C)",
               "exp_fc2.hex": "score 0 (Normal), score 1 (Abnormal), Q6.10",
               "exp_decision.hex": "1 = Abnormal (score 1 > score 0), 0 = Normal",
               "beat_labels.hex": "true class from the data set (1 = Abnormal)"}
        for n in per:
            f.write("%-20s %-12d %s\n" % (n, per[n], lay[n]))
        f.write("\nBEATS\n#   test beat   true  pred  score0     score1     sat(c1,c2,fc1,fc2)  why chosen\n")
        for k, i in enumerate(sel):
            s0, s1 = full["fc2"][k]
            f.write("%-3d %-11d %-5s %-5s %-10.4f %-10.4f %-19s %s\n" % (
                k, i, "Abn" if labels[i] else "Nor", "Abn" if dec[k] else "Nor", s0 / 1024, s1 / 1024,
                ",".join(str(int(v)) for v in full["ovf"][k]), tags[i]))

    print("\n[6] hardware replay: network recomputed from the hex files only")
    replay_from_hex(a.out, a.rom_dir, K, chk)

    print("\n%s" % ("ALL CHECKS PASSED" if not chk.hard_fail else "%d HARD CHECK(S) FAILED" % chk.hard_fail))
    sys.exit(1 if chk.hard_fail else 0)


if __name__ == "__main__":
    main()
