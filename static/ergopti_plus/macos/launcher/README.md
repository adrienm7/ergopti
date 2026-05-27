# Ergopti macOS Launcher

Tiny Swift app that wraps a vendored Hammerspoon into `Ergopti.app`. The user
sees only "Ergopti" in the menubar — Hammerspoon is fully hidden inside
`Contents/Frameworks/Hammerspoon.app`.

The launcher's job is to:

1. Set the embedded Hammerspoon's `MJConfigDir` so it loads our bundled Lua
   tree from `Contents/Resources/config/` instead of `~/.hammerspoon`.
2. Spawn the embedded Hammerspoon as a child `Process`, forwarding lifecycle
   events so quitting the launcher cleanly terminates Hammerspoon.
3. Host [Sparkle](https://sparkle-project.org/) so the in-app updater can
   ship new releases via the configured appcast.

## Build

The launcher is compiled by `tools/build_macos_app.sh` as part of the macOS
app assembly. To iterate on the Swift code alone:

```sh
cd static/drivers/hammerspoon/launcher
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

## Bundle id

The embedded Hammerspoon's `CFBundleIdentifier` is rewritten to
`com.ergoptiplus.app` at bundle-assembly time. This isolates its preferences
from a stock Hammerspoon install the user may also be running, so the two
never fight over `MJConfigDir`.
