<!-- docs/handovers/2026-09-29-overnight/DECISIONS.md -->

# Maintainer decisions of 2026-09-29

## HS-274 / Karabiner runtime

- Karabiner is NOT installed as the Karabiner-Elements app: only an Ergopti-owned background runtime
  (unmodified pqrs VirtualHIDDevice + Ergopti-built headless 3-product fork of Karabiner-Elements 16.3.0 with the HS-274 stream).
- The Ergopti Karabiner runtime runs ONLY when the Tap-Hold (etc.) feature is enabled. When it runs, Ergopti automatically
  quits any other active Karabiner to avoid conflicts, governed by an Ergopti menu option (default ON: "close other
  Karabiner instances"). A user keeps their own Karabiner by disabling Ergopti's Tap-Hold (or unticking the option).
  (This intentionally overrides the earlier R3 rule for that explicit, default-on option.)
- pqrs branding of the VirtualHIDDevice is acceptable; NO Apple Developer ID (stay self-signed; accept Gatekeeper friction).
- Maintain the Karabiner-Elements 16.3.0 fork (re-anchor on upstream bumps).
- Heatmap becomes physical-only once the stream is active (no autorepeat; nav-layer letters count as letters).
- Count everything: fn/globe AND media keys.
- Metrics-only users (Tap-Hold off) do NOT run the Ergopti Karabiner runtime; metrics use the event tap.
- Hardware available for real-Mac acceptance: internal Mac keyboard (fn/globe) only.

## Other

- force_quit_frontmost asks for confirmation (Cancel default), like trash/quarantine.
- Key combinations: their own switch only, identical on every OS (macOS generates hold-based combo rules even when Tap-Hold is off).
- Physical magic-key setting on all 3 OSes (choose by pressing the key or from a list; same config key; migrate Windows setting). After the demo.
- Delta updates: macOS Sparkle deltas right after the demo, then Windows and Linux with automatic full-download fallback.
- macOS release archive to .tar.xz after the demo (verify Sparkle, Homebrew cask, CI install).
- Ergopti-only hotstring groups (SFB reduction, rolls, repeat corrections) move into the Ergopti extension, shown under a
  "Hotstrings Ergopti" submenu, available when the extension/layout is installed.
- macOS app as light as possible: no bundled Ollama; Ollama and MLX runtimes installed only the first time each is selected as AI backend.
- UI windows are only focused when opened, never always-on-top (overlays exempt).
- Unknown/outdated config → one WARNING + offered by config cleanup, never ERROR.
- Login Items approval must be automatic or explicitly guided by Ergopti (native dialog + opened pane at boot).
- Push rarely: every push to dev is a release.
