# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the ergopti project.

## What is an ADR?

An ADR is a short document that captures a significant architectural decision: the context that led to it, the decision itself, and its consequences. ADRs form a permanent, searchable log of *why* the codebase is shaped the way it is — not just *what* it does.

ADRs are immutable once accepted. If a decision is revisited, the old ADR is marked **Superseded** and a new one is created.

## Status values

| Status | Meaning |
|---|---|
| **Proposed** | Under discussion — not yet binding |
| **Accepted** | Decision is in force |
| **Deprecated** | No longer relevant; kept for historical context |
| **Superseded** | Replaced by a later ADR (link provided) |

## Naming convention

Files are named `NNN-short-slug.md` where `NNN` is a zero-padded three-digit sequence number. Numbers are never reused.

## How to add a new ADR

1. Copy `template.md` to `docs/adr/NNN-your-slug.md`.
2. Fill every section — leave none blank.
3. Set status to **Proposed** and open a PR for team review.
4. Once merged, update status to **Accepted**.

## Index

| # | Title | Status |
|---|---|---|
| [001](001-hexagonal-architecture.md) | Hexagonal architecture with ports and adapters | Accepted |
| [002](002-codegen-manifest.md) | Features manifest generated from TOML | Accepted |
| [003](003-single-toml-schema.md) | Single TOML schema with snake_case keys for all config | Accepted |
| [004](004-linux-backend-luajit.md) | Linux driver uses LuaJIT + libinput + uinput | Proposed |
| [005](005-hotstring-engine-ownership.md) | Hotstring engine canonical spec lives in `_shared/domain/` | Accepted |
| [006](006-cross-driver-corpus-testing.md) | Shared test-vector corpus consumed by all drivers | Accepted |
| [007](007-i18n-audit-findings.md) | i18n audit findings (1.3.6) | Partially resolved |
