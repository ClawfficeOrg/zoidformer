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

```rust
// In zoidformer-core — also pub re-exported from zoidborg-agent when feature active.
pub enum InferResponse {
    Text(String),
    Token(u32),
    Done(StopReason),
    Error(String),
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

## Open Decisions

- [ ] Token-streaming vs text-streaming as primary interface (currently both in enum)
- [ ] Batch size for multi-user: initially 1, generalize in phase 0.6+
- [ ] CUDA graph capture strategy (per-sequence-length vs bucketed)
- [ ] BF16 vs F16 intermediate activations — depends on target GPU capability
