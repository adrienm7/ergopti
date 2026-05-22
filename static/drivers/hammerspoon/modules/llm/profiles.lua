--- modules/llm/profiles.lua

--- ==============================================================================
--- MODULE: LLM Profiles
--- DESCRIPTION:
--- Loads built-in prompt profiles from the shared JSON registry
--- (``static/drivers/_shared/llm/profiles.json``) and merges them with the
--- user-defined profiles. The JSON file is the single source of truth so a
--- prompt tweak applies to both the Hammerspoon and AutoHotkey drivers
--- with no risk of drift; the hardcoded constants below are kept as a
--- fallback only — used when the JSON file is missing / unparseable so
--- the driver never starts in a broken state.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")
local i18n   = require("lib.i18n")
local hs     = hs
local LOG    = "llm.profiles"




-- ===================================
--- ===================================
-- ======= 1/ Built-in Prompts =======
--- ===================================
-- ===================================

-- These constants ARE the fallback used when profiles.json can't be loaded.
-- They MUST stay in lockstep with the strings in
-- ``static/drivers/_shared/llm/profiles.json`` so the driver still produces
-- usable predictions even if the shared file is missing.

local RAW_PROMPT_SINGLE = [[{context}]]

local BASIC_PROMPT_SINGLE = [[You are an ultra-concise keyboard completion engine.
User context: {context}

Output strictly the immediate continuation of the context.
ABSOLUTE RULE: generate AT LEAST {min_words} words and AT MOST {max_words} words. NOT ONE WORD MORE OR LESS.
Match the language of the context. If the context language is ambiguous, default to {language}.
No explanation, no comment, no list, no bullet, no quote, no rephrasing of the context.
Return only the words to append.]]

-- Universal prompt: English instructions for cross-model reliability, minimal
-- examples to reduce token overhead for small models (Qwen 3.5-4B, etc.)
local ADVANCED_PROMPT_SINGLE = [[You are a text correction and completion engine.
You receive PREFIX (full context) and TAIL (last few words).
Reply with exactly two lines — nothing else:
TAIL_CORRECTED: <corrected tail>
NEXT_WORDS: <continuation>

Rules:
- TAIL_CORRECTED: fix spelling/grammar in TAIL only. If already correct, copy it exactly unchanged.
- NEXT_WORDS: natural continuation, between {min_words} and {max_words} words. Empty if the sentence is complete.
- Match the language of the context. If the context language is ambiguous, default to {language}.
- No explanations, no markdown, no quotes.

PREFIX: "Je vous envoit ce mail pour vous dir"
TAIL: "envoit ce mail pour vous dir"
TAIL_CORRECTED: envoie ce mail pour vous dire
NEXT_WORDS: que tout est prêt.

PREFIX: "Salut, comment ça"
TAIL: "Salut, comment ça"
TAIL_CORRECTED: Salut, comment ça
NEXT_WORDS: va ?

PREFIX: "Je fais très attentio"
TAIL: "fais très attentio"
TAIL_CORRECTED: fais très attention
NEXT_WORDS: à ce que tu dis.
]]

local BATCH_ADVANCED_TEMPLATE = [[BATCH MODE: Generate exactly {n} different continuations.
Separate each with `===`.

TAIL_CORRECTED: <tail>
NEXT_WORDS: <prediction 1>
===
TAIL_CORRECTED: <tail>
NEXT_WORDS: <prediction 2>
===]]




-- ========================================
-- ========================================
-- ======= 2/ Shared JSON Loader =========
-- ========================================
-- ========================================

