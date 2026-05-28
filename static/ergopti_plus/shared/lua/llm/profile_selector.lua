--- shared/lua/llm/profile_selector.lua

--- ==============================================================================
--- MODULE: ProfileSelector — Shared Lua Implementation
--- DESCRIPTION:
--- Canonical Lua implementation of the LLM profile registry and prompt variable
--- injector, shared between the Hammerspoon driver and any future Lua-based
--- driver. Loads the built-in profile catalogue from shared/llm/profiles.json,
--- merges user-defined overrides, resolves the active profile by ID, and
--- performs template variable substitution.
---
--- This module is the Lua counterpart of shared/domain/ProfileSelector.js.
--- All logic and fallback behaviour MUST stay in sync with the JS reference.
---
--- FEATURES & RATIONALE:
--- 1. Shared JSON source: profiles.json is the single source of truth for all
---    drivers. This module resolves its path relative to its own location in
---    shared/lua/llm/ so it works regardless of CWD.
--- 2. User overrides: callers pass an array of user profiles that extend or
---    replace built-in ones with the same id.
--- 3. Template injection: system prompts carry {context}, {tail}, {min_words},
---    {max_words}, {n}, {language} placeholders resolved in a single pass.
--- 4. Fallback chain: unknown id falls back to "basic"; if "basic" is also
---    absent returns nil.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Profile Path Resolution =========
-- =============================================
-- =============================================

-- Resolve profiles.json path relative to this file's location.
-- shared/lua/llm/ -> shared/llm/profiles.json
local _PROFILES_JSON_PATH = nil

--- Returns the absolute path to profiles.json.
--- Deferred to first call so the path resolution works in test environments.
--- @return string|nil path Absolute path, or nil if not resolvable.
local function get_profiles_path()
	if _PROFILES_JSON_PATH then return _PROFILES_JSON_PATH end
	-- Try to resolve relative to this source file's directory
	local src = debug.getinfo(1, "S").source
	if src and src:sub(1, 1) == "@" then
		local dir = src:sub(2):match("^(.+)[/\\][^/\\]+$")
		if dir then
			-- Navigate up two levels: llm/ -> lua/ -> shared/ -> llm/profiles.json
			local candidate = dir .. "/../../llm/profiles.json"
			local fh = io.open(candidate, "r")
			if fh then
				fh:close()
				_PROFILES_JSON_PATH = candidate
				return _PROFILES_JSON_PATH
			end
		end
	end
	return nil
end




-- =============================================
-- =============================================
-- ======= 2/ Profile Loading and Merging ======
-- =============================================
-- =============================================

--- Loads the built-in profiles from profiles.json.
--- Returns an empty table (and logs a warning) if the file cannot be read.
--- @return table profiles Array of profile objects.
function M.load_built_in_profiles()
	local path = get_profiles_path()
	if not path then return {} end
	local fh = io.open(path, "r")
	if not fh then return {} end
	local raw = fh:read("*a")
	fh:close()
	-- Use the platform-agnostic shared JSON decoder so this module stays
	-- usable outside Hammerspoon (hs.json is HS-only and must not leak here).
	local ok_json, json = pcall(require, "json")
	if not ok_json or not json then return {} end
	local ok2, decoded = pcall(json.decode, raw)
	if ok2 and type(decoded) == "table" then
		return decoded
	end
	return {}
end

--- Returns the merged profile catalogue: user profiles override built-in ones
--- with the same id.
--- @param user_profiles table Array of user-defined profile overrides (may be nil).
--- @return table merged Array of merged profile objects.
function M.get_all_profiles(user_profiles)
	user_profiles = user_profiles or {}
	local built_in = M.load_built_in_profiles()

	-- Index by id so user profiles shadow built-in ones
	local by_id = {}
	local order = {}
	for _, p in ipairs(built_in) do
		if p.id then
			by_id[p.id] = p
			table.insert(order, p.id)
		end
	end
	for _, p in ipairs(user_profiles) do
		if p.id then
			if not by_id[p.id] then
				table.insert(order, p.id)
			end
			by_id[p.id] = p
		end
	end

	local result = {}
	for _, id in ipairs(order) do
		table.insert(result, by_id[id])
	end
	return result
end




-- =============================================
-- =============================================
-- ======= 3/ Profile Resolution ===============
-- =============================================
-- =============================================

