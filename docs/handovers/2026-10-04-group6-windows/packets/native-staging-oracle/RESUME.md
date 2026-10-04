# Resume deferred Windows qualification on the user's PC

All Windows runtime candidates here are **prepared, uncompiled and unexecuted**.
No native test, AHK suite or production download was run by this author. Keep
TODO62 open; portable/model success cannot replace the following native gates.
The Windows candidates must remain a saved handover until qualification succeeds.

1. Fetch the latest `origin/dev` and create an isolated owned Windows checkout.
   Read AGENTS/memory/verify-change first; inspect existing work and coordinate
   shared-file ownership. Verify saved patch preimages and source SHA256 values
   before applying anything. Preserve old assertions, independent corpora, BOM/LF
   and the existing 8191-character staging transport cap.
2. Compose the exact dependencies as one reviewable Windows tranche: canonical
   shared network policy (including redirects.max_hops and environment bypass
   precedence); audit_network62's native WinINet settings reader, ordered WinHTTP
   Ex worker and full-route helper; byte-identical legacy native proxy factor;
   updater revision3; shared failure contract/Windows presenter and native-only
   Versions owner bindings; existing managed-remote CA fixture; new native staging
   acceptance; then the separate terminal-oracle correction. The current routes
   `SHA256SUMS` inventory hashes to
   `5558d230624ad9e3d9bf5830f1de661e648f07853a938b7623d6c0fe2edacf26`
   (its later bundle-path correction supersedes the previously advertised 62dca
   inventory). Updater revision3 manifest:
   `8402ac0a281f0a8a79ae27bc38eb101039336362ff04b1a1b3ff169ea8958bdc`;
   native staging base manifest:
   `15ff8901aa4d85d3bec5bda25cf0f741c4307a8208d055ac1af760fc7d0f2055`;
   terminal correction manifest:
   `8641ff3d6a4a72290d501b834841d17de80eb6cf66211b2736e803dae5e3863e`.
   Recheck dependency source hashes against the preserved inventory before use.
3. Register both new unit files and actual native fixtures through the repository's
   existing suite manifest/include owner/generator. Verify installed bundle paths:
   vendor modules relocate while shared JSON lives beneath static/ergopti_plus;
   updater paths must come explicitly from `_SharedDir`. Run selected verify-change
   gates through RTK, then the real AutoHotkey v2/PowerShell Windows suite using the
   existing ci-windows.yml native launch procedure. Do not run JS drift checks
   concurrently with native gates.
4. Qualify the actual WinINet configuration reader separately, then native ordered
   PAC/static/env selection and callback/HANDLE_CLOSING retirement. Controlled
   test ReadConfig/ReadEnvironment callbacks exercise real WinHTTP machinery;
   they cannot prove system setting discovery. Require actual native closing
   receipts, zero active callbacks and exact operation/epoch refusal behavior.
5. Run the unchanged eight managed-remote CA cases, the fifteen updater receipt
   controls, eight caller controls and the ten actual generated staging cases.
   Require rejected certificate, owned-root trusted download/digest/persisted READY,
   exact per-hop PAC relays, size/hash/truncation/file denial, HTTP407 versus origin
   401/403 without guessed proxy cause, exact old executable sentinel bytes and
   independent certificate/service/event/input retirement. Store/policy admission
   failures remain failures; never bypass TLS or mutate unrelated roots/proxies.
6. Run real parent cancellation and monotonic deadline over live slow-body Jobs.
   `terminate()` suppresses OnDone by contract; require the exact native terminal
   claim's TreeQuiesced, NativeExitObserved, zero process/thread/job handles,
   no native errors, nonzero exit, partial removal, no swap and one failed terminal.
   Never fabricate a completion callback or a cleanup ACK. Fix actual retirement
   refusal while preserving primary deadline/cancellation evidence and retained
   owners. The separately frozen correction leaves all eight original remote
   assertions unchanged.
7. Add/qualify a real owned Negotiate/NTLM proxy challenge exchange. Current
   CredentialCache is proxy-only Negotiate/NTLM, origin credentials are disabled
   and Basic/Digest must remain rejected. Prove connection-bound NTLM lifetime
   with the current KeepAlive=false/unique connection group rather than assuming
   it; Basic-only407 refusal does not prove SSPI success. SOCKS/HTTPS WebProxy
   transports currently refuse honestly. Also qualify the actual signed PE
   packaging/install/rollback path: fixture sentinel/body bytes prove staging
   preservation, not an installed application version or swap success.
8. Save exact tested SHA, native receipts and separate passed/failed/skipped/not-run
   results. Integrate only qualified sources with the group's serialized ci-lock /
   ci-validation protocol, cancel automatic exact-SHA workflows and use manual
   non-release Windows qualification. Shared driver changes require every affected
   OS. Keep unfinished Windows steps in TODO62 until their full required scope
   passes, with no deletion of transversal validation items16/38.
