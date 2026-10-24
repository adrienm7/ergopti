<!-- docs/memory/README.md -->

# Project memory

This index routes durable Ergopti engineering knowledge. Read only the topics
needed for the current task; loading the complete memory catalog wastes context
and makes stale details harder to notice.

## Topics

- [Workflow and verification](workflow-and-verification.md) — repository
  safety, targeted gates, hosted CI evidence, audit evidence, and generated
  artifacts.
- [Shared architecture](shared-architecture.md) — ownership, shared data,
  logging, i18n, menus, and cross-driver invariants.
- [Windows and AutoHotkey](windows-ahk.md) — AHK v2 syntax, startup, callbacks,
  suspension, files, menus, WebView2, and the native DLL build.
- [Windows live checks](windows-live-checks.md) — driving a real, isolated
  Windows driver for the maintainer's checks: smoke hooks, tray clicks, timers
  and modal dialogs, real keys, and why a second driver spoils them.
- [macOS and Hammerspoon](macos-hammerspoon.md) — event taps, lifecycle
  ownership, timers, tasks, clipboard, Karabiner, test isolation, packaging,
  and AppleEvents.
- [Text input and configuration](text-input-and-config.md) — hotstrings,
  synthetic input, typing order, TOML, caches, and locale data.
- [Linux, web, and release](linux-web-release.md) — Linux input contracts,
  native port boundaries, CI runner prerequisites, website details,
  deployment, and release assets.
- [Rejected proposals](rejected_proposals.md) — measured ideas that should not
  be raised again without changed evidence.

## Maintenance

Store only non-obvious, durable knowledge that is not already evident in code,
tests, an ADR, or the repository instructions. Prefer updating an existing
entry to adding a near-duplicate. Every claim names the mechanism and the action
future work should take.

Do not store completed audit transcripts, branch history, commit summaries,
temporary measurements, or TODO snapshots. Git and audit artifacts own that
history. When retiring an artifact, retain only a verified invariant or a
measured rejected proposal that prevents repeated work.
