# Linux personal-information audit

Audited SHA: `7aecd9a25b35efdcff68898919506dc2f6fd02d0`. Date: 2026-11-05. Scope: personal information fields/aliases, typed single and multi-field expansion, prefix mappings, preview/log classification, configuration routing and native editor source/receipt lifecycle. Three confirmed findings. No production or registered test edits. Exact source hashes: `source-hashes.json`.

Execution uses genuine LuaJIT and actual production business owners. Native focus observations/uinput writes and page evaluation acknowledgments are faithful controlled ports; no native editor, window, clipboard, accessibility service, user configuration or real secrets were used. The configuration-route probe uses genuine bootstrap Storage, path APIs and TOML writer inside a runner-isolated home plus private scratch files. Command/native acknowledgment is never counted as proof that an application received text.

## PIL-001 — Personal multi-field output discards the original destination publication

High severity, high confidence; G2/G3. Full source paths below are relative to `static/ergopti_plus/`.

Public path: Main captures a retained text destination and supplies it to `dyn_hotstrings.on_trigger(buf,ch,boundary,destination)` at `linux/ergopti_hotstrings.lua:1580-1583`. The single-field branch requires and forwards it. For a multi-alias `@np★`, `manager.on_trigger:488-493` instead calls `_fire_combo(prefix,t)`; `_fire_combo:432` calls `injector.inject_fields` without that destination. `inject_fields:1008-1071` accepts no publication, prepares with nil publication and starts `run_transaction` with nil publication. Its output owner checks the channel/layout APIs, not which field is focused.

Reproduction: initialize private first/last-name aliases, capture an actual focus-guard publication for the original field, then change the controlled resident focus observation during actual layout planning. The publication is stale by its actual `current()` check, without explicitly invalidating the guard. A single `@p★` refuses with zero writes. Multi-field `@np★` returns success and records 14 native-shaped writes, including backspaces, personal content and one real Tab, to the successor field. Both stable controls succeed. The only values are synthetic `s`/`e`.

Evidence: `probes/combo-publication.lua`, `logs/final-a-combo-publication.log`, `logs/final-b-combo-publication.log`, `logs/source-boundaries.txt`. The manager, injector, layout planner and focus guard/detector/policy are production code; the focus receipt and uinput transport are controlled. This establishes loss of destination admission at native output boundaries, not a live desktop leak observation.

Visibility/backstops: the combo reports committed, clears its logical trigger through Main and carries the correct private flag, but privacy logging does not prevent writing into the wrong field. No warning detects the retired destination. Native write refusal still invokes existing cleanup/emergency-stop behavior; that is not a backstop when writes to the wrong focused field succeed. Avoiding the combo/single-field use is an alternative. Ordinary application undo is unmeasured.

Regression direction: drive actual Main/manager/injector with focus/privacy/pause retirement before the first erase and at planning/clipboard settlement boundaries; require zero data writes to a successor and normal owned key-up/clipboard cleanup. Retain the initial field authority through the first output. Model legitimate form continuation separately: real Tabs intentionally move to following fields, so do not simply require the original field identity after every intended Tab and break the feature.

## PIL-002 — Dynamic personal data and editor save ignore the configuration-directory override

Medium severity, high confidence; G2.

`linux/infra/config_paths.lua:123-139,175-191,206-210` owns an acknowledged effective configuration-directory override; `Paths.config("personal_info.toml")` and the public open-personal-info action (`modules/gestures/manager.lua:460`) use it. Dynamic manager init instead builds `default_config_dir() .. "/personal_info.toml"` at `manager.lua:179-181`. Main's startup and magic-key reinitialization supply only trigger_char (`ergopti_hotstrings.lua:934-935,2710-2711`), so the optional explicit personal_info_path does not repair the production route.

