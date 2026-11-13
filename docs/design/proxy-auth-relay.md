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
`native_http` module (`_shared/core/network/native/go/native_http/proxyrelay` and
`cmd/ergopti-proxy-relay`). It is not spliced into the Ollama build (the
splice lists files in `managed_ollama_runtime.json`), and the module keeps no
`require`.

Two subcommands, both given every bound and deadline on the command line by the
caller, which reads them from `_shared/core/timing/data/constants.toml`
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

| OS      | Negotiate                                                        | NTLM                             |
| ------- | ---------------------------------------------------------------- | -------------------------------- |
| Windows | SSPI `Negotiate`, current logon (`secur32.dll`, `syscall`)       | SSPI `NTLM`, current logon       |
| macOS   | GSS-API SPNEGO, `GSS.framework` loaded with `dlopen` (cgo)       | refused: `ntlm_requires_windows` |
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

The closed set is `_shared/core/network/data/proxy_auth_relay.json` `refusals`;
each names its locale key under `network.relay.*`. The Go constants are pinned
to it by `contract_test.go`, and the Lua policy (`network/proxy_auth_relay.lua`)
reads the same file. A relay that ran but did not answer by contract (a crash,
a timeout, a foreign line) is the caller's `relay_unavailable`. A relay binary
that is not installed is the binding's `not_installed` status, not a refusal:
the client keeps the proxy as named, as before the relay existed, with one
WARNING, and the network check reports `relay_not_installed`. Every Linux
package, the macOS application and the Windows bundle ship the relay;
`not_installed` remains for a source checkout.

## Security

- Loopback bind and loopback peers only; per-run token; no listener outlives
  the child it serves.
- Logs carry fixed event names and closed reasons only: never a header, token,
  challenge, URL, proxy host or authority. Callers never log the relay URL; it
  only reaches the child environment, as the proxy URL did before.
- Every buffer and leg is bounded; every network wait has a deadline.

## Callers

A refused sign-in means the same on all three (maintainer decision, 2026-11-01): the
managed daemon starts without the proxy, so the models on disk keep working; a receipt
names the closed reason; only the pull is refused, with that reason's message.

- Linux: `modules/llm/managed_ollama_proxy.lua` probes the selected relay for
  the registry authority once the route plan settles, and on `required` the
  daemon is started under `run`. On a refusal the repair result carries
  `relay_refusal` and `ollama_install_state` holds it for that daemon's origin;
  `model_download` refuses there, and on its retry.
- macOS: the stock daemon start (`modules/llm/ollama_server_command.lua`) runs
  `ollama serve` through `run_with_proxy_sign_in_relay` (`network-retry.sh`),
  which probes the relay the system settings named and, on `required`, starts
  the daemon under `run`. The receipt is a file each start removes first
  (`modules/llm/proxy_relay_receipt.lua`), read by the pull of a daemon Ergopti
  started; the user's own Ollama has its own network settings and is not refused.
  The Debug network check reports the same probe (`proxy_relay`). The Swift-owned
  managed daemon (`managed_ollama_serve.py`) does not use the relay yet, so it has
  no refusal to record; see "macOS managed daemon" below.
- Windows: `ollama-runtime-launch.ps1` runs the same probe where the tunnel probe
  answers `windows_login`, and on `required` starts the daemon under `run`, the
  listener admitted only as the child of that exact relay from the admitted image.
  The receipt is the runtime's (`proxy_relay`); the live evidence is in
  [proxy-relay-testing.md](../tooling/proxy-relay-testing.md).

## macOS managed daemon (design, not built)

`run` makes the relay the daemon's parent, which the managed path cannot accept:
`SuspendedImageOwner` starts the exact verified image itself, suspended, and retires
that one child. So the relay is the daemon's sibling, under the same owner.

- **Who launches it.** The Swift worker behind `SuspendedImageOwner`, before it
  resumes the daemon, so one owner ends both and a quit leaves neither behind. Python
  stays out of the process tree; it only decides, as below.
- **Go.** A new `listen` command beside `run`: bind `127.0.0.1:0`, print one JSON line
  with the port and the per-run token, serve until stdin reaches EOF. The EOF is how
  the relay dies with its owner, and `run` stays as it is for the other callers.
- **Probe.** `managed_ollama_serve.py` asks the same `probe` once it has captured the
  route and before it writes the bootstrap snapshot. `not_needed` changes nothing.
  `required` marks the snapshot, and the worker replaces the relay route with the
  local one from `listen`, never logging the token.
- **Refusal.** Lua passes the path of `proxy_relay_receipt` to the serve owner as an
  argument. A refused probe writes the closed reason there and captures a snapshot
  with no relay, the same outcome as `start_without_proxy_after_refusal`. A refusal of
  `listen` comes back to Python in the worker's result and ends in the same receipt,
  so the pull reads one file whichever owner started the daemon.

The relay inherits the launcher's bundle admission (`managed_bootstrap_launcher_available`
for the shell path); the Swift side must resolve it beside the admitted launcher too.

## Packaging

`tools/build/build-proxy-relay.sh` is the one builder: offline, cgo required,
no-replace output, a smoke run of the host slice. CI installs the repository's
one Go pin (`managed_ollama_runtime.json` `go_version`) or the module's
`go.mod` floor through `actions/setup-go`.

- Linux: `build-linux-driver.sh` builds it into `linux/bin/`, beside the archive
  backend, so the .deb, .rpm, tarball and AppImage carry it at
  `<driver>/bin/ergopti-proxy-relay`. It needs at most `GLIBC_2.34` and only
  `libc.so.6` (`check-elf-glibc-ceiling.cjs`). The Flatpak never takes a
  host-built ELF: it rebuilds the relay from the shipped Go sources with the
  SDK's `org.freedesktop.Sdk.Extension.golang`.
- Windows: `tools/build/build_windows_proxy_relay.ps1` builds the amd64 binary with
  the Go pin, without cgo, and publishes it with its manifest into `windows/vendor`,
  committed like the PAC worker. The owner passes the manifest's digest and the
  launcher refuses another image. Nested vendor binaries ship unsigned for now.
- macOS: `build_macos_app.sh` builds an arm64 and an x86_64 slice with each
  architecture's clang, joins them with `lipo` into
  `Contents/MacOS/ergopti-proxy-relay` and signs it as nested code before the
  launcher, in the full application and the Git-checkout helper. A developer app
  needs no installed Go: `tools/dev/macos_dev_go.py` hands it the pin, downloaded
  by digest into `build/macos-dev-go`. When that fails the build says so and the
  developer app goes without the relay, which then reports `not_installed`; a
  release build still requires it.

## Not covered

- Channel bindings, Kerberos delegation, and mutual authentication of the
  proxy: the tunnel carries TLS to the origin, which authenticates the origin.
