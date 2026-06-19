# Concerns — Zoidformer

Open design risks and how they're being handled.

## §1 CUDA Version Lock

CUDA 12.x is the target. Kernels use features not present in CUDA 11.x.
**Mitigation:** `build.rs` checks `nvcc --version` and emits a clear error if < 12.

## §2 Stub Engine in CI

CI machines won't have a GPU. All tests must pass with `--no-default-features`
(stub engine path). GPU-dependent tests go behind `#[cfg(feature = "cuda")]`
and are documented as manual-run only.

## §3 GGUF Format Churn

GGUF spec evolves alongside llama.cpp. We track v1/v2/v3; v4 may appear.
**Mitigation:** GGUF parser version is checked at open-time; unknown version → `Err(ZoidformerError::Unsupported)`.

## §4 Memory Safety in Kernels

Raw FFI to CUDA kernels is inherently unsafe. Every FFI call must have a `// SAFETY:`
comment documenting the pointer validity invariant, shape assumptions, and
expected alignment.

## §5 Training Data Privacy

Export must strip PII before writing JSONL. The redaction pass runs before any
file I/O. Format is opt-in per session (never automatic).

## §6 LoRA Shape Compatibility

LoRA adapters must match the base model's hidden dim and head count exactly.
Loading an incompatible LoRA panics today (acceptable in stub phase); production
must return `Err(ZoidformerError::ModelLoad("LoRA rank mismatch: ..."))`.
