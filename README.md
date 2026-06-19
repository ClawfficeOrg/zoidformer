# Zoidformer

Local LLM inference engine. CUDA-first, Rust-wrapped, designed to plug directly into
[zoidborg-agent](https://github.com/ClawfficeOrg/zoidborg-agent) as an in-process provider.

## What It Is

Zoidformer is the local-inference half of the Clawffice AI stack. It runs quantized
language models on the host GPU and exposes a simple `tokio::sync::mpsc` channel API
that `zoidborg-agent` consumes via `ZoidformerProvider` — no HTTP, no IPC, same process.

Key design goals:
- **Fast first token** via CUDA graphs and fused kernels
- **Low VRAM footprint** via GGUF quantization (Q4_K_M, Q8_0, and higher)
- **PagedAttention KV-cache** for efficient multi-turn and batched inference
- **LoRA hot-swap** without reloading the base model
- **Live telemetry** — `ZoidformerMetrics` streamed over a `tokio::sync::watch` channel
  so the zoidborg TUI panel shows decode speed, VRAM usage, and cache occupancy in real time

## Architecture

```
┌──────────────────────────────────────────────────────┐
│ zoidborg-agent                                        │
│   ZoidformerProvider ──mpsc──► ZoidformerEngine       │
│                      ◄─watch── ZoidformerMetrics      │
└──────────────────────────────────────────────────────┘
         ▲  channel contract defined in zoidformer-core
         │
┌──────────────────────────────────────────────────────┐
│ zoidformer (this repo)                                │
│   zoidformer-core     — shared types, traits          │
│   zoidformer-engine   — inference loop + CUDA kernels │
│   zoidformer-gguf     — GGUF/GGML file loading        │
│   zoidformer-tokenizer— tokenizer wrapper             │
│   zoidformer-train    — training-data export          │
└──────────────────────────────────────────────────────┘
```

## Build Requirements

- Rust stable (MSRV: 1.80)
- CUDA Toolkit 12.x (optional — stub engine compiles without it via `--no-default-features`)
- `cargo` with `cc` crate for CUDA kernel compilation

```sh
# Build without CUDA (stub engine only)
cargo build --workspace --no-default-features

# Build with CUDA
cargo build --workspace --features cuda
```

## Status

Phase 0 — Foundation in progress. Not yet functional.

See [`todo.md`](todo.md) for the current roadmap.

## License

MIT — see [LICENSE](LICENSE).
