--- modules/keylogger/text_cipher.lua

--- ==============================================================================
--- MODULE: Typed-Text Cipher (Linux)
--- DESCRIPTION:
--- Runs the shared at-rest codec (_shared/lua/keylogger/text_crypto.lua) against
--- the columns that hold literal typed text, using a key derived once from this
--- machine's ID.
---
--- FEATURES & RATIONALE:
--- 1. The key is derived ONCE and cached. `openssl enc -pbkdf2 -iter 600000`
---    costs roughly half a second per invocation, so deriving per row — or even
---    per flush — would make the keylogger unusable. Every subsequent call passes
---    the raw key with -K/-iv and costs only the process spawn.
--- 2. The machine ID is read by openssl itself via `-pass file:/etc/machine-id`.
---    Passing it as an argument would publish it in the process table, and
---    piping it through a shell would put it in a command line too.
--- 3. Fail CLOSED on encryption, OPEN on decryption. If encryption is enabled but
---    the key cannot be derived, the caller is told so and must not store the
---    plaintext it was about to protect. Decryption of a value that is not an
---    envelope returns it unchanged, so a database written before the feature was
---    enabled still reads.
--- 4. Disabled is genuinely disabled: with the toggle off, encrypt() returns the
---    plaintext untouched and spawns nothing at all.
--- ==============================================================================

local M = {}

local Logger  = require("logger.shim")
local Shell   = require("adapters.shell_runner")
local Crypto  = require("adapters.crypto")
local TextCrypto = require("keylogger.text_crypto")

local LOG = "modules.keylogger.text_cipher"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- Where systemd stores this installation's stable machine identifier. Present
--- on every systemd distribution; the fallback below covers the rest.
local MACHINE_ID_PATH = "/etc/machine-id"

--- Older/alternative location, populated by dbus on non-systemd systems.
local MACHINE_ID_FALLBACK_PATH = "/var/lib/dbus/machine-id"





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

-- Set once the derivation has been attempted and failed, so a broken install
-- does not re-run a 600 000-iteration derivation on every single flush.
local _derivation_failed = false




-- ==================================
-- ==================================
-- ======= 3/ Key Derivation ========
-- ==================================
-- ==================================

-- Overrides the machine-id search (test seam). The real paths are absolute and
-- root-owned, so a test cannot create them; without this seam the happy path
-- could only ever be exercised on a live Linux box.
local _machine_id_override = nil

--- Points the machine-id lookup at a specific file, or nil to restore.
--- @param path string|nil
function M._set_machine_id_path(path)
	_machine_id_override = (type(path) == "string" and path ~= "") and path or nil
	_key_hex = nil
	_derivation_failed = false
end

--- Returns the readable machine-id path, or nil when the system has none.
--- @return string|nil
local function machine_id_path()
	local candidates = _machine_id_override
		and { _machine_id_override }
		or { MACHINE_ID_PATH, MACHINE_ID_FALLBACK_PATH }
	for _, path in ipairs(candidates) do
		local fh = io.open(path, "r")
		if fh then
			local first = fh:read("*l")
			fh:close()
			if type(first) == "string" and first:match("%S") then return path end
		end
	end
	return nil
end

--- Derives and caches the session key. Runs at most once per process.
--- @return string|nil The 64-hex key, or nil when it cannot be derived.
local function ensure_key()
	if _key_hex then return _key_hex end
	if _derivation_failed then return nil end

	local path = machine_id_path()
	if not path then
		_derivation_failed = true
		Logger.error(LOG, "No machine id found (%s, %s) — at-rest encryption unavailable.",
			MACHINE_ID_PATH, MACHINE_ID_FALLBACK_PATH)
		return nil
	end

	local cmd, reason = TextCrypto.derive_key_command("file:" .. path)
	if not cmd then
		_derivation_failed = true
		Logger.error(LOG, "Cannot compose the key derivation: %s.", reason)
		return nil
	end

	Logger.start(LOG, "Deriving the at-rest key from the machine id…")
	local key = TextCrypto.parse_derived_key(Shell.exec(cmd))
	if not key then
		_derivation_failed = true
		Logger.error(LOG, "Key derivation produced no usable key — is openssl installed?")
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

--- Reports whether a usable key can be derived on this machine. Used by the menu
--- to refuse to tick a box the backend cannot honour.
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
	-- Already an envelope: re-encrypting would double-wrap and make the value
	-- undecryptable in one pass.
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
	local ciphertext = Shell.exec_exact_stdin(cmd, plaintext)
	if type(ciphertext) ~= "string" or ciphertext == "" then
		Logger.error(LOG, "Encryption produced no output — refusing to store plaintext.")
		return nil
	end

	return TextCrypto.wrap(iv, (ciphertext:gsub("%s+$", "")))
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

	local plaintext = Shell.exec_exact_stdin(cmd, ciphertext)
	if type(plaintext) ~= "string" then return "" end
	return plaintext
end

return M
