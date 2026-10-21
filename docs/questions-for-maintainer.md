<!-- docs/questions-for-maintainer.md -->

# Questions for the maintainer

Collected while working alone (October 20-21). Each question names the default taken meanwhile;
answer once, then move the answered line below.

## Open

- **Tap-hold hold rows on Windows and Linux (October 21):** the tap and, on macOS, the hold now open the shared action
  picker. The Windows and Linux « Hold → … » rows still list the seven shared hold options (none, five modifiers, the
  navigation layer) in a submenu, because they are hold options, not actions. Default meanwhile: kept as a submenu. Say
  if they should open a picker window too ([handoff](todo-agents/macos-tap-hold-action-picker.md)).

## Answered

- **Merge commits on `dev` (answered October 21):** no merge commits, `dev` and `main` stay linear. Integrate by
  rebasing and fast-forwarding; the merge `330cbe4c04` was rewritten into linear commits (`dev` force-pushed once, with a lease).
- **Replies on GitHub (answered October 21):** not posted, by the maintainer's choice; issues #84 and #95-#97
  are closed without a reply. Their open checks stay in the TODO.
- **AppImage catalog (answered October 21):** `/retest` is posted on AppImage/appimage.github.io#10422 against
  v1.0.4; the bot's result is awaited.
- **Release (answered October 21):** v1.0.4 is released, with no deferred scope.
- **October 21 answers:** FileDescription in English with the website in Comments; macOS manual ISO/ANSI selector; SignPath
  application implications to be listed before deciding; Linux aligned on Windows and macOS (`[BS]x`, recommended settings);
  Ollama redirect policy: best design even if long; no review screen for bug reports; NTLM: WinHTTP system stack; HS-274
  tools: delete or put in CI; Hammerspoon coexistence. Details in the checklist.
