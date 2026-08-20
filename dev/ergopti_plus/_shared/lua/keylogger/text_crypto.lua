--- _shared/lua/keylogger/text_crypto.lua

--- ==============================================================================
--- MODULE: Typed-Text At-Rest Encryption Codec (shared)
--- DESCRIPTION:
--- The one definition of how Ergopti encrypts the columns that hold literal
--- typed text, shared by the three drivers so a database written on one machine
--- stays readable on another.
---
--- WHY ONLY SOME COLUMNS:
--- Only `events_typing.text` and `events_typing.events_json` hold what the user
--- actually typed. The aggregates — n-grams, counters, WPM, scancodes — are what
--- the dashboard computes over, and they are not readable as text. Encrypting
--- the whole database would make every dashboard query decrypt megabytes it does
--- not need; encrypting these two columns costs nothing to read and removes the
--- plaintext this feature exists to remove.
---
--- THE PERFORMANCE TRAP THIS MODULE EXISTS TO AVOID:
--- `openssl enc -pbkdf2 -iter 600000` re-derives the key on EVERY invocation,
--- which costs roughly half a second. Deriving per row — or even per flush —
--- would make the keylogger unusable. The key is therefore derived ONCE
--- (derive_key_command) and every subsequent call passes the raw key with
--- `-K`/`-iv`, which skips derivation entirely and costs only the process spawn.
---
--- THREAT MODEL — STATED PLAINLY:
--- The key derives from the machine ID, so it can never be lost, but the
--- repository is public: anyone who reads the source knows how the key is built.
--- This protects against OFF-machine disclosure — a stolen disk, a backup, a
--- synced folder — and not against code running on the machine itself. That is a
--- deliberate trade of secrecy for durability: a key that can be lost turns every
--- log into garbage the first time the secret store is wiped.
---
--- FEATURES & RATIONALE:
--- 1. Self-describing envelope. Every ciphertext carries a version marker and its
---    IV, so a half-migrated database is detectable row by row instead of
---    silently corrupt, and a future algorithm change can migrate rather than
---    guess.
--- 2. Deterministic per-row IV. Reusing one IV across rows encrypted with the
---    same key leaks whether two rows start with the same text. The IV is derived
---    from (device_id, event_id), which is unique per row by construction, so
---    uniqueness needs no randomness and no extra subprocess.
--- 3. Pure. Every function here is string-in, string-out: the commands are built
---    but never run. Running them is the driver's job, and a test can assert the
---    exact command without openssl being installed.
--- ==============================================================================

local M = {}





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- Envelope prefix. The version is part of the marker so a later algorithm
--- change is a migration rather than a guess about what a blob contains.
M.MARKER = "ergopti-enc-v1"

--- Field separator inside the envelope. Colon is safe: the two fields after the
--- marker are hex and base64, neither of which can contain it.
M.SEPARATOR = ":"

--- Cipher used for the payload. Matches macos/apps/Encryptor.app, so the droplet
--- and the driver speak the same format.
M.CIPHER = "aes-256-cbc"

--- PBKDF2 iteration count for the one key derivation. High on purpose: it runs
--- exactly once per session, never per row.
M.KDF_ITERATIONS = 600000

--- Digest backing the key derivation.
M.KDF_DIGEST = "sha256"

--- Fixed salt for the derivation. A random salt would have to be stored, and a
--- stored salt can be lost — which would make every existing log unreadable.
--- The salt is therefore a constant: it separates this key from any other key
--- derived from the same machine ID, which is all a salt can do here.
--- (16 bytes, the ASCII of "ergopti-metrics1").
M.KDF_SALT_HEX = "6572676f7074692d6d65747269637331"

--- Length of an AES-256 key and of an AES block, in hex characters.
M.KEY_HEX_LENGTH = 64
M.IV_HEX_LENGTH  = 32





-- ===========================
-- ===========================
-- ======= 2/ Envelope =======
-- ===========================
-- ===========================

