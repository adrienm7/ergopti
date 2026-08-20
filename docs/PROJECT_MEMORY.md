<!-- docs/PROJECT_MEMORY.md -->

# Project memory

This file is the routing index for Ergopti's durable engineering memory. Read
only the topic files relevant to the work at hand; do not load the whole
catalog by default.

## Topic files

- [Workflow and verification](project-memory/workflow-and-verification.md) —
  commits, tests, audit evidence, generated files, and documentation hygiene.
- [Shared architecture](project-memory/shared-architecture.md) — ownership,
  shared data, logging, i18n, menus, and cross-driver invariants.
- [Windows and AutoHotkey](project-memory/windows-ahk.md) — AHK v2 syntax,
  startup, callbacks, suspension, files, menus, and WebView2.
- [macOS and Hammerspoon](project-memory/macos-hammerspoon.md) — event taps,
  lifecycle ownership, timers, tasks, clipboard, Karabiner, and test isolation.
- [Text input and configuration](project-memory/text-input-and-config.md) —
  hotstrings, synthetic input, typing order, TOML, caches, and locale data.
- [Linux, web, and release](project-memory/linux-web-release.md) — Linux input
  contracts, website details, deployment, and release assets.

## Maintenance policy

Store only non-obvious, durable knowledge that is not already clear in code,
tests, an ADR, or repository instructions. Keep every entry concise and in
English. Prefer updating an existing entry over adding a similar one.

Do not store completed audit transcripts, branch history, commit summaries,
temporary measurements, or TODO snapshots. Git already preserves that history.
When an audit artifact is retired, retain only the verified invariant or
rejected idea that future work genuinely needs.

