<!-- docs/design/proxy-auth-relay.md -->

# Local authenticating relay for NTLM and Negotiate proxies

Status on 2026-10-31. Maintainer decision: Ergopti embeds a local relay for
corporate proxies that answer `407` with `NTLM` or `Negotiate`, instead of
telling users to install Px or Cntlm. Items 62 and the "Ergopti-started Ollama
behind a PAC proxy" entry of `TODO.md` depend on it.

## Problem

Environment-driven clients (the stock Ollama daemon, uv, curl without
`--proxy-negotiate`) send only Basic proxy credentials. A proxy that demands
the user's Windows or Kerberos sign-in refuses them with `407`, so a model pull
fails. Windows WinHTTP downloads already answer the challenge through SSPI; the
daemon Ergopti starts cannot, and today the pull refuses with
`network.failure.proxy_windows_login`.

## Shape

One Go program, `ergopti-proxy-relay`, in the standard-library-only
`native_http` module (`_shared/go/native_http/proxyrelay` and
`cmd/ergopti-proxy-relay`). It is not spliced into the Ollama build (the
splice lists files in `managed_ollama_runtime.json`), and the module keeps no
`require`.

Two subcommands, both given every bound and deadline on the command line by the
caller, which reads them from `_shared/modules/timings/constants.toml`
(`[adapters]` `proxy_relay_*`):

- `probe --upstream URL --authority HOST:PORT`: sends one `CONNECT` through the
  selected proxy and prints one JSON line. `not_needed` when the proxy opens the
  tunnel (or answers anything but `407`, which the client then classifies
  itself); `required` with the scheme when the proxy answered `407` with
  `Negotiate` or `NTLM` and the relay completed the sign-in on that probe, so the
  credentials are proven before a daemon starts; `refused` with a closed reason
  otherwise.
- `run --upstream URL --variable NAME ... -- COMMAND ARGS`: binds
  `127.0.0.1:0`, draws a 32-byte per-run token from `crypto/rand`, sets each
  named variable of the child to `http://ergopti:TOKEN@127.0.0.1:PORT`, starts the
  child with inherited standard streams and exits with its status. The relay is
  the service Ergopti owns, so it stops with Ergopti exactly as the daemon did; a
  terminating signal is forwarded to the child, and on Linux the child also gets
  `Pdeathsig`. The token never leaves the relay and its child: it is not printed,
  logged or written to disk.

The caller runs the relay only when the probe answered `required`. A direct
route, a proxy that needs no sign-in, a Basic proxy with credentials in its URL,
or a proxy the user exported keep their current behaviour.

## Protocol

- Only `CONNECT host:port` is relayed; HTTPS stays end to end, without TLS
  interception. Every managed origin is `https` (`route_plan.lua` refuses
  another scheme), so a plain `GET http://...` is refused with `405`.
- Every client must send `Proxy-Authorization: Basic` with the run token,
  compared in constant time; otherwise `407` and close. Go `net/http` and curl
  send it from the proxy URL's userinfo.
- A peer whose address is not loopback is closed before a byte is read.
- Upstream: `CONNECT` without credentials; on `407` the relay picks `Negotiate`,
  then `NTLM`, from `Proxy-Authenticate`, and answers on the same connection
  (NTLM is connection-bound). A `407` that closes the connection before any token
  was sent is retried once on a new connection. At most
  `max_auth_rounds` legs; a `407` after the last token is `sign_in_rejected`.
- Bounds: response header bytes, 407 body bytes, challenge bytes and legs come
  from `proxy_auth_relay.json`; dial, handshake and tunnel-idle deadlines come
  from the timings registry. A tunnel copies bytes both ways and closes on idle.

## Sign-in backends (never a stored or prompted password)

| OS      | Negotiate                                                      | NTLM                         |
| ------- | -------------------------------------------------------------- | ---------------------------- |
| Windows | SSPI `Negotiate`, current logon (`secur32.dll`, `syscall`)     | SSPI `NTLM`, current logon   |
| macOS   | GSS-API SPNEGO, `GSS.framework` loaded with `dlopen` (cgo)     | refused: `ntlm_requires_windows` |
| Linux   | GSS-API SPNEGO, `libgssapi_krb5.so.2` loaded with `dlopen` (cgo) | refused: `ntlm_requires_windows` |

The service name is `HTTP@<proxy host>`. macOS and Linux use an existing
Kerberos ticket only (`kinit`, Ticket Viewer, SSSD); without one the probe
refuses with `sign_in_unavailable`. NTLM without a password exists only through
the Windows logon session. GSS-API is opened at run time, so no Kerberos
development package is needed to build and a machine without the library gets a
named refusal instead of a loader error. A build without cgo answers
`sign_in_unavailable` for Negotiate on macOS and Linux. No third-party module is
used, so there is no dependency to pin or licence to record.

## Refusals

The closed set is `_shared/modules/network/proxy_auth_relay.json` `refusals`;
each names its locale key under `network.relay.*`. The Go constants are pinned
to it by `contract_test.go`, and the Lua policy (`network/proxy_auth_relay.lua`)
reads the same file. A relay binary that is not installed is the caller's
`relay_unavailable`.

## Security

- Loopback bind and loopback peers only; per-run token; no listener outlives
  the child it serves.
- Logs carry fixed event names and closed reasons only: never a header, token,
  challenge, URL, proxy host or authority. Callers never log the relay URL; it
  only reaches the child environment, as the proxy URL did before.
- Every buffer and leg is bounded; every network wait has a deadline.

## Callers

- Linux: `modules/llm/managed_ollama_proxy.lua` probes the selected relay for
  the registry authority once the route plan settles, and on `required` the
  daemon is started under `run`.
- macOS: the same shared policy; the Debug network check (`field_check_ports.lua`
  route plan port) reports whether the selected proxy needs the relay. The
  daemon start in `network-retry.sh` is generated and follows in its owner.
- Windows: [windows-pc-agent-handoff.md](../tooling/windows-pc-agent-handoff.md)
  (the PC agent owns `.ahk` and the PowerShell route plan).

## Not covered

- Packaging the binary in each release (Linux packages, the macOS app, the
  Windows bundle) and its hosted build cells; until then the caller refuses
  with `relay_unavailable`.
- Channel bindings, Kerberos delegation, and mutual authentication of the
  proxy: the tunnel carries TLS to the origin, which authenticates the origin.
