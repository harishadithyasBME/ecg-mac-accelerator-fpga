import numpy as np
import pickle

# Upload ecg_cnn_weights_fixedpoint.pkl to this Colab session first
with open('ecg_cnn_weights_fixedpoint.pkl', 'rb') as f:
    qw = pickle.load(f)

def quantize_input(x, frac_bits=12):
    return np.clip(np.round(x * (2**frac_bits)), -32768, 32767).astype(np.int64)

def sat16(x):
    # real 16-bit signed saturation, applied at EVERY layer this time, not just the end
    return np.clip(x, -32768, 32767)

overflow_count = {'conv1': 0, 'conv2': 0, 'fc1': 0, 'fc2': 0}

def fixed_point_forward_v2(raw_beat):
    x = quantize_input(raw_beat, frac_bits=12)  # Q4.12, unchanged

    # --- conv1: Q4.12 x Q2.14 -> Q26 acc, bias <<12, rescale >>16 -> Q6.10 ---
    w1 = qw['conv1.weight'].reshape(8, 5).astype(np.int64)
    b1 = qw['conv1.bias'].astype(np.int64)
    out_len1 = 260 - 5 + 1
    conv1_out = np.zeros((8, out_len1), dtype=np.int64)
    for f in range(8):
        for i in range(out_len1):
            acc = np.sum(x[i:i+5] * w1[f])
            acc = acc + (b1[f] << 12)
            acc = acc >> 16                       # CHANGED: was >>12, now targets Q10
            conv1_out[f, i] = acc
    overflow_count['conv1'] += int(((conv1_out > 32767) | (conv1_out < -32768)).sum())
    conv1_out = sat16(conv1_out)                  # NEW: real saturation, not just at the end
    conv1_out = np.maximum(conv1_out, 0)           # ReLU
    pool1_out = conv1_out[:, 0::2][:, :conv1_out.shape[1]//2]
    pool1_out = np.maximum(pool1_out, conv1_out[:, 1::2][:, :pool1_out.shape[1]])

    # --- conv2: Q6.10 x Q1.15 -> Q25 acc, bias <<10, rescale >>15 -> Q6.10 ---
    w2 = qw['conv2.weight'].astype(np.int64)
    b2 = qw['conv2.bias'].astype(np.int64)
    out_len2 = pool1_out.shape[1] - 5 + 1
    conv2_out = np.zeros((16, out_len2), dtype=np.int64)
    for f in range(16):
        for i in range(out_len2):
            acc = np.sum(pool1_out[:, i:i+5] * w2[f])
            acc = acc + (b2[f] << 10)             # CHANGED: was <<14
            acc = acc >> 15                        # unchanged numerically, but now relative to Q25 not Q29
            conv2_out[f, i] = acc
    overflow_count['conv2'] += int(((conv2_out > 32767) | (conv2_out < -32768)).sum())
    conv2_out = sat16(conv2_out)
    conv2_out = np.maximum(conv2_out, 0)
    pool2_out = conv2_out[:, 0::2][:, :conv2_out.shape[1]//2]
    pool2_out = np.maximum(pool2_out, conv2_out[:, 1::2][:, :pool2_out.shape[1]])

    flat = pool2_out.flatten()  # Q6.10, length 992

    # --- fc1: Q6.10 x Q1.15 -> Q25 acc, bias <<10, rescale >>16 -> Q7.9 ---
    w_fc1 = qw['fc1.weight'].astype(np.int64)
    b_fc1 = qw['fc1.bias'].astype(np.int64)
    fc1_out = (w_fc1 @ flat)
    fc1_out = fc1_out + (b_fc1 << 10)             # CHANGED: was <<14
    fc1_out = fc1_out >> 16                        # CHANGED: was >>15
    overflow_count['fc1'] += int(((fc1_out > 32767) | (fc1_out < -32768)).sum())
    fc1_out = sat16(fc1_out)
    fc1_out = np.maximum(fc1_out, 0)

    # --- fc2: Q7.9 x Q1.15 -> Q24 acc, bias <<9, rescale >>14 -> Q6.10 ---
    w_fc2 = qw['fc2.weight'].astype(np.int64)
    b_fc2 = qw['fc2.bias'].astype(np.int64)
    fc2_out = (w_fc2 @ fc1_out)
    fc2_out = fc2_out + (b_fc2 << 9)              # CHANGED: was <<14
    fc2_out = fc2_out >> 14                        # CHANGED: was >>15
    overflow_count['fc2'] += int(((fc2_out > 32767) | (fc2_out < -32768)).sum())
    fc2_out = sat16(fc2_out)

    return fc2_out
