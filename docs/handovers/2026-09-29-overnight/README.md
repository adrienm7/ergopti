<!-- docs/handovers/2026-09-29-overnight/README.md -->

# Overnight handoff of 2026-09-29

> Historical snapshot of 2026-09-29, archived on 2026-10-03. Follow
> [AGENTS.md](../../../AGENTS.md) and
> [the current continuation checklist](../../ERGOPTIPLUS_TODO.md) for ongoing
> work. The branch table and commands below record the overnight operation;
> its backup, force-push and release instructions are superseded. Preserve
> existing changes, create no `backup/*` branches and use no force-push.
> Current manual validations use `codex/ci-validation`, with an independent
> concurrency group per run and release publication disabled.

This handoff records the branches, in-flight work, maintainer decisions and
release procedure as they stood on 2026-09-29. Its decisions are in
[DECISIONS.md](DECISIONS.md); its HS-274 plan is in
[hs274-delivery-plan.md](hs274-delivery-plan.md).

## Context

- Start point: `origin/dev` = `c3005e0` (published as `v0.0.0-dev.146`).
- The maintainer demos Ergopti on 2026-09-30 in the afternoon and wants a
  tested release in the morning. A regression is worse than a missing feature.
- Every push to `dev` cuts a release: push rarely. Temporary `backup/*`
  branches are authorized; delete them after the final push.
- The macOS/Windows drivers cannot run in the Linux container used tonight:
  Windows AHK suites and macOS packaging/launch are only proven by CI.

## Where the work is

All branches below exist locally and are mirrored on GitHub as
`backup/<same name>` (for example `backup/wip/d3-desktops`).

| Branch                                      | Content                                                                              | State                              |
| ------------------------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------- |
| `integration-3` (published to `dev`)        | `c3005e0` + everything below marked integrated                                       | Released 2026-09-30 (TODO item 14) |
| `wip/ci-windows-launch-smoke(-fix)`         | Windows smoke test detects a startup dialog, 120 s hang guard                        | Integrated                         |
| `wip/about-menu`                            | Channel submenu, version + commit, Uninstall under Version                           | Integrated                         |
| `wip/win-tooltip-border`                    | Tooltip border z-order and ring region                                               | Integrated                         |
| `wip/win-bundle-trim`                       | Windows bundle manifest, 556 → 228 files                                             | Integrated                         |
| `wip/d3-desktops(-fix)`                     | Desktop prev/next with and without wrap; `space_wrap` retired                        | Integrated                         |
| `wip/d5-system-actions(-fix)`               | Approved system actions with confirmation                                            | Integrated                         |
| `wip/d4-ai-prediction`                      | AI prediction action, labels; Windows trigger shortcut retired (config v4)           | Integrated                         |
| `wip/c4-update-check(-fix)`                 | Shared update-check window on 3 OSes                                                 | Integrated                         |
| `wip/a4-taphold-menu(-fix)`                 | Tap-hold menu by hand + separator, key combinations group                            | Integrated                         |
| `wip/f2-karabiner-touchpad(-fix)`           | Karabiner switch (`integration_enabled`), touchpad registry owner                    | Integrated                         |
| `wip/w1-taphold-global(-fix)`               | Tap-hold scopes, global composition (fix commit `a30b4001` deliberately NOT applied) | Integrated                         |
| `wip/w1-hotstrings(-fix)`                   | Hotstrings scopes, Linux storage.json import                                         | Integrated                         |
| `wip/l4-layouts(-fix)`                      | Extension packs on macOS, bindings, magic key                                        | Integrated                         |
| `wip/w2-wizard(-fix)`                       | Seven-page wizard (`085f1368` partially applied, see its message)                    | Integrated                         |
| `wip/macos-size(-fix)`                      | macOS payload manifest, 99.3 → 46.6 MB                                               | Integrated                         |
| `wip/delta-updates`                         | Sparkle deltas + ADR 010                                                             | HELD until after the demo          |
| `wip/remap-guardian-bulk-fix(-fix)`         | macOS tap-hold outage (TODO 24)                                                      | Integrated                         |
| `wip/config-unknown-keys-warn(-fix)`        | Unknown config → WARNING + cleanup (TODO 25)                                         | Integrated                         |
| `wip/diag-ui-i18n(-fix)`                    | Diagnostics raw keys (TODO 26)                                                       | Integrated                         |
| `wip/ui-focus-not-topmost(-fix)`            | Focus-only windows (TODO 27)                                                         | Integrated                         |
| `wip/macos-permission-dialog(-fix)`         | Native permission dialog (TODO 28)                                                   | Integrated                         |
| `wip/forcequit-confirm-combos-switch(-fix)` | TODO 29                                                                              | Integrated                         |
| `wip/ergopti-hotstrings-ext(-fix)`          | TODO 23 (built on `wip/l4-layouts`)                                                  | Integrated                         |
| `wip/macos-lazy-ai-runtimes(-fix)`          | No bundled Ollama; lazy Ollama/MLX (built on `wip/macos-size`)                       | Integrated                         |
| `wip/windows-ci-fixes(-fix)`                | Eight Windows AHK CI failures, shell-runner settle ceiling                           | Integrated                         |
| `wip/guardian-approval-ux`                  | Login Items steps when the guardian awaits approval (TODO 24)                        | Integrated                         |

