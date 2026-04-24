--- modules/llm/profiles.lua

--- ==============================================================================
--- MODULE: LLM Profiles
--- DESCRIPTION:
--- Manages built-in and user-defined prompt profiles.
--- ==============================================================================

local M = {}

local Logger = require("lib.logger")
local hs     = hs
local LOG    = "llm.profiles"





-- ===================================
-- ===================================
-- ======= 1/ Built-in Prompts =======
-- ===================================
-- ===================================

local RAW_PROMPT_SINGLE = [[{context}]]

local BASIC_PROMPT_SINGLE = [[Tu es un moteur de complétion clavier ultra-concis.
Contexte utilisateur : {context}

Donne strictement la suite immédiate du contexte.
C’EST UNE OBLIGATION ABSOLUE : Tu DOIS générer AU MINIMUM {min_words} mots et AU MAXIMUM {max_words} mots. PAS UN MOT DE PLUS OU DE MOINS.
N’ajoute aucune explication, aucun commentaire, aucune liste, aucune puce, aucun guillemet, aucune reformulation du contexte.
Retourne uniquement les mots à ajouter.]]

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

--- Generates a batch prompt for multiple predictions.
--- @param n number The number of predictions required.
--- @return string The formatted prompt string.
local function BATCH_ADVANCED_PROMPT(n)
	return ADVANCED_PROMPT_SINGLE .. "\n\n" ..
[[BATCH MODE: Generate exactly ]] .. tostring(n) .. [[ different continuations.
Separate each with `===`.

TAIL_CORRECTED: <tail>
NEXT_WORDS: <prediction 1>
===
TAIL_CORRECTED: <tail>
NEXT_WORDS: <prediction 2>
===]]
end





-- ========================================
-- ========================================
-- ======= 2/ Registry & Resolution =======
-- ========================================
-- ========================================

M.BUILTIN_PROFILES = {
	{
		id            = "raw",
		label         = "○○○ Autocomplétion — Aucun prompt, juste le contexte",
		batch         = false,
		system_single = RAW_PROMPT_SINGLE,
		system_multi  = nil,
	},
	{
		id            = "basic",
		label         = "●○○ Basique — Prédiction simple",
		batch         = false,
		system_single = BASIC_PROMPT_SINGLE,
		system_multi  = nil,
	},
	{
		id            = "advanced",
		label         = "●●○ Avancé — Correction + Prédiction",
		batch         = false,
		system_single = ADVANCED_PROMPT_SINGLE,
		system_multi  = nil,
	},
	{
		id            = "batch_advanced",
		label         = "●●● Batch Avancé — 1 req. avancée avec {n} prédiction{s}",
		batch         = true,
		system_single = ADVANCED_PROMPT_SINGLE,
		system_multi  = BATCH_ADVANCED_PROMPT,
	},
}

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

--- Retrieves the currently active profile object, falling back to basic if invalid.
--- @param active_id string The ID of the currently requested profile.
--- @param user_profiles table Current user defined profiles.
--- @return table The active profile object.
function M.get_active_profile(active_id, user_profiles)
	local id = tostring(active_id)
	
	-- Auto-migrate legacy profiles to maintain compatibility
	if id == "parallel" or id == "parallel_simple" then id = "basic" end
	if id == "batch" or id == "batch_simple" then id = "batch_advanced" end
	if id == "parallel_advanced" then id = "advanced" end
	if id == "base_completion" then id = "raw" end
	
	for _, p in ipairs(M.get_all_profiles(user_profiles)) do
		if type(p) == "table" and p.id == id then return p end
	end
	Logger.warn(LOG, string.format("Profile %s not found, falling back to basic.", id))
	return M.BUILTIN_PROFILES[2]  -- Fallback: basic
end

--- Resolves the appropriate system prompt logic based on the current profile.
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
		if type(profile.system_multi) == "function" then 
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
	
	return prompt
end

return M
