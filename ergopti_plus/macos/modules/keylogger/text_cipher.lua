--- modules/keylogger/text_cipher.lua

--- ==============================================================================
--- MODULE: Typed-Text Cipher (Hammerspoon)
--- DESCRIPTION:
--- macOS counterpart of linux/modules/keylogger/text_cipher.lua. Runs the shared
--- at-rest codec (_shared/lua/keylogger/text_crypto.lua) against the columns that
--- hold literal typed text, with a key derived once from this Mac's hardware
--- UUID.
---
--- WHAT THIS REPLACES:
--- The "Chiffrement" menu entry used to call two empty stubs. It ticked its box,
--- persisted the setting, and encrypted nothing — while the privacy guide told
--- users to enable it for at-rest protection. It also collected `*.log.gz` files,
--- a storage format retired when persistence moved to SQLite.
---
--- FEATURES & RATIONALE:
--- 1. The key is derived ONCE and cached. `openssl enc -pbkdf2 -iter 600000`
---    costs roughly half a second per invocation, so a per-row derivation would
---    make the keylogger unusable. Every later call passes the raw key with
---    -K/-iv and costs only the process spawn.
--- 2. The hardware UUID is piped into openssl rather than interpolated into the
---    command line: an argument would publish it in the process table.
--- 3. Fail CLOSED on encryption, OPEN on decryption — identical to Linux, so a
---    database written on one machine reads on the other.
--- ==============================================================================

local M = {}

local Logger     = require("infra.logger")
local Shell      = require("adapters.shell_runner")
local Crypto     = require("adapters.crypto")
local Heredoc    = require("shell.heredoc")
local TextCrypto = require("keylogger.text_crypto")

local LOG = "keylogger.text_cipher"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- Reads this Mac's hardware UUID. Stable across reboots and OS upgrades, and
--- unique per machine — exactly the durability the maintainer asked for, since a
--- key that can be lost turns every stored log into garbage.
local MACHINE_ID_COMMAND =
	"/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | " ..
	"/usr/bin/awk -F'\"' '/IOPlatformUUID/{print $4}'"





-- ========================
-- ========================
-- ======= 2/ State =======
-- ========================
-- ========================

-- Whether at-rest encryption is active. Off by default, matching the shared
-- manifest's metrics.encrypt.
local _enabled = false

-- Cached derived key (64 hex characters). nil until first use.
local _key_hex = nil

-- Set once a derivation has failed, so a broken install does not re-run a
-- 600 000-iteration derivation on every flush.
local _derivation_failed = false

-- Overrides the machine-id command (test seam).
local _machine_id_command_override = nil





-- ==================================
-- ==================================
-- ======= 3/ Key Derivation ========
-- ==================================
-- ==================================

--- Points the machine-id lookup at a specific command, or nil to restore.
--- @param command string|nil
function M._set_machine_id_command(command)
	_machine_id_command_override = (type(command) == "string" and command ~= "") and command or nil
	_key_hex = nil
	_derivation_failed = false
end

--- Derives and caches the session key. Runs at most once per process.
--- @return string|nil The 64-hex key, or nil when it cannot be derived.
local function ensure_key()
	if _key_hex then return _key_hex end
	if _derivation_failed then return nil end

	local machine_id = Shell.exec(_machine_id_command_override or MACHINE_ID_COMMAND)
	machine_id = type(machine_id) == "string" and machine_id:gsub("%s+", "") or ""
	if machine_id == "" then
		_derivation_failed = true
		Logger.error(LOG, "No hardware UUID available — at-rest encryption unavailable.")
		return nil
	end

	local derive, reason = TextCrypto.derive_key_command("stdin")
	if not derive then
		_derivation_failed = true
		Logger.error(LOG, "Cannot compose the key derivation: %s.", reason)
		return nil
	end

	Logger.start(LOG, "Deriving the at-rest key from the hardware UUID…")
	-- Byte-exact stdin: the plain heredoc appends a newline, so the key would be
	-- PBKDF2("<uuid>\n") here and PBKDF2("<uuid>") on Linux and Windows. Same
	-- machine id, three different keys — which quietly falsifies the "identical
	-- format everywhere" claim the parity gate exists to protect.
	local key = TextCrypto.parse_derived_key(Shell.exec(Heredoc.with_exact_stdin(derive, machine_id)))
	if not key then
		_derivation_failed = true
		Logger.error(LOG, "Key derivation produced no usable key — is openssl available?")
		return nil
	end

	_key_hex = key
	Logger.success(LOG, "At-rest key derived (cached for this session).")
	return _key_hex
end





-- =====================================
-- =====================================
-- ======= 4/ Public API ===============
-- =====================================
-- =====================================

--- Turns at-rest encryption on or off.
--- @param enabled boolean
function M.set_enabled(enabled)
	_enabled = (enabled == true)
	Logger.debug(LOG, "At-rest encryption: %s.", tostring(_enabled))
end

--- Returns whether at-rest encryption is active.
--- @return boolean
function M.is_enabled()
	return _enabled
end

--- Reports whether a usable key can be derived on this machine.
--- @return boolean
function M.is_available()
	return ensure_key() ~= nil
end

--- Encrypts one value for storage.
--- @param device_id string    Owning device.
--- @param event_id  number|string Row identifier, unique per device.
--- @param plaintext string    Value to protect.
--- @return string|nil The envelope, the untouched plaintext when disabled, or
---   nil when encryption is enabled but impossible — the caller must NOT store
---   the plaintext in that case.
function M.encrypt(device_id, event_id, plaintext)
	if not _enabled then return plaintext end
	if type(plaintext) ~= "string" or plaintext == "" then return plaintext end
	if TextCrypto.is_encrypted(plaintext) then return plaintext end

	local key = ensure_key()
	if not key then return nil end

	local iv = TextCrypto.iv_for(device_id, event_id, Crypto.sha256)
	if not iv then
		Logger.error(LOG, "Cannot derive an IV for %s/%s — refusing to store plaintext.",
			tostring(device_id), tostring(event_id))
		return nil
	end

	local cmd, reason = TextCrypto.encrypt_command(key, iv)
	if not cmd then
		Logger.error(LOG, "Cannot compose the encryption command: %s.", reason)
		return nil
	end

	-- Byte-exact stdin, never the plain heredoc: that one normalises the payload's
	-- trailing newlines away, so "line\n\n" would be stored as the ciphertext of
	-- "line" and read back as a value the user never typed.
	local ciphertext = Shell.exec(Heredoc.with_exact_stdin(cmd, plaintext))
	if type(ciphertext) ~= "string" or ciphertext == "" then
		Logger.error(LOG, "Encryption produced no output — refusing to store plaintext.")
		return nil
	end

	return (TextCrypto.wrap(iv, (ciphertext:gsub("%s+$", ""))))
end

--- Decrypts one stored value.
--- @param value any Stored column value.
--- @return any The plaintext, or the value unchanged when it is not an envelope.
function M.decrypt(value)
	local iv, ciphertext = TextCrypto.unwrap(value)
	if not iv then return value end

	local key = ensure_key()
	if not key then
		Logger.warn(LOG, "Encrypted row cannot be read: no key on this machine.")
		return ""
	end

	local cmd, reason = TextCrypto.decrypt_command(key, iv)
	if not cmd then
		Logger.error(LOG, "Cannot compose the decryption command: %s.", reason)
		return ""
	end

	local plaintext = Shell.exec(Heredoc.with_exact_stdin(cmd, ciphertext))
	if type(plaintext) ~= "string" then return "" end
	return plaintext
end

return M