Reproduction: use actual `Paths.set_config_dir` and bootstrap Storage to select a private custom directory. Put different synthetic first-name values in the default and effective personal files. Actual manager init without an explicit personal_info_path loads the default value, and its genuine capture/edit/save owner writes the default file while the effective file is untouched. Reinitializing with the explicitly effective path is the positive control and loads the correct value.

Evidence: `probes/config-route.lua`, both `final-*-config-route.log`, source boundaries and source hashes. The writer's successful disk result is measured; no native page presentation is inferred.

Visibility/backstops: expansion/editor state and save can all succeed against the wrong source without an error, while opening personal_info.toml through the configured-path action targets another file. Resetting the directory to default or explicitly supplying the path to init works; Main does not do the latter. Regression direction: exercise public configuration-directory selection, actual startup/magic-key init and editor save with distinct default/effective sources, requiring one effective file authority. Preserve bootstrap storage's own independent location.

## PIL-003 — The personal editor cannot initialize or create its missing first-boot source

Medium severity, high confidence; G2.

With no personal_info.toml, `_parse_personal_info_toml:128-130` returns empty tables, while `capture_info_edit:731-735` requires an existing classified `ok` file with an info table. The real bridge's page-epoch ready branch (`ui/personal_info_editor/bridge.lua:125-130`) returns pushed=false when this receipt is absent. It emits no initData script or refusal notification. Save from that opening has no retained receipt and cannot create a source. The page script renders only host-provided fields and has no field-add/source-create path. Repository searches of Linux daemon, infra, installer, launch/build packaging and onboarding consumers found no personal-info first-create/seed owner; the shared example is an example, not a called bootstrap path.

Reproduction: initialize the actual manager against a nonexistent private source, then call the actual editor bridge's ready action for a valid current page epoch. Result: pushed=false, zero initial JS evaluations, zero initial notices. Saving a known first_name remains false and the file remains absent. Create a valid source independently and reinitialize: the identical current page now receives its field payload. Closing the exact epoch continues to block later saves, as required.

Evidence: `probes/editor-firstboot.lua`, both `final-*-editor-firstboot.log`, source boundaries. This is actual bridge/source execution with acknowledged page-host seams; no screenshot or native window observation is claimed.

Visibility/backstops: the initial refusal is silent; a later Save reports failure, but offers no way to create fields. Manual creation of a valid TOML source followed by reinitialization works. Regression direction: test absent-source first launch end-to-end with an authorized empty-field creation transaction, then edit/save/reopen; also test source appearance/race, foreign epoch and write refusal. Preserve the current absent/stale-source guard rather than treating a nonexistent receipt as ordinary authority.

## Fields, aliases and routes covered

`probes/all-fields.lua` independently covers all 15 declared keys through the real manager, field policy and editor payload. It assigns synthetic custom aliases to each key, checks full resolved values at the recording insertion boundary, private flags, masking and log redaction. The four masked fields are `bic`, `credit_card`, `iban`, `social_security_number`. The unmasked fields are `city`, `country`, `date_of_birth`, `email_address`, `first_name`, `last_name`, `phone_number`, `phone_number_clean`, `postal_code`, `street_address`, `work_email_address`. Unknown fields fail closed for preview. Editor payloads intentionally contain full values to edit; that is a different UI from previews.

The shipped example has 13 aliases: a→street_address, b→bic, c→credit_card, d→date_of_birth, e/m→email_address, f→phone_number_clean, i→iban, n→last_name, p→first_name, s→social_security_number, t→phone_number, w→work_email_address. City, country and postal_code can be given custom aliases; they are not absent data fields. Alias keys must be one valid codepoint; NFC multi-byte and malformed/decomposed suffix behavior is exercised by registered tests. Whole combos with an unknown/blank alias are deliberately refused on Linux to avoid shifting later form fields. Uppercase non-ASCII alias normalization/cross-OS matching remains a matrix/intent question, not a new PIL finding.

