<!-- docs/questions-for-maintainer.md -->

# Questions for the maintainer

Collected while working alone (October 20-22). Each question names the default taken meanwhile;
answer once, then move the answered line below.

## Open

- **Linux recommended gestures doubled by the desktop (October 22):** since fa965e42f2 Linux
  recommends the Windows three- and four-finger swipes (tab close/prev/next/new, desktop
  prev/next). The touchpad is read without being grabbed, so GNOME, KWin, Hyprland and
  cosmic-comp also run their own action (a double desktop switch). Default meanwhile: kept. Say
  if Linux should recommend `none` for them, with the reason in the menu.
- **macOS recommendations differ from Windows (October 22):** AI backend and model (Windows
  Ollama Qwen3.5-0.8B, macOS MLX gemma-4-E2B-it), trigger debounce (500 against 200 ms),
  three-finger swipes (tabs against tabs and word selection), four-finger swipes (windows and
  desktops against none), four-finger tap (alt_tab_monitor against win_app_next), number row
  (digits against native). Default meanwhile: unchanged. Say which to align.
- **AI off on Linux (October 22):** the agent's automatic mode still runs with the AI off (pinned
  on purpose by `test_agent_auto`) and the `llm_*` chords stay bound (they refuse the keystroke).
  Default meanwhile: unchanged. Say if both should be disarmed with the AI off, as on macOS
  (6dff8de6bf) and Windows.

## Answered

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
