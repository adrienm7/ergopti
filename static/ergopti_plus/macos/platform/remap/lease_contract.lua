--- platform/remap/lease_contract.lua

--- ==============================================================================
--- MODULE: Karabiner Lease Contract
--- DESCRIPTION:
--- Defines the pure, shared contract for ErgoptiPlus Karabiner generation tokens
--- and their variable names. Keeping token validation and name derivation outside
--- both the generator and lifecycle controller prevents a silent split-brain in
--- which a healthy watchdog activates variables that no manipulator reads.
---
--- FEATURES & RATIONALE:
--- 1. Canonical Tokens: Runtime consumers accept only 32 lowercase hexadecimal
---    characters, giving every generation one unambiguous representation.
--- 2. UUID Normalization: Host UUIDs are normalized without accepting arbitrary
---    punctuation or malformed hyphen placement.
--- 3. Variable Derivation: Atomic mode, irreversible revocation, and every
---    driver-owned runtime name are produced by one source of truth shared by
---    generation, lifecycle, rule generation, and asynchronous writers.
--- 4. Pure Contract: No host API, logger, filesystem, or mutable state is used,
---    so callers can validate a generation before any external side effect.
--- 5. Personal Isolation: Bare names never belong to ErgoptiPlus at runtime;
---    every driver-owned state variable carries its exact generation token.
--- ==============================================================================

local M = {}

M.TOKEN_HEX_LENGTH = 32
M.UUID_TEXT_LENGTH = 36
M.MODE_VARIABLE_PREFIX = "ergopti_mode_"
M.REVOKED_VARIABLE_PREFIX = "ergopti_revoked_"
M.LEGACY_LEASE_VARIABLE_PREFIX = "ergopti_lease_"
M.LEGACY_PAUSE_VARIABLE_PREFIX = "ergopti_pause_"
M.RUNTIME_VARIABLE_PREFIX = "ergopti_"
M.RUNTIME_HELD_LOGICAL_PREFIX = "ke_held_"
M.MODE_OFF = 0
M.MODE_ACTIVE = 1
M.MODE_PAUSED = 2

local UUID_HYPHEN_POSITIONS = { 9, 14, 19, 24 }
local RUNTIME_LOGICAL_NAMES = {
	layer_active = true,
	capsword = true,
}





-- ===================================
-- ===================================
-- ======= 1/ Token Validation =======
-- ===================================
-- ===================================

--- Reports whether a value is the canonical runtime token representation.
--- @param token any Candidate generation token.
--- @return boolean valid Whether the token is exactly 32 lowercase hex characters.
function M.is_valid_token(token)
	return type(token) == "string"
		and #token == M.TOKEN_HEX_LENGTH
		and token:match("^[0-9a-f]+$") ~= nil
end

--- Returns a stable explanation for a rejected generation token.
--- @param token any Rejected token.
--- @return string error_message Human-readable contract failure.
function M.invalid_token_error(token)
	return string.format(
		"lease token must be exactly %d lowercase hexadecimal characters, got %s",
		M.TOKEN_HEX_LENGTH,
		tostring(token)
	)
end

--- Normalizes a canonical token or RFC 4122 textual UUID.
--- Uppercase hexadecimal is accepted only at this host-input boundary and is
--- lowered before the token reaches the generator or lifecycle state.
--- @param raw any Canonical token or hyphenated UUID candidate.
--- @return string|nil token Canonical lowercase token.
--- @return string|nil error_message Validation failure.
function M.normalize_token(raw)
	if type(raw) ~= "string" then return nil, M.invalid_token_error(raw) end
	local lowered = raw:lower()
	if M.is_valid_token(lowered) and #raw == M.TOKEN_HEX_LENGTH then return lowered end
	if #lowered ~= M.UUID_TEXT_LENGTH then return nil, M.invalid_token_error(raw) end

	local expected_hyphens = {}
	for _, position in ipairs(UUID_HYPHEN_POSITIONS) do expected_hyphens[position] = true end
	for position = 1, #lowered do
		local character = lowered:sub(position, position)
		if expected_hyphens[position] then
			if character ~= "-" then return nil, M.invalid_token_error(raw) end
		elseif character:match("[0-9a-f]") == nil then
			return nil, M.invalid_token_error(raw)
		end
	end

	local token, removed = lowered:gsub("%-", "")
	if removed ~= #UUID_HYPHEN_POSITIONS or not M.is_valid_token(token) then
		return nil, M.invalid_token_error(raw)
	end
	return token
end





-- ======================================
-- ======================================
-- ======= 2/ Variable Derivation =======
-- ======================================
-- ======================================

--- Builds the exact atomic mode variable for one generation.
--- @param token string Canonical generation token.
--- @return string|nil variable_name Generation-scoped mode name.
--- @return string|nil error_message Validation failure.
function M.mode_variable_name(token)
	if not M.is_valid_token(token) then return nil, M.invalid_token_error(token) end
	return M.MODE_VARIABLE_PREFIX .. token
end

--- Builds the exact tombstone variable that permanently fences one generation.
--- @param token string Canonical generation token.
--- @return string|nil variable_name Generation-scoped revocation name.
--- @return string|nil error_message Validation failure.
function M.revoked_variable_name(token)
	if not M.is_valid_token(token) then return nil, M.invalid_token_error(token) end
	return M.REVOKED_VARIABLE_PREFIX .. token
