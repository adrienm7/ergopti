<!-- docs/handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md -->

# Group 2 Windows continuation

The maintainer explicitly deferred Windows-dependent implementation and native
qualification to their PC. These steps cover TODO 34/37/102/104/105. Prepared
Windows sources, source checks and portable Lua tests do not establish Windows
runtime success. Keep the parent items partial until their remaining acceptance
steps pass. Preserve the independent corpora and cross-cutting items 16/38;
item 22 remains out of scope.

## Common qualification

- [ ] Use the integrated `origin/dev` SHA and record it with every result. Use
      the authenticated runtime/compiler versions in
      `static/ergopti_plus/_shared/modules/updater/windows_release_toolchain.json`.
      Activate the repository's pinned Node version and install frozen dependencies.
- [ ] Run `node tools/test/verify-change.cjs --plan`, then the applicable gates
      through `tools/rtk/rtk.sh`. Run the actual AHK unit/meta runner
      `static/ergopti_plus/windows/tests/run_all.ahk` with `/ErrorStdOut`, preserving
      its exit status and newest complete result transcript. Run the actual engine
      runner `static/ergopti_plus/windows/tests/e2e/run_e2e.ahk`. Keep passed, failed,
      skipped and unexecuted outcomes separate; check registered cases ran.
- [ ] Build, package, install, launch, restart, upgrade from a prior beta and
      uninstall the same SHA using the existing Windows build/installation procedure,
      without publishing a release. Verify source-distribution and compiled launches,
      required bundle inventories and preservation of personal source/preferences.
      Keep UTF-8 BOM on AHK and LF on all text; regenerate artifacts through owners.
- [ ] Fix any reproduced Windows defects, preserving refusal/rollback assertions.
      Each correction gets a coherent commit and immediate push; cancel automatic
      workflows for that precise SHA. Optional CI uses manual `ci.yml` dispatch with
      `os_lanes=windows` on an independently owned CI branch. Final integration alone
      uses the exclusive `codex/ci-lock` and `codex/ci-validation` protocol.

## TODO34: delays and handwritten delimiters

- [ ] Requalify recommended 0.5-second delays and clearing to inherited 1.0-second
      source delays for all current common families. Preserve personal/unknown
      parameters, exact metadata-cache identity and transactional refusal recovery.
- [ ] Qualify the actual Windows delimiter-string owner first: handwritten
      `__global__.word_delimiters` and `consumed_delimiters` in
      `hotstrings_config.toml`, native Add/Delete/toggle, save and restart.
      Windows currently has no `[[hotstrings.terminators]]` record consumer.
- [ ] Implement the missing Windows custom-record consumer/editor for the shared
      handwritten `[[hotstrings.terminators]]` contract before closing TODO34.
      Keep native input in the Windows adapter and shared admission/list policy
      centralized. Replay independently authored record lists through native
      Add/Delete/toggle, save and restart; preserve unknown neighbors and metadata.
      Refused disk or runtime publication must restore the prior admitted
      definition/runtime and allow an acknowledged retry. Do not count native
      delimiter-string tests as proof that this record path exists.
- [ ] Test the timing boundaries through physical typing in the installed driver,
      then recommended/clear settings and restart. Historical Windows validation of
      the earlier delay implementation does not qualify this integrated source SHA.

## TODO37: shipped Ergopti sections

- [ ] Run extension, language-pack and category-scope native tests. In a profile
      with no installed Ergopti layout, verify the always-visible shipped pack, all
      24 unchanged suffix rules and the metadata-only magic-key replacement section.
- [ ] Verify the replacement uses the actual chosen physical key, including held
      repeats and retirement after pause, source change or refused injection. The
      native Layout menu must not retain the old duplicate replacement row.
- [ ] Verify bulk enable/disable includes the bound replacement/repeat controls,
      preserves unrelated `text_expansion_symbols`/TypsT choices and opens the magic
      group only when enabling its bound controls. Refused save/reload must not leave
      a partial runtime/menu. Check persistence and all 21 translated descriptions.
- [ ] Verify the Windows package contains the required `suffixes_a.toml` and
      `magickeyreplace.toml` extension sources, with no retired French-source fallback.
      Uninstalling only the layout must leave the shipped hotstring pack available.

## TODO102: personal files and source controls

