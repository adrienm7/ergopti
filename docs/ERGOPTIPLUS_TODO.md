<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-09-29. Integration branch: `dev`. This ordered checklist is the
current handoff; older workflow task-status files are historical evidence.
Update the completed item and its verification before moving to the next item.

## Delivery checkpoint

The overhaul is not finished. Eight reviewed integration commits ended at
`eaa06eeba`, followed by the published handoff and CI repairs. The macOS
cold-start errors were then fixed on `dev` (`d8d171fcd`, `56eeb70dc`,
`8ee659e17`) and CI published `v0.0.0-dev.144` on 2026-09-29. Two stricter
local macOS corrections followed on top of that release: gesture event-tap
acquisition deferred to explicit startup, and configuration consumers required
only after path initialization.

Work continues from a fresh clone on a Linux container. The Windows workstation
no longer holds any worktree, branch or external working directory: `D:/ewt`
was deleted after its useful content was committed here. The historical
workflow context (prompts, task status, feature map, analysis reports and
journal) is in the handoff package's `workflow-context-2026-09-24.zip`.

The user authorizes publishing `dev` and necessary CI repairs, forbids force
pushes and new feature branches, and wants a cloneable GitHub handoff. Preserve
unrelated changes and stage exact paths.
After CI and a verified new release, continue one TODO item at a time without
parallel agents. Update this file after each finished unit and reserve enough
quota to commit, publish and document the final clean checkpoint.

## Already integrated functionality

The history on `dev` contains the following substantial parts of the overhaul.
These are software implementations; final hardware verification remains below.

- Shared scrollable configuration cleanup, offered as cleanup rather than a
  startup error; valid configurable gesture parameters remain owned settings.
- Shared title composition with one product prefix and regression coverage for
  the broader window-title family; configured action values replace placeholders.
- Bundled keyboard-layout catalogue and manager on three OSes, installation
  owners, Ergo-L support, and independent base/Shift versus AltGr emulation.
  Extension geometry and physical magic-key completion remain in L4.
- Manifest-driven menus, category masters and retained child choices;
  configuration schema/migration infrastructure; substantial neutral-state and
  transactional recommended/clear machinery. W1 is explicitly incomplete.
- Shared action catalogue, Unicode case/plain-paste/wrap actions and three
  configurable number-row edge keys.
- Shared navigation-layer data, generated driver projections and web editor.
- Logger repetition handling, log-directory ownership, larger centered debug
  consoles, diagnostics/error interfaces and issue-reporting improvements.
- Shared updater channels, release notes and automatic-check scheduling.
  The common update-result interface remains C4.

## Ordered TODO

1. [x] Finish the current verification and repair its failures. Windows:
       7,239/7,239 unit checks and 5/5 E2E passed. Linux native: 3,576/3,576 passed
       in the fresh complete run after the Lua 5.4 test-loader correction.
       Linux E2E: 115/115. macOS full: 11412 passed and one old test-oracle failure; the corrected
       module passes 15/15 (11426 distinct cases in the composite).
       macOS E2E: 67/67 plus one platform-specific skip. JavaScript's five
       failures are resolved: four corrected guards/evidence checks pass in the
       real checkout; generation passes on the byte-identical export. Windows
       production compilation and strict conventions also pass. The Mac full run
       found a stale boot-boundary test; its strengthened replacement passes 15/15
       and rejects removal of each of 12 mandatory startup failure gates.
2. [x] Commit the eight reviewed integration units atomically: macOS canonical
       hotstring caches, personal-info boot gate, delay publication, remap field
       preservation; Linux shortcut scopes; shared AI/metrics scope commands;
       canonical Ctrl+G; configuration-surface verification.
3. [x] Account for every local branch and unfinished proposal. Preserve useful
       unapplied patches, full product specifications, proof summaries and precise
       continuation instructions inside this repository. Distinguish executable
       code from untested design fragments. Remove branches only after proof that
       their work is integrated or preserved. The cloneable package now exists at
       [the handoff directory](handovers/2026-09-28-ergoptiplus/README.md), including
       four pending patches and eleven exact original commits. Branch audit found
       two missing L4 contributions (`f35930ec2`, `e58cadf95`) and one dependency
       update (`c4f5973`) to review. These are preserved, not silently merged.
       The retired-worktree audit also recovered unapplied D4 model labels/21
       locales and L4 boot/test changes; their exact deltas are in the same package.
4. [x] Finish publication: every Windows, Linux, shared and macOS job passed
       and CI published `v0.0.0-dev.144`. Verify the CI verdict of the two
       later local macOS corrections before starting item 5.
5. [ ] Complete W1 neutral configuration and recommended/clear scopes. Finish
       macOS Hotstrings and TapHold, Linux Hotstrings and TapHold, then global
       composition. Keep unknown fields, verified backups, exact runtime
       acknowledgement, external-write conflict detection and retryable rollback.
       Recommended delay values must match effective runtime inheritance: deleting
       `autocorrection.caps` currently inherits 1.0 s while the manifest recommends
       0.5 s. Do not assume deletion implements the recommendation.
6. [ ] Complete L4 extension layout geometry and physical magic-key behavior.
       Keep independent base/Shift, AltGr/ShiftAltGr and number-row emulation.
7. [ ] Complete W2: seven-page first-run opt-in wizard, per-category recommended
       choices, consistent WebView behavior and genuine translations in 21 locales.
8. [ ] Complete A4: TapHold menu grouped by hand, shared catalogue, key
       combinations under Shortcuts, with the actual configuration/runtime owners.
9. [ ] Complete C4: shared centered update-check WebView, checking/current/new
       release/error states, other-channel notices and explicit install action.
10. [ ] Complete D3: separate previous/next desktop actions with and without
        wrapping on each OS; retire the global wrapping toggle.
11. [ ] Complete D4: explicit AI prediction action, recommended slots, removal of
        duplicate trigger paths, Windows feedback and model/suggestion/menu labels.
12. [ ] Complete D5: remaining approved system actions, including required
        confirmation for quarantine/trash; exclude the rejected quit-all-apps action.
13. [ ] Complete F2: honor the Karabiner integration switch before leases and
        guardians; preserve personal rules; back up and restore Windows touchpad
        registry values through one owner. Remaining: turning the switch off or
        « Retirer Ergopti de Karabiner » does not unregister a guardian
        LaunchAgent registered while it was on (needs a headless unregister
        role in the launcher, verified on a Mac).
14. [ ] Run final cross-driver, shared, encoding, convention and 21-locale gates;
        record real-device checks still unavailable on this Windows host.
15. [x] Finish storage cleanup after all useful work is recoverable from GitHub.
        `C:/ewt`, `C:/ewtb` and `D:/ewt` are deleted. Their unique commits,
        pending patches and specifications are in the handoff package; their
        full-tree exports differed from `dev` only by formatting.
16. [ ] Publish final corrective commits, verify CI and release assets, and write
        the final report with completed scope, limitations and manual test results.

## Time estimate

Budgetary estimate: 20–35 hours of effective work for all remaining product and
verification tasks, with uncertainty around native input and multi-file
transactions. The earlier six-hour estimate was too optimistic. The immediate
integration/handoff comes first; do not spend the remaining weekly quota on new
features while leaving uncommitted work or external-only specifications.

## Current local evidence

Portable specifications, pending changes, branch accounting and verification
results are in [the handoff package](handovers/2026-09-28-ergoptiplus/README.md).
Read its `VERIFICATION.md` and `VERIFICATION.json` for composite gate results.
Paths under `D:/ewt/` in those files are historical; that directory no longer
exists.
