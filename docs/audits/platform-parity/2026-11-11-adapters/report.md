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

## Decisions pending (behaviour left unchanged)

- **ADD-1, password-manager applications.** macOS treats every field of a
  listed password manager (1Password, Bitwarden, KeePassXC…) as secure
  (`macos/modules/keymap/utils.lua` `isSecureApp`), so hotstrings and keymap
  output are inert there. Linux (`adapters/secure_field_detector.lua`
  `isSecureApp`) and Windows (`SFD_IsSecureApp`) keep such a list with no
  production caller, and the Linux keystats comment that says the list is
  « consulted in addition » is not true; the three lists also differ.
  Recommendation: make the app-wide gate the contract on the three drivers,
  from one shared list.
- **ADD-2, restoring an empty clipboard.** Linux restores a clipboard nobody
  owned as an owned empty string (pinned, `clipboard-unowned-empty`); macOS
  clears the pasteboard and Windows restores an empty `ClipboardAll`.
  Clipboard managers record the empty entry on Linux.
- **ADD-3, the Linux application identity.** X11 reports `/proc/<pid>/comm`,
  which the kernel cuts to 15 bytes (`window_info.lua`); Wayland reports the
  `app_id` or window class. An exclusion list built under one session type
  stops matching under the other. A change needs a migration of saved
  exclusion lists.

## Windows, report only

`SFD_IsSecureApp` (`secure_field_detector.ahk:604`) has no production
caller; it rides on ADD-1.

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
