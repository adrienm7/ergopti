# Actual Windows updater staging acceptance

This three-source scratch tranche composes after the frozen managed-remote CA
fixture and updater revision 3. Exact preimage and candidate hashes are in
`handoff.json`; no repository source or registration was edited and no test or
native command was executed. All existing eight native remote CA assertions and
case bodies are byte-identical. The original fixture service deadline remains
90 seconds in both modes; the original production generation/readiness TLS,
PAC, revocation and cleanup handlers remain.

`ServeUpdater` adds two owned loopback relay listeners, independent GET handlers
and a separate per-URL PAC. Original `Serve` uses its existing three listeners.
The current-user root uses the same unique subject/thumbprint, ephemeral keys,
exact store admission/removal, native event ownership and independent cleanup
acknowledgement. No hosts, DNS, global proxy settings or foreign certificate is
modified. Listener/service errors remain asserted; new diagnostics are only
bounded typed counters. The Basic-only 407 relay refuses any credential header.
Origin challenge handlers refuse any origin/proxy authorization header.

The new native owner calls the actual `_Updater_BuildStagingTransport` and
`_Updater_BuildStagingWorkerScript`, with the existing private inherited payload
and exact shared/vendor paths. It adds only declared trusted ScriptBlock config
and environment callbacks to the real invocation. These create fresh owned PAC
snapshots and isolate inherited runner overrides; no network transport, native
WinHTTP method, size/hash/READY check or generated worker body is replaced.
Controlled snapshots qualify native selection machinery and exact per-hop URL
routing, **not global WinINet settings-reader discovery**.

The controller independently fixes body bytes (0..255 repeated 2048 times),
524288 length and SHA-256
`33bc8aab40703678c3ebe94d2dd8f2afff285dd901f9234e841e4679f8204fd5`.
It never derives integrity expectations from downloaded files or the worker.
Ten authored actual staging cases demand:

- Untrusted system-store TLS refusal before HTTP; then owned root admission and
  real production download, digest, persisted swap input and exact READY.
- A redirect that acquires the first relay and a final full path/query that
  independently selects the second relay, proven by exact counter deltas.
- Same-size altered bytes, small body, truncated Content-Length, origin401/403,
  Basic-only relay407, and actual owned-directory-as-file denial. Refusals keep
  the exact existing executable sentinel bytes and remove staged/swap inputs.
- Exact root removal restores TLS refusal, zero origin credentials and no
  Basic downgrade. Selected relay/status cannot fabricate proxy/CONNECT cause.

A second warm fixture separately qualifies real parent cancellation and absolute
monotonic deadline. It runs the actual generated slow-body download in a real
private Job, publishes that real handle/original tick into the parent transaction,
and calls the actual parent cancellation/deadline functions. It requires native
TreeQuiesced (Job empty, root exited, handles closed), partial input removal,
exact old bytes, no swap, one failed terminal and idempotent cancellation. No
synthetic Job closure or clock sample supplies success. The real original tick
feeds both parent and helper; the shorter controlled budget changes only this
qualification transaction. An independent fixture ledger retains every worker
and certificate/event/input owner even when production cancellation or an
assertion refuses. A native failure must be repaired, never loosened.

This is authored source, **not passed acceptance**. The new C# and AHK sources
have not been compiled or executed. Native budgets/real PowerShell startup,
actual .NET CONNECT407 response receipt and WinHTTP HTTPS full-URL PAC behavior
must be observed on Windows. Real Negotiate/NTLM authenticated relay success and
connection-bound handshake lifetime remain separate prerequisites. No Basic or
Digest fallback/origin credentials/TLS bypass is allowed. The bytes are an
independent staging fixture, not a signed PE/application version; swap execution,
packaging and full actual installation/rollback are separate existing native
qualification obligations. This tranche alone does not complete TODO62.

Root owns registration: add the new unit include after the existing native
remote fixture test so its owned fixture classes are available, and add its test
suite manifest entry using the existing registration generator/workflow. The
shared contract and revision3 sources must be staged together with canonical
route modules/policy data before bundle checks. Preserve every older assertion.
