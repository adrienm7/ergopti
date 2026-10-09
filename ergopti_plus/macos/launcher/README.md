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

These rules describe the shared Karabiner mode shipped today. The owned mode
decided in [ADR 011](../../docs/adr/011-owned-karabiner-runtime.md) will add
Ergopti's own headless runtime, whose console user server is started with the
owner's PID so that the daemon stops grabbing, and the keyboard returns to
native input, when that owner disappears. Stock Karabiner processes stay out of
reach in both modes, except for the explicit, default-on « close other
Karabiner instances » option of the owned mode.

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

The GUI launcher never registers this LaunchAgent: it starts Hammerspoon at
once and exports `ERGOPTI_REMAP_GUARDIAN_STATUS=not_requested`. Only the driver
reads « Ergopti uses Karabiner », so the driver registers the guardian through
the headless `--register-remap-guardian` role, on the first guardian
observation of a lifecycle, which it reaches only while that switch is on. A
user who never turns the integration on never gets a Background Item from
ErgoptiPlus. Turning it off, or removing Ergopti from Karabiner with the switch
already off, joins exact lease retirement and calls the headless
`--unregister-remap-guardian` role. The driver keeps its transition exclusive
until the child actually settles; accepted termination is not an exit receipt.
The native owner checks durable record retirement, removes only the exact
legacy plist, confirms ServiceManagement removal and waits for guardian exit.
Only the exact missing-job launchctl status acknowledges absence. A refusal
keeps the previous preference and recovers a fresh READY lease when it was on;
the next enable registers the guardian again. Personal rules remain byte-owned
by their existing removal transaction.

The hosted `helper_registration` diagnostic qualifies the signed headless roles
without opening the application UI: a wrong inode cannot remove the live job,
successful removal requires the exact receipt plus launchctl absence, and a
second removal is idempotent. Primary and cleanup failures are recorded together.

This is deliberately not a Karabiner process watchdog. In the shared mode,
Karabiner's UI, menubar, root Core Service, console user server, user/session
agents, observers, extensions, watchers, `Karabiner-VirtualHIDDevice-Daemon` and
its DriverKit process are shared with the user's own configuration and remain
entirely user-managed. Disabling ErgoptiPlus revokes
only `ergopti_mode_<token>` / `ergopti_revoked_<token>`; it neither quits nor
restarts stock Karabiner. The owned mode of ADR 011 does not turn this guardian
into a watchdog either: its fail-safe is the daemon's own ungrab when the
owner-started console user server exits.

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

`SUFeedURL` points to the build channel's appcast on the machine-managed
`sparkle-appcasts` branch, using `appcast-main.xml` for stable builds and
`appcast-dev.xml` for prereleases. Once the menu names a channel
(`ergoptiplus://updater/check/<channel>` or `ergoptiplus://updater/channel/<channel>`,
accepted only for the ids in `UpdateChannels.generated.swift`),
`UpdateChannelFeed` serves Sparkle that channel's appcast from the same
directory instead, and keeps the choice for the next check. Sparkle schedules
no check of its own (`SUEnableAutomaticChecks` is false): the Lua driver owns
the cadence (`modules/updater/auto_check.lua`) and asks for a check when the
user clicks the About row or the new-release notification. Release
finalization replaces only the current channel's asset after the versioned
release and its signed application archive have been published, then downloads
the permanent feed again and compares it byte-for-byte.

The release generator accepts `sign_update -f` output only in its complete
`sparkle:edSignature="…" length="…"` form. It rejects extra attributes and
requires the signed length to equal the archive size before emitting XML; the
fragment is inserted once, without wrapping it in a second signature attribute.

## Code-signing identity

macOS stores each Accessibility, Screen Recording, Automation and Login Items
grant against the app's designated requirement. An ad hoc signature
(`codesign --sign -`) makes that requirement the code hash, which every build
changes, so each update used to cost users every permission. A stable
self-signed certificate (free, no Apple Developer ID) makes it
`identifier "com.ergoptiplus.app" and certificate leaf = H"…"`, which every
later build signed with the same certificate satisfies.

Create the certificate once, on your own machine (never in CI):

```sh
bash tools/build/create_macos_signing_identity.sh   # writes ~/ErgoptiPlus-signing/
```

It prints the two repository secrets to add under GitHub > Settings > Secrets
and variables > Actions: `MACOS_SIGNING_CERTIFICATE_BASE64` (the password-
protected `.p12`, base64) and `MACOS_SIGNING_CERTIFICATE_PASSWORD`. Keep the
`.p12` and its password in a password manager: a lost certificate means a new
identity and one more re-grant for every user. The script refuses to
overwrite an existing identity.

`tools/build/build_macos_app.sh` imports the `.p12` into a temporary keychain
when both variables are set, signs every nested code object with it (LuaSocket,
Hammerspoon, Karabiner when bundled as an app, Sparkle, the launcher, then the
app), verifies the seal and logs the designated requirement, then deletes the
keychain. `ci.yml` passes the secrets to release runs only. Without them the
build still signs ad hoc, logs a warning, and a release run shows a
`::warning::`. Setting only one of the two fails the build.

The first update signed with the certificate still needs one last re-grant:
the grants recorded for the previous ad hoc build name its code hash, which
the new signature cannot match. Remove and re-add ErgoptiPlus in each privacy
list once; from then on grants survive updates. Replacing the certificate
later (it is valid ten years) costs the same single re-grant.

## Bundle id

The embedded Hammerspoon's `CFBundleIdentifier` is rewritten to
`com.ergoptiplus.app.hammerspoon` at bundle-assembly time. This isolates its
preferences from stock Hammerspoon and gives it a Launch Services identity
distinct from the single-instance outer `com.ergoptiplus.app` bundle. Before
spawning that GUI child, the launcher removes inherited `__CFBundleIdentifier`
and `XPC_SERVICE_NAME` markers so AppKit and `NSUserDefaults` resolve the
embedded bundle rather than the outer Launch Services identity.