end

--- Derives the complete immutable-by-convention variable bundle for a token.
--- @param token string Canonical generation token.
--- @return table|nil variables Token, atomic mode name, and tombstone name.
--- @return string|nil error_message Validation failure.
function M.variables(token)
	if not M.is_valid_token(token) then return nil, M.invalid_token_error(token) end
	return {
		token = token,
		mode = M.MODE_VARIABLE_PREFIX .. token,
		revoked = M.REVOKED_VARIABLE_PREFIX .. token,
	}
end

--- Reports whether a bare logical name belongs to ErgoptiPlus runtime state.
--- The whitelist deliberately excludes stock Karabiner variables such as
--- `system.use_fkeys_as_standard_function_keys`, which generated rules may read
--- but must never rename or claim.
--- @param name any Bare logical variable name candidate.
--- @return boolean owned Whether the name must be generation-scoped.
function M.is_runtime_logical_name(name)
	if type(name) ~= "string" then return false end
	if RUNTIME_LOGICAL_NAMES[name] then return true end
	if name:sub(1, #M.RUNTIME_HELD_LOGICAL_PREFIX) ~= M.RUNTIME_HELD_LOGICAL_PREFIX then
		return false
	end
	local key_code = name:sub(#M.RUNTIME_HELD_LOGICAL_PREFIX + 1)
	return key_code ~= "" and key_code:match("^[a-z0-9_]+$") ~= nil
end

--- Builds one exact generation-scoped runtime variable name.
--- @param logical_name string Driver-owned bare logical name.
--- @param token string Canonical generation token.
--- @return string|nil variable_name Generation-scoped runtime name.
--- @return string|nil error_message Validation failure.
function M.runtime_variable_name(logical_name, token)
	if not M.is_runtime_logical_name(logical_name) then
		return nil, "runtime variable must be an ErgoptiPlus-owned logical name"
	end
	if not M.is_valid_token(token) then return nil, M.invalid_token_error(token) end
	return M.RUNTIME_VARIABLE_PREFIX .. logical_name .. "_" .. token
end

--- Parses one exact generation-scoped runtime name.
--- @param name any Variable name candidate.
--- @return string|nil logical_name Driver-owned bare logical name.
--- @return string|nil token Canonical generation token.
function M.parse_runtime_variable_name(name)
	if type(name) ~= "string" then return nil end
	local suffix_length = M.TOKEN_HEX_LENGTH + 1
	if #name <= #M.RUNTIME_VARIABLE_PREFIX + suffix_length then return nil end
	local token = name:sub(-M.TOKEN_HEX_LENGTH)
	if not M.is_valid_token(token) or name:sub(-suffix_length, -M.TOKEN_HEX_LENGTH - 1) ~= "_" then
		return nil
	end
	local logical_name = name:sub(#M.RUNTIME_VARIABLE_PREFIX + 1, -suffix_length - 1)
	if not M.is_runtime_logical_name(logical_name) then return nil end
	if M.runtime_variable_name(logical_name, token) ~= name then return nil end
	return logical_name, token
end

--- Detects exact token-scoped runtime state names.
--- @param name any Variable name candidate.
--- @return boolean runtime Whether the name is a managed runtime variable.
function M.is_runtime_variable_name(name)
	return M.parse_runtime_variable_name(name) ~= nil
end

--- Detects the complete reserved runtime namespace, including malformed names.
--- This is intentionally broader than `is_runtime_variable_name`: producers
--- must fail closed instead of treating a mistyped Ergopti prefix as personal.
--- @param name any Variable name candidate.
--- @return boolean reserved Whether the name claims an Ergopti runtime prefix.
function M.is_runtime_variable_namespace_name(name)
	if type(name) ~= "string" then return false end
	for logical_name in pairs(RUNTIME_LOGICAL_NAMES) do
		local prefix = M.RUNTIME_VARIABLE_PREFIX .. logical_name .. "_"
		if name:sub(1, #prefix) == prefix then return true end
	end
	local held_prefix = M.RUNTIME_VARIABLE_PREFIX .. M.RUNTIME_HELD_LOGICAL_PREFIX
	return name:sub(1, #held_prefix) == held_prefix
end

--- Detects names reserved for generation ownership, atomic mode and revocation.
--- @param name any Variable name candidate.
--- @return boolean managed Whether the name belongs to the managed namespace.
function M.is_managed_variable_name(name)
	return type(name) == "string"
		and (name:sub(1, #M.MODE_VARIABLE_PREFIX) == M.MODE_VARIABLE_PREFIX
			or name:sub(1, #M.REVOKED_VARIABLE_PREFIX) == M.REVOKED_VARIABLE_PREFIX
			or name:sub(1, #M.LEGACY_LEASE_VARIABLE_PREFIX) == M.LEGACY_LEASE_VARIABLE_PREFIX
			or name:sub(1, #M.LEGACY_PAUSE_VARIABLE_PREFIX) == M.LEGACY_PAUSE_VARIABLE_PREFIX
			or M.is_runtime_variable_namespace_name(name))
end

return M
