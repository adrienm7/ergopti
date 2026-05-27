# vendor/

Third-party Lua libraries bundled with the Linux driver so the test suite and
runtime have no external dependency on the system LuaRocks tree.

## Planned dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| lua-luv | ≥ 1.44  | libuv bindings for async timers and fd polling (TimerScheduler, KeyboardHook) |
| lua-http | ≥ 0.3  | Async HTTP/1.1 + HTTP/2 client (HttpClient) |
| luafilesystem (lfs) | ≥ 1.8 | stat() / directory iteration (FileSystem, test runner) |

Vendor libraries are not committed to the repository. Add a `fetch-vendor`
script or a Makefile target that downloads and places them here before running
the test suite.
