--- modules/llm/profiles.lua

--- ==============================================================================
--- MODULE: LLM Profiles
--- DESCRIPTION:
--- Loads built-in prompt profiles from the shared JSON registry
--- (``static/ergopti_plus/shared/llm/profiles.json``) and merges them with the
--- user-defined profiles. The JSON file is the single source of truth so a
--- prompt tweak applies to both the Hammerspoon and AutoHotkey drivers
--- with no risk of drift.
---
--- ARCHITECTURE:
--- Profile loading and merging are delegated to shared/lua/llm/profile_selector.lua
--- (platform-neutral, no hs.* calls). This module adds only the two
--- Hammerspoon-specific layers that profile_selector cannot provide:
---   1. i18n label decoration — hs locale-aware via lib.i18n.
---   2. resolve_system_prompt — reads live min/max_words from hs.settings and
---      the active UI locale from lib.i18n so the prompt always reflects the
---      user's current session preferences.
--- ==============================================================================

local M = {}

local Logger   = require("lib.logger")
local i18n     = require("lib.i18n")
local Selector = require("llm.profile_selector")
local hs       = hs
local LOG      = "llm.profiles"


-- Fallback prompt used when the profile object is malformed.
local BASIC_PROMPT_FALLBACK = [[You are an ultra-concise keyboard completion engine.
User context: {context}

Output strictly the immediate continuation of the context.
ABSOLUTE RULE: generate AT LEAST {min_words} words and AT MOST {max_words} words. NOT ONE WORD MORE OR LESS.
Match the language of the context. If the context language is ambiguous, default to {language}.
No explanation, no comment, no list, no bullet, no quote, no rephrasing of the context.
Return only the words to append.]]




-- ============================================
-- ============================================
-- ======= 1/ Built-in Profile Registry =======
-- ============================================
-- ============================================

--- Decorates a profile table with its i18n label.
--- JSON entries don't carry a ``label`` field — the strings live in locale files.
--- @param profile table Profile object to decorate in place.
--- @return table The same profile object.
local function decorate_label(profile)
	if type(profile) == "table" and type(profile.id) == "string" then
		profile.label = i18n.get("llm.profile." .. profile.id .. ".label")
	end
	return profile
end

-- Delegate profile loading to the shared module (no hs.* dependency).
-- Decorate with i18n labels after loading so the shared module stays neutral.
local LOADED_PROFILES = Selector.load_built_in_profiles()
if #LOADED_PROFILES == 0 then
	Logger.warn(LOG, "Shared profile_selector returned 0 profiles — falling back to empty.")
end
for _, p in ipairs(LOADED_PROFILES) do decorate_label(p) end
M.BUILTIN_PROFILES = LOADED_PROFILES


--- Combines built-in profiles and user profiles into a single table.
--- User profiles with the same id override built-in ones (via profile_selector).
--- @param user_profiles table Current user-defined profiles.
--- @return table An array containing all available profiles.
function M.get_all_profiles(user_profiles)
	local all = Selector.get_all_profiles(user_profiles)
	-- Re-apply label decoration so user-defined profiles also get a locale label.
	for _, p in ipairs(all) do decorate_label(p) end
	return all
end


-- Migration table for IDs that were renamed in previous versions.
-- Kept here (not in profile_selector) because it encodes macOS driver history.
local LEGACY_IDS = {
	parallel          = "basic",
	batch             = "batch_advanced",
	parallel_advanced = "advanced",
	base_completion   = "raw",
}

--- Retrieves the currently active profile object, falling back to basic if invalid.
--- Silently migrates stale profile IDs that were renamed in previous versions.
--- @param active_id string The ID of the currently requested profile.
--- @param user_profiles table Current user-defined profiles.
--- @return table The active profile object.
function M.get_active_profile(active_id, user_profiles)
	local id = tostring(active_id)

	-- Silently migrate stale IDs saved before the profile rename.
	if LEGACY_IDS[id] then
		Logger.debug(LOG, "Migrating legacy profile id '%s' -> '%s'.", id, LEGACY_IDS[id])
		id = LEGACY_IDS[id]
	end

	local profile = Selector.get_active_profile(id, user_profiles)
	if profile then return profile end

	-- Last-resort fallback: synthesize a minimal raw profile so the engine
	-- never sees nil even on a totally broken config.
	Logger.warn(LOG, "Profile '%s' not found via profile_selector — using emergency fallback.", id)
	return { id = "raw", batch = false, system_single = "{context}" }
end




-- ============================================
-- ============================================
-- ======= 2/ Prompt Resolution (macOS) =======
-- ============================================
-- ============================================

--- Resolves the appropriate system prompt, injecting live session values.
--- Reads min/max_words from hs.settings and the UI locale from lib.i18n so
--- the prompt always reflects the user's current preferences.
---
--- Supports both schemas:
---   - function ``system_multi(n)`` (legacy Lua callbacks)
---   - string template ``system_multi_template`` (JSON / AHK shape)
---
--- @param profile table The active profile data.
--- @param n number The number of predictions expected.
--- @return string The resolved system prompt string.
function M.resolve_system_prompt(profile, n)
	local prompt = ""

	if type(profile) ~= "table" then
		prompt = BASIC_PROMPT_FALLBACK
	elseif type(profile.raw_prompt) == "string" and profile.raw_prompt ~= "" then
		prompt = profile.raw_prompt
	elseif n == 1 then
		prompt = type(profile.system_single) == "string"
			and profile.system_single or BASIC_PROMPT_FALLBACK
	else
		-- Two-step build for the multi-template case so the user-facing system
		-- prompt mirrors the AHK shape (system_single + template footer).
		if type(profile.system_multi_template) == "string" and profile.system_multi_template ~= "" then
			local base   = type(profile.system_single) == "string" and profile.system_single or ""
			local footer = profile.system_multi_template:gsub("{n}", tostring(n))
			prompt = (base ~= "" and (base .. "\n\n" .. footer) or footer)
		elseif type(profile.system_multi) == "function" then
			prompt = profile.system_multi(n)
		elseif type(profile.system_multi) == "string" then
			prompt = profile.system_multi
		else
			prompt = BASIC_PROMPT_FALLBACK
		end
	end

	-- Lazy load Core to avoid circular dependency (init.lua requires profiles.lua).
	local Core    = require("modules.llm.init")
	local def_min = Core.DEFAULT_STATE.llm_min_words
	local def_max = Core.DEFAULT_STATE.llm_max_words

	-- Read live user settings; fall back to Core defaults when absent.
	local min_w = tonumber(hs.settings.get("llm_min_words")) or def_min
	local max_w = tonumber(hs.settings.get("llm_max_words")) or def_max
	if max_w > 0 and max_w < min_w then max_w = min_w end

	prompt = prompt:gsub("{max_words}", (max_w > 0) and tostring(max_w) or "illimité")
	prompt = prompt:gsub("{min_words}", tostring(min_w))

	-- Inject the active UI locale so the model replies in the user's language.
	local locale = i18n.get_locale() or "fr"
	prompt = prompt:gsub("{language}", locale)

	return prompt
end

return M
