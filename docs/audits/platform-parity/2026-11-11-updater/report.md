# Updater: Windows, macOS, Linux and shared

Audited source: `61162fd0` (`claude/ergopti-todo-parity-audit`, merged with
`dev` `205fce86`). Date: November 11, 2026.

The census's next module after the shortcuts. The updater was campaigned on
2026-11-04 ([recovery audit](../2026-11-04-recovery/report.md), source
`3a680d9f`); its findings (LUR-001, MUR-001) and recorded policies
(notify-only, a feed-only release is never installed, signature enforcement
off, backup of the chosen release only) are not repeated. This clone is
shallow (oldest commit `c6582d2e`), so the drift since `3a680d9f` was read
from the current source, not from a diff. Windows
(`windows/modules/updater/*.ahk`) is the read-only reference; the shared
updater (`_shared/lua/updater`, `_shared/modules/updater`), the Linux manager
and menu and the macOS updater were compared with it. Candidates were
replayed through the real Linux manager under LuaJIT; no network, desktop
notification, Sparkle or AHK was executed.

## Fixed (Linux)

| Id      | Sequence                                                                                                                                    | Windows                                                                                       | Linux before                                                       | Regression                     |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------ |
| UPL-001 | A manual check finds v1.4.0, the window is closed, the next background check fails offline                                                  | `_Updater_HandleBackgroundResult` records the failure and shows nothing (`self_update.ahk`)   | The failed check handed back the known release: it was announced   | `failed-check-no-announcement` |
| UPL-002 | No update-check window (no WebKitGTK or display): a release without the bundle, no release, a parse failure, a failure with a release known | `Updater_ShowAvailableUpdateCallback` words each outcome (`self_update.ahk:1589-1625`)        | « up to date », « up to date », « no connection », « new version » | `check-notice-wording`         |
| UPL-003 | A background check reads a newer release from the public feed (API blocked)                                                                 | `_Updater_AnnounceCheckOnlyRelease` appends `update_check.check_only` (`self_update.ahk:756`) | The plain « new version » sentence                                 | `check-only-notice`            |

UPL-002 and UPL-003 share `linux/modules/updater/check_notice.lua`, which
words a notification from the structured answer the window shows
(`updater.check_result`). macOS clears its latest release on a failed
background check (UPL-001 does not apply), and its feed-only announcement
hands off to Sparkle, which installs from the appcast (UPL-003 does not
apply).

## Decided

- **UPD-1, a proxy or captive-portal answer** (decided by the maintainer on
  2026-11-11): a 200 whose body does not open a JSON array is « no
  connection » with the feed fallback on every driver, through the shared
  `updater.release_sources.opens_release_array` (Linux `accept_page`, macOS
  `read_response`); a malformed or cut array stays « parse failed ». A Linux 304
  with no usable cached page is « no connection » with the feed too, the
  cached page dropped. Regressions `upd1-captive-portal` (Linux and macOS).
  Windows counterpart, for the maintainer (`modules/updater/core.ahk`
  `_Updater_InterpretResponse`): for a 200 whose body does not open a JSON
  array (`^\x{FEFF}?\s*\[`, the opening half of `ui/changelog/init.ahk:747`), log a warning
  and return "" (no list, so the caller reads the feed) instead of handing the
  page to the release parser; test with an HTML 200 that the feed is
  requested and the answer is `updater.no_connection`.

## Windows, report only

- **UPW-005:** `asset_signature.ahk:147-149,162` compares the policy's
  `enforcement` with AHK's case-insensitive `=`, so « Required » or « OFF »
  are admitted where Lua (`linux/infra/asset_signature.lua`) refuses them as
  a bad policy. It matters only for a hand-edited `asset_signing.json` (the
  shipped value is « off »). Counterpart: compare with `==`.

## Refuted

Version ordering and labels (non-semver fails closed, build metadata
stripped, the shared vectors replayed); the schedule (next due, clock moved
back, backoff capped at the interval, jitter, a refused write keeping the
session's copy, a paused driver skipping a due check); the shared defaults
and channel registry read by both Lua drivers; the busy refusal; the
rate-limit sentence; the feed fallback on background and one-click checks;
the signature gate failing closed on a bad policy; the chosen-release
backup; an unknown persisted channel and a channel switch revoking an
answer in flight; every updater locale key in the 21 locales.

## Remaining work

Not compared: the macOS manual check without its window, the Linux asset
URL bound by exact name rather than by repository path (integrity rests on
the `.sha256` file). Native receiving unqualified.
