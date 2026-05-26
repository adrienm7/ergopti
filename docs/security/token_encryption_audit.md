# API Token Encryption — Security Audit & OS Keystore Migration Guide

**Item:** 6.3.1  
**Date:** 2026-05-26  
**Scope:** `static/drivers/hammerspoon/modules/llm/api_token_crypto.lua` (macOS)  
and `static/drivers/autohotkey/modules/llm/api_token_crypto.ahk` (Windows)

---

## 1. Current Implementation Summary

Both modules encrypt API tokens for at-rest storage using the OS-supplied secret
store. They share an identical public contract: a `<scheme>:<opaque>` storage
shape that the rest of the codebase never needs to inspect.

### 1.1 macOS driver (`api_token_crypto.lua`)

| Property | Value |
|---|---|
| Mechanism | macOS Keychain via `/usr/bin/security` CLI |
| Write path | `security add-generic-password -U -a <entry_id> -s org.ergopti.llm-api-token -w` (secret read from stdin, never from argv) |
| Read path | `security find-generic-password -a <entry_id> -s … -w` (outputs password to stdout) |
| Storage shape | `keychain:<entry_id>` (opaque reference, no secret material on disk) |
| Legacy compat | Any value without the `keychain:` prefix is treated as cleartext and silently migrated on next save |
| Error strategy | On any failure, falls back to plaintext — token is never lost |

### 1.2 Windows driver (`api_token_crypto.ahk`)

| Property | Value |
|---|---|
| Mechanism | Windows DPAPI — `Crypt32\CryptProtectData` / `CryptUnprotectData` via DllCall |
| Storage shape | `dpapi:<base64>` (DPAPI ciphertext encoded as a single-line base64 string) |
| Secondary entropy | Static application string `"ergopti.llm.token"` mixed into every call |
| Encoding | `CryptBinaryToStringW` / `CryptStringToBinaryW` (CRYPT_STRING_BASE64, no CRLF wrapping) |
| Legacy compat | Same pattern: missing prefix → cleartext → re-encrypted on next save |
| Error strategy | On any failure, returns cleartext — token is never lost |

---

## 2. Security Properties

### 2.1 What the implementations protect against

**macOS Keychain (`api_token_crypto.lua`)**

- **Disk leaks.** The Keychain entry is stored in `~/Library/Keychains/`, encrypted
  by the user's login password. A raw copy of `hs.settings` (a plist in
  `~/Library/Preferences/`) reveals only the opaque `keychain:<entry_id>` string.
- **Cross-user access.** macOS ACLs prevent another local user from reading the
  entry — each user account has its own Keychain.
- **Process isolation (partial).** The `security` CLI requires the user to have
  unlocked the login Keychain. Background processes (e.g., launchd items running as
  a service user) cannot read the entry without first authenticating.
- **ps-visibility of the secret.** The token is piped via stdin (`task:setInput`),
  not placed in argv. It therefore does not appear in `ps aux` output.

**Windows DPAPI (`api_token_crypto.ahk`)**

- **Disk leaks.** The DPAPI master key is derived from the user's Windows login
  credentials (PBKDF2 + domain context). A raw copy of `config.toml` or
  `api_entries.json` reveals only base64 ciphertext that is unreadable without
  the originating user session.
- **Cross-user access.** DPAPI keys are per-user; a different Windows user account
  on the same machine cannot decrypt.
- **Cross-machine portability.** DPAPI keys are machine- and user-scoped; copying
  the base64 blob to another machine produces a decrypt failure.
- **Secondary entropy.** The hardcoded `"ergopti.llm.token"` entropy string means
  a generic DPAPI tool (`dpapi.py`, PowerShell snippets) cannot round-trip the
  value without knowing this application-specific entropy. This is a mild barrier,
  not a cryptographic guarantee.

### 2.2 What the implementations do NOT protect against

| Threat | macOS | Windows | Notes |
|---|---|---|---|
| Same-user malicious process | Not protected | Not protected | Any process running as the same user can call `security find-generic-password` or `CryptUnprotectData` — this is by design in both DPAPI and Keychain. |
| Unlocked-screen attack | Not protected | Not protected | If the screen is unlocked, a logged-in attacker can trivially extract tokens. |
| Memory scraping | Not protected | Not protected | Cleartext is held in Lua/AHK string variables during runtime; a process with ptrace/debugging rights can dump it. |
| Backup leaks (macOS) | Partially protected | N/A | Time Machine backs up the Keychain file but encrypts it with the Keychain password. iCloud Keychain syncs are encrypted. Third-party backup tools that grab raw plist files see only the reference string. |
| Cloud sync of config file | Protected | Protected | The secret material is never in the config file — only the opaque reference/ciphertext blob. |
| Roaming profile / domain scenarios (Windows) | N/A | Partially protected | DPAPI behaves differently in domain environments with roaming profiles. If the domain controller is unreachable, the DPAPI master key may be inaccessible. |
| Legacy cleartext configs | Cleartext until next save | Cleartext until next save | Both modules auto-migrate on next write, but if the user never opens the LLM panel again after upgrading, the old plaintext value persists. |

