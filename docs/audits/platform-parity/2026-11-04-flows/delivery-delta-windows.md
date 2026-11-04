# Windows delivery delta review

Baseline (reports remain pinned): `213d65af24d2aa4845ba47743c9bab6787b61964`.
Reviewed delivery ref `origin/dev`: `1fa4c28f318258dd1af31920b1a55b8bb4c33de1`.
Read-only source/static diff only. No generators, tests, native probes or production mutations executed.

## Changed production contexts

- `38b58f5`: personal hotstring model now consistently names its hidden strict flag `is_case_sensitive_strict`: fallback reader, typed projection/preservation/validation, reload registration, native editor and WebView initialization. The TOML/shared page already uses that name. This repairs strict-flag editor persistence, not the general config transaction protocol or clipboard target ownership.
- `4a91f19`: `_HSE_CharOpensWord(Ch, Boundaries)` accepts a nonempty custom boundary or non-word character. `_HSE_WordBoundaryAllows`, retained-buffer trimming, expansion canonical effects and repeat word-character classification use it. Thus word-only triggers after punctuation such as `(`, `=`, `-` gain the shared macOS/Linux behavior. It changes eligibility and known-boundary metadata, not the selection snapshot, SendInstant clipboard preparation, native final admission or synthetic output custody.
- `1fa4c28`: TODO only. Explicitly retains preview bubble's old boundary finder and per-call boundary-set construction as follow-ups. Do not claim this delta achieves complete preview/matching parity or measured performance improvement; no benchmark run here.

## Findings at delivery ref

| Finding | Applicability after delta                                                                                                                                                                                                                                                                                                                                                |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| WCP-001 | Still applies. `hotstring_send.ahk:GetSelectionAsync` and startup admission helpers are unchanged. Gesture actions, physical/UIA callers and shared action/menu declarations are unchanged. Word-start recognition does not insert an admission between snapshot and clear/copy.                                                                                         |
| WCP-002 | Still applies. `SendInstant`/plain-paste boundaries, `modules/keymap/layout.ahk` and prefix wrapping watcher are unchanged. Newly eligible personal punctuation hotstrings can change which input dispatches, but no destination/pause capability is added to transformation/wrapping senders. Existing independent case-transform and explicit-wrap repro paths remain. |
| WCR-001 | Still applies. Raw SQL builder, prefix-idempotent cipher and encryption migration are byte-identical between refs; no literal/ciphertext provenance repair.                                                                                                                                                                                                              |
| WCF-001 | Still applies. WPM position owner and runtime Storage adapter are byte-identical. Personal TOML strict-flag repair is a different owner; no tuple transaction or acknowledged compensation added.                                                                                                                                                                        |
| WDS-001 | Still applies. `modules/gestures/system_actions.ahk` and ordinary quit receipt handling unchanged.                                                                                                                                                                                                                                                                       |
| WDS-002 | Still applies. Same unchanged system action file; no Recycle Bin child completion observer added.                                                                                                                                                                                                                                                                        |

Blob identity was checked for actual send/inputhook/layout/text-case, WPM/Storage, SQL/cipher/migration and desktop action owners. The complete diff changes only 14 files: TODO, five hotstring infra owners, two personal-editor owners and six AHK test files. Shared sources and `modules/gestures/actions.ahk` have an empty diff.

## Intentional differences / limitations

All clipboard report difference rows retain their original provenance and current applicability: OS simple case mapping versus generated Lua Unicode mapping; typed-symbol wrapping Windows/Linux versus explicit macOS wrapping; Linux-only direct selection menu rows; conditional Windows plain-paste/Excel behavior; restoration delay versus receiver consumption; cleanup while paused; delayed-rendering clipboard sequence caveat; unresolved pause/resume pulse policy. Their implementation/declaration owners are unchanged.

Do not continue advertising the old Windows refusal of word-only triggers after all non-listed punctuation as an intentional platform difference: this delta explicitly aligns that matching behavior with macOS/Linux. Preview still uses an older boundary finder according to the new TODO, so distinguish matching from preview. Strict-case flag loss in Windows WebView saves is likewise fixed by this delta and must not be presented as a current missing feature. Neither historical behavior is one of the six finding IDs reviewed here.

Native Windows execution remains unavailable. This is delivery applicability review, not a re-audit or runtime certification of the new commits. Immutable baseline reports were not edited.
