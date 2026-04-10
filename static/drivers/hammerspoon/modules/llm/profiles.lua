--- modules/llm/profiles.lua

--- ==============================================================================
--- MODULE: LLM Profiles
--- DESCRIPTION:
--- Manages built-in and user-defined prompt profiles.
--- ==============================================================================

local M = {}





-- ======================================
-- ======================================
-- ======= 1/ Built-in Prompts ==========
-- ======================================
-- ======================================

local RAW_PROMPT_SINGLE = [[{context}]]

local BASIC_PROMPT_SINGLE = [[Tu es un moteur de complétion clavier ultra-concis.
Contexte utilisateur : {context}

Donne strictement la suite immédiate du contexte en 1 à 5 mots maximum.
N’ajoute aucune explication, aucun commentaire, aucune liste, aucune puce, aucun guillemet, aucune reformulation du contexte.
Retourne uniquement les mots à ajouter.]]

local ADVANCED_PROMPT_SINGLE = [[Tu es un moteur strict de correction et de complétion de texte.
RÈGLES CRITIQUES :
1. Tu reçois un PREFIX (le contexte complet) et un TAIL (les ~5 à 7 derniers mots).
2. Format : Deux lignes commençant par "TAIL_CORRECTED:" et "NEXT_WORDS:".
3. TAIL_CORRECTED : Corrige l’orthographe, la grammaire et les accents UNIQUEMENT dans le TAIL. Ne modifie pas le sens. S’il n’y a pas de faute, recopie le TAIL EXACTEMENT à l’identique sans rien changer.
4. NEXT_WORDS : Prédis 1 à 5 mots pour continuer la phrase de façon logique. Laisse vide si la phrase est terminée.

EXEMPLES :

Exemple 1 (Correction Grammaticale) :
PREFIX: "Il est aller à Paris"
TAIL: "est aller à Paris"
TAIL_CORRECTED: est allé à Paris
NEXT_WORDS: 

Exemple 2 (Correction + Prédiction) :
PREFIX: "Je vous envoit ce mail pour vous dir"
TAIL: "envoit ce mail pour vous dir"
TAIL_CORRECTED: envoie ce mail pour vous dire
NEXT_WORDS: que tout est prêt.

Exemple 3 (Aucune Correction + Courte Prédiction) :
PREFIX: "Salut, comment ça"
TAIL: "Salut, comment ça"
TAIL_CORRECTED: Salut, comment ça
NEXT_WORDS: va ?

Exemple 4 (Aucune Correction + Longue Prédiction) :
PREFIX: "Je pense qu’il est important de"
TAIL: "qu’il est important de"
TAIL_CORRECTED: qu’il est important de
NEXT_WORDS: prendre une décision rapidement.

Exemple 5 (Code) :
PREFIX: "def calculate_total(price, tax):"
TAIL: "def calculate_total(price, tax):"
TAIL_CORRECTED: def calculate_total(price, tax):
NEXT_WORDS: return price * (1 + tax)
]]

--- Generates a batch prompt for multiple predictions.
--- @param n number The number of predictions required.
--- @return string The formatted prompt string.
local function BATCH_ADVANCED_PROMPT(n)
    return ADVANCED_PROMPT_SINGLE .. "\n\n" ..
[[=========================================
RÈGLE SPÉCIALE BATCH : Tu DOIS OBLIGATOIREMENT générer EXACTEMENT ]] .. tostring(n) .. [[ suites logiques différentes.
Ne t’arrête SURTOUT PAS avant d’avoir donné les ]] .. tostring(n) .. [[ propositions.
Sépare chaque proposition par `===`.

Format strict à respecter scrupuleusement :
TAIL_CORRECTED: <tail>
NEXT_WORDS: <prédiction 1>
===
TAIL_CORRECTED: <tail>
NEXT_WORDS: <prédiction 2>
===
(Continue ainsi jusqu’à la proposition ]] .. tostring(n) .. [[)
===]]
end





-- =======================================
-- =======================================
-- ======= 2/ Registry & Resolution ======
-- =======================================
-- =======================================

M.BUILTIN_PROFILES = {
    {
        id            = "raw",
        label         = "○○○ Raw — Aucun prompt, juste le contexte",
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
    return M.BUILTIN_PROFILES[2]  -- Fallback: basic
end

--- Resolves the appropriate system prompt logic based on the current profile.
--- @param profile table The active profile data.
--- @param n number The number of predictions expected.
--- @return string The resolved system prompt.
function M.resolve_system_prompt(profile, n)
    if type(profile) ~= "table" then return BASIC_PROMPT_SINGLE end
    
    -- Support for custom profiles built from the Prompt Editor
    if type(profile.raw_prompt) == "string" and profile.raw_prompt ~= "" then
        return profile.raw_prompt
    end

    if n == 1 then
        return type(profile.system_single) == "string" and profile.system_single or BASIC_PROMPT_SINGLE
    else
        if type(profile.system_multi) == "function" then return profile.system_multi(n) end
        if type(profile.system_multi) == "string"   then return profile.system_multi    end
    end
    return BASIC_PROMPT_SINGLE
end

return M
