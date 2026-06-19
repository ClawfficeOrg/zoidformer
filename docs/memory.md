# Memory — Zoidformer

Architectural decisions, key discoveries, and rationale for choices made in this project.

## Format

Each entry: **Decision** → **Context** → **Impact** → **Follow-up**

---

## 2026-06-19 — Project init

- Decision: Separate repo from `zoidborg-agent`. Zoidformer is a standalone inference engine; zoidborg-agent depends on it via a feature-gated optional dep.
- Context: The CUDA toolchain, large model weights, and training pipeline would bloat the agent repo. Keeping them separate lets the agent compile on machines without CUDA or a GPU.
- Impact: `zoidborg-agent` has `[features] zoidformer = ["dep:zoidformer-core"]` (planned in task 0.9.x). This repo has its own ralph loop.
- Follow-up: Coordinate `ZoidformerMetrics` shape and channel contract between the two repos before implementing 0.8.x and the agent-side 1.0.0 task.
