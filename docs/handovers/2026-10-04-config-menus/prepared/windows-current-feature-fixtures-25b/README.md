# Windows current-feature fixture preconditions on origin/dev

Base commit: `25b879aac1e93e9f86d39c41d5ff4b2b2866c2a7` (`origin/dev` at extraction).
Owned source: `static/ergopti_plus/windows/tests/unit/test_features_manifest.ahk`.
Patch SHA-256: `93ea4d5b0c968644c78cb038d8bc54b59aaa8dd2e7dde2441ef7de8d306fe12d`.
Source preimage SHA-256: `85ad22063c010c0ff3c5ca5778f5beb092059827b52a30b5809ed3fbcbee08d7`.
Source postimage SHA-256: `49931539f8ad89428385d394d7c4fb7593664d08377483376197a0faa4dda8d2`.

This source-only patch retargets the eleven existing ownership-dependent fixture functions from removed `hotstrings.autocorrection.caps` to the actually published `hotstrings.autocorrection.names`. Both current names defaults remain enabled=false and timing=0.5. The published feature replacement originates in commit `5a077157af6f083cdf4d1f1c2e1b749e07beaf46`; no removed feature is restored.

All 62 original assertions in those functions retain their counts, constants, outcomes and purposes. Literal-versus-nested owner collisions retain paired spellings. Every other source byte, original registration, unrelated function, arbitrary dotted-corpus golden and caps_lock control remains unchanged. Nine function preimages are byte-identical to the independently reviewed d5bb fixture packet; the other two retain this base's exact older full-save assertions and inline refusal outcome while changing only the feature identity. No newer request-generation acknowledgement assertions or inline-success behavior are imported.

This packet deliberately excludes the root-only full-save/restart additions and the new retired-caps preservation probe. It has no dependency on the newer source-shape/configuration implementation or feature_state_boot_smoke support changes. Apply only this source patch to a checkout whose preimage matches the SHA above; adapt by inspecting later source owners if its bytes differ.

Qualification: source pre/post identities, UTF-8 BOM/LF, exact reversible function substitutions and preservation of all remaining source bytes are checked. Private sparse preimage `git apply --check` passes. AutoHotkey syntax compilation, native unit execution, filesystem behavior and restart are NOT RUN here. The Windows owner must replay and qualify this patch on the actual branch and owns integration; source checks do not claim resolution of the six native failures.