- [ ] Exercise the actual personal-file controller and category-scope tests.
      Verify exactly two category bulk commands and the shared declared file/section
      controls. Test first admission, explicit canonical choices, legacy disabled
      choices and independently stored section choices across save/restart.
- [ ] Test real primary/additional files, duplicate names, unreadable files,
      hardlinks, junctions/symlinks and the depth 16 discovery boundary. A primary alias
      or ambiguous identity must remain visibly unavailable; names/equal bytes must
      never grant physical source ownership.
- [ ] Edit delay, priority, color and tooltip through real menus/windows. Recheck
      literal case collisions, quoted/dotted keys and active canonical-versus-legacy
      overrides; fix any Windows mismatch while preserving inactive/unknown records.
      An unavailable field needs a translated reason without disabling safe controls.
- [ ] Test stale rendered pages, source/catalogue replacement during a prompt,
      new sibling/alias files, write refusal and runtime refusal. Require exact source,
      preference and runtime rollback or explicitly retained inverse debt. Recheck
      source-only unchanged CAS targets, complete cohort ownership and actual native
      cache/registry acknowledgement; no equality-based ownership shortcut is valid.

## TODO104: common autocorrection families

- [ ] Run common-migration, config-migration, cache and scope native cases plus
      the engine E2E manifest. Cold-start private schema 10 preferences/overrides and
      verify schema 11 fanout to names/abbreviations/technical_terms. Preserve explicit
      destination false, occupied namespaces, unknowns, comments and recognized
      delay/color/show_tooltip/priority leaves. Replay must be idempotent.
- [ ] Repeat enabled/disabled legacy choices, absent overrides, malformed owned
      metadata, invalid global values, concurrent replacement and refusal. Cold
      admission may omit unavailable common families while loading unrelated sources;
      refused live reload must retain the complete committed image.
- [ ] Enable each family independently and verify 34/95/11 rules, all 140 historical
      triggers/flags, case/order arbitration and source priority using frozen expected
      data. Examples include `autohotkey`→`AutoHotkey`, `api`→`API` and
      `adaboost`→`AdaBoost`; preserve the actual shipped corpus spelling/semantics.
- [ ] Verify independent timing/priority, recommended/clear settings, cache and
      preview retirement, backup/inverse ownership and language-pack independence.
      Requalify the same migration/registration in source and compiled installations,
      including all 21 actual translated family/menu labels.

## TODO105: programmable hotstrings

- [ ] Run `run_all.ahk --only "programmable hotstrings"`: the prepared source
      currently selects 20 cases, including all 13 compiled-required names. Then run
      the complete unit/meta and engine E2E suites. Cover real worker callbacks and
      actions, string `"0"`, Unicode/multiline framing, private errors and descendant
      Job cancellation, builtin priority and late source/input/destination guards.
- [ ] Cover all four global/hotstrings recommended/clear combinations and strict
      cancellation-debt refusal. Missing/unreadable source must remain closed with a
      repair/create action; explicit create preserves existing bytes and never runs
      code. Test valid empty factories, source disappearance on repeated enable or
      admitted reload, and an actual exclusive read-lock refusal.
- [ ] Execute the prepared compiled probe with the actual packaged executable,
      startup-admitted extracted bundle, matching private LocalAppData and same-SHA
      startup evidence. `tools/test/run-compiled-user-hotstrings.ps1` requires those
      explicit arguments; its contract fixture alone is not this acceptance test.
      Require complete selected TAP results, all 13 mandatory names, exit 0, exact
      bundle marker/hash/SHA and acknowledged Job/descendant cleanup. Never substitute
      downloaded source execution for the compiled executable's `/script` path.
- [ ] Confirm the installed bundle supplies the native worker and shared policy.
      Physically type in ordinary/password fields; verify Unicode/multiline text,
      builtin/personal precedence and action/cancellation semantics. Source, focus,
      control, input, pause, disable, reload and shutdown changes must fence deferred
      output and retain cancellation debt until its actual acknowledgement.
- [ ] Check installed default-off menus, count/error/open/create/reload commands,
      all 21 translations and durable settings after save/restart/recommended/clear.
      User source bytes must remain unchanged. Retained callbacks/metadata do not
      authorize active output after quarantine or a foreign same-generation owner.
