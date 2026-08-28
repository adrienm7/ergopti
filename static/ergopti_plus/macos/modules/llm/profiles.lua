--- modules/llm/profiles.lua

--- ==============================================================================
--- MODULE: LLM Profiles
--- DESCRIPTION:
--- Loads built-in prompt profiles from the shared JSON registry
--- (``static/ergopti_plus/_shared/modules/llm/profiles.json``) and merges them with the
--- user-defined profiles. The JSON file is the single source of truth so a
--- prompt tweak applies to both the Hammerspoon and AutoHotkey drivers
--- with no risk of drift.
---
--- ARCHITECTURE:
--- Profile loading and merging are delegated to _shared/lua/llm/profile_selector.lua
--- (platform-neutral, no hs.* calls). This module adds only the two
--- Hammerspoon-specific layers that profile_selector cannot provide:
---   1. i18n label decoration — hs locale-aware via lib.i18n.
---   2. resolve_system_prompt — reads live min/max_words from hs.settings and
---      the active UI locale from lib.i18n so the prompt always reflects the
---      user's current session preferences.
--- ==============================================================================

local M = {}

local Logger   = require("infra.logger")
local text_utils = require("infra.text_utils")
local i18n     = require("infra.i18n")
local Manifest = require("infra.manifest_reader")
local Selector = require("llm.profile_selector")
local Storage  = require("adapters.storage")
local LOG      = "llm.profiles"


-- Ultimate degraded-mode text: used only if profiles.json cannot be read at
-- all, so BASIC_PROMPT_FALLBACK below still has a value to fall back to. This
-- is the single hand-maintained copy of the "basic" prompt on this driver —
-- everywhere else derives from profiles.json
local BASIC_PROMPT_EMERGENCY = [[You are an ultra-concise keyboard completion engine.
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

-- Fallback prompt used when a profile object is malformed or missing a
-- prompt field (M.resolve_system_prompt below). Derived from the "basic"
-- profile actually loaded from profiles.json so it can never drift
-- from the prompt the user sees when everything is working; only falls back
-- to the hand-maintained emergency copy if profiles.json failed to load.
local BASIC_PROMPT_FALLBACK = BASIC_PROMPT_EMERGENCY
for _, p in ipairs(LOADED_PROFILES) do
	if p.id == "basic" and type(p.system_single) == "string" and p.system_single ~= "" then
		BASIC_PROMPT_FALLBACK = p.system_single
		break
	end
end


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


-- Migration table for IDs that were renamed in previous versions. Shared with
-- the AHK driver via _shared/modules/llm/legacy_ids.json — both
-- drivers had the identical mapping hand-copied, not "macOS driver history".
local LEGACY_IDS = Selector.load_legacy_ids()

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

--- Resolves the live (min, max) word bounds for prompt interpolation from the
--- single source of truth. The canonical defaults live in _shared/modules/llm/defaults.json
--- (surfaced as DEFAULT_STATE.llm_min_words / llm_max_words); a live user override
--- in the user settings takes precedence. We never substitute a divergent literal:
--- a nil in DEFAULT_STATE means the LLM module failed to initialise its defaults,
--- which is surfaced loudly rather than silently masked with a made-up value.
--- @param ds table DEFAULT_STATE (canonical defaults from defaults.json).
--- @param get_setting function Reads a live user setting by key (returns nil if unset).
--- @return number|nil min_w The resolved minimum word count.
--- @return number|nil max_w The resolved maximum word count.
function M._resolve_word_bounds(ds, get_setting)
	ds = ds or {}
	local def_min = ds.llm_min_words
	local def_max = ds.llm_max_words
	if def_min == nil or def_max == nil then
		Logger.error(LOG, "resolve_word_bounds: DEFAULT_STATE is missing llm_min_words/llm_max_words — LLM defaults were not initialised from _shared/modules/llm/defaults.json.")
	end

	local min_w = tonumber(get_setting("llm_min_words")) or def_min
	local max_w = tonumber(get_setting("llm_max_words")) or def_max
	if min_w and max_w and max_w > 0 and max_w < min_w then max_w = min_w end
	return min_w, max_w
end

--- Resolves the appropriate system prompt, injecting live session values.
--- Delegates the pure prompt-building algorithm to the shared
--- Selector.resolve_system_prompt() (profile_selector.lua), keeping only
--- the macOS-specific glue: live min/max_words from hs.settings and the active
--- UI locale from lib.i18n.
---
--- @param profile table The active profile data.
--- @param n number The number of predictions expected.
--- @return string The resolved system prompt string.
function M.resolve_system_prompt(profile, n)
	-- Lazy load Core to avoid circular dependency (init.lua requires profiles.lua).
	local Core = require("modules.llm.init") or {}
	local ds   = (Core and Core.DEFAULT_STATE) or {}

	-- Read live user settings; fall back to the canonical Core defaults when the
	-- user has not overridden them. Guard hs for stubbed test/CI envs.
	local min_w, max_w = M._resolve_word_bounds(ds, Storage.get)

	-- Inject the active UI locale so the model replies in the user's language.
	local locale = i18n.get_locale() or Manifest.default_for("script.locale")

	-- Delegate the pure algorithm to the shared selector
	-- Convert max_w == 0 to "illimité" (the shared selector substitutes
	-- whatever string it receives; the macOS convention for "unlimited" is
	-- the French word rather than a literal 0).
	local vars = {
		n         = n,
		min_words = tostring(min_w or ""),
		max_words = (max_w and max_w > 0) and tostring(max_w) or "illimité",
		language  = locale,
		context   = "",  -- injected elsewhere by prompt_builder
	}
	local result = Selector.resolve_system_prompt(profile, vars)

	if result and type(result.system) == "string" and result.system ~= "" then
		-- The shared selector already substituted all placeholders.
		return result.system
	end

	-- Fallback: use BASIC_PROMPT_FALLBACK and substitute placeholders manually.
	-- This only runs when the profile is nil/malformed or has no prompt field,
	-- matching the old behaviour before the selector delegation
	local prompt = BASIC_PROMPT_FALLBACK
	prompt = prompt:gsub("{max_words}", text_utils.escape_gsub_replacement((max_w and max_w > 0) and tostring(max_w) or "illimité"))
	prompt = prompt:gsub("{min_words}", text_utils.escape_gsub_replacement(tostring(min_w or "")))
	prompt = prompt:gsub("{language}", text_utils.escape_gsub_replacement(locale))

	return prompt
end

return M
