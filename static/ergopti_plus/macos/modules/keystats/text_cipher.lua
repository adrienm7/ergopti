--- modules/keystats/text_cipher.lua

--- ==============================================================================
--- MODULE: Typed-Text Cipher (Hammerspoon)
--- DESCRIPTION:
--- macOS counterpart of linux/modules/keystats/text_cipher.lua. Supplies the
--- ports of the shared cipher policy (_shared/metrics/engine/privacy/text_cipher_core.lua),
--- which runs the shared at-rest codec (_shared/metrics/engine/privacy/text_crypto.lua)
--- against the columns that hold literal typed text, with a key derived once
--- from this Mac's hardware UUID.
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
---    make the keystats unusable. Every later call passes the raw key with
---    -K/-iv and costs only the process spawn.
--- 2. Secrets never reach a command line. The hardware UUID and typed text are
---    written to openssl's standard input by this process
---    (ShellRunner.exec_private_stdin): an `sh -c` argument, printf operand
---    included, is readable by every local account in the process table.
--- 3. Fail CLOSED on encryption, OPEN on decryption — identical to Linux, so a
---    database written on one machine reads on the other.
--- 4. Bytes and receipts are exact. Secret input is written byte for byte, NUL
---    included (a heredoc truncated it and stored the prefix's ciphertext);
---    ciphertext, which is not secret, still travels through
---    ShellRunner.exact_stdin_pipeline. Every result needs a zero exit and a
---    complete delivery: a failed openssl prints partial blocks, and a short
---    write hands it only a prefix.
--- ==============================================================================

local M = {}

local Logger     = require("core.logger.engine.logger")
local Shell      = require("core.process.adapters.shell_runner")
local Crypto     = require("core.crypto.crypto")
local TextCrypto = require("metrics.engine.privacy.text_crypto")

local LOG = "metrics.engine.privacy.text_cipher_core"





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

-- Overrides the machine-id command (test seam).
local _machine_id_command_override = nil





-- ==================================
-- ==================================
-- ======= 2/ Ports =================
-- ==================================
-- ==================================

--- Runs one openssl command whose stdin is ciphertext, which may appear in the
--- process table, and returns stdout after exit 0.
--- @param cmd string Composed openssl command.
--- @param input string Exact standard-input bytes.
--- @return string|nil output, string|nil reason
local function run_with_public_stdin(cmd, input)
	local command, reason = Shell.exact_stdin_pipeline(cmd, input)
	if not command then return nil, reason end
	return Shell.exec_checked(command)
end

--- Derives the key from the hardware UUID.
--- @return string|nil The 64-hex key, or nil after logging why not.
local function derive_key()
	local machine_id = Shell.exec(_machine_id_command_override or MACHINE_ID_COMMAND)
	machine_id = type(machine_id) == "string" and machine_id:gsub("%s+", "") or ""
	if machine_id == "" then
		Logger.error(LOG, "No hardware UUID available — at-rest encryption unavailable.")
		return nil
	end

	local derive, reason = TextCrypto.derive_key_command("stdin")
	if not derive then
		Logger.error(LOG, "Cannot compose the key derivation: %s.", reason)
		return nil
	end

	Logger.start(LOG, "Deriving the at-rest key from the hardware UUID…")
	-- Byte-exact stdin: the plain heredoc appends a newline, so the key would be
	-- PBKDF2("<uuid>\n") here and PBKDF2("<uuid>") on Linux and Windows. Same
	-- machine id, three different keys — which quietly falsifies the "identical
	-- format everywhere" claim the parity gate exists to protect.
	local output, failure = Shell.exec_private_stdin(derive, machine_id)
	local key = TextCrypto.parse_derived_key(output)
	if not key then
		Logger.error(LOG, "Key derivation produced no usable key — is openssl available? (%s)",
			failure or "no key in its output")
		return nil
	end
	return key
end

--- Encrypts one value through the openssl child.
--- @return string|nil The envelope payload, or nil after logging the refusal.
local function encrypt_value(key, iv, plaintext)
	local cmd, reason = TextCrypto.encrypt_command(key, iv)
	if not cmd then
		Logger.error(LOG, "Cannot compose the encryption command: %s.", reason)
		return nil
	end

	-- Byte-exact stdin: trailing newlines and NUL are part of the typed value, so
	-- "line\n\n" must never be stored as the ciphertext of "line".
	local ciphertext, failure = Shell.exec_private_stdin(cmd, plaintext)
	if type(ciphertext) ~= "string" or ciphertext == "" then
		Logger.error(LOG, "Encryption refused (%s) — refusing to store plaintext.",
			failure or "no output")
		return nil
	end
	return (ciphertext:gsub("%s+$", ""))
end

--- Decrypts one envelope payload through the openssl child.
--- @return string|nil The plaintext, or nil after logging the refusal.
local function decrypt_value(key, iv, ciphertext)
	local cmd, reason = TextCrypto.decrypt_command(key, iv)
	if not cmd then
		Logger.error(LOG, "Cannot compose the decryption command: %s.", reason)
		return nil
	end

	local plaintext, failure = run_with_public_stdin(cmd, ciphertext)
	if type(plaintext) ~= "string" then
		Logger.error(LOG, "Encrypted row cannot be read: decryption refused (%s).", failure)
		return nil
	end
	return plaintext
end

local Cipher = require("metrics.engine.privacy.text_cipher_core").new({
	logger = Logger,
	log = LOG,
	sha256 = Crypto.sha256,
	derive_key = derive_key,
	-- The openssl child is the primitive here: nothing to probe up front.
	ready = function() return true end,
	encrypt = encrypt_value,
	decrypt = decrypt_value,
})





-- =====================================
-- =====================================
-- ======= 3/ Public API ===============
-- =====================================
-- =====================================

--- Points the machine-id lookup at a specific command, or nil to restore.
--- @param command string|nil
function M._set_machine_id_command(command)
	_machine_id_command_override = (type(command) == "string" and command ~= "") and command or nil
	Cipher.reset_key()
end

-- Requested posture is independent of key readiness and starts unknown.
local _requested_enabled = nil

--- Admits textual ROI only when the requested and active postures are both known off.
--- @return boolean
function M.roi_text_enabled()
	if _requested_enabled ~= false or Cipher.is_enabled() ~= false then return false end
	local preferences = package.loaded["settings.engine.preferences.preferences"]
	if type(preferences) ~= "table" or type(preferences.roi_encryption_requested) ~= "function" then return false end
	local called, requested = pcall(preferences.roi_encryption_requested)
	return called and requested == false
end

--- Closes textual capture before checking encryption availability or publishing a posture.
--- @return boolean settled Whether the exact prior journal receipt is settled.
function M.prepare_roi_encryption()
	_requested_enabled = true
	-- Read only constructed owners: initialization must not recursively load them.
	local engine = package.loaded["modules.keystats.init"] or package.loaded["modules.keystats"]
	if type(engine) == "table" and type(engine.revoke_roi_text) == "function" then engine.revoke_roi_text() end
	local manager = package.loaded["modules.keystats.log_manager"]
	if type(manager) == "table" and type(manager.retire_roi_text) == "function"
		and manager.retire_roi_text() ~= true then
		Logger.error(LOG, "Encryption transition refused: a prior textual ROI journal write remains pending.")
		return false
	end
	return true
end

--- Abandons a refused attempt only with a proven off preference and no journal debt.
--- The retired words are never restored when fresh capture becomes available.
--- @param requested boolean Canonical preference after refusal.
--- @return boolean abandoned
function M.abandon_roi_encryption(requested)
	if requested ~= false or Cipher.is_enabled() ~= false then return false end
	local manager = package.loaded["modules.keystats.log_manager"]
	if type(manager) == "table" and type(manager.retire_roi_text) == "function"
		and manager.retire_roi_text() ~= true then return false end
	_requested_enabled = false
	return true
end

--- Publishes encryption only after the prior textual journal receipt settles.
--- @param value boolean Effective cipher posture.
--- @param requested boolean|nil Requested policy; defaults to the effective posture.
--- @return boolean committed
function M.set_enabled(value, requested)
	assert(type(value) == "boolean", "Encryption posture must be explicit")
	if requested == nil then requested = value end
	assert(type(requested) == "boolean", "Encryption policy must be explicit")
	if (_requested_enabled ~= false or requested or value) and M.prepare_roi_encryption() ~= true then return false end
	_requested_enabled = requested
	return Cipher.set_enabled(value)
end

M.is_enabled = Cipher.is_enabled
M.is_available = Cipher.is_available
M.encrypt = Cipher.encrypt
M.decrypt = Cipher.decrypt

return M
