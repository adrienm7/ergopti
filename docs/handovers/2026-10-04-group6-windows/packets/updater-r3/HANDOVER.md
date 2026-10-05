# Windows active updater staging revision 3

This seven-source scratch packet supersedes `../handoff.json` revision 2.
Preimages remain exact b88d2c9689c5b7f05f8345e62ce642c782390e8d bytes.
No repository edits or tests were performed. Apply only after coordinating root
source ownership and latest HEAD preimages. The native factor still preserves
all existing C# definition bytes and every existing native fixture assertion.

The prior packet's architecture and ownership seams remain. This revision:

- Checks the original parent monotonic deadline at completion admission before
  clearing the owned worker or stopping its monitor. Expired READY cannot reach
  installation/swap. Expected staging epoch fences cancellation of a successor.
- Passes that original tick into the actual private staging worker; native
  GetTickCount64 measures its remaining budget before routing, reads, after EOF,
  flush, hash and swap-worker persistence. Startup never grants another budget.
- Carries the exact failed owner into the existing Critical reservation boundary.
  That boundary compares current identity, epoch and Request before retiring only
  that owner or reserving the retry. Preliminary validation cannot revoke a later
  terminal owner. Exact retirement also refuses a foreign expected object.
- Passes proxy policy and updater defaults paths explicitly from `_SharedDir`.
  Installed bundles relocate `vendor`; checkout-relative helper defaults would
  be incorrect. No cwd, environment-selected policy path or silent fallback is
  introduced.
- Offers only optional trusted ScriptBlock config/environment readers, null in
  production. An owned acceptance harness may supply fresh controlled PAC
  snapshots while exercising real native WinHTTP and actual download/integrity
  mechanics. This cannot qualify actual system settings discovery.
- Preserves canonical resolver primary Receipt and its private CleanupDebt flag
  as optional `native_cleanup_debt` in the private failed envelope. No shared
  receipt field or imaginary cleanup resource is added. Token admission requires
  an actual JSON boolean and unique top-level fields, rather than AHK integer
  truthiness. The native helper cannot claim callback/handle retirement when the
  canonical resolver refuses it. Only the existing parent Job-quiescence callback
  proves that the worker and descendants physically retired before retry.

The compact production script is 2,936 characters, 7,832 UTF-16 Base64 characters,
under the unchanged 8,191 per-value environment cap. Original size, independent
trusted SHA-256, Content-Length, READY and separate swap lifecycle checks remain.
The fifteen authored PowerShell controls include one real owned-file permission
operation and native monotonic clock checks; synthetic typed disposal/resolver
controls do not prove real TLS, proxy authentication or WinHTTP closure. Eight
AHK tests include independent literal envelope inputs plus causal late-READY and
replaced-owner reservation regressions. All are **unexecuted**.

Required qualification remains Windows native AHK/PowerShell, actual controlled
CA/PAC/CONNECT downloads and trust refusal, redirect routing, HTTP407 versus
origin401, real integrity/file denial and old-version preservation. Actual SSPI
Negotiate/NTLM challenge success and connection-bound handshake lifetime require
wire observations; current KeepAlive=false has not been qualified for that.
SOCKS and HTTPS WebProxy transports remain honestly unavailable and fail closed.
No Basic/Digest downgrade, origin credentials or TLS bypass is permitted.

Root-owned canonical route files, shared JSON amendments, Windows safe presenter,
Versions capability wiring, registration and JS/native gates are dependencies;
this packet alone does not complete TODO62.
