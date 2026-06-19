# Todo v0 — Foundation

Release branches: `0.1` · `0.2` · ... (one per phase above)

Conventions: per-task spec uses **Goal / Touches / Success / Tests / Difficulty**
(+ optional **Model**). Architectural invariants in `AGENTS.md` are binding on every task.

---

## Phase 0.1 — Core Types + Channel Contract

- [ ] `0.1.0` Workspace scaffold
  - **Goal:** Set up Cargo workspace with `zoidformer-core` crate. Define the channel
    contract types: `InferRequest` (prompt tokens, sampling params, cancel token),
    `InferResponse` (enum: `Token(u32)`, `Text(String)`, `Done(StopReason)`, `Error(String)`),
    `ZoidformerMetrics` (decode_tps, prefill_tps, vram_used_mb, vram_total_mb,
    kv_cache_occupancy_pct, cuda_graph_active: bool). Feature-gate: `features = ["cuda"]`
    present in root Cargo.toml but no CUDA dep in core. `ZoidformerEngine` trait with
    `async fn infer(req: InferRequest, tx: mpsc::UnboundedSender<InferResponse>,
    metrics: watch::Sender<ZoidformerMetrics>)`.
  - **Touches:** `Cargo.toml`, `crates/zoidformer-core/`
  - **Success:** `cargo check --workspace` passes. Types are `Send + Sync`.
  - **Tests:** unit: `InferResponse` variants round-trip through a channel; `ZoidformerMetrics` default is sensible zeros. **Difficulty:** Low

- [ ] `0.1.1` Error taxonomy
  - **Goal:** `ZoidformerError` enum (`ModelLoad`, `Tokenize`, `Cuda(String)`, `Cancelled`,
    `OutOfMemory`, `Unsupported(String)`). `thiserror` derive. All engine error paths return this. Map to `InferResponse::Error`.
  - **Touches:** `crates/zoidformer-core/src/error.rs`
  - **Success:** All variants implement `std::error::Error`. `Cuda(String)` carries the CUDA error code + message.
  - **Tests:** each variant `Display` output is non-empty and human-readable. **Difficulty:** Low

- [ ] release/0.1 → main

---

## Phase 0.2 — GGUF Loader

- [ ] `0.2.0` GGUF file parser
  - **Goal:** `zoidformer-gguf` crate. Parse GGUF v1/v2/v3 header: magic, version,
    tensor count, metadata KV pairs, tensor info (name, type, shape, offset). Mmap the
    file; expose `GgufFile` with iterator over `TensorView` (name, quant type, raw bytes).
    No quantization-dequantization yet — just memory-mapped access.
  - **Touches:** `crates/zoidformer-gguf/`
  - **Success:** Can open a real `.gguf` file and iterate tensor names + shapes without panic.
    No CUDA dep. **Tests:** parse a 1MB synthetic GGUF fixture (hand-crafted binary); verify tensor count, metadata values, tensor shapes. **Difficulty:** Medium

- [ ] `0.2.1` Quantization type registry
  - **Goal:** `QuantType` enum covering Q4_0, Q4_1, Q4_K_S, Q4_K_M, Q5_0, Q5_1,
    Q5_K_S, Q5_K_M, Q8_0, F16, F32, BF16. `block_size()` and `type_size()` for each.
    Used by the engine to know how many bytes per weight block.
  - **Touches:** `crates/zoidformer-gguf/src/quant.rs`
  - **Success:** `block_size()` and `type_size()` match llama.cpp reference values.
  - **Tests:** table-driven test against known reference values. **Difficulty:** Low

- [ ] release/0.2 → main

---

## Phase 0.3 — Tokenizer

- [ ] `0.3.0` Tokenizer wrapper
  - **Goal:** `zoidformer-tokenizer` crate. Thin wrapper around `tokenizers` crate
    (HuggingFace tokenizer JSON format). `Tokenizer::from_file(path)`,
    `encode(text) -> Vec<u32>`, `decode(tokens) -> String`, `vocab_size() -> u32`.
    No bespoke tokenization — pure delegation.
  - **Touches:** `crates/zoidformer-tokenizer/`
  - **Success:** round-trip `encode → decode` recovers original text for ASCII inputs.
  - **Tests:** encode + decode a short sentence; `vocab_size()` is non-zero. **Difficulty:** Low

- [ ] release/0.3 → main

---

## Phase 0.4 — Stub Engine

- [ ] `0.4.0` Stub inference engine
  - **Goal:** `zoidformer-engine` crate. `StubEngine` implements `ZoidformerEngine` trait.
    Emits a fixed response ("Zoidformer stub: [echo of first 10 prompt tokens]") as
    `InferResponse::Text` tokens at ~100 tok/s simulated, then `Done(EndTurn)`.
    Sends constant `ZoidformerMetrics` with zeroed VRAM and 100.0 decode_tps.
    Must compile without CUDA — no `[cuda]` feature needed here.
  - **Touches:** `crates/zoidformer-engine/src/stub.rs`
  - **Success:** `StubEngine::infer()` completes without panic and sends `Done` last.
    Metrics channel stays open until `infer` returns.
  - **Tests:** spawn infer, collect all responses, verify `Done` is last; metrics update fires at least once. **Difficulty:** Low

- [ ] release/0.4 → main

---

## Phase 0.5 — CUDA Kernel Harness

- [ ] `0.5.0` CUDA build harness
  - **Goal:** `build.rs` in `zoidformer-engine` that compiles `kernels/*.cu` via
    `cc` crate when `cuda` feature is enabled. Detects CUDA toolkit via `CUDA_PATH`
    env or common install locations. Falls back gracefully to stub-only if CUDA not
    found and `cuda` feature is off. Emits `cargo:rerun-if-changed=kernels/` and
    `cargo:rerun-if-env-changed=CUDA_PATH`.
  - **Touches:** `crates/zoidformer-engine/build.rs`, `kernels/` (placeholder .cu)
  - **Success:** `cargo build --features cuda` finds CUDA and compiles; `cargo build` (no feature) skips kernels. CI can test both paths.
  - **Tests:** build script unit test: `detect_cuda_path()` returns `None` when `CUDA_PATH` unset and toolkit absent. **Difficulty:** Medium

- [ ] `0.5.1` GEMV attention kernel stub
  - **Goal:** `kernels/attention.cu` — placeholder kernel `zf_attn_gemv` that takes
    Q/K/V pointers and emits zeros (shape-correct). Linked into `zoidformer-engine`
    via FFI (`extern "C"`). Called by a `CudaAttention` struct that wraps the raw FFI.
    Safety comment required explaining memory layout invariant.
  - **Touches:** `kernels/attention.cu`, `crates/zoidformer-engine/src/cuda/attention.rs`
  - **Success:** `CudaAttention::forward()` compiles and runs without CUDA error on a small (4-head, 64-dim) test tensor. **Difficulty:** High · **Model:** PRO_DEV_AGENT

- [ ] release/0.5 → main

---

## Phase 0.6 — PagedAttention KV-Cache

> Details to be filled in after Phase 0.5. See `docs/plan.md §kv-cache`.

- [ ] `0.6.0` KV-cache block allocator — TBD
- [ ] release/0.6 → main

---

## Phases 0.7–0.10

> Detailed specs TBD — will be added before those release branches are cut.

- [ ] `0.7.x` LoRA adapter loading + hot-swap
- [ ] `0.8.x` ZoidformerMetrics + watch channel
- [ ] `0.9.x` zoidborg-agent integration seam
- [ ] `0.10.x` Training-data export (zoidformer-train)