--- Locates and parses ``profiles.json`` from ``_shared/llm/``. Mirrors the
--- path probe order in api_common.lua / load_inference_constants. Returns an
--- array of profile tables on success or nil on failure (file missing or
--- malformed); the caller falls back to the hardcoded constants.
--- @return table|nil Array of profile tables, or nil on failure.
local function load_profiles_json()
	local candidates = {
		hs.configdir .. "/../_shared/llm/profiles.json",
		hs.configdir .. "/../../static/drivers/_shared/llm/profiles.json",
		(os.getenv("HOME") or "") .. "/Library/Application Support/Hammerspoon/../../../static/drivers/_shared/llm/profiles.json",
	}
	for _, p in ipairs(candidates) do
		local fh = io.open(p, "r")
		if fh then
			local raw = fh:read("*a")
			fh:close()
			local ok, parsed = pcall(hs.json.decode, raw)
			if ok and type(parsed) == "table" and #parsed > 0 then
				Logger.debug(LOG, "Loaded %d profiles from %s.", #parsed, p)
				return parsed
			end
			Logger.warn(LOG, "Failed to parse profiles.json at %s — falling back.", p)
		end
	end
	Logger.warn(LOG, "profiles.json not found — using hardcoded fallback.")
	return nil
end

--- Builds the fallback (hardcoded) profile registry. Used when
--- profiles.json can't be loaded so the driver still starts cleanly.
local function build_fallback_profiles()
	return {
		{ id = "raw",            batch = false, system_single = RAW_PROMPT_SINGLE,      system_multi = nil },
		{ id = "basic",          batch = false, system_single = BASIC_PROMPT_SINGLE,    system_multi = nil },
		{ id = "advanced",       batch = false, system_single = ADVANCED_PROMPT_SINGLE, system_multi = nil },
		{ id = "batch_advanced", batch = true,  system_single = ADVANCED_PROMPT_SINGLE,
		  system_multi_template = BATCH_ADVANCED_TEMPLATE },
	}
end

--- Decorates a profile table with its i18n label. JSON entries don't carry
--- a ``label`` field (the strings live in the locale files); fallback
--- profiles also delegate to i18n.
local function decorate_label(profile)
	if type(profile) == "table" and type(profile.id) == "string" then
		profile.label = i18n.get("llm.profile." .. profile.id .. ".label")
	end
	return profile
end




-- ============================================
-- ============================================
-- ======= 3/ Registry & Resolution ===========
-- ============================================
-- ============================================

-- Loaded once at require time; mirrors how api_common.lua / inference.json
-- caches its parsed values. Editing profiles.json requires a Hammerspoon
-- reload, same as every other shared-config file.
local LOADED_PROFILES = load_profiles_json() or build_fallback_profiles()
for _, p in ipairs(LOADED_PROFILES) do decorate_label(p) end
M.BUILTIN_PROFILES = LOADED_PROFILES

--- Combines built-in profiles and user profiles into a single table.
--- @param user_profiles table Current user defined profiles.
--- @return table An array containing all available profiles.
function M.get_all_profiles(user_profiles)
	local all = {}
	for _, p in ipairs(M.BUILTIN_PROFILES) do table.insert(all, p) end
	if type(user_profiles) == "table" then
		for _, p in ipairs(user_profiles) do table.insert(all, p) end
	end
	return all
end

-- Migration table for IDs that were renamed in previous versions.
local LEGACY_IDS = {
	parallel          = "basic",
	batch             = "batch_advanced",
	parallel_advanced = "advanced",
	base_completion   = "raw",
}

--- Retrieves the currently active profile object, falling back to basic if invalid.
--- @param active_id string The ID of the currently requested profile.
--- @param user_profiles table Current user defined profiles.
--- @return table The active profile object.
function M.get_active_profile(active_id, user_profiles)
	local id = tostring(active_id)

	-- Silently migrate stale IDs saved before the profile rename.
	if LEGACY_IDS[id] then
		Logger.debug(LOG, "Migrating legacy profile id '%s' → '%s'.", id, LEGACY_IDS[id])
		id = LEGACY_IDS[id]
	end

	for _, p in ipairs(M.get_all_profiles(user_profiles)) do
		if type(p) == "table" and p.id == id then return p end
	end
	Logger.warn(LOG, "Profile '%s' not found — falling back to 'basic'.", id)
	for _, p in ipairs(M.BUILTIN_PROFILES) do
		if p.id == "basic" then return p end
	end
	-- Last-resort fallback: synthesize a minimal raw profile so the engine
	-- never sees nil even on a totally broken config.
	return { id = "raw", batch = false, system_single = "{context}" }
end

--- Resolves the appropriate system prompt logic based on the current profile.
--- Supports both schemas: a function ``system_multi(n)`` (legacy Lua) and a
--- string template ``system_multi_template`` (JSON / AHK shape — ``{n}`` is
--- substituted by the requested count).
--- @param profile table The active profile data.
--- @param n number The number of predictions expected.
--- @return string The resolved system prompt.
function M.resolve_system_prompt(profile, n)
	local prompt = ""

	if type(profile) ~= "table" then
		prompt = BASIC_PROMPT_SINGLE
	elseif type(profile.raw_prompt) == "string" and profile.raw_prompt ~= "" then
		prompt = profile.raw_prompt
	elseif n == 1 then
		prompt = type(profile.system_single) == "string" and profile.system_single or BASIC_PROMPT_SINGLE
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
			prompt = BASIC_PROMPT_SINGLE
		end
	end

	-- Lazy load Core module to prevent circular dependency crashes
	local Core = require("modules.llm.init")
	local def_min = Core.DEFAULT_STATE.llm_min_words
	local def_max = Core.DEFAULT_STATE.llm_max_words

	-- Dynamically inject the user-configured words limits and fallback to Core defaults
	local min_w = tonumber(hs.settings.get("llm_min_words")) or def_min
	local max_w = tonumber(hs.settings.get("llm_max_words")) or def_max
	if max_w > 0 and max_w < min_w then max_w = min_w end

	local max_w_str = (max_w > 0) and tostring(max_w) or "illimité"
	local min_w_str = tostring(min_w)

	prompt = prompt:gsub("{max_words}", max_w_str)
	prompt = prompt:gsub("{min_words}", min_w_str)

	-- Inject the active UI locale so the model replies in the user's language
	local locale  = i18n.get_locale() or "fr"
	prompt = prompt:gsub("{language}", locale)

	return prompt
end

return M