--- Resolves the active profile by ID from the merged catalogue.
--- Falls back to the "basic" built-in profile if the requested id is not found.
--- Returns nil if "basic" is also absent.
--- @param profile_id string The requested profile ID.
--- @param user_profiles table|nil User-defined overrides.
--- @return table|nil profile The resolved profile object.
function M.get_active_profile(profile_id, user_profiles)
	local all = M.get_all_profiles(user_profiles)
	for _, p in ipairs(all) do
		if p.id == profile_id then return p end
	end
	-- Fallback to "basic"
	for _, p in ipairs(all) do
		if p.id == "basic" then return p end
	end
	return nil
end




-- =============================================
-- =============================================
-- ======= 4/ Template Variable Injection ======
-- =============================================
-- =============================================

--- Injects template variables into a profile's system prompt string.
---
--- Supported placeholders: {context}, {tail}, {min_words}, {max_words}, {n}, {language}.
---
--- @param profile table|nil The resolved profile object.
--- @param vars table Variable values: context, tail, min_words, max_words, n, language.
--- @return table result Keys: system (string|nil), is_batch (boolean).
function M.resolve_system_prompt(profile, vars)
	if not profile then
		return { system = nil, is_batch = false }
	end
	vars = vars or {}

	local n        = vars.n or 1
	local is_batch = profile.batch == true and n > 1 and profile.system_multi_template ~= nil
	local template = is_batch and profile.system_multi_template
		or profile.system_single
		or nil

	if not template then
		return { system = nil, is_batch = is_batch }
	end

	local context  = tostring(vars.context   or "")
	local tail     = tostring(vars.tail      or "")
	local min_w    = tostring(vars.min_words or 1)
	local max_w    = tostring(vars.max_words or 5)
	local language = tostring(vars.language  or "fr")
	local n_str    = tostring(n)

	-- Single-pass substitution of all placeholders
	local system = template
		:gsub("{context}",   context)
		:gsub("{tail}",      tail)
		:gsub("{min_words}", min_w)
		:gsub("{max_words}", max_w)
		:gsub("{n}",         n_str)
		:gsub("{language}",  language)

	return { system = system, is_batch = is_batch }
end




-- =============================================
-- =============================================
-- ======= 5/ Test Vectors =====================
-- =============================================
-- =============================================

--- Returns cross-driver test vectors matching ProfileSelector.js:profileSelectorTestVectors().
--- @return table vectors Array of test vector objects.
function M.test_vectors()
	return {
		{
			id          = "inject_basic_context",
			description = "resolve_system_prompt replaces {context} and {min_words}/{max_words}.",
			call        = "resolve_system_prompt",
			profile     = { id = "basic", system_single = "Context: {context} -- {min_words}-{max_words} words.", batch = false },
			vars        = { context = "bonjour", min_words = 2, max_words = 5, language = "fr" },
			assert      = { field = "system", contains = "bonjour", not_null = true },
		},
		{
			id          = "inject_language_placeholder",
			description = "resolve_system_prompt replaces {language}.",
			call        = "resolve_system_prompt",
			profile     = { id = "basic", system_single = "Default language: {language}.", batch = false },
			vars        = { context = "", language = "en" },
			assert      = { field = "system", contains = "en" },
		},
		{
			id          = "batch_mode_uses_multi_template",
			description = "Batch profile with n>1 returns is_batch=true.",
			call        = "resolve_system_prompt",
			profile     = {
				id = "batch_test", batch = true,
				system_single = "Single: {context}",
				system_multi_template = "Batch n={n}: {context}",
			},
			vars   = { context = "test", n = 3 },
			assert = { field = "is_batch", value = true },
		},
		{
			id          = "null_profile_returns_null_system",
			description = "resolve_system_prompt(nil) returns system=nil.",
			call        = "resolve_system_prompt",
			profile     = nil,
			vars        = {},
			assert      = { field = "system", value = nil },
		},
		{
			id          = "user_profile_overrides_builtin",
			description = "User profile with same id takes precedence over built-in.",
			call        = "get_active_profile",
			profile_id  = "basic",
			user_profiles = { { id = "basic", system_single = "CUSTOM PROMPT {context}", batch = false } },
			assert      = { field = "system_single", starts_with = "CUSTOM PROMPT" },
		},
	}
end

return M
