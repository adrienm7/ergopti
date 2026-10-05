# Windows PC resumption: incomplete async auth preparation

## Status

Scratch preparation only; not integrated, staged or committed by this agent. No AutoHotkey/PowerShell/.NET compile, native auth, CA, E2E, packaging or installation checks ran for this preparation. Root's focused validation slot excluded these files. BOM/LF byte inspection was the only local check. This packet is **unreviewed incomplete WIP**, not native-qualified, and must remain a TODO step.

Exact four preimages are preserved with SHA256 in preimages.json. Five proposed repository files and a surgical patch are included. Compare current files against those exact preimages before applying; adapt all intervening Windows/other-agent changes. No force/reset/clean/stash is needed.

## Dependencies and preserved packets

1. Existing b88d2c968 Windows native proxy slice: HTTP adapter, remote API, registered CNR/remote tests and ergopti_system_proxy_worker.ps1. Keep the already-authored native contract assertions.
2. Frozen `windows-curl-auth` manifest d9cf67cbd45094ec312ef295ced6432977e7413b8c5992fce3fbf0ddfe958902. Apply the exact proposed ergopti_curl_capabilities_worker.ps1 and its test_curl_proxy_auth_policy.ahk. Its selector is copied verbatim into this HTTP adapter; **do not include/apply the separate curl_proxy_auth_policy.ahk adapter as well**, which would duplicate the function. Compose only the test include with latest run_all.ahk. Native capability worker test remains unexecuted.
3. Frozen `windows-full-routes` manifest 5558d230624ad9e3d9bf5830f1de661e648f07853a938b7623d6c0fe2edacf26: ordered WinHTTP Ex/helper + actual settings reader and policy proposal. Independent reviewed source findings are cleared; native callbacks/ABI/PAC/WPAD remain unexecuted. Updater staging author has the separate revision with explicit \_SharedDir policy/default paths; compose it without duplicating routing. This packet does not switch remote curl to full ordered Ex routes.
4. Frozen `managed-remote-acceptance` patch b0caa8e845269300356431441b77a8d1d826886ae9a5b75f4bde84b49066f77a: all eight actual remote generation/readiness CA/relay cases, exact root-thumbprint cleanup. Preserve these assertions. The updater extension of that fixture belongs to review_brew_boundary and is separate.
5. `dependencies/ollama-boundaries/REVIEW.md`: authoritative Ollama/Go trust/env/redirect/logging boundaries. Foreign daemons cannot inherit GUI proxy/SSPI/trust policy retroactively; no owned serve lifecycle or full model pull qualification is prepared here.

## Authored integration

The actual build observer is an exact ShellRunner Job whose input contains budget only; child argv is fixed '--disable --version'. Publish its owner before Start, cancel silently on supersession, retain exact late/refused child handles and private cleanup debt, release timer/callback references at terminal retirement. Both former ANYAUTH writers admit sole proxy-negotiate with private proxy-user ':' only after actual Schannel/SSPI/SPNEGO receipt. No combined flags or Basic/Digest/origin integrated credentials. Ambient curl config is disabled.

Generation retains its original reservation deadline, obtains a fresh exact-destination proxy answer after feature observation, checks current settings again before launch, and gives retries unique artifacts. Readiness retains its original 3s deadline across initial proxy lookup, feature observation, fresh proxy lookup and curl; actual CurlAsyncRequest receives that deadline/resolver. Fixed explicit SetProxy callers preserve their manual route semantics. Missing capabilities refuse before payload/provider-token staging. Stronger existing assertions replace only ANYAUTH expectation with sole Negotiate plus downgrade refusal; existing duplicate/cancel/private-argv tests remain.

Eleven authored deterministic owner controls cover both production callers: pending artifacts, duplicate/late receipts, canceled/replaced requests, expired original deadline, missing SSPI/SPNEGO and unfinished feature descendants. These use explicit test ports and are not native wire qualification. Original regression fake ports explicitly supply a capability owner; production has no synthetic default feature receipt.

## Known incomplete boundaries

- No independent review or runtime validation of this integration; parser/behavior defects remain possible. Do not label it ready based on byte inspection.
- b88 SystemProxy_ResolveCurlAsync returns bool and uses a session-shared PAC Job, with its independent 10s lookup budget. Request cancellation/deadline fences its callback but does not physically retire a shared lookup independently when other waiters exist. The smaller readiness budget can expire while the PAC Job finishes under its own owner. Cancelable per-waiter resolver tickets/budgets require a separate coherent owner change and regression proof. Do not kill another request's PAC owner.
- Real Negotiate/NTLM SSPI challenge acceptance, native auth target evidence and downgrade/privacy fixtures are not prepared/executed. NTLM-only HTTP challenge fallback is not implemented. Sole Negotiate may use Windows Negotiate package's NTLM when the server advertises Negotiate; that does not cover an NTLM-only scheme offer.
- Native HTTPS/SOCKS relay capability and full PAC failover remain separate. This current-user integrated auth slice refuses a non-HTTP(S) selected relay; it does not invent support.
- Runtime trust remains enforced; existing best-effort revocation option was preserved, not used to bypass untrusted certificates. Installed package paths and native child deployment still need actual checks.

## Resume on the user's Windows PC

1. Read AGENTS, Windows memory/skills and current group-6 TODO. Fetch current origin/dev, inspect working tree/index, preserve other agents' changes, and compare these exact preimages before rebasing/applying any preparation.
2. Review this WIP's callback/late-handle/debt/timer lifecycle and the eleven controls. Resolve shared PAC per-waiter ownership as its own TODO before claiming physical full-budget cancellation. Keep all original assertion intent. Compose current run_all includes with its owner; do not copy a stale whole run_all file.
3. Install/activate the repository-pinned Windows AutoHotkey/build tools. Run verify-change's selected encoding/static/unit and Windows E2E gates serially; report pass/fail/skip/not-run separately. Fix failures without weakening assertions.
4. Run actual native capability/PAC/CA fixture entrypoints from the real Windows driver. Require exact descendant retirement, cleanup acknowledgments and unique CurrentUser root removal by exact owned thumbprint in finally. Never alter persistent proxy/security settings or disable certificate verification. Unsupported runner capabilities remain failed qualification, not a synthetic success.
5. Author and execute a controlled proxy SSPI challenge fixture through actual generation/readiness (Negotiate, NTLM-only, Basic-only negative, artifact-origin401 negative). Prove native authentication target and no credentials/body in argv/logs. Only then design causal NTLM-only fallback under the same original deadline and after exact preceding child retirement. Do not combine auth CLI flags.
6. Qualify real installed bundle/updater/rollback routing, per-hop PAC/failover, minimum/size/SHA/READY refusal, packaging and installation; compose separate updater and CA-extension packets. For Ollama, verify actual installed version, owned process environment, OS trust, registry+CDN/auth redirect paths and log redaction; preserve foreign daemon ownership and group4 API.
7. Remove only genuinely completed group6 TODO steps after these native checks; commit coherent fixes and follow the user's current integration/workflow authorization. Keep unexecuted Windows tasks explicit.
