# Adapters and infrastructure: Windows, macOS, Linux and shared

Audited source: `486194c1` (`claude/ergopti-todo-parity-audit`). Date:
November 11, 2026.

The census's next areas after the updater: the `adapters/` and `infra/`
folders of the Lua drivers, whose files changed most since the pinned census
(`2026-11-05-native-ui/source-areas.json`: 80 changed and 20 new files on
Linux, 69 and 11 on macOS, compared by Git blob). Windows
(`windows/adapters/*.ahk`) is the read-only reference. Candidates were
replayed through the real Linux clipboard adapter under LuaJIT with the
fixture of `test_clipboard_snapshot_restorability.lua`; no X server,
compositor, Hammerspoon or AHK was executed.

## Triage

| Group                                                   | Risk                             |
| ------------------------------------------------------- | -------------------------------- |
| Clipboard borrow and restore, selection probes          | High (taken)                     |
| Secure-field and privacy, focus and window identity     | High (taken)                     |
| Input access and injection plumbing                     | High, engines already campaigned |
| Configuration read and write, scopes, migration         | Medium                           |
| Lifecycle: reload, shutdown, wake                       | Medium                           |
| Notifications and UI surfaces                           | Medium-low                       |
| HTTP, proxy and network                                 | Low-medium                       |
| Timers, event loop, logging, diagnostics, shell, crypto | Low (plumbing)                   |

## Fixed (Linux)

| Id      | Sequence                                                                                          | Windows                                                                  | Linux before                                                      | Regression             |
| ------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------- | ---------------------- |
| CBL-001 | X11, a screenshot copied alone (no text target), then an emoji hotstring or a selection transform | `CB_SaveAll` saves any format with `ClipboardAll` (`clipboard.ahk:1036`) | The failed text read of an owned clipboard refused every borrower | `clipboard-image-only` |

A clipboard whose owner advertises no text format is now saved format by
format and restored through the multi-format owner; a text format that fails
to read, or no owner able to restore the formats, still refuses before the
clipboard changes. On Wayland, `wl-paste` falls back to an offered type, so
the case did not arise there.

## Decided

- **ADD-1, password-manager applications** (decided by the maintainer on
  2026-11-11): every application of `_shared/data/secure_apps.json` (the
  three driver lists merged) is a secure field as a whole on the three
  drivers. macOS `isSecureApp` and Linux `isSecureApp` and the metrics read
  the file (rule `_shared/lua/secure_apps.lua`); Linux
  `keystats.is_context_protected` protects a listed application whatever the
  metrics filters say, and the focus guard publishes that verdict to every
  text consumer (hotstrings, AI, clipboard borrowers). The keystats comment
  claiming the detector list was « consulted in addition » is replaced.
  Regressions `add1-secure-app`; gate `test-secure-apps-single-source.cjs`.
  Windows counterpart, for the maintainer
  (`adapters/secure_field_detector.ahk`): build `SFD_SECURE_APPS` from the
  file's `windows` names (a `Map` with `CaseSense := "Off"`, a read or parse
  failure treating every application as secure), and return true at the top
  of `SFD_IsSecureField` when `SFD_IsSecureApp` holds the focused window's
  process name (`WinGetProcessName`); test in `test_secure_field_detector.ahk`
  that a `RoboForm.exe` window is secure.
- **ADD-2, restoring an empty clipboard** (decided by the maintainer on
  2026-11-11): a Linux borrow of a clipboard nobody owned gives it back
  unowned, as macOS clears its pasteboard (`clipboard.lua` snapshot
  `unowned`, `x11_selection_stamp.disown`, `wl-copy --clear`), no longer as
  an owned empty string. Regressions `clipboard-unowned-empty`, updated
  deliberately. Windows: no change (an empty `ClipboardAll` empties the
  clipboard).
- **ADD-3, the Linux application identity** (decided by the maintainer on
  2026-11-11): X11 reports the `WM_CLASS` class (`x11_focus.window_class`),
  the identity Wayland's app_id and class already gave; `/proc/<pid>/comm`
  (cut to 15 bytes) is only the fallback. Saved exclusion lists are
  converted once (`infra/app_identity_migration.lua`, table
  `_shared/data/linux_app_identities.json`), unknown entries kept and
  logged. Regressions `add3-app-identity`. macOS and Windows: no change.

## Windows, report only

`SFD_IsSecureApp` (`secure_field_detector.ahk:604`) has no production
caller; ADD-1 above gives its counterpart.

## Refuted

A foreign copy overwritten by a restore (only Ergopti's own or the saved
bytes are replaced, as Windows' sequence fence); a Ctrl left held after a
failed paste chord; the X11 owner worker's INCR, TARGETS, TIMESTAMP and
MULTIPLE handling and its private snapshot file; the 64 MB rich-snapshot cap
and its fail-closed reads; xsel-only and GNOME-without-data-control sessions
refusing rich borrowing; the Wayland empty-clipboard message; macOS
`save()` refusing multi-item, partially read or changed pasteboards; macOS
borrower predicates failing closed; macOS secure-field classification
failing closed on incomplete AX reads; the Linux notifier reporting a
missing or failing `notify-send`.

## Remaining work

Not reviewed: configuration, lifecycle, notification and network adapter
groups in depth. Native receiving unqualified.
