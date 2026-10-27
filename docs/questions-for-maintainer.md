<!-- docs/questions-for-maintainer.md -->

# Questions for the maintainer

Collected while working alone (October 20-22). Each question names the default taken meanwhile;
answer once, then move the answered line below.

## Open

- **"Sticky" in French and Latin-script locales:** the sticky-modifier labels keep the English "Sticky", as
  the existing `menu.tapholds.sticky_*` strings do. Default meanwhile: kept. Use a French term such as
  "rémanent" instead?
- **Dutch "Rolls":** `category.rolls` and `hs_config.cat_rolls` keep "Rolls" (the Dutch "Rollen" means
  "roles"). Default meanwhile: kept. Another Dutch word?

## Answered

- **Coordinator decisions of 2026-10-27 (the maintainer asked not to be asked; override if needed):**
  - **App Cloner folder picker on macOS:** the Cancel button keeps the system label. NSOpenPanel has no
    key-value `cancelButtonTitle`, so the wizard's guarded setter always failed silently; it is removed with
    its assertion instead of hiding the error.
  - **AppImage:** no bundled glibc or loader (the host GTK, GL and NSS modules must match the loader that
    starts them); built on ubuntu:22.04, glibc 2.35 or newer, musl refused in words; a build gate refuses a
    foreign loader or a staged C library.
- **Answers of 2026-10-26 (QCM):**
  - **Slow-segment threshold:** 5 ms on the three OS (macOS and Linux were at 20 ms).
  - **Tap-hold delay migration marker:** a versioned migrator for `tap_hold.toml` on the three OS replaces the
    permanent `[tap_hold] explicit_delays = true` marker.
  - **Duplicate keys in the macOS hotstring override file:** strict, as Linux (kept).
  - **Linux crash notice:** the immediate notification only; the next-start crash dialog goes (one notice, as
    macOS).
  - **Linux Quit refusal:** the same refusals as macOS.
  - **`config_template.toml`:** asked for advice; rule: share as much as possible. Advice given: the three
    templates are already one generator over the schema (filtered per OS), so keep them generated and shipped
    as the commented reference of every setting.
  - **Hotstring colour palette:** the 14 Windows colours on the three OS, from one source.
  - **`_shared/ui/metrics_apps/script.js`:** retire it.
  - **AI-off hint text:** a dedicated string in every locale.
  - **Older macOS LLM user profiles:** add a registry op that re-encodes a value (Windows `config_migrate.ahk`
    learns it first, on the PC), then delete the macOS reader import.
  - **PAR-66 section readers:** re-point the source-pin gates to the shared module text, keep only the call
    pins in the drivers, then extract the five readers.
  - **Prediction request floor (PAR-65):** an explicit request is never held by the floor (only automatic
    requests wait); one global floor (not per backend), settable from the menu on the three OS; a "never"
    debounce (no automatic trigger) on the three OS; live mode fires instantly at a word end on the three OS.
  - **Prediction floor, follow-up:** the variants of one request (a "predict n" profile run as n calls) are
    never held, automatic or explicit; the floor only separates distinct requests. Default floor 300 ms, 0
    accepted (no floor). A mashed explicit shortcut supersedes its in-flight request instead of stacking one.
  - **`tap_hold.toml` migration:** a byte-preserving rewrite (comments and layout kept), as config.toml;
    `[tap_hold.retired_delays]` is kept forever.
  - **Quit:** Quit wins on the three OS: during a reload it abandons the reload and exits, once a write
    already in progress has finished. A pending per-category scope write blocks Linux Quit, as macOS.
  - **PAR-41 (coordinator decisions, overridable):** the "no migration" of the design note is superseded by a
    real config migration (schema v15) so no saved binding is lost, in line with the PAR-40 answer; the
    parameters of renamed slots wait for a `rename_prefix` op (release blocker in the TODO); macOS `ctrl_g`
    becomes an `open_url` slot with its URL later, with Windows `gpt`; the role name `secondary` is kept.
  - **Localized "general" metrics category:** the live dashboard folds its 19 spellings into one id, from the
    generated alias file.

