<!-- docs/questions-for-maintainer.md -->

# Questions for the maintainer

Collected while working alone (October 20-22). Each question names the default taken meanwhile;
answer once, then move the answered line below.

## Open

- **Tap-hold hold rows on Windows and Linux (October 21):** the tap and, on macOS, the hold now open the shared action
  picker. The Windows and Linux « Hold → … » rows still list the seven shared hold options (none, five modifiers, the
  navigation layer) in a submenu, because they are hold options, not actions. Default meanwhile: kept as a submenu. Say
  if they should open a picker window too ([handoff](todo-agents/macos-tap-hold-action-picker.md)).
- **Site deploy reads its receiver from main:** `deploy-site.yml` takes its receiver from `main`, so
  the site lags `dev` until the next release. Default meanwhile: unchanged. Say if the deploy
  should follow `dev`.
- **macOS typing dashboard and a partial SQLite history:** since the Codex integration (f0fb919379)
  the dashboard refuses a history whose database reads were incomplete instead of showing partial
  counts (dev had chosen "shown but not cached"). Default meanwhile: refuse. Say if users should
  see partial counts during a transient SQLite error.
- **Number-row switches against the October 13 request:** a row is emulated or native as a whole;
  the base and Shift levels cannot be emulated independently. Default meanwhile: per-row switches
  only. Say if they cover the request.
- **#99: automatic proxy discovery without a WPAD server for Ollama pulls:** an Ergopti-started
  Ollama refuses to pull when the system proxy is PAC, WPAD or SOCKS-only (its Go client cannot
  follow an automatic proxy). Default meanwhile: refused, the log names the mode. Once
  `scutil --proxy` is read on the Mac, say if "Auto Proxy Discovery" with no server should be
  admitted (`apply_opaque_system_network`, `macos/modules/llm/network-retry.sh`).
- **Versions window with a feed-only list (macOS):** when the API gives no list, the Versions
  window cannot install from the Atom feed (no digests) and warns. Default meanwhile: refused.
  Option: hand a click on the channel's newest release to Sparkle (needs a page phase and 21
  locale strings). Say if wanted.
- **SignPath: apply now or later (item 132):** the conditions are in the checklist. Default
  meanwhile: not applied, unsigned stable releases authorised.
- **Issue #100: model download through a PAC proxy with an Ollama started outside ErgoptiPlus
  (October 22):** 2353a72eed relaxed the #99 refusal for a foreign daemon (Ollama.app, Homebrew,
  PATH): `ollama pull` only asks that daemon to fetch with its own network settings, which
  Ergopti cannot govern, so the pull now runs and its own failure is reported; a daemon of
  unknown or Ergopti origin stays fail-closed. Default meanwhile: relaxed (on dev, after v1.0.5).
  Confirm or ask for a revert.
- **macOS 2.8-3.2 s freeze when a webview window opens (October 22):** `wv:hswindow()` scans every
  window of every application on the main thread. Default meanwhile: not changed. Say if an agent
  should fix it by looking only among Hammerspoon's own windows.

## Answered

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
