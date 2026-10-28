<!-- platform/network/README.md -->

# Native network ownership on Windows

STATUS: existing native owners; remaining Windows qualification is deferred.

The HTTP owner is [adapters/http_client.ahk](../../adapters/http_client.ahk).
Every managed request runs in one request-owned, tree-owned PowerShell worker
([ergopti_managed_http_worker.ps1](../../vendor/ergopti_managed_http_worker.ps1))
that talks to the Windows system HTTP stack, WinHTTP, through
[ergopti_winhttp_transport.ps1](../../vendor/ergopti_winhttp_transport.ps1). The
same engine serves the updater artifact download and the Ollama archive
download. WinHTTP follows the route list chosen by the canonical route owner,
answers Negotiate and NTLM proxies with the signed-in session, trusts the Windows
certificate store and needs no binary beyond Windows itself, so a company proxy
that offers NTLM alone works on an up-to-date Windows (the System32 curl lost
NTLM). The worker returns closed failure receipts that never contain a URL.

Native automatic proxy discovery is bounded by the existing tree-owned
[PowerShell worker](../../vendor/ergopti_system_proxy_worker.ps1), which calls
WinHTTP for configured PAC or WPAD. The adapter retains request ownership and
keeps private request configuration out of the command line.

Linux needs a GIO runtime and compiled proxy schemas; Windows uses its own
native APIs and does not load GIO. Shared policy belongs in
`_shared/lua/network/` and `_shared/modules/network/`. Saved Windows candidate
patches are inactive preparation, with the actual native/E2E/package/install
checks listed in the [Windows handover](../../../../../docs/handovers/2026-10-04-group6-windows/README.md).
Real WinHTTP behavior is proven against owned loopback services by
`tests/fixtures/winhttp_transport_controls.ps1`; this directory does not claim
that enterprise certificate and authentication acceptance passed.
