# Windows integrated curl authentication boundary

Scratch-only feature producer + pure admission candidate. No repository edits or suites; no native compile/probe/auth request was executed. Not integrated and not a completed fix.

## Authoritative boundary

Pinned curl source HEAD 61a31e02be295596a0a20b692df585fd498bdb7b (`src/config2setopts.c` 859-868), and curl-8_13_0 ea9d0dd523e7b4e166e3d3325ca31def3359017c (`src/tool_operate.c` 976-985), use an else-if chain: ANYAUTH wins, then Negotiate, then NTLM. Combining CLI flags cannot express a Negotiate|NTLM allowlist. Existing production proxy-anyauth + proxy-user ':' therefore does not establish a no-Basic/Digest policy. Docs/cmdline-opts/proxy-user.md permits ':' current-user selection for Windows SSPI Negotiate/NTLM; credentials belong in private config, never argv. PAC AutoLogonIfChallenged authenticates PAC retrieval, not curl transport.

## Candidate seam and mandatory integration

The PowerShell feature worker must itself run inside the exact request-owned ShellRunner Job under the original generation/readiness deadline. Input JSON contains schema_version=1 and remaining budget_ms only. It executes the real System32 curl binary with fixed '--disable --version', observes actual Schannel/SSPI/SPNEGO/NTLM flags, physically retires that child, emits only a bounded capability receipt. No raw output/exception/environment is published. '--disable' suppresses curl's ambient config even for the probe. FileGetVersion remains only the separate minimum-version size-limit gate.

The pure AHK selector admits one proxy-negotiate + private proxy-user ':' configuration only after an owned ready capability receipt proves actual Schannel+SSPI+SPNEGO and child_quiesced. Neither a generic map nor a caller-supplied test value is production admission: integration must bind receipt to exact reserved generation/request, cancel on supersession, refuse after original total deadline, retire exact probe Job before dispatch/retry, and preserve private cleanup debt. No synchronous version subprocess on the input thread. Cacheless observation initially avoids binary freshness claims. Direct routes and explicit environment credentials require separate existing-policy handling.

Authored registered-test proposal includes actual System32 capability worker execution and native Schannel/SSPI/SPNEGO assertions with bounded exact Job/capture cleanup. It is not executed; unsupported runner capabilities remain failed qualification rather than skipped or manufactured receipt. Pure controls refuse missing features/non-native backend/unretired child/string-valued feature forgery, and deny ANYAUTH/Basic/Digest/origin user options. These controls do not substitute for proxy challenge acceptance.

Root must replace BOTH existing production proxy-anyauth writers (http_client.ahk CurlAsyncRequest.Send and api_remote.ahk \_LLMRemote_DispatchCurl) with owned asynchronous capability admission before staging launch config. Existing cancellation/readiness/output-limit/reservation assertions remain registered and unchanged. New source and producer alone are not a production patch. AHK include/registered tests must be composed with latest run_all owner.

## Remaining NTLM-only path

Sole proxy-negotiate can use Windows Negotiate package's Kerberos/NTLM selection when the proxy advertises Negotiate. A proxy advertising only the HTTP NTLM scheme needs a separate sole proxy-ntlm attempt. Permit that only with an observed native CONNECT407, bounded parsed Proxy-Authenticate NTLM challenge, zero delivered origin/body bytes, actual SSPI+NTLM feature receipt, physically retired preceding curl child, and the same owned request/config/deadline. Plain HTTP407 alone cannot prove proxy authentication target; do not infer it from an admitted relay or familiar backend. No Basic/Digest attempt, no origin credentials, no retry of origin401/TLS/body errors. This fallback is not authored here.

## Native qualification still required

Actual production generation + readiness through an owned CONNECT proxy implementing SSPI AcceptSecurityContext for Negotiate and NTLM; successful native context token must match current-user SID without publishing token/user identity. Add negative Basic-only/downgrade and artifact-origin401 cases; tokens stay in memory/private configs and out of argv/logs. Use one warm owned CA/relay fixture revision, preserving all frozen CA cases and exact root-thumbprint cleanup. TCP SSPI avoids HTTP.sys URL ACL/security policy changes. Workgroup/loopback NTLM reflection policies can cause legitimate refusal; never disable them to make CI pass. Authenticating curl alone is not production-entrypoint acceptance. No auth or CA success is claimed yet.

Review considerations: producer compile/startup cost must count inside parent total budget; parent Job is the hard physical fence if native child cannot exit inside the budget. The worker emits child_quiesced=false and unavailable, never success, on retirement failure. Worker startup failure is capability unavailable rather than an invented network/TLS/auth failure receipt.
