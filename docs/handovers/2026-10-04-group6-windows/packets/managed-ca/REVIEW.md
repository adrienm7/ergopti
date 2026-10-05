<!-- Scratch candidate; not integrated or natively qualified. -->

# Windows managed remote acceptance candidate

This tranche adds one registered native acceptance test, one owned PowerShell fixture,
and one include in `windows/tests/run_all.ahk`. It does not change production transport.
It complements commit `b88d2c9689c5b7f05f8345e62ce642c782390e8d` and retains its assertions.

The only request seam is the user-settings reader supplied to the real
`SystemProxy_ResolveCurlAsync`. Its native worker, WinHTTP PAC evaluation, explicit
process-environment precedence, curl executable, private curl config, native process
owners, pollers, response parser and readiness HTTP implementation remain live.
The generation entrypoint is `_LLMRemote_DispatchCurl` with its real reservation;
readiness uses `LLM_RemoteIsReady_Async` with a unique temporary provider entry.
No `run`, `poll`, `write`, `create_http`, terminal-receipt or transport seam is supplied.

One warm PowerShell child starts three owned loopback listeners: an HTTPS endpoint,
a CONNECT relay and a PAC/CRL server. The reserved hostname `managed-fixture.invalid`
resolves only inside the relay to its owned TLS listener; no DNS or hosts-file changes
occur. The PAC script allows the exact generation URL including its query and the
exact readiness path, and otherwise names a refused endpoint.

The fixture generates ephemeral CNG root/leaf keys, verifies their ephemeral status,
and installs only its public root in CurrentUser/Root. A unique subject and exact
thumbprint are latched before the controller can signal installation. Borrowed
certificates and system proxy settings are untouched. A signed empty CRL allows the
existing strict Schannel revocation policy to operate; no curl verification/revocation
bypass flag or trust callback is added. The actual shipped System32 curl version must
report Schannel. Native Cryptnet may cache the generated public CRL normally; the test
does not delete shared native caches.

Eight production requests cover generation and readiness before trust (refused),
after trust through a static relay (success), after trust through native PAC (success),
and after exact root removal (refused). Successful requests must pass the real
Authorization and JSON-body checks at the TLS server and the production response
parser. Counters prove all requests use the relay, native PAC was fetched, actual CRL
fetching occurred and no authenticated HTTP request arrived outside trusted phases.
Native service errors or failed graceful shutdown remain red after recovery cleanup.

The fixture has a 90-second server lifetime. Startup allows 20 seconds, generation
has a production 15-second deadline, readiness keeps shipped timing limits, individual
controller waits are bounded, and shutdown/independent cleanup have 8/15-second budgets.
The expected healthy wall time is approximately 30–60 seconds including Add-Type;
this estimate is not a measurement. A failed request stops the test immediately.

Cleanup retires only captured generation reservations, exact readiness cancel
closures, exact PAC worker handles and this fixture's URL-matched HTTP cleanup debts.
The server Job must acknowledge physical descendant quiescence before an independent
bounded PowerShell cleanup child reopens CurrentUser/Root and verifies exact-thumbprint
absence. Events and private state are released afterwards. Refused cleanup retains
its fixture object and retries, including an OnExit retry; it fails the test rather
than turning cleanup debt into success. A test-process hard kill can prevent OnExit,
so CI must not impose an outer timeout shorter than this test's cleanup budgets.

`run_all.ahk` is concurrently owned by group 4. The snapshot in `proposed/` is only
an exact-preimage proposal; the coordinator must compose its one include with the
latest AI-group registration before integration. No shared manifest, locales,
schema, workflow or TODO block is modified by this tranche.

## Qualification status

Native execution is **not run** in this Linux container: AutoHotkey, Windows
PowerShell/.NET Framework, Schannel and the Windows certificate store are unavailable.
The candidate needs real Windows compile/unit/native acceptance, then the existing
Windows E2E and packaging checks selected by verify-change. Neither source review nor
standalone curl execution would establish these claims.

Explicit inherited HTTPS/ALL proxy or NO_PROXY overrides make the controlled
qualification fail with a names-only diagnostic. They are neither cleared nor
mocked. Real current-user integrated authentication, managed WPAD discovery, OS proxy
setting changes, ordered PAC failover, updater/rollback staging and Ollama pulls are
outside this tranche and remain unqualified.
