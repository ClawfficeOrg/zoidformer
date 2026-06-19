# Plan — Zoidformer

High-level design intent. Updated as architecture evolves.

## Goals

1. Run GGUF-quantized models locally on NVIDIA GPU (CUDA 12.x).
2. Expose an in-process `tokio::sync::mpsc` channel API for `zoidborg-agent`.
3. Stream tokens in real time via `InferResponse::Text(String)`.
4. Emit live telemetry via `ZoidformerMetrics` on a `watch::Sender`.
5. Support LoRA adapters without reloading the base model.
6. Export conversation sessions as JSONL training data.

## Non-Goals (this repo)

- Training the base model (that lives in a separate pipeline).
- Any HTTP/REST API layer — the channel API is the interface.
- Windows support in Phase 0 (Linux + WSL2 first).

## Channel Contract

Streaming order per request: `Token(u32)*` → `Text(String)` → `Done(StopReason)` → _(channel closes)_

- `Token(u32)` — **primary streaming path**. One per generated token, in order. Consumers that want word-level streaming decode these.
- `Text(String)` — full assembled response text, sent exactly once just before `Done`. Consumers that only want the final answer ignore all `Token` variants and wait for this.
- `Done(StopReason)` — terminal signal. Always last. Consumer must drain `Token`/`Text` before acting on `Done`.
- `Error(String)` — terminal error. Replaces `Done`. Channel closes after this.

```rust
// In zoidformer-core — also pub re-exported from zoidborg-agent when feature active.

pub enum InferResponse {
    Token(u32),      // primary: one per generated token, in generation order
    Text(String),    // full assembled text, sent once before Done
    Done(StopReason),
    Error(String),
}

pub enum StopReason {
    EndTurn,
    MaxTokens,
    StopSequence(String),
    Cancelled,
}

pub struct ZoidformerMetrics {
    pub decode_tps: f32,
    pub prefill_tps: f32,
    pub vram_used_mb: u64,
    pub vram_total_mb: u64,
    pub kv_cache_occupancy_pct: f32,
    pub cuda_graph_active: bool,
}

#[async_trait]
pub trait ZoidformerEngine: Send + Sync {
    async fn infer(
        &self,
        req: InferRequest,
        tx: mpsc::UnboundedSender<InferResponse>,
        metrics: watch::Sender<ZoidformerMetrics>,
    );
}
```

## KV-Cache §kv-cache

PagedAttention blocks of fixed size (default 16 tokens per block).
Block pool pre-allocated at engine startup based on available VRAM.
Eviction: LRU with swap-to-CPU fallback for multi-session use.
Design note: keep block size configurable (16, 32, 64) — test on target hardware.

## Research Insights

### cuTile Rust — arxiv 2606.15991v1

Proposes safe host-to-device kernel programming in Rust via tile-level abstractions. Evaluated with Grout, a Qwen3 inference engine — essentially the closest published analog to what zoidformer is building.

**Key techniques relevant to zoidformer:**

**KernelInput / KernelOutput trait protocol** — type-safe boundary crossing: `Arc<Tensor<T>>` in → `Arc<Tensor<T>>` out. Enforces ownership at the FFI boundary. We should adopt this pattern for any kernel bindings in `kernels/`.

**Partition-based write safety** — mutable tensor outputs split into disjoint sub-tensors before launch. Each tile gets exclusive `&mut Tensor` over exactly one sub-tensor. Eliminates index-swap races structurally. Apply in our attention and GEMM kernels.

**Prefill as StepGraph, decode as CUDA graph replay** — Grout caches prefill as a typed `StepGraph` of operations with a reusable tensor pool. Decode is recorded into a CUDA graph once and replayed for subsequent tokens. This resolves our open CUDA graph strategy decision (see below).

**Three execution modes from one kernel** — sync / async (IntoFuture) / CUDA graph — same composed DeviceOp runs in all three without rewriting. We should design `ZoidformerEngine::infer` so the inner kernel path is composable across these modes.

**Escape hatches** — `unchecked_accesses` (disable bounds checks when provably safe) + raw `*mut T` for unsupported patterns. Both explicitly `unsafe`. We need a similar 3-tier policy: safe default → `unchecked` with comment → `*mut` with `// SAFETY:`.

