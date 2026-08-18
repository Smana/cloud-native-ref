# Spec archive (retired workflow)

> **This directory is a read-only archive. Do not add new specs here.**

From 2026-Q1 to 2026-Q3 this repository used an in-house spec-driven workflow — `/spec` →
`/clarify` → `/validate` → `/create-pr` — where each spec was a three-artifact directory
(`spec.md` = WHAT, `plan.md` = HOW, `clarifications.md` = an append-only decision log). It drew
on GitHub Spec Kit, with a platform constitution and a four-persona review checklist layered on
top.

It was retired on **2026-08-18** in favour of the
[Superpowers](https://github.com/obra/superpowers) plugin, which had been the workflow in
practice for several months. See [`CLAUDE.md`](../../CLAUDE.md) → *Development Workflow* for the
current flow, and [`docs/superpowers/`](../superpowers/) for its artifacts.

## What is here

| Bucket | Specs |
|--------|-------|
| [`done/2024-Q1/`](done/2024-Q1/) | `0000-eks-pod-identity` |
| [`done/2026-Q2/`](done/2026-Q2/) | `0001-llm-platform-prometheus-autoscaling` |
| [`done/2026-Q3/`](done/2026-Q3/) | `002`–`012`: gateway routing, `engineArgs` escape hatch, per-service InferencePool, vLLM cold start, GenAI observability, app workload types, Flux schema validation, app wizard (×2), CNPG Barman Cloud, InferencePool saturation, KVStore |

Directories were bucketed by their last-commit date when the archive was created, so a bucket is
an approximation of the merge quarter — **git history is the authority on when each shipped**.

The platform constitution these specs cite now lives at
[`docs/platform-constitution.md`](../platform-constitution.md).
