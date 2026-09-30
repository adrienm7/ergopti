<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-09-30. Published to `dev` from `integration-3` in one release. This ordered checklist is the
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
pushes to `dev`/`main`, and wants a cloneable GitHub handoff. Preserve
unrelated changes and stage exact paths. Every push to `dev` cuts a release,
so push rarely: run the full CI on a temporary `backup/*` branch through
`workflow_dispatch` (a non-dev ref runs the CI profile and publishes nothing),
and push `dev` only once that run is green. Temporary `backup/*` branches are
authorized and must be deleted after the final push.

**Overnight session of 2026-09-29 (supersedes the "one item at a time"
instruction: the maintainer asked for maximum parallelism).** Items 5 to 13
were implemented in parallel on `wip/*` branches, adversarially reviewed, fixed
on `wip/*-fix` branches and integrated in order on the local branch
`integration-2`, then `integration-3` after a container restart; the whole
batch was published to `dev` in one release on 2026-09-30.
The maintainer demos Ergopti on 2026-09-30 in the afternoon. Read
[the overnight handoff](handovers/2026-09-29-overnight/README.md) first: it
lists every branch, the in-flight fixes, the maintainer's decisions and the
exact release procedure.

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
5. [~] Complete W1 neutral configuration and recommended/clear scopes. Finish
   macOS Hotstrings and TapHold, Linux Hotstrings and TapHold, then global
   composition. Keep unknown fields, verified backups, exact runtime
   acknowledgement, external-write conflict detection and retryable rollback.
   Recommended delay values must match effective runtime inheritance: deleting
   `autocorrection.caps` currently inherits 1.0 s while the manifest recommends
   0.5 s. Do not assume deletion implements the recommendation.
   Hotstrings: Linux categories, sections and scalar settings are canonical
   config.toml leaves, with a one-shot import of legacy storage.json choices;
   both Lua drivers have a two-file recommended/clear owner whose planner
   writes explicit delays where inheritance differs, bound Ergopti groups
   included. Finished on `next/w1-hotstrings-scope` (unpublished):
   `hotstrings_menu` declares `scope_restore`/`scope_clear` beside the switch
   and all three drivers register them (Windows from `_HS_ScopeCommands`);
   macOS constructs its owner once per session and composes it into the
   global restore, its transaction now reverting and releasing; Linux word
   delimiters are config.toml leaves (`[hotstrings.terminator_states]`,
   `hotstrings.terminators`, the macOS paths) imported once from
   storage.json, and both Linux modes return them to the catalogue as
   Windows does. Still open: the macOS scope leaves its delimiter leaves as
   they are, and the Windows rows are verified statically only.
6. [~] Complete L4 extension layout geometry and physical magic-key behavior.
   Keep independent base/Shift, AltGr/ShiftAltGr and number-row emulation.
7. [~] Complete W2: seven-page first-run opt-in wizard, per-category recommended
   choices, consistent WebView behavior and genuine translations in 21 locales.
   Still open: the tap-holds page has no per-key checklist, so a Yes imports
   no key (Windows sets only `category_enabled.tap_holds`; macOS and Linux
   show a note). Import keys through each driver's tap-hold writer. Until W1
   moves them into config.toml, Linux applies its hotstring sections through
   hotstrings_config (storage.json) and leaves the trigger to its tray.
8. [x] Complete A4: TapHold menu grouped by hand, shared catalogue, key
       combinations under Shortcuts, with the actual configuration/runtime owners.
9. [x] Complete C4: shared centered update-check WebView, checking/current/new
       release/error states, other-channel notices and explicit install action.
10. [x] Complete D3: separate previous/next desktop actions with and without
        wrapping on each OS; retire the global wrapping toggle.
11. [x] Complete D4: explicit AI prediction action, recommended slots, removal of
        duplicate trigger paths, Windows feedback and model/suggestion/menu labels.
12. [x] Complete D5: remaining approved system actions, including required
        confirmation for quarantine/trash; exclude the rejected quit-all-apps action.
13. [~] Complete F2: honor the Karabiner integration switch before leases and
    guardians; preserve personal rules; back up and restore Windows touchpad
    registry values through one owner. Remaining: turning the switch off or
    « Retirer Ergopti de Karabiner » does not unregister a guardian
    LaunchAgent registered while it was on (needs a headless unregister
    role in the launcher, verified on a Mac).
    Legend: `[x]` implemented, reviewed and integrated on `integration-2`
    (published only once `dev` is pushed); `[~]` integrated with the precise
    remainder recorded in the item or in the overnight handoff.
