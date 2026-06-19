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

## §7 Floating-Point Non-Determinism

GPU parallel reductions are non-deterministic: warp scheduling varies run-to-run → different IEEE 754 rounding → different output bits. Same input, same model, different output each run. cuBLAS 11.x and 12.x produce different bits even in "deterministic mode."

Consequences: threshold drift, index inconsistency across partial re-indexes, audit failure, closed-loop cache feedback corrupted (see plan.md cache-feedback-gap).

**Mitigation:**
- Pin exact CUDA + cuBLAS version in build artifact (Dockerfile / Nix shell)
- `cublasSetMathMode(CUBLAS_MATH_DISALLOW_REDUCED_PRECISION_REDUCTION)` at engine init
- For similarity accumulators: fixed-point int64 scaled arithmetic (1.5–3× overhead, but truly bit-exact and cross-restart stable)
- Integer arithmetic is associative (float is not) → INT8/INT4 quantized kernels are inherently more reproducible

**Blocker:** Any closed-loop cache or RAG feedback feature is blocked until this is solved. Solve in phase 0.5 before phase 0.9 RAG work.

## §8 HBM Memory Layout for KV-Cache

Pointer-chased data structures (HNSW-style graph traversal, scattered block pointers) achieve ~3% effective HBM bandwidth on GPU (128-byte cache line, 4-byte pointer read, 124 bytes wasted). GPU has no hardware prefetcher for irregular access patterns.

**Mitigation:**
- KV-cache blocks: contiguous pool allocation, accessed sequentially
- Before any bulk gather from HBM: sort indices by memory address first (adaptive sort — fingerprint first, use zero-allocation path on presorted data)
- IVF layout preferred over HNSW for any vector store additions
- Never use pointer-chased structures in the decode hot path

## §9 PCIe Throughput Ceiling on Sub-H100 Hardware

PCIe Gen4 ceiling ~64 GB/s vs HBM bandwidth 3–8 TB/s: 52× mismatch. Any architecture that transfers model weights or activations over PCIe per request will idle ~40% of compute.

**Mitigation:** Persistent CUDA context — load model weights into HBM once at startup, never evict during serving. `ZoidformerEngine::new()` pays the 30–60s load cost; requests hit HBM directly thereafter. This is an architectural invariant, not an optimization.

## §10 Kernel Safety Tiers (cuTile Pattern)

Three-tier unsafe policy for CUDA kernel bindings:
1. **Safe default** — trait-based KernelInput/KernelOutput boundary, partition-based disjoint sub-tensor writes
2. **`unchecked_accesses`** — disable bounds checks when statically provable safe; requires inline comment proving safety
3. **Raw `*mut T`** — direct pointer access for patterns not expressible in tiers 1-2; must be wrapped in `unsafe {}` with `// SAFETY:` comment

All tier-2 and tier-3 uses must be audited before any phase release. Document in AGENTS.md when policy is finalized.
