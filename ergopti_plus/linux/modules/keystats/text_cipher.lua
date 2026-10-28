--- modules/keystats/text_cipher.lua

--- ==============================================================================
--- MODULE: Typed-Text Cipher (Linux)
--- DESCRIPTION:
--- Supplies the ports of the shared cipher policy
--- (_shared/lua/keystats/text_cipher.lua), which runs the shared at-rest codec
--- (_shared/lua/keystats/text_crypto.lua) against the columns that hold literal
--- typed text, using a key derived once from this machine's ID.
---
--- FEATURES & RATIONALE:
--- 1. The key is derived ONCE and cached. `openssl enc -pbkdf2 -iter 600000`
---    costs roughly half a second per invocation, so deriving per row — or even
---    per flush — would make the keystats unusable. Subsequent AES operations
---    use native EVP byte buffers, without processes or key-bearing arguments.
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
local Crypto  = require("adapters.crypto")
local OpenSSL = require("infra.openssl_command")
local NativeCipher = require("infra.openssl_cipher")
local TextCrypto = require("keystats.text_crypto")

local LOG = "modules.keystats.text_cipher"





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

-- Overrides the machine-id search (test seam). The real paths are absolute and
-- root-owned, so a test cannot create them; without this seam the happy path
-- could only ever be exercised on a live Linux box.
local _machine_id_override = nil





-- ==================================
-- ==================================
-- ======= 2/ Ports =================
-- ==================================
-- ==================================

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

--- Derives the key from the machine id, which openssl itself reads.
--- @return string|nil The 64-hex key, or nil after logging why not.
local function derive_key()
	local path = machine_id_path()
	if not path then
		Logger.error(LOG, "No machine id found (%s, %s) — at-rest encryption unavailable.",
			MACHINE_ID_PATH, MACHINE_ID_FALLBACK_PATH)
		return nil
	end

	local cmd, reason = TextCrypto.derive_key_command("file:" .. path)
	if not cmd then
		Logger.error(LOG, "Cannot compose the key derivation: %s.", reason)
		return nil
	end

	Logger.start(LOG, "Deriving the at-rest key from the machine id…")
	local derived, native_error = OpenSSL.exec(cmd)
	local key = TextCrypto.parse_derived_key(derived)
	if not key then
		Logger.error(LOG, "Key derivation failed or returned no usable key — %s.", native_error or "invalid key output")
		return nil
	end
	return key
end

--- Whether the native AES primitive can serve an action.
--- @param action string "encrypt" or "decrypt".
--- @return boolean
local function ready(action)
	if NativeCipher.available then return true end
	if action == "encrypt" then
		Logger.error(LOG, "Native AES unavailable — refusing to store plaintext.")
	else
		Logger.warn(LOG, "Encrypted row cannot be read: native AES unavailable.")
	end
	return false
end

--- Encrypts one value with the native primitive.
--- @return string|nil The Base64 payload, or nil after logging the refusal.
local function encrypt_value(key, iv, plaintext)
	local ciphertext = NativeCipher.encrypt(key, iv, plaintext)
	if type(ciphertext) ~= "string" or ciphertext == "" then
		Logger.error(LOG, "Native encryption refused — refusing to store plaintext.")
		return nil
	end

	local encoded = NativeCipher.encode_base64(ciphertext)
	if not encoded then
		Logger.error(LOG, "Native ciphertext encoding refused.")
		return nil
	end
	return encoded
end

--- Decrypts one Base64 payload with the native primitive.
--- @return string|nil The plaintext, or nil after logging the refusal.
local function decrypt_value(key, iv, payload)
	local bytes = NativeCipher.decode_base64(payload)
	if not bytes then
		Logger.error(LOG, "Encrypted row has invalid Base64.")
		return nil
	end

	local plaintext = NativeCipher.decrypt(key, iv, bytes)
	if type(plaintext) ~= "string" then
		Logger.error(LOG, "Native decryption refused.")
		return nil
	end
	return plaintext
end

local Cipher = require("keystats.text_cipher").new({
	logger = Logger,
	log = LOG,
	sha256 = Crypto.sha256,
	derive_key = derive_key,
	ready = ready,
	encrypt = encrypt_value,
	decrypt = decrypt_value,
})





-- =====================================
-- =====================================
-- ======= 3/ Public API ===============
-- =====================================
-- =====================================

--- Points the machine-id lookup at a specific file, or nil to restore.
--- @param path string|nil
function M._set_machine_id_path(path)
	_machine_id_override = (type(path) == "string" and path ~= "") and path or nil
	Cipher.reset_key()
end

M.set_enabled = Cipher.set_enabled
M.is_enabled = Cipher.is_enabled

--- Reports whether a usable key can be derived on this machine. Used by the menu
--- to refuse to tick a box the backend cannot honour.
--- @return boolean
function M.is_available()
	return NativeCipher.available and Cipher.is_available()
end

M.encrypt = Cipher.encrypt
M.decrypt = Cipher.decrypt

return M