- **Answers of 2026-10-25 (QCM), implemented the same day unless noted:**
  - **CI design:** one lane per OS plus Common, each Unit → Integration → E2E → Build → Install and launch →
    Verdict, strictly sequential; a failure skips the later stages. macOS Build after E2E (the XCTest and native
    probes moved to an E2E cell); the distribution unit suites in Linux Unit and their integration group in Linux
    Integration; the Flatpak built in the Linux Build and installed as its own lot; the cold MLX bootstrap in a
    macOS 26 launch lot; one verdict name; the shared lane is "Common"; no diagnostic Build after a failed E2E.
  - **Portable programs:** every program the Linux code launches needs a checked proof (declared, installed by
    CI, probed, or replaced); `ps` became a `/proc` read, `cmp` a `sha256sum` comparison.
  - **Hotstring cascading:** `hotstrings.cascade_max_arrows` counts arrows (1 = a single expansion, 2 = a → b →
    c), default 3, range 1 to 10; the chain is resolved in-process and typed once. A link fires only where typing
    the same text would fire it (each entry's word-start flag decides).
  - **End character:** Windows behaviour on the three OS: the typed delimiter appears once after the final output;
    the per-delimiter "consumed" choice decides, also in a chain; ★ ships consumed. No per-entry field.
  - **Tap-hold delays:** one global delay (200 ms) for every key; no shipped per-key delay; a key the user set
    keeps its value when the global changes; "use global" resets it.
  - **Gestures:** Windows keeps its recommendations; each slot the system does not map to Ergopti's shortcut is
    greyed with its reason; the status submenu is gone. macOS and Linux need no system mapping.
  - **AI off:** disarm everything on the three OS, including tap-hold actions bound to the AI and the agent's
    manual menu entries (greyed with the reason).
- **Answers of 2026-10-24 evening (QCM):**
  - **PAR-6:** yes, `hotstrings.expansion_delay` becomes user-settable on all three drivers; the per-section delays
    become optional offsets from that base.
  - **PAR-8:** write the built-in delimiter states through the live config writer (no reload per click), drop the
    override-file strings, keep custom delimiters as records, but KEEP the per-character "consumed" option and carry it
    to macOS and Linux as well.
  - **PAR-15:** per-key tap-hold thresholds on macOS too, after the key-id vocabularies are reconciled (shared with
    PAR-41).
  - **PAR-21:** delete the Linux autocompletion delay row; `llm.trigger.debounce_ms` is the only delay.
  - **PAR-24:** migrate Windows `category_enabled.dynamichotstrings` to `hotstrings.dynamic.enabled`, with a config
    migration that keeps the old value.
  - **Hotstring cascading:** build it for every hotstring, shipped pack included, behind a user setting: the
    cascade depth, 0 disables it, 1 lets a hotstring output trigger one more hotstring, and so on (for example
    `chatg` > `chatgpt` > `ChatGPT` when both are enabled). Keep SendInput and a same-spec guard.
  - **Space tap-hold:** a Space tap must complete an end-character trigger exactly like a plain space; only the
    hold runs the action.
  - **Recommended defaults rule (gestures, keys):** by default recommend nothing that conflicts with the system's
    own default; every combination stays reassignable, as on macOS, and the menu says clearly to remove the system
    assignment first to avoid a double action. On Linux the recommended three- and four-finger swipes become `none`.
  - **AI off on Linux:** disarm the agent's automatic mode and the `llm_*` chords, as on macOS and Windows.
  - **macOS recommendations:** one shared trigger debounce value for all OS; gestures follow the rule above; keep
    MLX on macOS (a real platform difference, with its reason); never touch the user's number row or layout by
    default on any OS, both stay options the user turns on.
  - **PAR-12:** enable token streaming on Windows after a live Ollama check on the PC.
  - **Windows prediction tooltip Gui pool:** decide after measuring with and without the pool in the PC logs.

- **#99: automatic proxy discovery without a WPAD server (answered October 22):** not the
  maintainer's setup, no change. His Mac has Auto Proxy Discovery off and Automatic Proxy
  Configuration on with a corporate PAC URL; the static Web (HTTP), Secure Web (HTTPS), SOCKS
  and other proxies are all off, so the PAC file is the only proxy source. Resolving a PAC for an Ergopti-started Ollama is a
  checklist item; his own Ollama.app is covered by 2353a72eed.
- **October 22 answers, second batch:** the site deploy design is confirmed (`main` -> ergopti.fr, `dev` ->
  ergopti.fr/dev/); the workflow definition being read from `main` (a `workflow_run` workflow) is
  accepted, no change; the macOS typing
  dashboard shows a partial history's counts, not cached, with an "incomplete history" mention
  (parity checked on Windows and Linux); the per-row number-row switches do not cover the
  October 13 request, which becomes a per-layer layout composer (big item 4 of the checklist);
  the Versions window hands a click on the channel's newest release to Sparkle when the list came
  from the feed.
- **October 22 answers:** issue #100: keep 2353a72eed (a foreign Ollama daemon pulls through a PAC
  proxy; a daemon of unknown or Ergopti origin stays fail-closed); the macOS webview-open freeze
  (`wv:hswindow()` scanning every window) is fixed now; SignPath Foundation: apply now; the
  Windows and Linux tap-hold « Hold → … » rows open the shared action picker with holdable
  actions only, like macOS. Agents are on each; details in the checklist.
