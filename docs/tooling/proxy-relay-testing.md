<!-- docs/tooling/proxy-relay-testing.md -->

# Building and testing the proxy sign-in relay on Windows

The design is [proxy-auth-relay.md](../design/proxy-auth-relay.md). This page says
how to build the Windows binary and how to prove it without a company network.

## Go toolchain

The only Go that builds the committed binary is the repository's one pin,
`managed_ollama_runtime.json` `go_version`; another compiler gives other bytes. It
needs no administrator and changes no machine setting:

1. Read the file name and SHA-256 of the pin from
   `https://go.dev/dl/?mode=json&include=all` (`windows`, `amd64`, `archive`).
2. Download `https://go.dev/dl/<file>` and refuse any other SHA-256.
3. Extract its `go` folder to `%LOCALAPPDATA%\Programs\go-<version>`. Do not touch
   `PATH`: the builder and the end-to-end test look there first.

## Building the binary

`npm run build:windows-proxy-relay` (`tools/build/build_windows_proxy_relay.ps1
-Publish`) writes `windows/vendor/ergopti-proxy-relay.exe` and its manifest
`ergopti-proxy-relay.json`, both committed like the PAC worker. The build is
offline, without cgo, with `-trimpath -buildvcs=false -ldflags="-s -w -buildid="`,
so the same pin gives the same bytes on any host. After editing the relay's Go,
rebuild: `test-windows-proxy-relay-bundle.cjs` fails on every OS until the
fingerprint matches, and the CI package job rebuilds with `-Verify`. The launcher
refuses a binary whose digest is not the manifest's.

The binary is amd64 only; Windows on Arm runs it under emulation, as it runs the
AutoHotkey driver and the PAC worker. Like the other nested vendor binaries it ships
unsigned: signing nested files needs a second SignPath request
([signpath-foundation-application.md](signpath-foundation-application.md)).

## The fake corporate network

`npm run tool:fake-network -- --mode=ntlm [--registry-mode=digest_mismatch]` serves a
loopback CONNECT proxy, a PAC and WPAD file server and an Ollama-like registry over
TLS, prints their addresses and the test credentials as one JSON line, and stops when
its standard input closes. Node only, ephemeral ports on 127.0.0.1, so no firewall
prompt and no real network: a tunnel only reaches the fake registry, whatever host it
names. `tools/test/lib/fake-network.cjs` holds the same pieces for a test, and
`test-fake-network.cjs` proves they tell right from wrong (a wrong NTLM password is
refused). The modes are `PROXY_MODES` in that file: open, Basic, NTLM and Negotiate
with the known credential or (`*_logon`) with any well-formed answer, a sign-in that
hangs or drops, Digest, refusing, slow, dropping.

## The end-to-end test

`npm run test:windows-proxy-relay-e2e`, about five minutes. It runs the bundled relay,
the real launcher, pull worker, managed file helper and PAC worker, with a stub daemon
(`tools/test/fixtures/ollama-stub`, Go `net/http` as in the real one) published
through the real archive path, in a private `%LOCALAPPDATA%\ergopti-relay-e2e-*` root.
Only the WinINet reader in a private vendor copy differs, because the real one reads
the user's proxy settings. The sign-in is real SSPI: most cases run in a
`LOGON_NETCREDENTIALS_ONLY` session (the `runas /netonly` mechanism), so the fake proxy
verifies the NTLMv2 proof against the known test password; two cases sign in as the
real user and check the shape only, and neither token nor name is ever stored.

A missing prerequisite prints `NOT EXECUTED` with its reason and the footer counts it;
CI passes `--required`, which fails on one.

What it does not prove: a real domain controller or Kerberos (without a domain, SSPI's
Negotiate falls back to raw NTLM), a TLS-inspecting proxy, the WPAD discovery itself
(the PAC is named, never discovered) and a corporate policy that blocks NTLM.

## The real daemon

`node tools/test/fetch-real-ollama.cjs` downloads the official Windows release of the
pin (`ollama_release.json`), refuses any other SHA-256 and unpacks `ollama.exe` and its
CPU libraries (67 MB; the GPU libraries are what makes the archive 1.4 GB) into
`%LOCALAPPDATA%\Programs\ergopti-ollama-e2e-<version>`. The same end-to-end test then
adds its `real daemon` rows; `--only="real daemon"` runs those alone, in about two
minutes. Without the folder one row prints `NOT EXECUTED`, which `--required` does not
count: CI stays independent of the network.

The rows publish the release through the real archive path and start it under the real
launcher, with a generated GGUF of 27 KB (`tools/test/lib/tiny-gguf.cjs`) that loads and
really infers: a pull, a digest mismatch failing twice then healing, a refused relay
with the daemon still answering, quit during a pull with the real CLI, and the socks and
https overrides. The daemon's home is the profile, so a user's `.ollama` stays untouched.

Two limits come from the daemon, not from the test:

- Go on Windows checks TLS only against the system store, and the test installs no
  root. Through HTTPS_PROXY, the relay and the socks override the rows therefore stop at
  the daemon's refusal of the test certificate, after showing its own ClientHello
  reached the registry. The complete pulls use Ollama's documented insecure registry,
  over plain http through HTTP_PROXY, by the API or by `ollama pull --insecure`. So no
  complete pull has gone through the relay, which accepts CONNECT only, and the real
  pull worker has only run to that refusal.
- **Ollama 0.40.4 fetched blob bytes outside the proxy.** After the 307 its
  `transfer.checkedClient` had no `Proxy`, so on a network whose only way out is the
  proxy a managed pull got its manifest and then failed. The pin is 0.40.6, which picks
  the proxy per request (#19065); the row `blob bytes come through the proxy too` now
  requires the storage bytes to be proxied.
