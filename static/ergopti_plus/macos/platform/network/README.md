<!-- platform/network/README.md -->

# Native network ownership on macOS

STATUS: implemented through existing native adapters; no GIO binding here.

The HTTP owner is [adapters/http_client.lua](../../adapters/http_client.lua).
It delegates ordinary requests to Hammerspoon's native `hs.http` API and owns
their cancellation and completion boundaries. Managed installer children use
the existing macOS proxy and certificate admission paths. This directory
records that OS seam without moving those established owners.

Linux needs an owned GIO lookup child, native library admission and compiled
proxy schemas. macOS does not load those libraries. Shared policy belongs in
`_shared/lua/network/` and `_shared/modules/network/`; native selection and
recipient trust remain platform responsibilities. Actual enterprise PAC,
authentication and certificate acceptance require native qualification; the
directory's presence does not claim those checks passed.
