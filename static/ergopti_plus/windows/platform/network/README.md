<!-- platform/network/README.md -->

# Native network ownership on Windows

STATUS: existing native owners; remaining Windows qualification is deferred.

The HTTP owner is [adapters/http_client.ahk](../../adapters/http_client.ahk).
Native automatic proxy discovery is bounded by the existing tree-owned
[PowerShell worker](../../vendor/ergopti_system_proxy_worker.ps1), which calls
WinHTTP for configured PAC or WPAD. The adapter retains request ownership and
keeps private request configuration out of the command line.

Linux needs a GIO runtime and compiled proxy schemas; Windows uses its own
native APIs and does not load GIO. Shared policy belongs in
`_shared/lua/network/` and `_shared/modules/network/`. Saved Windows candidate
patches are inactive preparation, with the actual native/E2E/package/install
checks listed in the [Windows handover](../../../../../docs/handovers/2026-10-04-group6-windows/README.md).
This directory does not claim those checks or enterprise certificate and
authentication acceptance passed.