`wip/macos-no-ollama` and `wip/macos-stale-shortcut-keys` are empty leftovers
of restarted runs; ignore them.

## Integration rules that were applied

- Integrate each `wip/X` with `git cherry-pick c3005e0..wip/X`, then its fix with
  `git cherry-pick wip/X..wip/X-fix`, in the order of the table above.
- Resolve sources first, then regenerate generated files through their owners
  (`npm run gen`, `npm run codegen`); never hand-merge generated output.
- Locale JSON files merge key by key (a local union merge driver was used).
- Config migrations are sequential: `v2_to_v3` (retires `gestures.space_wrap`)
  and `v3_to_v4` (retires the dedicated AI trigger shortcut). The next free step
  is `v4_to_v5`. Unknown keys are otherwise handled by the cleanup policy of
  TODO item 25, not by per-key migrations.
- After every branch: `node ./tools/test/verify-change.cjs --range=<base>..HEAD
--plan`, then the selected gates; full `test:js`, `test:hs`, `test:linux`
  and both E2E suites at the end.

## Release procedure (do not skip)

1. Integrate the remaining in-flight fix branches onto `integration-2`, at least
   TODO 24 (tap-hold outage) and TODO 25 (startup ERROR) before the demo.
2. Run every local gate (TODO item 14).
3. Push the tip to a temporary branch and run the full CI without a release:
   `git push origin +integration-2:refs/heads/backup/integration-2b`, then
   dispatch `.github/workflows/ci.yml` on `backup/integration-2b`
   (`workflow_dispatch` on a non-dev ref resolves "CI profile, no release").
4. Fix every red job with a new commit (never skip or weaken a test), repeat 3.
5. When the dispatched run is fully green: `git fetch origin dev`, make sure
   `integration-2` still contains `origin/dev` (rebase onto it if the
   maintainer pushed meanwhile, then repeat 2–4), and push
   `git push origin integration-2:dev` — one release.
6. Verify the release assets for the three OSes, update the TODO and write the
   final report plus a French manual test checklist for the maintainer.
7. Delete every `backup/*` branch and the hourly wake-up routine.

## Demo-day notes for the maintainer

- macOS tap-holds need the remap guardian: System Settings › General › Login
  Items & Extensions › allow ErgoptiPlus in the background. If the menu is
  stuck, Quit (not Reload) and relaunch.
- Windows: the dedicated Ctrl+Space AI trigger is retired; bind the Win+Space
  keyboard slot to « Générer une prédiction IA » in Raccourcis, or use
  « Restaurer les valeurs conseillées » there.
- First launch on Windows extracts the bundle (a few seconds); launch once
  before presenting.
- If the local Ollama AI is part of the demo on macOS, install Ollama system-wide
  beforehand once TODO 21's lazy runtime ships.
