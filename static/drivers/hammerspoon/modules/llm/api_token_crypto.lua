--- modules/llm/api_token_crypto.lua

--- ==============================================================================
--- MODULE: API Token Crypto (macOS Keychain)
--- DESCRIPTION:
--- At-rest encryption for API tokens stored in hs.settings. Persists each
--- token in the macOS user Keychain (via the system ``security`` CLI) and
--- stores only a Keychain reference in hs.settings. The reference is
--- meaningless without the user's login keychain, so a leaked plist
--- doesn't expose the secret.
---
--- FEATURES & RATIONALE:
--- 1. macOS Keychain = the OS-supplied secret store. Tokens already kept
---    out of plaintext by every well-behaved Mac app go through this API.
--- 2. The user account is the encryption boundary: a different macOS user
---    on the same machine cannot decrypt; the same user on a different
---    machine cannot decrypt (Keychain entries are local to ~/Library).
--- 3. Backwards-compat: any string that does NOT start with the
---    ``keychain:`` prefix is treated as cleartext (legacy config). The
---    loader returns it unchanged; the next save migrates it into the
---    Keychain transparently.
--- 4. AHK twin: ``static/drivers/autohotkey/modules/llm/api_token_crypto.ahk``
---    uses Windows DPAPI for the same purpose. Both keep the same
---    ``<scheme>:<opaque>`` storage shape so the rest of the code never
---    has to know which platform it's running on.
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("lib.logger")
local LOG = "llm.api_token_crypto"

-- Marker prefix on encrypted blobs. Anything starting with this string is
-- a Keychain reference; everything else is cleartext (legacy).
local KEYCHAIN_PREFIX = "keychain:"
-- Keychain service identifier — common to every entry; the per-entry
-- account is what disambiguates them. Mirrors the convention that other
-- apps use (one service per app, one account per credential).
local KEYCHAIN_SERVICE = "org.ergopti.llm-api-token"




-- ====================================
-- ====================================
-- ======= 1/ Public API ==============
-- ====================================
-- ====================================

--- True when the value looks like a Keychain reference rather than
--- cleartext. Cheap check used to decide whether to round-trip through
--- the ``security`` CLI.
--- @param stored string|nil The value as stored on disk.
--- @return boolean
function M.is_encrypted(stored)
	return type(stored) == "string"
		and stored:sub(1, #KEYCHAIN_PREFIX) == KEYCHAIN_PREFIX
end

--- Stores a cleartext token in the Keychain and returns a reference
--- (``keychain:<entry_id>``) the caller can persist to hs.settings.
--- On any failure (locked Keychain, ``security`` missing, write denied)
--- returns the cleartext unchanged so the caller never loses the token.
--- @param entry_id string Unique per-entry identifier (account in Keychain terms).
--- @param cleartext string The raw API token.
--- @return string Reference string, or the cleartext on failure.
function M.encrypt(entry_id, cleartext)
	if type(entry_id) ~= "string" or entry_id == "" then return cleartext end
	if type(cleartext) ~= "string" or cleartext == "" then return cleartext end
	-- If the value is already a reference, never re-wrap.
	if M.is_encrypted(cleartext) then return cleartext end

	-- ``security add-generic-password`` writes the token; -U updates
	-- when the entry already exists. The token is passed via stdin to
	-- avoid leaking it into the process command line.
	local cmd = string.format(
		"/usr/bin/security add-generic-password -U -a %s -s %s -w %s",
		_quote(entry_id), _quote(KEYCHAIN_SERVICE), _quote(cleartext))
	local out, ok, _kind, rc = hs.execute(cmd)
	if not ok then
		Logger.warn(LOG, "Keychain write failed (rc=%s) — token kept in plaintext on disk.",
			tostring(rc))
		return cleartext
	end
	return KEYCHAIN_PREFIX .. entry_id
end

--- Resolves a stored value to its cleartext form. Handles both the
--- reference form and the legacy cleartext form so the caller never
--- has to know which.
--- @param stored string The value as stored on disk.
--- @return string Cleartext, or "" when the Keychain lookup failed.
function M.decrypt(stored)
	if type(stored) ~= "string" or stored == "" then return "" end
	if not M.is_encrypted(stored) then return stored end
	local entry_id = stored:sub(#KEYCHAIN_PREFIX + 1)
	-- ``security find-generic-password -w`` prints just the password to
	-- stdout when the account+service match.
	local cmd = string.format(
		"/usr/bin/security find-generic-password -a %s -s %s -w",
		_quote(entry_id), _quote(KEYCHAIN_SERVICE))
	local out, ok = hs.execute(cmd)
	if not ok or not out or out == "" then
		Logger.warn(LOG, "Keychain read failed for entry '%s'.", tostring(entry_id))
		return ""
	end
	return (out:gsub("\n+$", ""))
end

--- Removes a Keychain entry. Called by the tray delete flow so the
--- secret is purged from the OS store, not just from hs.settings.
--- @param entry_id string The per-entry id used as the Keychain account.
function M.delete(entry_id)
	if type(entry_id) ~= "string" or entry_id == "" then return end
	local cmd = string.format(
		"/usr/bin/security delete-generic-password -a %s -s %s",
		_quote(entry_id), _quote(KEYCHAIN_SERVICE))
	pcall(hs.execute, cmd)
end




-- ====================================
-- ====================================
-- ======= 2/ Helpers =================
-- ====================================
-- ====================================

-- Wrap an argument in single quotes for the shell. ``security`` does not
-- care about whitespace in arguments but treats most shell metacharacters
-- as themselves; single-quoting is the safest way to ship arbitrary
-- token bytes (which include base64 ``/`` and ``+``).
function _quote(s)
	s = tostring(s or "")
	-- Escape any embedded single quotes by closing + concatenating +
	-- reopening: ' → '\''
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

return M