**Performance baseline (Grout / cuTile Rust):**
- RTX 5090, Qwen3-4B: **171 tok/s decode** (74.7% HBM roofline)
- B200, Qwen3-32B: **82 tok/s decode** (66.7% roofline)
- GEMM: 96.4% of cuBLAS on B200; elementwise: near bandwidth peak

These are our phase 0.5+ performance targets.

**JIT vs AOT:** cuTile compiles kernel AST at first launch. We use `nvcc` via `build.rs` (AOT). No first-launch penalty, but less runtime specialization. Acceptable tradeoff for phase 0.

### voxell.ai — ingot-poured (MTEB MoE Embedding Submission)

Qwen3-Embedding-8B backbone + per-domain LoRA adapter hot-swap via a compiled classification router (<0.5ms overhead). Router routes each request to one of 5 specialist LoRAs without loading separate full models. Achieved MTEB(eng v2) = 75.98.

**Implication:** LoRA hot-swap is the correct architecture for multi-task inference — not separate model instances. Phase 0.5+ LoRA design should route at request time, not per deployment.

---

### voxell.ai — mash-sort (9× Faster Sorting on Blackwell)

CUB `DeviceRadixSort` is data-oblivious. MASH fingerprints data topology first, routes to cheapest correct algorithm. Presorted data: **9.06× speedup vs CUB**. At 6B+ elements CUB OOMs on temp buffers; MASH detects presorted → zero-allocation in-place path.

Build: `nvcc -std=c++20 -O3 -arch=sm_121 --expt-relaxed-constexpr` on GB10 (HBM3e ~8 TB/s).

**Implication:** KV-cache eviction, token index maintenance, embedding compaction all benefit from adaptive sorting. Don't reach for CUB radix sort by default on partially-ordered data.

---

### voxell.ai — starved-cores (GPU Core Occupancy in Inference)

H100 idles ~40% in training-loop-style inference. Root cause: PCIe ceiling (64 GB/s) vs HBM bandwidth (3.35 TB/s) — 52× mismatch. Python GIL at batch collation adds another floor.

**Fix: persistent model server.** Keep weights in HBM at all times. Pay 30-60s cold start once at startup. CPU tokenizer (milliseconds) → forward pass → return. Their Forge engine: **87ms median e2e latency** including network.

**Implication:** `ZoidformerEngine` must hold a persistent CUDA context. No epoch-style loading; load once on `::new()`, serve forever. This is the architectural invariant for phase 0.4.

---

### voxell.ai — sweat-capital (27× Speedup: Go+Custom CUDA vs TEI)

TEI is tuned for H100 pods. On GB10 / ARM / RTX 5080: bottlenecked. Their stack: Go for gRPC/networking, CGO bridge to C, raw CUDA kernels in the hot path.

Key insight: **embedding models use bidirectional attention** — full sequence known upfront, no causal mask. TEI carries causal mask overhead. Writing a tightly-fused cuBLAS batched GEMM for bidirectional context, with tile sizes matching exact Qwen3 dims (1024d/2560d/4096d), eliminates padding waste.

Result: **27.6× attention speedup**. RTX 5080 16GB sufficient to serve Qwen3 natively. GB10: 16,000+ TPS.

**Implication:** When we hit the embedding/attention kernel in phase 0.5+: write bidirectional, tune tile dims to model dims, avoid causal mask logic. Rust server + raw CUDA kernel is the correct stack — validated by this.

---

### voxell.ai — cache-feedback-gap (Closed-Loop KV-Cache Prefetch)

Open-loop prefetch never receives outcome feedback. Four signals: HIT / MISS / EVICTED_UNUSED / STALE_HIT. `EVICTED_UNUSED` is highest signal — prefetched and occupies cache but never accessed.

**Prerequisite: bit-exact embeddings.** One bit difference → prediction ID unreliable → feedback signal corrupted. This makes embedding determinism a hard requirement for any cache learning strategy.

**Implication:** Phase 0.2+ KV-cache eviction should tag blocks with request IDs for future feedback instrumentation. Bit-exact determinism (see concerns.md §7) blocks this feature until solved.

---

