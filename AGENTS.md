# Agent Instructions — Zoidformer

These instructions apply to every agent (human or automated) working in this repository.

## Required Reading Before Any Task

1. `README.md` — project overview, architecture overview, build requirements
2. `docs/plan.md` — current design intent and open decisions
3. `todo.md` — phase index, pick up the correct `docs/todo-vN.md`
4. `docs/memory.md` — architectural decisions already made
5. `docs/learnings.md` — discovered constraints, crate quirks, CUDA gotchas

RTK rule: prefix all shell commands with `rtk` (e.g. `rtk cargo build`).

## Repository Layout

```
crates/          Rust workspace members
  zoidformer-core/    channel contract types, shared traits
  zoidformer-engine/  inference engine (stub → real CUDA)
  zoidformer-gguf/    GGUF model loading
  zoidformer-tokenizer/ tokenizer wrapper
  zoidformer-train/   training-data export seam (phase 1+)
kernels/         CUDA source (.cu) — compiled by build.rs in zoidformer-engine
docs/            project documentation
scripts/         ralph.sh, hooks, install-hooks.sh
skills/          agent skill files
```

## Pre-Commit Hook

A pre-commit hook lives in `scripts/hooks/pre-commit`.  
Install once per clone:

```sh
./scripts/install-hooks.sh
```

The hook runs `cargo fmt --check`, `cargo clippy -D warnings`, and `cargo test`.  
**Never use `--no-verify`.** Fix failures; don't bypass them.

## Code Quality Requirements

### Rust
- No `unwrap()` / `expect()` / `panic!()` / `todo!()` / `unimplemented!()` in production paths.
- All `Result` and `Option` must be handled or propagated.
- Use `thiserror` for library error types; `anyhow` for binary/test error handling.
- All public items must have doc comments.
- `cargo clippy --workspace --all-targets --all-features -- -D warnings` must pass clean.
- `cargo fmt --check` must pass.

### CUDA / C
- All `.cu` files live in `kernels/`. Compiled via `build.rs` in `zoidformer-engine`.
- Kernels must compile with `-Werror` in debug and release.
- No raw pointer arithmetic without a safety comment explaining the invariant.
- Document memory layout assumptions (tile sizes, warp sizes) in a comment block at the top of each kernel.

## Architectural Invariants

1. **Channel contract lives in `zoidformer-core`** — no CUDA dep in core. WASM-compatible types only.
2. **No hard dep on CUDA at compile time** — feature-gate with `features = ["cuda"]`. Stub engine must compile and pass tests without CUDA installed.
3. **`ZoidformerMetrics` is the single source of telemetry truth** — no other stats structs duplicating these fields.
4. **GGUF loading is isolated** — `zoidformer-gguf` has no dep on the inference engine or tokenizer.
5. **Tokenizer is a thin wrapper** — no bespoke tokenization logic; delegate to `tokenizers` crate or `tiktoken-rs`.
6. **Training export is one-way** — `zoidformer-train` reads session data, writes JSONL. It never modifies sessions.
7. **Kernel output is deterministic** — same seed + same weights = same output. Tests must verify this.

## Security Requirements

- No secrets in source. API keys, model paths, and credentials come from environment variables or config files excluded by `.gitignore`.
- Model weights are never committed. `.gitignore` covers common weight file extensions (`.gguf`, `.bin`, `.safetensors`).
- Training export: strip personal data, apply redaction pass before writing JSONL.

## Task Workflow (ralph-compatible)

1. **Read** — required reading above + the full task block in `docs/todo-vN.md`.
2. **Plan** — write numbered steps (cheap model, no code).
3. **Implement** — write code, then tests, then docs.
4. **Self-review** — check the diff against the task spec.
5. **Gate** — `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test --workspace`.
6. **Commit** — `feat: X.Y.Z — <description>` on the task branch.
7. **Docs** — update `docs/todo-vN.md` (mark done), `docs/memory.md`, `docs/learnings.md` (if new insight), `CHANGELOG.md`.

Scope: touch only the files listed in the task's **Touches** field. Justify any extra file in the commit message.
