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

## Fixed after review

- **NET-001 (macOS):** the owned Karabiner runtime artifact, the
  VirtualHIDDevice package and the Karabiner DMG ran `/usr/bin/curl` with the
  inherited Hammerspoon environment (no proxy), the DMG without
  `--proto =https`, so a Mac that reaches the internet only through its proxy
  could not install the remap engine and was told it was offline.
  `platform/remap/network_download.lua` now runs each behind the opaque system
  network prelude for the new `karabiner` client of `route_origins.json`
  (GitHub's release origins) and names a refused route by its shared managed
  network class. Regressions `net-001-remap-route` (route command, wiring,
  the DMG pipeline over https only).

- **NET-003 follow-up (macOS), decided by the maintainer on 2026-11-12:** the
  12 s no-token streaming watchdog is removed with `[llm] stream_watchdog_ms`;
  only the request's own deadline ends a slow stream, as on Windows and Linux.
  Regression `stream-watchdog-removed`.
- **NET-004, decided by the maintainer on 2026-11-12:** the release archive is
  bounded by one shared declaration aligned on Windows, `archive_transfer`
  `phase_timeout_ms.archive = 1200000` and `archive_idle_timeout_ms = 600000`,
  read on Linux (curl's speed bound) and macOS (staging script and launcher
  request) and Windows (the generated `UpdateArchiveTransferData()`). Regression
  `release-archive-budget`.

## Open

- **NET-005 (macOS, low, plausible):** `system_network_from_scutil` reads
  `ExcludeSimpleHostnames` for the fingerprint only, so a short internal host
  goes through the proxy where Windows' `<local>` bypass sends it direct.
  `NO_PROXY` has no syntax for every single-label host, so curl, uv and Python
  children cannot be told through the environment; the fix is a route-plan
  step that sends a dot-free target origin direct, which needs each child's
  target hosts at prelude time.

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