Single fields use literal injector text with retained destination. Multi-fields preplan all values, use a real KEY_TAB between fields and none after the last, and report logical concatenated values without tabs to private metrics. Linux prefix mappings append directly from the provider without output-token parsing; literal `{Tab}` in a personal value therefore takes text-only inject, unlike an explicitly tokenized ordinary hotstring. Existing native-seam tests cover output failures, direct-layout/clipboard preparation and owned cleanup; no application-level Tab focus receipt or undo behavior is established.

Phone/SSN/IBAN prefix mappings are all private and carry their field classification. Preview display masks each multi-field part against its own field policy and uses a visible separator for real field-advancing Tabs. Masking is kept out of insertion. Main only publishes logical replacement/metrics after the acknowledged result, and private fields do not become raw content logs. The synthetic all-field probe checks that full original values reach insertion even when preview text is masked.

Preferences are neutral/off by default, use canonical master/family flags, and prefix enable/disable rebuilds ordinary mappings. Configured delays and dynamic preview composition retain existing prior gaps below. Editor source receipts bind exact bytes, active path and initialization generation; native writer admission rechecks the page owner and source. Real editor tests cover source drift/unknown fields/save refusal/reload refusal/close/epoch retirement. Saved durability is distinct from successful catalogue reload: the bridge reports separate saved/reloaded/closed receipts. Full native interruption/recovery during rule refresh is not certified.

## Duplicates, intentional differences and limits

- Existing `2026-11-04/hotstrings.md` / TODO first inventory item already records Linux's shortest phone prefix firing without its magic key and the Lua +33 output retaining the national zero. Both were rechecked in current source and excluded from new PIL IDs.
- Existing Linux hotstring findings LH-001/002/003 cover registered single-field preview absence, invisible suggestion metrics and builtin delay admission. No duplicate preview/delay ID is raised.
- Existing LCP-001/002/003 cover text-only borrowed clipboard snapshot restoration, foreign-owner restoration and missing exact selected-range custody. They remain applicable to fallback/legacy routes; passing text-oriented tests does not establish all-format preservation.
- Shared role owns the independently replayed prefix-count mismatch: only raw/unspaced SSN+IBAN enabled yields two actual mappings but active_count four (`probes/prefix-count-owner.lua`). No PIL duplicate.
- Previous Linux native UI LVB-001 concerns personal hotstring editor auto-close, a different editor/source from personal-info. Crypto/config LKC/LCF findings were checked and do not duplicate these source/destination defects.
- Full-value editing is intentional; bubble masking is not a stored-data encryption or paste restriction. No additional encryption promise is invented. Missing classification/read/close errors fail closed in the actual policy reader and native special-file tests.

Native AT-SPI/uinput, real X11/Wayland clipboard MIME negotiation, editor DOM rendering in WebKit, actual field transition after Tab, application undo and user-perceived latency/memory are not measured. Source-only caller/packaging conclusions are marked; the owner probes do not impersonate native receiving.

## Verification and closure

Read the sequential brief and applicable repository audit/false-green instructions and routed memory. False-green scan stays within baseline, 0 vs 0; it does not detect an untested owner join. `probes/targeted.lua` follows standard private HOME, UTF-8/timing, secret-service and menu reload isolation and executes 16 registered relevant modules: **191 passed, zero failed**.

Two final whole-bounded dry sweeps after the last new root reconsidered all fields/aliases, public dispatch, preview/privacy, configuration source routing, editor creation/save/reload/teardown, stale callbacks and native refusal/backstop seams. Both reran the four primary probes, shared count countercheck and the 191 cases, with no additional new root. Canonical logs are `logs/final-a-<probe>.log` and `logs/final-b-<probe>.log`; `probes/run-sweep.sh a|b` reproduces them. Task-local manifest/enum/evidence checks are recorded in `logs/manifest-validation.txt`; the repository workflow validator only accepts in-repository ahk/hammerspoon paths, so this authorized scratch Linux scope uses task-local validation.
