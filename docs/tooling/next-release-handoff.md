<!-- docs/tooling/next-release-handoff.md -->

# Next release after 1.0.9: handoff

## Branch `next/linux-todo`

Base: `origin/dev` at `8a474b30a8`, with this file only, so its Linux lane is a checkpoint of `dev`'s own source.

### What this branch is for

The TODO items left that need neither a Mac nor the Windows desktop, after reading "Remaining code work", "All
drivers", "CI acceptance" and "To confirm on Linux" on 3 November:

- **CI acceptance 16/38, Linux half.** The hosted Linux lane dispatched on this branch is the first run of the rows
  that item lists (X11 window list, AppImage Build and `install-linux`, per-step installs, the managed Ollama route
  plan qualification, the private runtime in every package, the run-timing summary). Its receipts are recorded below.
- **Stale TODO line.** "Proxy variables in `network-retry.sh`" is already done on `dev`: one
  `clear_proxy_environment()` serves the direct override and the refused sign-in start, and
  `test-proxy-policy-single-source` allows 3. The line is removed on `next/owned-karabiner` (one TODO edit per area,
  to keep the two branches from conflicting).

### Skipped, and why

- Every "To confirm on Linux" line: they need a real desktop (evdev and uinput grabs, polkit, Wayland and X11
  sessions, a touchpad, a keyring, GNOME and KDE).
- "One folder name for Ergopti on the three OS": decided on 3 November, but a migration on all three drivers at once
  (macOS and Windows folders included) with backups and a boot test on each; starting the Linux half alone would break
  the one-name rule it introduces.
- "Test parity (audit item 14)", "Provider flags", "108": the first needs the macOS and Windows meta suites to judge
  which scans stay; the second reads provider documentation that refuses automated reads (SambaNova 403); the third
  waits for a design.
- "PAC list walk on macOS and Windows": a pending maintainer decision.

### CI receipts

See the agent's report; the run ids and results are added here once the runs finish.
