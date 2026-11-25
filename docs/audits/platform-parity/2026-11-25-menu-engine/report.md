# Menu engine bindings and the reload hold

Audited source: `c360c722` (`integrate-2026-11-25a`, `dev` plus unpushed
commits). Date: November 25, 2026. Two units the
[2026-11-19 census](../2026-11-19-census/report.md) lists as never campaigned
(`macos/menu/engine`, rank 8, and `linux/menu/engine`, rank 19), read against
the shared `_shared/menu/engine` they bind and the Windows `menu/engine` that
plays their part.

## Scope

- macOS and Linux `menu/engine/manifest_menu.lua`, `manifest_reader.lua` and
  `native_presentation.lua`, the bindings of the shared renderer, features
  manifest reader and native presentation receiver;
- macOS `menu/engine/ui_restore.lua`, which holds a file-watcher reload while a
  protected window is open and reopens windows after an uncontrolled reload;
- against Windows `menu/engine/manifest_reader.ahk`, `manifest_menu.ahk`,
  `reload_replay.ahk` and `core/lifecycle/engine/dev_source.ahk`, and the Linux
  `core/fs/engine/file_watchers.lua`.

Read for each: which manifest and platform token each driver binds, the
defaults that depend on the machine, rows a driver cannot honour, and what
happens to an open window when a reload starts. Source reading only; no source
changed.

Checked and kept:

- **Bindings.** Both Lua drivers bind the same renderer, reader and receiver
  with their platform token (`hs`, `linux`), their logger and their JSON
  decoder (Hammerspoon's C decoder, the pure-Lua one on Linux). The two
  `native_presentation.lua` differ only by that token.
- **Machine-dependent default.** Only macOS resolves one (the model backend:
  MLX on Apple silicon with a recent macOS, else Ollama); MLX exists on macOS
  only, so Linux and Windows have no such resolution.
- **Rows a window cannot draw.** Linux greys a row whose window the start check
  found the system cannot draw (`command_unavailable`), naming the missing
  component; Windows answers the click with its localized WebView2 refusal;
  macOS always has WebKit. Both refusals are loud, so neither is a drift.
- **`ui_restore` is macOS's alone by mechanism.** A hotstring TOML or source
  change makes Hammerspoon rebuild its whole Lua state (`hs.reload`), which
  closes every webview: the hold keeps the metrics windows and the hotstring
  editor open until the user closes them, and the snapshot reopens them after
  an uncontrolled reload. Linux re-reads a TOML change in its running daemon,
  so no window closes; Windows does not watch the hotstring files.

## Fixed

None: no confirmed drift in these units.

## Open

- **Developer source reloads under an open window.** In a developer run,
  Windows (`dev_source.ahk`) and Linux (a source edit restarts the daemon)
  reload as soon as the tree settles, while macOS holds the reload until its
  protected windows are closed. Only developer runs reach this path, so the
  default kept is no hold on Windows and Linux (« Maintainer decisions
  pending », decided by the agent on 2026-11-25).
- **Log tags.** The macOS reader logs as `manifest_reader`, the Linux one as
  `menu.engine.manifest_reader`; harmless, left to the logger's next tag pass.
