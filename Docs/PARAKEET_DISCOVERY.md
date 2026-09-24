# Current ASR Parakeet runtime

Website release 1.1 installs a versioned runtime at `~/Library/Application Support/AutoSendRecorder/Runtime/20260918`. Setup downloads the pinned models from Hugging Face and checks their size and SHA-256 before an atomic installation. It preserves the legacy AIR runtime at `~/Library/Application Support/AutoImproveRecorder/ParakeetCpp`, which remains the fallback until the new runtime is complete.

`AutoSendRecorder/AutoSendParakeetCompatibility.swift` defines the root. `AutoSendParakeetService.swift` uses its CLI and models; the shared `AutoImproveRecorder/Engines/ParakeetCAPI.swift` resolves the same root in the ASR target.

Required files by route:

- Saved-audio fallback: `bin/parakeet-cli`, `models/tdt-0.6b-v2-q4_k.gguf` and the CLI's ggml libraries in `lib/`.
- Live: `capi/libparakeet.dylib`, its adjacent ggml libraries and `models/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf`. The app also requires the fallback and at least 16 GiB memory.
- Resident wireless: the C API and `models/tdt_ctc-110m-q4_k.gguf`, with saved-audio fallback.

The website archive bundles a universal CLI and C API library. The downloader installs all three model routes; it publishes its completion marker only after every checksum passes. A restart is required after installation because the C API resolves its library once per process. The legacy-runtime readiness check still checks only the CLI and fallback model.

## Third-party provenance

Parakeet.cpp, ggml and NVIDIA model weights remain third-party dependencies. Preserve their required licenses and notices. `Tools/AutoSendRelease/models.json`, `THIRD-PARTY-NOTICES.txt`, and `licenses/` record the website release's model URLs, checksums, source revisions, and licenses. `build-runtime.sh` rebuilds the universal CPU/Accelerate runtime. Historical build notes are not a redistribution manifest.

[Historical discovery and build evidence](History/PARAKEET_DISCOVERY_HISTORY.md) retains earlier experiments and captured paths unchanged. It is not current ASR setup guidance.
