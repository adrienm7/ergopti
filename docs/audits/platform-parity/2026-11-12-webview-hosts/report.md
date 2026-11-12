# Webview hosts

Audited source: `8e976501` (`claude/ergopti-todo-parity-audit`). Date:
November 12, 2026.

## Scope

The native layer every page window runs on: Linux `ui/webview_manager.lua`,
`webkit_host` and `dialog_host`, macOS `ui/ui_builder.lua` and
`window_toggle`, and the page-side `_shared/ui/host_bridge.js`, against the
Windows `WebViewHost` (`windows/infra/webview_utils.ahk`). The 2026-11-05
native-ui findings are not repeated, and pausing is out of scope (EDD-1).

Checked and kept:

- **Devtools and gestures:** devtools are off, and swipe and gesture
  navigation are off.
- **New windows:** no page opens one. External links go through the
  `open_url` bridges' allowlist.
- **Window:** a reopen focuses the open window.
- **Messages:** stale or late page messages are refused by session epoch, and
  invalid JSON is dropped.
- **Geometry:** the hard-coded geometry fallbacks are unreachable, because
  every app has a full manifest entry. Windows' hard-coded `MinSize` values
  equal the manifest today, so they are a drift risk only.

## Fixed

| Id      | OS           | Sequence                                                                     | Windows                                | Before                                                   | Regression                        |
| ------- | ------------ | ---------------------------------------------------------------------------- | -------------------------------------- | -------------------------------------------------------- | --------------------------------- |
| WVH-001 | Linux        | Tray, Hotstrings delays, « Settings… »                                       | State pushed on navigation completed   | The window opened empty: the page never posted « ready » | `test-linux-pages-post-ready.cjs` |
| WVH-002 | macOS        | Enlarge the action picker, prompt, personal info, paths or onboarding window | Every page window is `+Resize`         | Not resizable                                            | `wvh-002-resizable-windows`       |
| WVH-003 | macOS, Linux | Right-click a page                                                           | WebView2's default context menu is off | Reload, Back and Forward offered; a reload drops a draft | `test-host-context-menu.cjs`      |

Notes on the fixes:

- **WVH-001:** the new gate holds every shared page a Linux bridge waits for
  to posting « ready ». `token_prompt` is exempt because nothing on Linux opens
  it. The hardware harness `linux/tests/hardware/run_webview_push.lua` still
  sends its own « ready »; it now also arrives from the page.
- **WVH-002:** the manifest minimum size is not applied on macOS, because
  hs.webview offers no minimum-size constraint.
- **WVH-003:** the context menu stays available in text fields, for its
  editing items.

## Open

- **macOS minimum window size (WVH-002):** shrinking a resizable window below
  the manifest minimum needs a native NSWindow constraint that hs.webview does
  not expose.

Native receiving is unqualified.
