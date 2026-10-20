<!-- docs/questions-for-maintainer.md -->

# Questions for the maintainer

Collected while working alone (October 20-21 night). Each question names the default taken meanwhile;
answer once, then delete the answered lines.

## Open

1. **Linux `[BS]x` pairs.** After a correction Windows and macOS count pairs such as `[BS]x`; Linux
   deliberately does not (an existing test requires it). Align Linux on the other two? Default: left as is.
2. **Ollama redirect policy.** Ollama 0.40.4 resolves the download host through local DNS
   (`ValidateRedirectTarget`); behind a proxy that cannot resolve it locally, pulls are refused. Leave an
   unresolved name to the proxy or native worker while still refusing names that resolve to private
   addresses? It reverses an assertion in `address_policy_test.go` and needs a Go toolchain. Default:
   fixture changed only, product policy unchanged.
3. **Linux recommended setting for LAlt then CapsLock.** The manifest still recommends `none` on Linux;
   CapsWord now works there. Recommend `caps_word`? Default: unchanged.
4. **Report a bug without a review screen.** The menu button copies the approved report and saves a file;
   the old on-screen review step is gone. Keep (default) or restore a review step?
5. **Replies on GitHub.** Drafts are ready but not posted: #97 (`scratchpad/issue97/reply.md`), #96 after the
   next release, #95 point 2 (Mac `curl` measurement). Post them as drafted?
6. **AppImage catalog.** `/retest` on AppImage/appimage.github.io#10422 only helps after the next release
   (the catalog tests the latest release). Post it from PowerShell right after the release? Default: wait.
7. **Release.** Cut the next release once `dev` is green, with no deferred scope? Default: no tag without
   your word.
8. **Windows `config.toml` blank lines.** All three drivers and templates now use the 5/3 style. Anything
   else to align? Default: done.

## Answered

(none)