- **Merge commits on `dev` (answered October 21):** no merge commits, `dev` and `main` stay linear. Integrate by
  rebasing and fast-forwarding; the merge `330cbe4c04` was rewritten into linear commits (`dev` force-pushed once, with a lease).
- **Replies on GitHub (answered October 21):** not posted, by the maintainer's choice; issues #84 and #95-#97
  are closed without a reply. Their open checks stay in the TODO.
- **AppImage catalog (answered October 21):** the catalog test passed on v1.0.4; post `/retest` on
  AppImage/appimage.github.io#10422 for v1.0.5 to refresh its screenshot (maintainer checks).
- **Release (answered October 22):** v1.0.5 is released (tag 17d4a3f421).
- **October 21 answers:** FileDescription in English with the website in Comments; macOS manual ISO/ANSI selector; SignPath
  application implications to be listed before deciding; Linux aligned on Windows and macOS (`[BS]x`, recommended settings);
  Ollama redirect policy: best design even if long; no review screen for bug reports; NTLM: WinHTTP system stack; HS-274
  tools: delete or put in CI; Hammerspoon coexistence. Details in the checklist.
- **Hotstring cascading (asked 2026-10-24):** you asked that a hotstring's output can trigger another hotstring
  while keeping SendInput. The real engine shows that no driver cascades today (the retired native engine did, via
  SendEvent). Building it is a new feature (an in-engine re-feed with a depth bound and a same-spec guard). Caveat:
  124 of the 2786 shared replacements end with their own trigger (case aside) and 131 end with another trigger, so
  the shipped pack's output would change. Do you want cascading, for which hotstrings (personal only, the pack too),
  and with which guards? Until you answer, nothing changes.
- **Space tap-hold and end-character triggers (asked 2026-10-24):** `_SpaceTap` resets both buffers, so a trigger
  ending with the space cannot complete from the Space tap-hold. Is that expected with the tap-hold on?
- **Redacted full-day log as an attachment (asked 2026-10-24, item 138):** the report is a closed projection that
  excludes free text. May a redacted full-day log ever be an opt-in attachment? If yes, one shared collector with three
  thin drivers; GitHub field editability still needs a real draft.
- **Config-directory names in logs (asked 2026-10-24, item 139):** folder and file names under the config directory
  (for example hotstring pack names) appear in thousands of log lines; they are user-chosen identifiers that the
  account-name rule only catches when they contain the account name. Reduce those paths to a placeholder?
- **Legacy ownership (asked 2026-10-24, item 131):** what should "legacy ownership" cover for SMAppService: a login item
  left by an older Ergopti copy at another path, or something else?
- **Items 46, 47, 48 (asked 2026-10-24):** the original audit context cannot be found; only the macOS Ollama
  process-termination debt (120) is known. Re-state them or retire them?
- **Expansion delay with Shift or Alt (asked 2026-10-24):** macOS widens the delay for keystrokes typed with Shift or
  Alt (`COMPLEX_DELAY_MULT` in the keymap) while Windows and Linux do not. All other time-gate rules are now
  identical on the three drivers (commit 1e12217b92). Which should win: remove the multiplier on macOS, or declare it
  once in the shared constants and apply it on all three (it helps slow Shift typing but lengthens the window on
  Windows and Linux)?
- **Delimiters as config leaves on Windows (asked 2026-10-24, PAR-8):** on Windows every terminator edit goes through
  a reload-and-acknowledge path and users can enter arbitrary delimiter characters and mark any as consumed; the macOS
  and Linux leaves (`terminator_states`, `terminators`) cannot express that. Proposed: write the built-in states through
  the live config writer (like the WPM settings, no reload per click), drop the override-file strings and the
  per-character consume opt-in on built-ins, keep custom delimiters as records. Acceptable? (about 230 references in 17
  files and 40 AHK tests.)
- **Hotstring base delay setting (asked 2026-10-24, PAR-6):** `hotstrings.expansion_delay` is now the single
  declaration of the 0.75 s default, but only macOS reads a user-set value; Windows and Linux ignore one written in
  `config.toml` (their delay is set per section in the « Délais & couleurs » window). Should the base value become
  user-settable on all three?