14. [x] Run final cross-driver, shared, encoding, convention and 21-locale gates;
        record real-device checks still unavailable on this Windows host.
        Local gates on the released tip: JS 319/320, macOS Lua 12231/12231, Linux 4289/4289, macOS E2E and Linux E2E all scenarios, strict conventions, AHK encoding (1738 files) and gen:check (39 outputs of 22 generators, no drift). The only JS red is the
        container-only "Linux install.sh … sandboxed real run", which refuses
        root. Full CI without release (run 36649301758 (CI #619)) was green on the same tip,
        including the Windows AHK suites, packaging and install-and-launch on
        the three OSes. Real-device checks remain: macOS tap-holds and the
        guardian's Login Items approval, Windows tooltip rendering.
15. [x] Finish storage cleanup after all useful work is recoverable from GitHub.
        `C:/ewt`, `C:/ewtb` and `D:/ewt` are deleted. Their unique commits,
        pending patches and specifications are in the handoff package; their
        full-tree exports differed from `dev` only by formatting.
16. [~] Publish final corrective commits, verify CI and release assets, and write
    the final report with completed scope, limitations and manual test results.
    Published on 2026-09-30; the maintainer's manual test results remain.

## Maintainer requests added on 2026-09-29 (see the overnight handoff)

17. [~] About/Version submenu: one titled release-channel submenu, version row
    with the short commit hash ("Version locale (hash)" for a source
    checkout), Uninstall moved to its bottom. Integrated.
18. [~] Configuration › « Chemins » (was « Dossiers ») in 21 locales. Integrated.
19. [~] Windows tooltip border hidden under its content and white corner pixels
    (pooled border z-order + ring drawn from the content region). Integrated;
    verify visually on Windows 10/11.
20. [~] Windows launch smoke test: detect a real startup dialog instead of a 20 s
    extraction deadline. Integrated.
21. [~] Lighter bundles: Windows bundle 556 → 228 files; macOS zip 99.3 → 46.6 MB
    (unused Karabiner-Elements.pkg dropped, payload manifest, zip -9).
    No bundled Ollama; Ollama and MLX runtimes are installed only the first
    time each is selected as AI backend. Integrated. After the demo: `.tar.xz`
    archive.
22. [ ] Delta updates: macOS Sparkle deltas ready on `wip/delta-updates`
        (held until after the demo because its CI step only runs on real
        releases); then Windows and Linux per ADR 010.
23. [~] Ergopti-only hotstring groups (SFB reduction, rolls, repeat corrections)
    moved into the Ergopti extension, shown under « Hotstrings Ergopti ».
    Integrated. Open maintainer decisions: "installed" currently means
    "shipped with the app" (the submenu shows for every user); other
    Ergopti-looking groups (distancesreduction `qu`, `comma_j`,
    `comma_far_letters`, `ê` sections, French `suffixes_a`, magickey `replace`)
    were not moved.
24. [~] macOS tap-hold outage: a not-ready remap guardian held every Karabiner
    regeneration forever and pinned the first bulk edit (Restore defaults),
    refusing later edits and Reload. Fixed, with a Tap-Hold menu row saying
    why tap-holds wait. Guardian approval UX: registration was already
    automatic; a requires_approval answer now opens numbered Login Items steps
    in the native permission dialog (once per launch, after the Accessibility
    dialog, closed automatically on approval; not while Tap-Holds are off,
    where the banner stays). Integrated; verify on a Mac.
25. [~] Config policy: an unknown/retired key or a value naming something that
    no longer exists is one WARNING, ignored, and offered by the config
    cleanup — never an ERROR (fixes the dev.146 startup ERROR
    « M.enable(): unknown hotkey 'at_hash' »). Integrated for config.toml on
    the three drivers. Remaining: files other than config.toml (layers.toml,
    installed.json, storage.json, tap_hold.toml, api_keys.json, Karabiner
    files), quoted keys the cleanup cannot cut, and two maintainer decisions
    (config_migrate's fail-closed guard for invalid stamps; a migrations.toml
    exception for key removals handled by the cleanup).
26. [~] Diagnostics window showed raw translation keys (possibly because boot
    failed first); it must show real text even in a degraded boot.
    Integrated.
27. [~] Every Ergopti window is only focused when opened, never always-on-top
    (overlays exempt), with a guard test. Integrated.
28. [~] macOS permission instructions in a native dialog, never a one-line
    hs.alert banner. Integrated.
29. [~] force_quit_frontmost asks for confirmation; key combinations governed only
    by their own switch on every OS. Integrated. After the demo: the Windows
    wizard's Shortcuts answer should also write the key-combinations switch.
30. [ ] Physical magic-key setting on all three OSes (after the demo).
31. [ ] HS-274 exact physical key accounting with an Ergopti-owned background
        Karabiner runtime (no Karabiner-Elements app). Plan and decisions in the
        overnight handoff; ~32–42 agent-days; not in the demo release.
32. [ ] Post-demo test hygiene: AutoHotkey `AssertThrows` closures over a
        for-loop variable pass whatever the product does
        (`test_virtual_desktops.ahk`, `test_config_migrate.ahk`,
        `test_config_scope_manifest.ahk`,
        `test_config_window_patch_toml_meta_error.ahk`,
        `test_layout_catalogue.ahk`); extend `test-ahk-loop-capture.cjs` to
        in-loop closures. The OS-purity ratchet core baseline can drop from 253
        to 252.

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