---

## 3. Implementation Correctness

### 3.1 macOS (`api_token_crypto.lua`) — PASS

- **No custom crypto.** The implementation delegates entirely to the OS Keychain.
  There is no symmetric cipher, no IV, no mode-of-operation to get wrong.
- **Stdin-only secret delivery.** `hs.task:setInput(cleartext)` feeds the token
  via stdin; the token never appears in argv. This is the correct approach per
  `security(1)` man page.
- **Shell injection mitigation.** `quote_shell()` single-quotes all arguments and
  escapes embedded single quotes with `'\''`. This prevents injection through
  entry_id values. The only path that touches a shell is `hs.execute(cmd)` in
  `decrypt` and `delete`; the write path uses `hs.task` (no shell involvement).
  **Minor finding:** the read/delete paths go through `hs.execute` with a
  shell-escaped string. This is safe for reasonable `entry_id` values but a
  defence-in-depth improvement would be to use `hs.task` there too (see §4).
- **Double-wrap prevention.** `is_encrypted` guard in `encrypt` prevents
  re-wrapping an already-stored reference.
- **No key material on disk.** Confirmed — only `keychain:<entry_id>` is persisted.

### 3.2 Windows (`api_token_crypto.ahk`) — PASS with one observation

- **No custom crypto.** DPAPI is a well-audited OS primitive.
- **DATA_BLOB layout.** The `Buffer(8 + A_PtrSize, 0)` layout places `cbData`
  (UInt, 4 bytes) at offset 0, then 4 bytes of padding on 64-bit, then `pbData`
  (Ptr) at offset 8. This matches the `DATA_BLOB` struct on 64-bit Windows.
  **Note:** on 32-bit Windows, `A_PtrSize` is 4 and the struct is 8 bytes; the
  `NumPut("Ptr", ..., in_blob, 8)` is still correct because `cbData` is UInt (4
  bytes) and `pbData` is a 4-byte pointer at offset 4 — but the hardcoded `8`
  offset is the 64-bit alignment offset. This works only on 64-bit Windows and
  would silently corrupt the struct on 32-bit. Ergopti only targets 64-bit
  Windows, so this is acceptable but worth a comment.
- **LocalFree on DPAPI output.** Both protect and unprotect correctly call
  `Kernel32\LocalFree` on the DPAPI-allocated output buffer.
- **UTF-8 encode/decode.** Input is UTF-8 encoded before DPAPI and decoded after
  — correct for non-ASCII tokens.
- **Secondary entropy tradeoff.** The `"ergopti.llm.token"` string is a
  hardcoded compile-time constant visible in the source. It adds friction but is
  not a secret. This is acceptable (DPAPI's user-binding is the real security
  boundary) but should be documented as such.

---

## 4. Threat Model Analysis

### 4.1 Attacker model

The primary threat is **passive exfiltration of the config file** — a backup
tool, cloud sync, or nosy process reads the file. Both implementations
defeat this threat completely.

The secondary threat is **an active malicious process running as the same
Windows/macOS user**. Neither implementation defends against this. This is a
fundamental limitation of user-scoped secret stores: protecting against same-user
malicious code requires hardware attestation (Secure Enclave, TPM) or a separate
broker process with its own authentication, neither of which is in scope.

### 4.2 Risk summary by scenario

| Scenario | Risk before | Risk after encryption landing |
|---|---|---|
| Laptop stolen with disk unencrypted | Critical — plaintext token in plist/TOML | Low — DPAPI/Keychain requires the user password |
| Config file copied to untrusted system | Critical | Low |
| Cloud backup / Dropbox sync of config | Critical | Low |
| Malware on the same user account | Critical | Critical (unchanged) |
| Screen-unlocked physical access | Critical | Critical (unchanged) |
| Old cleartext entry never re-saved | Critical | Critical (unchanged — see §4.3) |

### 4.3 Residual risk: never-re-saved cleartext entries

If a user installs a version of Ergopti that included the encryption landing, but
never opens the LLM settings panel again before that machine is compromised, the
old cleartext value in `hs.settings` / `config.toml` is never migrated.

**Mitigation path:** run a one-shot migration at application startup (see §5.4).

---

## 5. Recommended Migration Path

> **Status:** both modules already use OS keystores. No migration of the
> cryptographic primitive is needed. The recommendations below target code
> hardening, the one structural correctness issue (§3.2), and the residual
> plaintext risk (§4.3).

### 5.1 macOS — replace `hs.execute` with `hs.task` in `decrypt`/`delete`

**File:** `static/drivers/hammerspoon/modules/llm/api_token_crypto.lua`

