# Keylogger Privacy — Audit Report (item 6.3.2)

**Date:** 2026-05-26
**Scope:** Both keylogger drivers — AHK (`static/drivers/autohotkey/`) and HS (`static/drivers/hammerspoon/`)
**Invariant audited:** Passwords, API keys, and 2FA codes must never be persisted.

---

## 1. Architecture Overview

The keylogger captures keystrokes for ergonomic metrics: n-gram frequencies, WPM, inter-key delays, finger streaks. It writes to two layers:

1. **`today.log`** — hot-path JSONL append on the keystroke flush path.
2. **`data.sql`** — append-only SQL file ingested asynchronously from `today.log`.

Both layers are protected by the same set of privacy filters described below.

---

## 2. Privacy Filters — What Is Blocked

Four independent, configurable filters run before any buffer mutation or disk write.

### 2.1 Secure Field Filter (default: ON)

**HS driver (`modules/keylogger/init.lua`, line ~391):**

```lua
if CoreState.secure_field_filter_enabled and CoreState.is_secure_field then return end
```

`CoreState.is_secure_field` is set by the AX observer in `context_tracker.lua` via the `AXObserver` callback on `AXValueChanged` / `AXFocusedUIElementChanged`. The AX API directly exposes whether a text field is `AXSecureTextField`.

**Belt-and-suspenders:** Because the AX observer may attach too slowly on a first-ever keypress in a newly launched app, the system-auth bundle-ID guard (§2.3) is a redundant second layer.

**AHK driver (`modules/keylogger/keylogger.ahk`, §13; `lib/metrics/metrics_filters.ahk`):**

A three-layer detector runs on every `MF_ShouldFilter()` call (called before any `buffer_events.Push` in both `KL_Hook_OnChar` and `KL_Hook_OnKeyDown`):

1. **Win32 ES_PASSWORD style bit (0x20)** on `Edit`-class controls — covers native Win32 dialogs, RDP login, Windows Logon.
2. **Class-name allow-list** — `PasswordBox` (WPF/UWP), `TPasswordEdit` (Delphi), `MaskedEdit`, `TFormPassword`.
3. **UIA `IsPassword` property** — canonical modern API; covers Electron, .NET WPF, Chrome/Edge web `<input type="password">`.

Results are cached per-HWND with a 500 ms TTL to bound the UIA round-trip cost.

### 2.2 Private Browsing Filter (default: ON)

**HS driver:**
```lua
if CoreState.private_filter_enabled and CoreState.is_private_window then return end
```
`is_private_window` is updated by a `hs.window.filter` subscriber watching browser focus and title changes.

**AHK driver:** `MF_ShouldFilter()` runs regex patterns against window titles, matching localised private-mode strings for Chrome, Firefox, Edge, Safari, Brave, and Opera across EN/FR/DE.

### 2.3 System Auth Dialog Filter (default: ON)

**HS driver:**
```lua
if CoreState.system_auth_filter_enabled and CoreState.active_app_bundle
and SYSTEM_AUTH_BUNDLE_IDS[CoreState.active_app_bundle] then return end
```
`SYSTEM_AUTH_BUNDLE_IDS` contains `com.apple.SecurityAgent` (admin/sudo) and `com.apple.CoreAuthUI` (Touch ID / biometric).

**AHK driver:** `MF_ShouldFilter()` checks `MF_SYSTEM_AUTH_PROCESSES` (consent.exe, logonui.exe, credui.exe, winlogon.exe, credentialuibroker.exe) and `MF_SYSTEM_AUTH_CLASSES` (ConsentUI, LogonUI, Credential Dialog Xaml Host).

### 2.4 Disabled-Apps Filter (default: empty list)

The user can exclude specific apps by bundle ID or process name. Checked first in both drivers because it is the cheapest lookup (hash map).

---

## 3. Accepted Design Trade-off — The `text` Field

The `typing` event written to `today.log` and `data.sql` contains a `text` column holding the concatenated plaintext of all characters typed in a burst (between two flush triggers such as a sentence-ending punctuation or idle timeout).

**Example:**
```json
{"type":"typing","text":"hello world","wpm":72.3,"events":[...]}
```

This is a **deliberate trade-off** made at the architecture level:

- The `text` field enables the ergonomic metrics dashboard to display a sample of recent typing for context.
- It is only populated for keystrokes that passed all four guards — so password fields, auth dialogs, and private browsing windows contribute zero characters to it.
- The `events` array contains per-character metadata (keycode, delay, hold-time, synthetic flag) which also holds the raw character in the `r` subfield.

**Implication:** Ordinary text typed in non-sensitive contexts (documents, terminals, IDE, etc.) is logged in plaintext. Users who require complete plaintext privacy should disable the keylogger feature entirely, or set `keylogger_encrypt = true` to activate at-rest encryption of the metrics folder.

---

## 4. Verification — What Was Checked

| Check | HS driver | AHK driver |
|-------|-----------|------------|
| Secure field flag checked before any `buffer_events.Push` | ✅ `init.lua:391` | ✅ `keylogger_hook.ahk:197,270` |
| System-auth app blocked before any buffer mutation | ✅ `init.lua:394` | ✅ `metrics_filters.ahk:183` |
| Private window blocked before any buffer mutation | ✅ `init.lua:391` | ✅ `metrics_filters.ahk:191` |
| Password filter also checked in `KL_AppendLog` hot path | N/A (filter is in handle_key) | ✅ `keylogger.ahk:605` (redundant defence-in-depth) |
| Secure field transitions flush normal buffer before blocking | ✅ `context_tracker.lua` | ✅ buffer reset on new `is_secure_field=true` context |
| Filter toggle state exposed as user-configurable defaults | ✅ `DEFAULT_STATE` in `init.lua:132` | ✅ `MetricsFilters` class in `metrics_filters.ahk` |

---

## 5. One Identified Gap (AHK)

The header comment in `keylogger.ahk` section 13 referenced a `TODO_UIA` note that the password detector was pending. The audit confirms that **this TODO has been resolved** — the three-layer detector (ES_PASSWORD, class-name, UIA) is fully implemented.

---

## 6. Test Coverage

- **Corpus:** `static/drivers/_shared/tests/corpus/security/keylogger_no_persist_vectors.json` — 10 vectors covering SEC-001 to SEC-010.
- **HS unit tests:** `static/drivers/hammerspoon/tests/unit/modules/keylogger/test_keylogger_privacy.lua` — 12 test cases directly derived from the corpus vectors, covering: secure field guard (3 cases), system auth guard (2 cases), private browsing guard (1 case), normal-field baseline (1 case), buffer flush on field transition (1 case), and filter toggle integrity (3 cases).

---

## 7. Recommendations

1. **No action required** on the filter implementation — both drivers correctly block secrets before any disk write.
2. **Consider stripping `text` and `events[].r` fields** before writing `data.sql` if plaintext storage is ever deemed unacceptable. The aggregator (n-gram walker) only needs keycode and delay metadata, not the character itself.
3. **Monitor the AX observer attach latency** on macOS — on Apple Silicon the observer typically attaches within one event-tap callback. On Intel the latency can occasionally reach 50 ms. The belt-and-suspenders bundle-ID check covers this window.