### voxell.ai — memory-abuse (HNSW is GPU Anti-Pattern; Linear Scan Wins)

GPU cache line = 128 bytes. Pointer chase (HNSW graph traversal) reads 4 bytes, wastes 124: **3.125% effective HBM utilization**. GPU has no hardware prefetcher for irregular access.

Fix: sort gather indices by memory address before bulk read. Sort is cheap on GPU; sequential reads saturate HBM. IVF beats HNSW on GPU because cluster reads are contiguous.

MASH on 1B-vector index: **992ms → 109ms** query time from layout change alone.

Direct quote: *"Your ANN index, your embedding lookup table, your KV cache: all of them benefit from topology-aware layout. The GPU is a sequential-reading machine that happens to be very parallel. Design your data for it."*

**Implication:** KV-cache blocks must be laid out contiguously by sequence. PagedAttention block pool: allocate contiguously, sort access indices before gather. Never use pointer-chased structures in the HBM hot path.

---

### voxell.ai — rag-feedback (RAG Retrieval N+1 and Determinism)

50-70% of semantic queries are paraphrases of prior queries. Without closed-loop caching, each pays full embed+search+rerank. `EVICTED_UNUSED` signal identifies chunks retrieved but never cited (wasted context window).

Hard structural requirement: **bit-exact embedding computation**. "Closed-loop retrieval requires identical bits. Not approximately the same. Identical bits." Non-determinism corrupts prediction IDs before learning can begin.

**Implication:** Future RAG integration (phase 0.9+) is blocked on deterministic embedding output. Solve determinism first.

---

### voxell.ai — vector-search-lies (IEEE 754 Non-Determinism in GPU Reductions)

GPU parallel reductions are non-deterministic: warp scheduling varies → different reduction tree → different IEEE 754 rounding → different bits. Same input, same model, different output each run.

Consequences: threshold drift, index inconsistency across partial re-indexes, audit failure, agent instability.

Mitigation options:

| Approach | Bit-exact? | Perf overhead | Cross-version? |
|---|---|---|---|
| `cublasSetMathMode(DISALLOW_REDUCED_PRECISION_REDUCTION)` | Yes | 2-10× | No — pin cuBLAS version too |
| Fixed reduction order (`__syncthreads__` barriers) | Yes | 2-5× | Yes |
| Kahan summation | Near | 2-4× | Yes |
| Fixed-point int64 accumulators | Yes | 1.5-3× | Yes |
| Library version pinning only | Yes | 0× | Only within same version |

Note: cuBLAS 11.x and 12.x produce different deterministic results from each other. "Deterministic mode" is per-library-version, not cross-version.

**Implication:** Pin CUDA + cuBLAS versions in build artifact. Use `CUBLAS_MATH_DISALLOW_REDUCED_PRECISION_REDUCTION` for inference. For similarity accumulators: fixed-point int64 scaled arithmetic. Integer arithmetic is associative (float is not) — this is also why quantized kernels can be more reproducible than float16.

## Open Decisions

- [x] Streaming interface → **Token(u32) primary; Text(String) once before Done** — consumers choose which to use
- [x] Batch size for multi-user: initially 1 — persistent CUDA context model precludes multi-batch in phase 0 (starved-cores)
- [x] CUDA graph strategy → **prefill: StepGraph + tensor pool; decode: CUDA graph recorded once, replayed per token** (cuTile/Grout)
- [x] Float format → **BF16** for intermediate activations (Qwen3 native, Blackwell/Ampere+ preferred)
- [ ] Kernel safety tier policy: safe default / `unchecked_accesses` / raw `*mut T` (cuTile pattern — add to AGENTS.md at phase 0.5)
- [x] LoRA strategy → **hot-swap via router**, not separate model instances (ingot-poured)
- [x] Memory layout → **topology-aware contiguous layout for KV-cache blocks; sort gather indices before bulk HBM read** (memory-abuse)
- [x] Determinism → **strict**: `cublasSetMathMode(DISALLOW_REDUCED_PRECISION_REDUCTION)` + pin cuBLAS version in build artifact. Prerequisite for cache feedback features.
- [x] Sub-H100 hardware target → **RTX 5080/5090 as primary targets**, not H100 (sweat-capital, starved-cores)
