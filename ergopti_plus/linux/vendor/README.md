# vendor/

Third-party Lua libraries bundled with the Linux driver so the test suite and
runtime have no external dependency on the system LuaRocks tree.

## Dependencies

| Package             | Version | Lua module | Purpose |
| ------------------- | ------- | ---------- | ------- |
| lua-luv             | ≥ 1.44  | `luv`      | libuv event loop + async timers + non-blocking pipe I/O (`event_loop`, `timer_scheduler`, `http_client`) |
| luafilesystem       | ≥ 1.8   | `lfs`      | `stat()` / directory iteration (`file_system` adapter, test runner) |
| luaposix            | ≥ 36.0  | `posix`    | POSIX signals for graceful shutdown + SIGHUP reload (daemon signal handlers) |
| lgi                 | ≥ 0.9   | `lgi`      | GObject introspection — GTK windows, WebKit2GTK webviews, GDBus tray SNI (`webview_manager`, `tray_menu`) |
| lua-http            | ≥ 0.3   | `http`     | Async HTTP/1.1 + HTTP/2 client (`http_client` adapter, Ollama communication) |

## Installing dependencies

### Option A — System packages (recommended for most users)

```bash
# Debian / Ubuntu
sudo apt install lua-luv lua-filesystem lua-posix lua-lgi lua-http

# Fedora
sudo dnf install lua-luv lua-filesystem lua-posix lua-lgi lua-http

# Arch
sudo pacman -S lua-luv lua-filesystem lua-posix lua-lgi lua-http
```

### Option B — LuaRocks (global install)

```bash
luarocks install luv
luarocks install luafilesystem
luarocks install luaposix
luarocks install lgi
luarocks install http
```

### Option C — Vendored (self-contained, no system deps)

```bash
bash vendor/fetch_vendor.sh
```

This downloads each rock into `vendor/<name>/`. The daemon and test runner
inject `vendor/?.lua;vendor/?/init.lua` into `package.path` automatically.

## Runtime behaviour when deps are missing

The daemon is designed to degrade gracefully:

| Missing dependency | Effect |
| ------------------ | ------ |
| `luv`              | Pump-based fallback loop with 1 ms sleep (no async I/O, timers become no-ops logged as warnings). |
| `lfs`              | `file_system.exists()` falls back to `io.open()`. |
| `posix`            | Signal handlers (SIGINT/SIGTERM/SIGHUP) are not installed. |
| `lgi`              | Webview rendering disabled; pure-Lua bridge mode only. Tray menu falls back to `yad`. |
| `http`             | `http_client` falls back to blocking `curl` via `io.popen`. |

Vendor libraries are not committed to the repository.
