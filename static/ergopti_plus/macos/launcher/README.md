# Ergopti macOS Launcher

Tiny Swift app that wraps a vendored Hammerspoon into `Ergopti.app`. The user
sees only "Ergopti" in the menubar — Hammerspoon is fully hidden inside
`Contents/Frameworks/Hammerspoon.app`.

The launcher's job is to:

1. Set the embedded Hammerspoon's `MJConfigFile` so it loads our bundled Lua
   tree instead of `~/.hammerspoon/init.lua`.
2. Launch embedded Hammerspoon with `NSWorkspace` so AppKit receives a real
   application context, forwarding lifecycle events so quitting either side
   shuts down the other cleanly.
3. Host [Sparkle](https://sparkle-project.org/) so the in-app updater can
   ship new releases via the configured appcast.

## Abrupt launcher termination

`applicationWillTerminate` covers a normal launcher quit, but macOS cannot run
that callback after Activity Monitor sends `SIGKILL`. The launcher therefore
exports its exact process identity to its Hammerspoon child as
`ERGOPTI_LAUNCHER_PID` and, when available,
`ERGOPTI_LAUNCHER_BUNDLE_ID`.

`infra/launcher_guard.lua` starts a strongly retained native application watcher
before immediately resolving that PID. A matching termination event invokes an
injected emergency-quit callback once. A native `applicationForPID` lookup every
two seconds is only a backstop for a missed event; it does not shell out or run
from an eventtap. Direct developer Hammerspoon sessions remain supported: when
the launcher environment is absent, the guard deliberately stays inactive.

The emergency callback revokes only ErgoptiPlus-owned resources, including its
exact Karabiner lease. It must never terminate Karabiner's shared UI, Core
Service (called `karabiner_grabber` before v15.7), console server,
version-dependent session agents, `Karabiner-VirtualHIDDevice-Daemon`, or the
DriverKit VirtualHID process.

The Lua suite simulates the missing-parent and native-termination paths. A
physical Activity Monitor Force Quit and observable keyboard-release check still
requires a built application on macOS.

## Karabiner lease guardian

The same signed launcher executable provides retained outer and private-inner
roles, a detached one-shot revoker, and an independent per-user LaunchAgent.
The outer role owns Hammerspoon's standard-stream protocol and wait-supervises
one exact inner child over a private socket. The inner role is the only process
allowed to create, signal and reap transient lease-authority
`karabiner_cli --set-variables` children. The launchd-owned guardian holds no
Karabiner process authority: it watches a durable, locked exact-token record and
publishes only that token's OFF+tombstone variables if every private process is
Force Quit. Pipe EOF, outer loss, inner loss, guardian restart and bounded CLI
timeouts therefore converge on the same token-scoped fence.

This is deliberately not a Karabiner process watchdog. Karabiner's UI, menubar,
root Core Service, console user server, user/session agents, observers,
extensions, watchers, `Karabiner-VirtualHIDDevice-Daemon` and its DriverKit
process are shared with the user's own configuration and remain entirely
user-managed. Disabling ErgoptiPlus revokes
only `ergopti_mode_<token>` / `ergopti_revoked_<token>`; it neither quits nor
restarts stock Karabiner.

Non-authority engine state is isolated independently. Generated rules and
Hammerspoon writers use `ergopti_<logical-name>_<token>` for `layer_active`,
`capsword`, and every `ke_held_*` value. A delayed runtime writer may outlive
Hammerspoon, but its already-captured token cannot mutate a replacement
generation or an untagged personal Karabiner variable.

## Build

The launcher is compiled by `tools/build_macos_app.sh` as part of the macOS
app assembly. To iterate on the Swift code alone:

```sh
cd static/ergopti_plus/macos/launcher
swift build -c release --product Ergopti
swift run Ergopti          # for local testing (HS not bundled, expect a fail dialog)
```

## Sparkle keys

Sparkle uses EdDSA (Ed25519) signatures on every release zip. Generate a
keypair once and store it as repo secrets:

```sh
# On the maintainer's Mac:
brew install --formula sparkle
sparkle generate_keys > /tmp/sparkle_keys.txt
```

The output gives you:

- A **private key** (base64) — store as the `SPARKLE_ED_PRIVATE_KEY` GitHub
  secret. CI uses it to sign each release zip.
- A **public key** (base64) — store as the `SPARKLE_PUBLIC_KEY` GitHub
  secret AND keep a backup in a password manager. It gets embedded into the
  shipped Info.plist as `SUPublicEDKey` — losing this means no current build
  can verify any future update.

Do **not** commit either key. The launcher's `Info.plist` is generated at
build time so the public key is injected from the secret rather than living
in source.

`SUFeedURL` points to the machine-managed `sparkle-feed` release, using
`appcast-main.xml` for stable builds and `appcast-dev.xml` for prereleases.
Release finalization replaces only the current channel's asset after the
versioned release and its signed application archive have been published, then
downloads the permanent feed again and compares it byte-for-byte.

## Bundle id

The embedded Hammerspoon's `CFBundleIdentifier` is rewritten to
`com.ergoptiplus.app.hammerspoon` at bundle-assembly time. This isolates its
preferences from stock Hammerspoon and gives it a Launch Services identity
distinct from the single-instance outer `com.ergoptiplus.app` bundle. Before
spawning that GUI child, the launcher removes inherited `__CFBundleIdentifier`
and `XPC_SERVICE_NAME` markers so AppKit and `NSUserDefaults` resolve the
embedded bundle rather than the outer Launch Services identity.
