--- _shared/lua/keystats/text_cipher.lua

--- ==============================================================================
--- MODULE: Typed-Text Cipher Core (Shared)
--- DESCRIPTION:
--- The policy of the at-rest encryption of typed text on macOS and Linux
--- (modules/keystats/text_cipher.lua): when a value is encrypted, which stored
--- values are already envelopes, the cached key, and what a failure means. The
--- AES primitive, the machine identity and the key derivation are platform
--- code, so each driver supplies them as ports; the envelope format is the
--- shared codec (text_crypto.lua), so a database written on one machine reads
--- on the other.
---
--- FEATURES & RATIONALE:
--- 1. Fail CLOSED on encryption, OPEN on decryption. If encryption is enabled
---    but impossible, the caller is told so and must not store the plaintext it
---    was about to protect. A value that is not an envelope decrypts to itself,
---    so a database written before the feature was enabled still reads; an
---    envelope that cannot be read becomes the empty string, never garbage.
--- 2. The key is derived at most once per process: a derivation costs about half
---    a second, so a failed one is latched instead of retried on every flush.
--- 3. Disabled is genuinely disabled: with the toggle off, encrypt() returns the
---    plaintext untouched and starts nothing.
--- ==============================================================================

local TextCrypto = require("keystats.text_crypto")

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Public API =======================
-- =============================================
-- =============================================

--- Builds one driver's cipher.
--- @param ports table {
---   logger = central logger, log = log namespace,
---   sha256 = function(text) -> string|nil: the digest the IV derives from,
---   derive_key = function() -> string|nil: the 64-hex key; logs its own failure,
---   ready = function(action) -> boolean: whether the AES primitive can serve
---     "encrypt" or "decrypt" (logs why not),
---   encrypt = function(key, iv, plaintext) -> string|nil: the envelope payload,
---     nil after logging a refusal,
---   decrypt = function(key, iv, payload) -> string|nil: the plaintext, nil after
---     logging a refusal }
--- @return table cipher { set_enabled, is_enabled, is_available, encrypt, decrypt, reset_key }
function M.new(ports)
	assert(type(ports) == "table" and type(ports.logger) == "table" and type(ports.log) == "string",
		"a text cipher needs a logger and a log namespace")
	for _, name in ipairs({ "sha256", "derive_key", "ready", "encrypt", "decrypt" }) do
		assert(type(ports[name]) == "function", "a text cipher needs the port " .. name)
	end
	local Logger, LOG = ports.logger, ports.log
	local cipher = {}

	-- Whether at-rest encryption is active. Off by default, matching the shared
	-- manifest's metrics.encrypt.
	local enabled = false
	-- Cached derived key (64 hex characters). nil until first use.
	local key_hex = nil
	-- Set once a derivation has failed, so a broken install does not re-run a
	-- 600 000-iteration derivation on every flush.
	local derivation_failed = false

	--- Derives and caches the session key. Runs at most once per process.
	--- @return string|nil The 64-hex key, or nil when it cannot be derived.
	local function ensure_key()
		if key_hex then return key_hex end
		if derivation_failed then return nil end
		local key = ports.derive_key()
		if not key then
			derivation_failed = true
			return nil
		end
		key_hex = key
		Logger.success(LOG, "At-rest key derived (cached for this session).")
		return key_hex
	end

	--- Forgets the cached key and the failure latch (test seam of the drivers).
	function cipher.reset_key()
		key_hex = nil
		derivation_failed = false
	end

	--- Turns at-rest encryption on or off.
	--- @param value boolean
	--- @return boolean acknowledged
	function cipher.set_enabled(value)
		enabled = (value == true)
		Logger.debug(LOG, "At-rest encryption: %s.", tostring(enabled))
		return true
	end

	--- Returns whether at-rest encryption is active.
	--- @return boolean
	function cipher.is_enabled()
		return enabled
	end

	--- Reports whether a usable key can be derived on this machine. Used by the
	--- menu to refuse to tick a box the backend cannot honour.
	--- @return boolean
	function cipher.is_available()
		return ensure_key() ~= nil
	end

	--- Encrypts one value for storage.
	--- @param device_id string Owning device.
	--- @param event_id number|string Row identifier, unique per device.
	--- @param plaintext string Value to protect.
	--- @return string|nil The envelope, the untouched plaintext when disabled, or
	---   nil when encryption is enabled but impossible: the caller must NOT store
	---   the plaintext in that case.
	function cipher.encrypt(device_id, event_id, plaintext)
		if not enabled then return plaintext end
		if type(plaintext) ~= "string" or plaintext == "" then return plaintext end
		-- Already an envelope: re-encrypting would double-wrap and make the value
		-- undecryptable in one pass.
		if TextCrypto.is_encrypted(plaintext) then return plaintext end
		if not ports.ready("encrypt") then return nil end

		local key = ensure_key()
		if not key then return nil end

		local iv = TextCrypto.iv_for(device_id, event_id, ports.sha256)
		if not iv then
			Logger.error(LOG, "Cannot derive an IV for %s/%s — refusing to store plaintext.",
				tostring(device_id), tostring(event_id))
			return nil
		end

		local payload = ports.encrypt(key, iv, plaintext)
		if payload == nil then return nil end
		return (TextCrypto.wrap(iv, payload))
	end

	--- Decrypts one stored value.
	--- @param value any Stored column value.
	--- @return any The plaintext, or the value unchanged when it is not an envelope.
	function cipher.decrypt(value)
		local iv, payload = TextCrypto.unwrap(value)
		if not iv then return value end
		if not ports.ready("decrypt") then return "" end

		local key = ensure_key()
		if not key then
			Logger.warn(LOG, "Encrypted row cannot be read: no key on this machine.")
			return ""
		end

		local plaintext = ports.decrypt(key, iv, payload)
		if type(plaintext) ~= "string" then return "" end
		return plaintext
	end

	return cipher
end

return M
