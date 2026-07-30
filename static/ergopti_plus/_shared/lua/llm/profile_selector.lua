--- _shared/lua/llm/profile_selector.lua

--- ==============================================================================
--- MODULE: ProfileSelector — Shared Lua Implementation
--- DESCRIPTION:
--- Canonical Lua implementation of the LLM profile registry and prompt variable
--- injector, shared between the Hammerspoon driver and any future Lua-based
--- driver. Loads the built-in profile catalogue from _shared/modules/llm/profiles.json,
--- merges user-defined overrides, resolves the active profile by ID, and
--- performs template variable substitution.
---
--- This module is the Lua counterpart of _shared/core/domain/ProfileSelector.js.
--- All logic and fallback behaviour MUST stay in sync with the JS reference.
---
--- FEATURES & RATIONALE:
--- 1. Shared JSON source: profiles.json is the single source of truth for all
---    drivers. This module resolves its path relative to its own location in
---    _shared/lua/llm/ so it works regardless of CWD.
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

-- Resolve a shared LLM JSON file's path relative to this file's location.
-- _shared/lua/llm/ -> _shared/modules/llm/<name>
local _RESOLVED_PATHS = {}

--- Returns the absolute path to a file under _shared/modules/llm/, or nil if
--- it cannot be resolved / does not exist. Deferred to first call per name so
--- the resolution works in test environments, and cached thereafter.
--- @param name string File name under _shared/modules/llm/, e.g. "profiles.json".
--- @return string|nil path Absolute path, or nil if not resolvable.
local function get_llm_json_path(name)
	if _RESOLVED_PATHS[name] then return _RESOLVED_PATHS[name] end
	-- Try to resolve relative to this source file's directory
	local src = debug.getinfo(1, "S").source
	if src and src:sub(1, 1) == "@" then
		local dir = src:sub(2):match("^(.+)[/\\][^/\\]+$")
		if dir then
			-- Navigate up two levels: llm/ -> lua/ -> _shared/ -> modules/llm/<name>
			local candidate = dir .. "/../../modules/llm/" .. name
			local fh = io.open(candidate, "r")
			if fh then
				fh:close()
				_RESOLVED_PATHS[name] = candidate
				return candidate
			end
		end
	end
	return nil
end

--- Returns the absolute path to profiles.json.
--- @return string|nil path Absolute path, or nil if not resolvable.
local function get_profiles_path()
	return get_llm_json_path("profiles.json")
end





-- =============================================
-- ==============================================
-- ======= 2/ Profile Loading and Merging =======
-- ==============================================
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

--- Loads the profile-id migration table from legacy_ids.json. Returns
--- an empty table (never nil) if the file cannot be read or parsed, so a
--- missing/corrupt file degrades to "no migration" rather than throwing.
--- @return table<string,string> legacy_ids Map of old profile id -> current id.
function M.load_legacy_ids()
	local path = get_llm_json_path("legacy_ids.json")
	if not path then return {} end
	local fh = io.open(path, "r")
	if not fh then return {} end
	local raw = fh:read("*a")
	fh:close()
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
-- ==============================================
-- ======= 4/ Template Variable Injection =======
-- ==============================================
-- =============================================

--- Injects template variables into a profile's system prompt string.
---
--- Algorithm (must stay in sync with both drivers and ProfileSelector.js):
---   1. nil/empty profile → { system = nil }
---   2. raw_prompt non-empty → return it verbatim (raw mode, no placeholders)
---   3. n == 1 → system_single (or nil if absent)
---   4. n > 1 → system_single + "\n\n" + system_multi_template (footer pattern)
---      If no multi_template, falls back to system_single alone.
---   5. Substitutes {context}, {tail}, {min_words}, {max_words}, {n}, {language}
---      in a single gsub pass.
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

	-- raw_prompt short-circuit: verbatim, no substitution (matches both drivers)
	if type(profile.raw_prompt) == "string" and profile.raw_prompt ~= "" then
		return { system = profile.raw_prompt, is_batch = false }
	end

	local is_batch = profile.batch == true and n > 1 and type(profile.system_multi_template) == "string" and profile.system_multi_template ~= ""

	local base = type(profile.system_single) == "string" and profile.system_single or nil
	if not base then
		return { system = nil, is_batch = is_batch }
	end

	local template
	if is_batch then
		-- Footer pattern matching both drivers: base + "\n\n" + footer{n}
		local footer = profile.system_multi_template:gsub("{n}", tostring(n))
		template = base .. "\n\n" .. footer
	else
		template = base
	end

	local context  = tostring(vars.context   or "")
	local tail     = tostring(vars.tail      or "")
	local min_w    = tostring(vars.min_words ~= nil and vars.min_words or 1)
	local max_w    = tostring(vars.max_words ~= nil and vars.max_words or 5)
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
			id          = "batch_mode_uses_footer_pattern",
			description = "Batch profile n>1 returns is_batch=true and uses base+\\n\\n+footer pattern.",
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
			id          = "batch_footer_contains_base_and_footer",
			description = "Batch n>1 concatenates system_single + \\n\\n + footer{n}.",
			call        = "resolve_system_prompt",
			profile     = {
				id = "batch_test", batch = true,
				system_single = "BASE",
				system_multi_template = "FOOTER n={n}",
			},
			vars   = { context = "ctx", n = 5 },
			assert = { field = "system", contains = "BASE\n\nFOOTER n=5" },
		},
		{
			id          = "raw_prompt_short_circuit",
			description = "raw_prompt non-empty returns verbatim, no substitution, is_batch=false.",
			call        = "resolve_system_prompt",
			profile     = { id = "raw", raw_prompt = "JUST {context} VERBATIM", batch = false },
			vars        = { context = "hello", n = 1 },
			assert      = { field = "system", value = "JUST {context} VERBATIM" },
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
