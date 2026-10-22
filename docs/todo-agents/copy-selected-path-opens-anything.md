<!-- docs/todo-agents/copy-selected-path-opens-anything.md -->

# copy_selected_path opens what the selection names

The maintainer's report (October 21): the action bound by default to Win+S
on Windows and Ctrl+S on macOS (any shortcut or gesture can run it) searched
the web for a selected IP address instead of opening it. The request: on
every system, the action opens whatever the selection names (a site, an IP,
a file, a folder, a registry key, and so on) and searches only plain text.
The fix is in the action (`copy_selected_path`), not in a binding; no
default binding changed.

## Done

Committed on local dev (not pushed); see `git log --grep=open-target`.

- **One rule.** `_shared/lua/open_target` (macOS and Linux) and its port
  `windows/infra/open_target.ahk` classify the selection: a URL with or
  without its scheme, an IPv4 or IPv6 address and localhost (each with an
  optional port and path, opened as `http://`), a mail address (`mailto:`),
  the opaque schemes mailto, tel, sms, callto, sip, xmpp, magnet and news, a
  `file:` URI, a drive, UNC, `%VARIABLE%`, `~`, POSIX or `$VARIABLE` path, a
  registry key (`HKLM\…`, `HKCU:\…`, `Computer\…`, `Ordinateur\…`,
  `Registry::…`), `ms-settings:` and `shell:`, a bare `name.ext` file name,
  or plain text. Surrounding spaces (no-break ones too), quotes, brackets,
  guillemets and trailing punctuation are removed. `javascript:`,
  `vbscript:` and `data:` are never opened. The rule and 82 vectors are in
  `_shared/tests/corpus/shortcuts/open_target_vectors.json`, replayed by the
  three suites; `tools/test/test-open-target-vectors-shared.cjs` (js-0452)
  pins the two ports' vocabularies, the search fallback (the
  `shortcuts.search` default) and the four notices together.
- **Opening.** Windows hands a path to the shell quoted as one file (so no
  part of it becomes arguments), a URL only when it holds no whitespace, and
  a registry key to the existing `RegJump`. macOS uses `open` with the path as
  one argument (a file in its default application, a folder in Finder) and
  `hs.urlevent.openURL` for URLs. Linux uses `adapters/desktop_opener`
  (`xdg-open` with one argument, no shell) and reads the X11 primary
  selection like `search_web`.
- **Fail fast.** A path that does not exist, a bare file name (its folder is
  unknown outside the file manager, so it is not guessed), a target that
  cannot be launched, and on macOS and Linux a registry key, a Windows path,
  `ms-settings:` or `shell:` are logged (start/success pair, then an error)
  and notified with `open_target.*` (21 locales); none becomes a web search.
- **Linux** now offers the action (`platform = "all"`, needs xclip and
  xdg-open). Its file-manager branch (copying the selected files' paths) is
  still not implemented: a file manager publishes its selection as
  text/uri-list, which the clipboard adapter cannot read by MIME type.
- **Tests.** Windows `test_open_target_vectors.ahk` (cases
  `open-target-ip-address`, `open-target-missing-path-reported`) and the
  re-encoded search cases of `test_shortcuts.ahk`; macOS
  `text_actions/test_open_target_vectors.lua`; Linux
  `actions/test_open_selection.lua` (cases named `open-target`). Before the
  fix, HEAD's Windows `SearchPath` sent `192.168.1.1`, `10.0.0.1:8080/admin`
  and `localhost:3000` to the search engine, and HEAD's macOS
  `is_probable_url` searched them too and turned `/Users/ada/a.txt` into
  `http:///Users/ada/a.txt`.

## Remaining

- Linux file-manager branch (text/uri-list), as above.
- Internationalised domain names in Unicode (`例え.jp`) and a bare IPv6 with
  a zone (`fe80::1%eth0`) are searched, not opened; the punycode form opens.
- A bare file name is never resolved against a folder: outside Explorer and
  Finder the driver does not know one, and inside them the action copies the
  path instead.

## Check on each machine

1. Select `192.168.1.1` (or your router's address) in any text field and run
   the action (Win+S on Windows, Ctrl+S on macOS, a bound gesture or
   shortcut on Linux): the browser opens `http://192.168.1.1`, no search.
2. Same with `localhost:3000`, `example.com`, `ada@example.com` (mail
   draft) and `https://example.com/page.` (the final dot is dropped).
3. Select the full path of an existing file, then of a folder (with spaces,
   in quotes or not): the file opens in its application, the folder in
   Explorer, Finder or the file manager. Try `~/Documents` and, on Windows,
   `%APPDATA%`.
4. Select a path that does not exist: a notice says nothing exists there and
   nothing opens (no search).
5. Windows: select `HKEY_CURRENT_USER\Control Panel\Desktop`, then
   `HKCU:\Software`: Regedit opens at that key. macOS and Linux: the same text
   shows « … can only be opened on Windows ».
6. Windows: select `ms-settings:display`: the display settings open.
7. Select `notes.txt`: a notice asks for the full path. Select
   `bonjour le monde`: a web search opens.
