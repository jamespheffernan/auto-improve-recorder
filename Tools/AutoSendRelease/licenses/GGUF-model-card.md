---
license: cc-by-4.0
library_name: parakeet.cpp
tags:
  - automatic-speech-recognition
  - asr
  - parakeet
  - gguf
  - ggml
  - cpp-inference
  - nemo
pipeline_tag: automatic-speech-recognition
base_model:
  - nvidia/parakeet-tdt_ctc-110m
  - nvidia/parakeet_realtime_eou_120m-v1
  - nvidia/parakeet-ctc-0.6b
  - nvidia/parakeet-rnnt-0.6b
  - nvidia/parakeet-tdt-0.6b-v2
  - nvidia/parakeet-tdt-0.6b-v3
  - nvidia/parakeet-ctc-1.1b
  - nvidia/parakeet-rnnt-1.1b
  - nvidia/parakeet-tdt-1.1b
  - nvidia/parakeet-tdt_ctc-1.1b
---

# Parakeet GGUF — models for parakeet.cpp

GGUF-format weights for [parakeet.cpp](https://github.com/mudler/parakeet.cpp), a C++/ggml port of NVIDIA NeMo Parakeet that matches the upstream PyTorch models on CPU. This single repo collects **every supported model × quantization** as a flat set of `.gguf` files — download just the one you need.

**F16 is the recommended default** — same accuracy as F32, ~1.7× smaller, and typically the fastest on modern CPUs via ggml's F32×F16 matmul fast path.

## Models

### tdt_ctc-110m

Source: [nvidia/parakeet-tdt_ctc-110m](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m) · Hybrid TDT+CTC (FastConformer) · heads: TDT + CTC

| File | Variant | Size | WER vs NeMo |
|---|---|---:|---:|
| `tdt_ctc-110m-f16.gguf` ← **recommended** | F16 | 267.5 MB | 0.0000 |
| `tdt_ctc-110m-q8_0.gguf` | Q8_0 | 177.8 MB | 0.0000 |
| `tdt_ctc-110m-q6_k.gguf` | Q6_K | 155.9 MB | not measured |
| `tdt_ctc-110m-q5_k.gguf` | Q5_K | 143.3 MB | not measured |
| `tdt_ctc-110m-q4_k.gguf` | Q4_K | 131.4 MB | 0.0000 |

### realtime_eou_120m-v1

Source: [nvidia/parakeet_realtime_eou_120m-v1](https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1) · Cache-aware streaming RNNT (FastConformer, EOU/EOB) · heads: RNNT (streaming)

| File | Variant | Size | WER vs NeMo |
|---|---|---:|---:|
| `realtime_eou_120m-v1-f16.gguf` ← **recommended** | F16 | 266.5 MB | not measured |
| `realtime_eou_120m-v1-q8_0.gguf` | Q8_0 | 176.0 MB | not measured |
| `realtime_eou_120m-v1-q6_k.gguf` | Q6_K | 153.9 MB | not measured |
| `realtime_eou_120m-v1-q5_k.gguf` | Q5_K | 141.2 MB | not measured |
| `realtime_eou_120m-v1-q4_k.gguf` | Q4_K | 129.1 MB | not measured |

### ctc-0.6b

Source: [nvidia/parakeet-ctc-0.6b](https://huggingface.co/nvidia/parakeet-ctc-0.6b) · CTC (FastConformer) · heads: CTC

| File | Variant | Size | WER vs NeMo |
|---|---|---:|---:|
| `ctc-0.6b-f16.gguf` ← **recommended** | F16 | 1373.4 MB | 0.0000 |
| `ctc-0.6b-q8_0.gguf` | Q8_0 | 875.4 MB | 0.0000 |
| `ctc-0.6b-q6_k.gguf` | Q6_K | 746.8 MB | not measured |
| `ctc-0.6b-q5_k.gguf` | Q5_K | 676.3 MB | not measured |
| `ctc-0.6b-q4_k.gguf` | Q4_K | 609.9 MB | not measured |

### rnnt-0.6b

Source: [nvidia/parakeet-rnnt-0.6b](https://huggingface.co/nvidia/parakeet-rnnt-0.6b) · RNNT transducer (FastConformer) · heads: RNNT

| File | Variant | Size | WER vs NeMo |
|---|---|---:|---:|
| `rnnt-0.6b-f16.gguf` ← **recommended** | F16 | 1402.8 MB | 0.0000 |
| `rnnt-0.6b-q8_0.gguf` | Q8_0 | 903.9 MB | 0.0000 |
| `rnnt-0.6b-q6_k.gguf` | Q6_K | 776.3 MB | not measured |
| `rnnt-0.6b-q5_k.gguf` | Q5_K | 705.7 MB | not measured |
| `rnnt-0.6b-q4_k.gguf` | Q4_K | 639.2 MB | not measured |

### tdt-0.6b-v2

Source: [nvidia/parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) · TDT transducer (FastConformer) · heads: TDT

| File | Variant | Size | WER vs NeMo |
|---|---|---:|---:|
| `tdt-0.6b-v2-f16.gguf` ← **recommended** | F16 | 1404.2 MB | 0.0000 |
| `tdt-0.6b-v2-q8_0.gguf` | Q8_0 | 903.8 MB | 0.0000 |
| `tdt-0.6b-v2-q6_k.gguf` | Q6_K | 775.9 MB | not measured |
| `tdt-0.6b-v2-q5_k.gguf` | Q5_K | 705.0 MB | not measured |
| `tdt-0.6b-v2-q4_k.gguf` | Q4_K | 638.4 MB | not measured |

### tdt-0.6b-v3

Source: [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) · TDT transducer (FastConformer) · heads: TDT

| File | Variant | Size | WER vs NeMo |
|---|---|---:|---:|
| `tdt-0.6b-v3-f16.gguf` ← **recommended** | F16 | 1441.0 MB | 0.0000 |
| `tdt-0.6b-v3-q8_0.gguf` | Q8_0 | 940.7 MB | 0.0000 |
| `tdt-0.6b-v3-q6_k.gguf` | Q6_K | 812.7 MB | not measured |
| `tdt-0.6b-v3-q5_k.gguf` | Q5_K | 741.9 MB | not measured |
| `tdt-0.6b-v3-q4_k.gguf` | Q4_K | 675.2 MB | not measured |

### ctc-1.1b

Source: [nvidia/parakeet-ctc-1.1b](https://huggingface.co/nvidia/parakeet-ctc-1.1b) · CTC (FastConformer) · heads: CTC

| File | Variant | Size | WER vs NeMo |
|---|---|---:|---:|
| `ctc-1.1b-f16.gguf` ← **recommended** | F16 | 2395.8 MB | 0.0000 |
| `ctc-1.1b-q8_0.gguf` | Q8_0 | 1526.3 MB | 0.0000 |
| `ctc-1.1b-q6_k.gguf` | Q6_K | 1301.7 MB | not measured |
| `ctc-1.1b-q5_k.gguf` | Q5_K | 1178.5 MB | not measured |
| `ctc-1.1b-q4_k.gguf` | Q4_K | 1062.6 MB | not measured |

### rnnt-1.1b

Source: [nvidia/parakeet-rnnt-1.1b](https://huggingface.co/nvidia/parakeet-rnnt-1.1b) · RNNT transducer (FastConformer) · heads: RNNT

| File | Variant | Size | WER vs NeMo |
|---|---|---:|---:|
| `rnnt-1.1b-f16.gguf` ← **recommended** | F16 | 2425.2 MB | 0.0000 |
| `rnnt-1.1b-q8_0.gguf` | Q8_0 | 1554.7 MB | 0.0000 |
| `rnnt-1.1b-q6_k.gguf` | Q6_K | 1331.2 MB | not measured |
| `rnnt-1.1b-q5_k.gguf` | Q5_K | 1207.9 MB | not measured |
| `rnnt-1.1b-q4_k.gguf` | Q4_K | 1091.9 MB | not measured |

### tdt-1.1b

Source: [nvidia/parakeet-tdt-1.1b](https://huggingface.co/nvidia/parakeet-tdt-1.1b) · TDT transducer (FastConformer) · heads: TDT

| File | Variant | Size | WER vs NeMo |
|---|---|---:|---:|
| `tdt-1.1b-f16.gguf` ← **recommended** | F16 | 2425.3 MB | 0.0000 |
| `tdt-1.1b-q8_0.gguf` | Q8_0 | 1554.8 MB | 0.0000 |
| `tdt-1.1b-q6_k.gguf` | Q6_K | 1331.2 MB | not measured |
| `tdt-1.1b-q5_k.gguf` | Q5_K | 1207.9 MB | not measured |
| `tdt-1.1b-q4_k.gguf` | Q4_K | 1091.9 MB | not measured |

### tdt_ctc-1.1b

Source: [nvidia/parakeet-tdt_ctc-1.1b](https://huggingface.co/nvidia/parakeet-tdt_ctc-1.1b) · Hybrid TDT+CTC (FastConformer) · heads: TDT + CTC

| File | Variant | Size | WER vs NeMo |
|---|---|---:|---:|
| `tdt_ctc-1.1b-f16.gguf` ← **recommended** | F16 | 2429.5 MB | 0.0000 |
| `tdt_ctc-1.1b-q8_0.gguf` | Q8_0 | 1559.0 MB | 0.0000 |
| `tdt_ctc-1.1b-q6_k.gguf` | Q6_K | 1335.4 MB | not measured |
| `tdt_ctc-1.1b-q5_k.gguf` | Q5_K | 1212.1 MB | not measured |
| `tdt_ctc-1.1b-q4_k.gguf` | Q4_K | 1096.1 MB | not measured |

> WER (word error rate) is computed against the upstream NeMo reference on `tests/fixtures/speech.wav` (LibriSpeech `2086-149220-0033`, ~7.4 s, English). 0.0 = byte-for-byte identical transcript. See [parity.md](https://github.com/mudler/parakeet.cpp/blob/main/docs/parity.md) and [quantization.md](https://github.com/mudler/parakeet.cpp/blob/main/docs/quantization.md).

## Quantization notes

Quantization is applied **only** to the large linear weights fed directly into `ggml_mul_mat` (encoder FFN + attention projections, subsampling output projection, joint enc/pred projections). All other tensors (mel filterbank, LSTM prediction net, conv kernels, batch_norm stats, norms, biases, embeddings) stay F32.

## Usage

```bash
# 1. Clone + build parakeet.cpp
git clone https://github.com/mudler/parakeet.cpp
cd parakeet.cpp
cmake -B build -DPARAKEET_BUILD_CLI=ON && cmake --build build -j

# 2. Download one quant (F16 recommended)
huggingface-cli download mudler/parakeet-cpp-gguf tdt_ctc-110m-f16.gguf --local-dir models/

# 3. Transcribe
build/examples/cli/parakeet-cli transcribe \
    --model models/tdt_ctc-110m-f16.gguf \
    --input audio.wav
```

## License

The GGUF weights are derived from the NVIDIA NeMo Parakeet checkpoints, released under the [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) license. The parakeet.cpp runtime is MIT-licensed.
