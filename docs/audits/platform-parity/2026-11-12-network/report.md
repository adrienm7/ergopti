# Network: proxies, trust, deadlines and downloads

Audited source: `b8b55835` (`claude/ergopti-todo-parity-audit`). Date:
November 12, 2026.

## Scope

Proxy detection and authentication, loopback exemptions, PAC, TLS trust,
request deadlines, offline reporting, download integrity and request privacy,
against the Windows reference (`windows/vendor/ergopti_network_routes.ps1`,
`windows/vendor/ergopti_winhttp_transport.ps1`,
`windows/modules/llm/api_ollama/init.ahk`, `windows/modules/updater/core.ahk`).
Findings already filed by the 2026-11-11 updater, adapters and AI-flows
reports and by the maintainer decisions are not repeated. No network request
was made.

## Fixed

| Id      | OS             | Sequence                                                        | Windows                                                                                 | Before                                                                          | Regression                             |
| ------- | -------------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------- |
| NET-002 | Linux          | Any Ergopti request behind a Kerberos (Negotiate) company proxy | WinHTTP answers the challenge with the signed-in user (`winhttp_transport.ps1:383-387`) | 407 on every request but the Ollama pull                                        | `net-002-proxy-negotiate`              |
| NET-003 | macOS, Linux   | First prediction on a CPU-only machine (cold model load)        | 180 s (`api_ollama/init.ahk:471`)                                                       | Killed at 30 s (Linux, remote budget) or 60 s (macOS, typed)                    | `net-003-ollama-deadline`              |
| NET-004 | Linux          | (code health) an unread release download timeout                | —                                                                                       | `DOWNLOAD_TIMEOUT_MS` copy of the shared transfer budget                        | `test-updater-constants-single-source` |
| NET-006 | Linux AppImage | Any HTTPS request on openSUSE                                   | The Windows certificate store                                                           | No candidate CA bundle (`/etc/ssl/ca-bundle.pem` missing): every request failed | `test-linux-portable-network-runtime`  |

NET-002 adds `proxy-anyauth` and an empty `proxy-user` only for a selected
proxy whose URL carries no credentials, and only when the probed curl reports
SPNEGO, GSS-API or Kerberos; NTLM stays refused (`docs/design/proxy-auth-relay.md`).
NET-003 is `[llm] ollama_request_timeout_ms`; the macOS connect timeout reads
`stream_connect_timeout_ms`.

## Open

- **NET-001 (macOS, medium):** the owned Karabiner runtime artifact
  (`platform/remap/runtime_artifact_fetch.lua`), the VirtualHIDDevice package
  (`runtime_vhid_update.lua`) and the Karabiner DMG (`onboarding.lua`, without
  `--proto =https`) run `/usr/bin/curl` without the `network_env` prelude, so
  a Mac that only reaches the internet through its proxy cannot install the
  remap engine and is told it is offline. The fix runs each through the
  prelude with a `route_origins.json` client and the shared failure classes;
  left for its own batch.
- **NET-003 follow-up (macOS):** the 12 s no-token streaming watchdog still
  ends a cold load before its first token; the registry comment claims an AHK
  equivalent that no Windows or Linux code reads. Needs a cross-driver
  decision.
- **NET-004 (macOS, Windows):** the macOS release download keeps a typed
  900 s budget (`release_installer.lua`, `release_stage.sh`) and Windows 600 s
  receive and 1,200 s absolute, while the shared `archive_transfer.archive` is
  300 s. Which value is right is a maintainer decision.
- **NET-005 (macOS, low, plausible):** `system_network_from_scutil` reads
  `ExcludeSimpleHostnames` for the fingerprint only, so a short internal host
  goes through the proxy where Windows' `<local>` bypass sends it direct.

## Checked and kept

- Loopback is always direct (`proxy_policy.route`), Linux writes
  `proxy=""`/`noproxy="*"`.
- PAC: Linux evaluates it in Duktape, macOS through `--managed-proxy-route`,
  Windows through `WinHttpGetProxyForUrlEx`, all with the shared fallback
  stages.
- Certificate verification is never disabled on any driver.
- The Gemini `?key=` URL is redacted before logging on every driver, and on
  Linux URLs and headers reach curl through a stdin config.
- Every managed download is checked against a pinned or published SHA-256 and
  size, staged under `.partial`.
- Prediction failure notices are shown only for manual requests.
