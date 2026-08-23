<!-- TODO.md -->

# TODO

## P1 — Validate native macOS ownership contracts

Run the completed macOS lifecycle changes on a real Mac. Cover the launcher
XCTest suite in `static/ergopti_plus/macos/launcher/`, FSEvents/pathwatcher
startup refusal in `static/ergopti_plus/macos/infra/file_watchers.lua`, the
POSIX filesystem capability tests, and ServiceManagement process boundaries.
The Windows Lua and source gates prove the exposed ownership contracts but
cannot execute Darwin poll/FD behavior or the hidden native
`FSEventStreamStart` result. Until this is done, regressions below the Lua/Swift
test seams could remain platform-only.

## P2 — Capture a production Hammerspoon G4 profile

Collect `infra/hotpath_profiler.lua`, `infra/boot_profiler.lua`, and
`infra/perf.lua` artifacts from the resolved configuration directory on the
target Mac. Measure synchronous MLX adoption, WPM `mouseMoved` traffic,
Terminal identity lookup, keylogger app attribution, canvas/AX work, and
remaining synchronous shell helpers before prioritizing optimizations. The
candidate-loop lowercase allocation has already been removed; do not optimize
the remaining hypotheses from source inspection alone. Without this profile,
production latency and startup cost remain unquantified.