`decrypt` and `delete` currently call `hs.execute(cmd)` with a shell-quoted
command string. The write path correctly avoids the shell (`hs.task:setInput`).
Replacing the two `hs.execute` calls with `hs.task` eliminates the last
shell-interpolation surface entirely.

```lua
-- Current (decrypt)
local cmd = string.format(
    "/usr/bin/security find-generic-password -a %s -s %s -w",
    quote_shell(entry_id), quote_shell(KEYCHAIN_SERVICE))
local out, ok = hs.execute(cmd)

-- Recommended (no shell, no quote_shell needed for these paths)
local result = nil
local task = hs.task.new("/usr/bin/security",
    function(rc, stdout, _)
        if rc == 0 then result = stdout:gsub("\n+$", "") end
    end,
    { "find-generic-password", "-a", entry_id, "-s", KEYCHAIN_SERVICE, "-w" })
task:start()
task:waitUntilExit()
```

**Effort:** ~30 min. No breaking change. `quote_shell` can be removed once both
remaining call sites are ported.

### 5.2 Windows — document 64-bit-only assumption

**File:** `static/drivers/autohotkey/modules/llm/api_token_crypto.ahk`

Add a comment at the top of `_LLM_DPAPI_Protect` / `_LLM_DPAPI_Unprotect`
noting that the `8`-byte offset for `pbData` in the `DATA_BLOB` struct is
correct only on 64-bit Windows (`A_PtrSize == 8`). Ergopti already requires
64-bit Windows, but the assumption should be explicit and fail-fast rather than
silently wrong.

```ahk
; DATA_BLOB layout (64-bit only — Ergopti requires 64-bit Windows):
;   offset 0: cbData (UInt, 4 bytes)
;   offset 4: 4-byte struct alignment padding
;   offset 8: pbData (Ptr, 8 bytes)
; A_PtrSize assertion guards against accidental 32-bit compilation.
if (A_PtrSize != 8)
    throw Error("api_token_crypto: DPAPI binding requires 64-bit AHK runtime.")
```

**Effort:** ~15 min. No breaking change.

### 5.3 Linux driver (future work)

The Linux driver (`static/drivers/linux/`) does not yet have an
`api_token_crypto` module. When it is added, the recommended backend is
**`secret-tool`** from the `libsecret` package (ships with GNOME; available as
`libsecret-tools` on Debian/Ubuntu):

```bash
# Store
echo -n "$TOKEN" | secret-tool store --label="Ergopti LLM token" \
    application ergopti entry_id "$ENTRY_ID"

# Read
secret-tool lookup application ergopti entry_id "$ENTRY_ID"

# Delete
secret-tool clear application ergopti entry_id "$ENTRY_ID"
```

Storage shape: `secretservice:<entry_id>` (mirrors the macOS `keychain:` prefix).

On systems without a Secret Service daemon (headless servers, CI), fall back to
an environment variable (`ERGOPTI_LLM_TOKEN_<ENTRY_ID>`) rather than cleartext
on disk.

**Effort:** ~2–4 h for a new module following the existing module pattern. No
impact on macOS or Windows.

### 5.4 One-shot startup migration for legacy cleartext entries

Both drivers already auto-migrate on the next save from the LLM settings panel.
For users who never open that panel again, a startup migration function should be
added to each driver's LLM init path:

**macOS (`modules/llm/init.lua`):**

```lua
-- Migrate any stored cleartext tokens to Keychain on startup.
for _, entry in ipairs(state.api_entries or {}) do
    if entry.token and not ApiTokenCrypto.is_encrypted(entry.token) then
        Logger.info(LOG, "Migrating cleartext token for entry '%s' to Keychain…", entry.id)
        entry.token = ApiTokenCrypto.encrypt(entry.id, entry.token)
        -- persist back to hs.settings
    end
end
```

**Windows (`ErgoptiPlus.ahk` or equivalent LLM init):**

Iterate `api_entries`, call `LLM_ApiToken_Encrypt` on any value that
`LLM_ApiToken_IsEncrypted` returns false for, and write back to `config.toml`.

**Effort:** ~1–2 h per driver. Breaking change risk: low — worst case is a
Keychain/DPAPI write failure, which falls back to the existing cleartext value.

---

## 6. Migration Effort & Breaking Change Risk Summary

| Item | Driver | Effort | Breaking change risk |
|---|---|---|---|
| 5.1 Replace `hs.execute` with `hs.task` in decrypt/delete | macOS | 30 min | None |
| 5.2 Document + assert 64-bit assumption | Windows | 15 min | None |
| 5.3 Implement Linux `api_token_crypto` module | Linux | 2–4 h | None (new module) |
| 5.4 Startup migration for legacy cleartext entries | macOS + Windows | 2–4 h | Low |

No cryptographic primitive migration is required. Both drivers already use
OS-grade secret stores. The main residual risk — legacy cleartext entries that
are never re-saved — is addressed by item 5.4.