--- Reports whether a stored value is one of our envelopes.
--- @param value any
--- @return boolean
function M.is_encrypted(value)
	if type(value) ~= "string" then return false end
	return value:sub(1, #M.MARKER + 1) == M.MARKER .. M.SEPARATOR
end

--- Builds the stored representation of an encrypted value.
--- @param iv_hex     string 32 hex characters.
--- @param ciphertext string Base64 payload.
--- @return string The envelope to store in the column.
function M.wrap(iv_hex, ciphertext)
	return M.MARKER .. M.SEPARATOR .. iv_hex .. M.SEPARATOR .. ciphertext
end

--- Splits an envelope back into its IV and payload.
--- @param value string
--- @return string|nil iv_hex, string|nil ciphertext — both nil when not an envelope.
function M.unwrap(value)
	if not M.is_encrypted(value) then return nil, nil end
	-- Plain string operations, not a Lua pattern: MARKER contains "-", which is a
	-- quantifier in Lua patterns, so building a pattern out of it silently never
	-- matches. Every envelope then read back as "not encrypted".
	local rest = value:sub(#M.MARKER + #M.SEPARATOR + 1)
	local sep  = rest:find(M.SEPARATOR, 1, true)
	if not sep then return nil, nil end
	local iv_hex = rest:sub(1, sep - 1)
	if not M.is_hex(iv_hex, M.IV_HEX_LENGTH) then return nil, nil end
	return iv_hex, rest:sub(sep + #M.SEPARATOR)
end





-- ===============================
-- ===============================
-- ======= 3/ Derived Bits =======
-- ===============================
-- ===============================

--- Derives the per-row initialisation vector.
--- Uniqueness, not unpredictability, is what an IV needs here, and
--- (device_id, event_id) is unique per row by construction — so no randomness
--- and no extra subprocess are required.
--- @param device_id string    Owning device.
--- @param event_id  number|string Row identifier, unique per device.
--- @param sha256    function  Hex-digest function provided by the driver.
--- @return string|nil 32 hex characters, or nil when the digest is unusable.
function M.iv_for(device_id, event_id, sha256)
	if type(sha256) ~= "function" then return nil end
	local digest = sha256(tostring(device_id) .. M.SEPARATOR .. tostring(event_id))
	if type(digest) ~= "string" or #digest < M.IV_HEX_LENGTH then return nil end
	return digest:sub(1, M.IV_HEX_LENGTH)
end

--- Validates a hex string of an exact length. Used to refuse a malformed key or
--- IV BEFORE it reaches a shell command, where a bad value would either fail
--- obscurely or, worse, encrypt with something unintended.
--- @param value  any
--- @param length number Expected number of hex characters.
--- @return boolean
function M.is_hex(value, length)
	if type(value) ~= "string" or #value ~= length then return false end
	return value:match("^%x+$") ~= nil
end





-- ===================================
-- ===================================
-- ======= 4/ Command Building =======
-- ===================================
-- ===================================

--- Builds the ONE command that derives the session key from the machine ID.
--- `-P` makes openssl print the derived key instead of encrypting anything, so
--- the caller can cache it and never pay the 600 000 iterations again.
--- The machine ID is never passed as an argument: `openssl -pass pass:<secret>`
--- puts it in the process table, where every local account can read it. Callers
--- supply an openssl pass phrase SOURCE instead — "file:/etc/machine-id" on
--- Linux, "stdin" where the id comes from a command.
--- @param pass_spec string An openssl `-pass` source.
--- @return string|nil command, string|nil reason
function M.derive_key_command(pass_spec)
	if type(pass_spec) ~= "string" or pass_spec == "" then
		return nil, "pass_spec must be a non-empty openssl -pass source"
	end
	if pass_spec:match("^pass:") then
		return nil, "refusing -pass pass:<secret>; it exposes the key material in the process table"
	end
	return table.concat({
		"openssl enc", "-" .. M.CIPHER,
		"-pbkdf2", "-iter", tostring(M.KDF_ITERATIONS),
		"-md", M.KDF_DIGEST,
		"-S", M.KDF_SALT_HEX,
		"-pass", pass_spec,
		"-P",
	}, " ")
end

--- Extracts the key from `openssl enc -P` output.
--- @param output string|nil
--- @return string|nil 64 hex characters, or nil when absent or malformed.
function M.parse_derived_key(output)
	if type(output) ~= "string" then return nil end
	local key = output:match("key=(%x+)")
	if not key or not M.is_hex(key, M.KEY_HEX_LENGTH) then return nil end
	return key
end

--- Builds the per-value encryption command. No `-pbkdf2` here on purpose: the
--- key is already derived, and re-deriving would cost half a second per value.
--- @param key_hex string 64 hex characters.
--- @param iv_hex  string 32 hex characters.
--- @return string|nil command, string|nil reason
function M.encrypt_command(key_hex, iv_hex)
	if not M.is_hex(key_hex, M.KEY_HEX_LENGTH) then return nil, "key must be 64 hex characters" end
	if not M.is_hex(iv_hex, M.IV_HEX_LENGTH) then return nil, "iv must be 32 hex characters" end
	return "openssl enc -" .. M.CIPHER .. " -K " .. key_hex .. " -iv " .. iv_hex .. " -base64 -A"
end

--- Builds the per-value decryption command.
--- @param key_hex string 64 hex characters.
--- @param iv_hex  string 32 hex characters.
--- @return string|nil command, string|nil reason
function M.decrypt_command(key_hex, iv_hex)
	if not M.is_hex(key_hex, M.KEY_HEX_LENGTH) then return nil, "key must be 64 hex characters" end
	if not M.is_hex(iv_hex, M.IV_HEX_LENGTH) then return nil, "iv must be 32 hex characters" end
	return "openssl enc -d -" .. M.CIPHER .. " -K " .. key_hex .. " -iv " .. iv_hex .. " -base64 -A"
end

return M
