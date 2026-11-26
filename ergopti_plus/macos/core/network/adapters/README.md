<!-- core/network/adapters/README.md -->

# Native network ownership on macOS

STATUS: implemented through existing native adapters; no GIO binding here.

The HTTP owner is [core/network/adapters/http_client.lua](http_client.lua).
It delegates ordinary requests to Hammerspoon's native `hs.http` API and owns
their cancellation and completion boundaries. The manual update check uses
[managed_http_worker.lua](managed_http_worker.lua) instead: it runs the
launcher's native HTTP worker, whose closed failure reasons name a proxy,
offline or certificate cause that `hs.http` cannot report (UPD-13). Managed
installer children use
the existing macOS proxy and certificate admission paths. This directory
records that OS seam without moving those established owners.

Linux needs an owned GIO lookup child, native library admission and compiled
proxy schemas. macOS does not load those libraries. Shared policy belongs in
`_shared/core/network/engine/` and `_shared/core/network/data/`; native selection and
recipient trust remain platform responsibilities. Actual enterprise PAC,
authentication and certificate acceptance require native qualification; the
directory's presence does not claim those checks passed.
