<!-- docs/handovers/2026-10-10-group1-config-menus/MACOS-LINUX-STEPS.md -->

# Group 1 macOS and Linux continuation

Use the exact source SHA recorded by the integration's manual CI. A software-host unit suite
is separate from native E2E, packaging, installation and physical acceptance.

## macOS

- [ ] Install and launch the actual Hammerspoon/application source with required
      permissions. Replay the seven-page wizard in fresh, existing and moved
      folders; check selected options become effective after an actual restart.
- [ ] Check running/paused/reloaded menus, the selected layout child, deferred
      language/category choices and disabled reasons. Open the personal editor
      and verify queued delivery still belongs to its original source.
- [ ] Exercise recommended/clear scopes, external-write refusal, retry, obsolete
      preview and explicit cleanup. Inspect visible success/error outcomes.
- [ ] Qualify packaging, clean install, upgrade and uninstall on the same source.

On the work Mac, visible pass/fail observations are sufficient. No logs,
configuration files or other work-machine data need to leave the device.

## Linux

- [ ] Qualify the actual final unit/E2E/package/install lanes, including real
      libuv/LuaFileSystem, graphical-session and permission prerequisites.
- [ ] In an actual installed X11 session, replay wizard restart and scope/cleanup
      refusal scenarios and check physical input. Earlier bounded GTK/X11 probes
      do not qualify the final installed daemon.
- [ ] Verify the active/paused version header, actual resume callback and the
      empty extension status, retaining language and source-version formatting.
- [ ] Check available Wayland behavior and its explicit unsupported explanations;
      report the session actually tested rather than treating X11 as Wayland.

The cloud kernel does not expose the required /proc thread children observation
for the mandatory real-window probe. A stub or an incomplete probe cannot
replace its receiving receipt. Use a runner or real machine with the required
session. Keep all unexecuted scenarios open under transversal items 16/38.
