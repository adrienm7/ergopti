-- modules/llm.lua

-- ===========================================================================
-- LLM Prediction Engine Module.
--
-- Manages the communication with the local Ollama API to provide AI-assisted
-- text completions. Includes robust text parsing, prompt profiling, and a
-- custom token/character hybrid diffing algorithm to smoothly merge the AI’s
-- output with the user’s existing typing buffer.
-- ===========================================================================

local M = {}
local utils = require("lib.text_utils")

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end





-- =======================================
-- =======================================
-- ======= 1/ Constants & Defaults =======
-- =======================================
-- =======================================

M.DEFAULT_LLM_ENABLED         = false
M.DEFAULT_LLM_MODEL           = "llama3.1"
M.DEFAULT_LLM_DEBOUNCE        = 0.5
M.DEFAULT_LLM_NUM_PREDICTIONS = 3
M.DEFAULT_LLM_SEQUENTIAL_MODE = false  -- Kept for backward-compatibility





-- =======================================
-- =======================================
-- ======= 2/ Built-in Profiles ==========
-- =======================================
-- =======================================

-- System prompts are kept in French as they dictate instructions to the AI.
local SIMPLE_PROMPT_SINGLE = [[Tu es un assistant de frappe au clavier.
Voici le texte que je suis en train de taper : {context}

Prédis UNIQUEMENT la suite directe (1 à 5 mots).
RÈGLES ABSOLUES :
- NE RÉPÈTE PAS le texte déjà écrit. Donne uniquement la suite.
- N’écris jamais de points de suspension (...).
- Ne fais aucun commentaire, pas de guillemets.]]

local function SIMPLE_PROMPT_BATCH(n)
    return [[Tu es un assistant de frappe au clavier.
Voici le texte que je suis en train de taper : {context}

Tu dois proposer EXACTEMENT ]] .. tostring(n) .. [[ suites directes possibles (de 1 à 5 mots).
RÈGLES ABSOLUES :
- NE RÉPÈTE PAS le texte déjà écrit. Donne uniquement la suite.
- N’écris jamais de points de suspension (...).
- Sépare chaque proposition par une ligne "---".
Exemple :
suite une
---
suite deux
---
suite trois]]
end

local ADVANCED_PROMPT_SINGLE = [[Tu es un assistant strict d’autocomplétion. NE FAIS AUCUN COMMENTAIRE.
Voici le texte saisi jusqu’à présent : {context}

Réponds UNIQUEMENT sous ce format exact :
TAIL_CORRECTED: <réécris le dernier mot/fragment si mal orthographié, sinon recopie-le>
NEXT_WORDS: <suite prédite (1 à 5 mots), ou vide>

RÈGLE : NEXT_WORDS ne doit JAMAIS répéter le contexte, juste la suite. Ne mets pas de points de suspension.]]

local function ADVANCED_PROMPT_BATCH(n)
    return [[Tu es un assistant strict d’autocomplétion. NE FAIS AUCUN COMMENTAIRE.
Voici le texte saisi jusqu’à présent : {context}

Tu dois produire EXACTEMENT ]] .. tostring(n) .. [[ continuations DIFFÉRENTES.
FORMAT STRICTEMENT REQUIS (répété ]] .. tostring(n) .. [[ fois, séparé par une ligne "---"):
TAIL_CORRECTED: <réécris le dernier mot/fragment si mal orthographié, sinon recopie-le>
NEXT_WORDS: <suite prédite différente à chaque fois>
---

RÈGLE : NEXT_WORDS ne doit JAMAIS répéter le contexte, juste la suite. Ne mets pas de points de suspension (...).]]
end

-- Raw prompt for basic completion models (Base/Coder)
local BASE_PROMPT_SINGLE = [[{context}]]

-- UI labels and descriptions are kept in French for the menu display.
M.BUILTIN_PROFILES = {
    {
        id            = "parallel_simple",
        label         = "Parallèle (Simple) — N req. de 1 prédiction",
        description   = "Prédiction directe, très rapide, pour tous modèles",
        batch         = false,
        system_single = SIMPLE_PROMPT_SINGLE,
        system_multi  = nil,
    },
    {
        id            = "parallel_advanced",
        label         = "Parallèle (Avancé) — N req. de 1 prédiction",
        description   = "Correction + Prédiction, modèles performants",
        batch         = false,
        system_single = ADVANCED_PROMPT_SINGLE,
        system_multi  = nil,
    },
    {
        id            = "base_completion",
        label         = "Complétion Pure (Base) — 1 prédiction",
        description   = "Idéal pour modèles de complétion pure. Aucun prompt système.",
        batch         = false,
        system_single = BASE_PROMPT_SINGLE,
        system_multi  = nil,
    },
    {
        id            = "batch_simple",
        label         = "Batch (Simple) — 1 req. de N prédictions",
        description   = "Plusieurs suggestions en 1 seul appel",
        batch         = true,
        system_single = SIMPLE_PROMPT_SINGLE,
        system_multi  = SIMPLE_PROMPT_BATCH,
    },
    {
        id            = "batch_advanced",
        label         = "Batch (Avancé) — 1 req. de N prédictions",
        description   = "Correction + N suggestions en 1 appel",
        batch         = true,
        system_single = ADVANCED_PROMPT_SINGLE,
        system_multi  = ADVANCED_PROMPT_BATCH,
    },
}

-- Active profile ID (can be overridden from menu)
M.active_profile_id = "parallel_simple"

-- User custom profiles (loaded from config.json by menu.lua)
M.user_profiles = {}

--- Retrieves all available profiles (built-in + user-defined)
--- @return table A list of profile definitions
local function get_all_profiles()
    local all = {}
    for _, p in ipairs(M.BUILTIN_PROFILES) do table.insert(all, p) end
    if type(M.user_profiles) == "table" then
        for _, p in ipairs(M.user_profiles) do table.insert(all, p) end
    end
    return all
end

--- Retrieves the active profile safely, handling legacy migrations
--- @return table The active profile definition
function M.get_active_profile()
    local id = tostring(M.active_profile_id)
    
    -- Auto-migration from legacy profiles
    if id == "parallel" then id = "parallel_simple" end
    if id == "batch" then id = "batch_simple" end
    
    for _, p in ipairs(get_all_profiles()) do
        if type(p) == "table" and p.id == id then return p end
    end
    return M.BUILTIN_PROFILES[1]  -- Fallback: parallel_simple
end

--- Safely sets the active profile
--- @param id string The profile ID
function M.set_active_profile(id)
    if type(id) == "string" then
        M.active_profile_id = id
        local p = M.get_active_profile()
        M.DEFAULT_LLM_SEQUENTIAL_MODE = (p and not p.batch) or false
    end
end





-- ===================================
-- ===================================
-- ======= 3/ Model Heuristics =======
-- ===================================
-- ===================================

--- Detects if a model is considered "small" based on common naming conventions
--- @param name string The model name
--- @return boolean True if small
local function is_small_model(name)
    if type(name) ~= "string" then return false end
    name = name:lower()
    
    if name:match("0%.[0-9]+b") or name:match(":0%.[0-9]") or name:match("^0%.[0-9]") then return true end
    for _, tag in ipairs({"%-tiny", ":tiny", "%-mini", ":mini", "%-nano", ":nano", "%-small", ":small"}) do
        if name:match(tag) then return true end
    end
    return false
end
M.is_small_model = is_small_model

--- Detects if a model is a reasoning/thinking model based on naming conventions
--- @param name string The model name
--- @return boolean True if it is a thinking model
local function is_thinking_model(name)
    if type(name) ~= "string" then return false end
    name = name:lower()
    
    if name:match("qwen3")        then return true end
    if name:match("deepseek%-r")  then return true end
    if name:match("deepseek_r")   then return true end
    if name:match("%-r1")         then return true end
    if name:match(":r1")          then return true end
    if name:match("%-think")      then return true end
    if name:match(":think")       then return true end
    if name:match("gpt%-oss")     then return true end
    return false
end
M.is_thinking_model = is_thinking_model

--- Checks availability of the selected model locally via Ollama API
--- @param model_name string The target model name
--- @param on_available function Callback if model is found
--- @param on_missing function Callback if model is missing or server is down
function M.check_availability(model_name, on_available, on_missing)
    if type(model_name) ~= "string" then return end
    
    hs.http.asyncGet("http://127.0.0.1:11434/api/tags", {}, function(status, body)
        if status ~= 200 then 
            if type(on_missing) == "function" then pcall(on_missing, true) end
            return 
        end
        
        local ok, tags = pcall(hs.json.decode, body)
        if ok and type(tags) == "table" and type(tags.models) == "table" then
            local found = false
            for _, m in ipairs(tags.models) do
                if type(m.name) == "string" and m.name:find(model_name, 1, true) then 
                    found = true
                    break 
                end
            end
            
            if found then
                if type(on_available) == "function" then pcall(on_available) end
            else
                if type(on_missing) == "function" then pcall(on_missing, false) end
            end
        else
            if type(on_missing) == "function" then pcall(on_missing, false) end
        end
    end)
end





-- ========================================
-- ========================================
-- ======= 4/ Diff & Parsing Engine =======
-- ========================================
-- ========================================

--- Determines if two characters are fundamentally equivalent for diffing
--- @param c1 string The first char
--- @param c2 string The second char
--- @return boolean True if they match
local function chars_match(c1, c2)
    if c1 == c2 then return true end
    -- Treat all standard and non-breaking spaces equally
    local function is_sp(c) return c == " " or c == "\194\160" or c == "\226\128\175" end
    return is_sp(c1) and is_sp(c2)
end

--- Splits a string into word and symbol tokens
--- @param text string The input string
--- @return table An array of string tokens
local function tokenize(text)
    local tokens, cur, is_w = {}, "", nil
    if type(text) ~= "string" then return tokens end
    
    for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local w = c:match("[%w\128-\255]") ~= nil
        if is_w == nil then 
            is_w = w
            cur = c
        elseif is_w == w then 
            cur = cur .. c
        else 
            table.insert(tokens, cur)
            is_w = w
            cur = c 
        end
    end
    if cur ~= "" then table.insert(tokens, cur) end
    
    return tokens
end

--- Performs a fine-grained character-level diff between two segments
--- @param t1_str string Original segment
--- @param t2_str string Target segment
--- @return table, number Diff chunks and a similarity ratio
local function char_diff(t1_str, t2_str)
    local t1, t2 = {}, {}
    if type(t1_str) ~= "string" then t1_str = "" end
    if type(t2_str) ~= "string" then t2_str = "" end
    
    for c in t1_str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do table.insert(t1, c) end
    for c in t2_str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do table.insert(t2, c) end

    local dp = {}
    for i = 0, #t1 do dp[i] = {[0] = 0} end
    for j = 0, #t2 do dp[0][j] = 0 end
    
    for i = 1, #t1 do 
        for j = 1, #t2 do
            dp[i][j] = chars_match(t1[i], t2[j]) and dp[i-1][j-1] + 1
                       or math.max(dp[i-1][j], dp[i][j-1])
        end 
    end

    local diffs, i, j = {}, #t1, #t2
    while i > 0 or j > 0 do
        if i > 0 and j > 0 and chars_match(t1[i], t2[j]) then
            table.insert(diffs, 1, {type="equal",  text=t2[j]})
            i, j = i - 1, j - 1
        elseif j > 0 and (i == 0 or dp[i][j-1] >= dp[i-1][j]) then
            table.insert(diffs, 1, {type="insert", text=t2[j]})
            j = j - 1
        else
            i = i - 1
        end
    end

    -- Compress contiguous differences
    local merged = {}
    for _, d in ipairs(diffs) do
        if #merged > 0 and merged[#merged].type == d.type then
            merged[#merged].text = merged[#merged].text .. d.text
        else 
            table.insert(merged, {type=d.type, text=d.text}) 
        end
    end

    local max_len = math.max(#t1, #t2)
    local ratio = max_len > 0 and (dp[#t1][#t2] / max_len) or 0
    
    return merged, ratio
end

--- Processes the raw string output of the model to produce a safe edit operation
--- @param full_context string The context string supplied to the model
--- @param tail_text string The user’s active typing segment
--- @param tc_raw string The model’s "TAIL_CORRECTED" response
--- @param nw_raw string The model’s "NEXT_WORDS" response
--- @return table|nil The edit plan, or nil if invalid
local function process_prediction(full_context, tail_text, tc_raw, nw_raw)
    if type(full_context) ~= "string" then full_context = "" end
    if type(tail_text) ~= "string" then tail_text = "" end
    if type(tc_raw) ~= "string" or type(nw_raw) ~= "string" then return nil end

    local tc = tc_raw:gsub("^\"", ""):gsub("\"$", ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    local nw = nw_raw:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")

    -- Remove overlaps (hallucinations where the model repeats context inside next_words)
    local function strip_overlap(context, next_w)
        if not context or not next_w or context == "" or next_w == "" then return next_w end
        local c_low = context:lower()
        local n_low = next_w:lower()
        local max_len = math.min(#c_low, 150)
        local start_idx = #c_low - max_len + 1
        
        for i = start_idx, #c_low do
            local suffix = c_low:sub(i)
            if n_low:sub(1, #suffix) == suffix then
                return next_w:sub(#suffix + 1)
            end
        end
        return next_w
    end

    nw = strip_overlap(full_context, nw)
    nw = nw:gsub("^%s+", "")

    if tc == "" and nw == "" then return nil end

    local tail_trailing = tail_text:match("(%s+)$")
    if tail_trailing and not tc:match("%s$") then tc = tc .. tail_trailing end

    local last_char  = utils.utf8_sub(tc, -1)
    local first_char = utils.utf8_sub(nw, 1, 1)
    if not (last_char:match("[%s''%-]") or first_char:match("[%s.,;)%}%%%]]") or nw == "") then
        nw = " " .. nw
    end

    local tok1, tok2 = tokenize(tail_text), tokenize(tc)
    local dp = {}
    for i = 0, #tok1 do dp[i] = {[0]=0} end
    for j = 0, #tok2 do dp[0][j] = 0 end
    
    for i = 1, #tok1 do 
        for j = 1, #tok2 do
            dp[i][j] = chars_match(tok1[i], tok2[j]) and dp[i-1][j-1] + 1
                       or math.max(dp[i-1][j], dp[i][j-1])
        end 
    end

    local diffs, i, j = {}, #tok1, #tok2
    while i > 0 or j > 0 do
        if i > 0 and j > 0 and chars_match(tok1[i], tok2[j]) then
            table.insert(diffs, 1, {type="equal",  text=tok2[j]})
            i, j = i - 1, j - 1
        elseif j > 0 and (i == 0 or dp[i][j-1] >= dp[i-1][j]) then
            table.insert(diffs, 1, {type="insert", text=tok2[j]})
            j = j - 1
        else
            table.insert(diffs, 1, {type="delete", text=tok1[i]})
            i = i - 1
        end
    end

    while #diffs > 0 and diffs[1].type == "equal" do table.remove(diffs, 1) end

    local compressed, cur_del, cur_ins = {}, "", ""
    for _, d in ipairs(diffs) do
        if d.type == "equal" then
            if cur_del ~= "" or cur_ins ~= "" then
                table.insert(compressed, {type="replace", del=cur_del, ins=cur_ins})
                cur_del, cur_ins = "", ""
            end
            table.insert(compressed, {type="equal", text=d.text})
        elseif d.type == "delete" then 
            cur_del = cur_del .. d.text
        elseif d.type == "insert" then 
            cur_ins = cur_ins .. d.text
        end
    end
    if cur_del ~= "" or cur_ins ~= "" then
        table.insert(compressed, {type="replace", del=cur_del, ins=cur_ins})
    end

    local final_chunks, spilled_nw = {}, ""
    for idx, blk in ipairs(compressed) do
        if blk.type == "equal" then
            table.insert(final_chunks, {type="equal", text=blk.text})
        else
            if blk.del == "" and idx == #compressed then
                nw = blk.ins .. nw
            else
                local c_diffs, ratio = char_diff(blk.del, blk.ins)
                local is_single_word = not (blk.del:find("[%s\194\160\226\128\175]")
                                         or blk.ins:find("[%s\194\160\226\128\175]"))
                
                if is_single_word or ratio >= 0.5 then
                    for _, cd in ipairs(c_diffs) do table.insert(final_chunks, cd) end
                elseif blk.ins ~= "" then
                    table.insert(final_chunks, {type="insert", text=blk.ins})
                end
            end
        end
    end

    local merged = {}
    for _, ch in ipairs(final_chunks) do
        if #merged > 0 and merged[#merged].type == ch.type then
            merged[#merged].text = merged[#merged].text .. ch.text
        else 
            table.insert(merged, {type=ch.type, text=ch.text}) 
        end
    end

    while #merged > 0 do
        if merged[1].type == "equal" then 
            table.remove(merged, 1)
        elseif merged[1].type == "insert" and merged[1].text:match("^[%s\194\160\226\128\175]+$") then
            table.remove(merged, 1)
        else 
            break 
        end
    end

    if #merged > 0 and merged[#merged].type == "insert" then
        local text = merged[#merged].text
        local sp   = text:find("[%s\194\160\226\128\175]")
        if sp == 1 then
            spilled_nw = text
            table.remove(merged, #merged)
        elseif sp then
            merged[#merged].text = text:sub(1, sp-1)
            spilled_nw = text:sub(sp)
        end
    end

    local has_corrections = false
    for _, ch in ipairs(merged) do
        if ch.type == "insert" then has_corrections = true; break end
    end

    local common_len = utils.get_common_prefix_utf8(tail_text, tc)
    return {
        deletes         = utils.utf8_len(tail_text) - common_len,
        to_type         = utils.utf8_sub(tc, common_len+1) .. nw,
        nw              = spilled_nw .. nw,
        chunks          = merged,
        has_corrections = has_corrections,
    }
end





-- =======================================
-- =======================================
-- ======= 5/ Robust Text Parsers ========
-- =======================================
-- =======================================

--- Strips markdown formatting to process raw text properly
--- @param text string The raw output
--- @return string Cleaned text
local function clean_model_output(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("%*%*", "")
    text = text:gsub("`", "")
    return text
end

--- Attempts to extract the TAIL_CORRECTED value from the LLM output
--- @param text string The raw LLM string
--- @param default_tail string The fallback string if no match is found
--- @return string The extracted context
local function extract_tc(text, default_tail)
    text = clean_model_output(text)
    
    local tc = text:match("[Tt][Aa][Ii][Ll][_%s]?[Cc][Oo][Rr][Rr][Ee][Cc][Tt][Ee][Dd]%s*:%s*([^\n\r]+)")
        or text:match("[Cc][Oo][Rr][Rr][Ee][Cc][Tt][Ee][Dd]%s*:%s*([^\n\r]+)")
        or text:match("[Tt][Aa][Ii][Ll]%s*:%s*([^\n\r]+)")
        or text:match("TAIL_CORRIG.E%s*:%s*([^\n\r]+)")
        or text:match("[Ll][Ii][Nn][Ee]%s*1%s*:%s*([^\n\r]+)")
        or text:match("[Ll]1%s*:%s*([^\n\r]+)")
    
    if tc then return tc end
    
    -- Fallback to the original tail (for simple / base modes)
    return type(default_tail) == "string" and default_tail or ""
end

--- Attempts to extract the NEXT_WORDS value from the LLM output
--- @param text string The raw LLM string
--- @return string The extracted prediction
local function extract_nw(text)
    text = clean_model_output(text)
    
    local nw = text:match("[Nn][Ee][Xx][Tt][_%s]?[Ww][Oo][Rr][Dd][Ss]%s*:%s*([^\n\r]*)")
        or text:match("[Nn][Ee][Xx][Tt]%s*:%s*([^\n\r]*)")
        or text:match("[Cc][Oo][Nn][Tt][Ii][Nn][Uu][Aa][Tt][Ii][Oo][Nn]%s*:%s*([^\n\r]*)")
        or text:match("MOTS_SUIVANTS%s*:%s*([^\n\r]*)")
        or text:match("[Ll][Ii][Nn][Ee]%s*2%s*:%s*([^\n\r]*)")
        or text:match("[Ll]2%s*:%s*([^\n\r]*)")
    
    if nw then 
        -- Clean up stray ellipsis
        nw = nw:gsub("^%.%.%.%s*", ""):gsub("%s*%.%.%.$", "")
        return nw == "..." and "" or nw
    end
    
    -- Fallback if the format wasn’t explicitly matched
    if not text:match("TAIL_CORRECTED") and not text:match("TAIL_CORRIG") then
        local raw_nw = text:gsub("^%s+", ""):gsub("%s+$", "")
        raw_nw = raw_nw:gsub("^%.%.%.%s*", ""):gsub("%s*%.%.%.$", "")
        if raw_nw == "..." then return "" end
        return raw_nw
    end
    
    return ""
end

--- Splits a batch response into its respective prediction blocks
--- @param raw string The full LLM output
--- @return table An array of blocks
local function split_blocks(raw)
    if type(raw) ~= "string" then return {} end
    local text   = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    local blocks, current = {}, {}
    
    for line in (text .. "\n---\n"):gmatch("([^\n]*)\n") do
        if line:match("^%s*%-%-%-+%s*$") then
            if #current > 0 then 
                table.insert(blocks, table.concat(current, "\n"))
                current = {} 
            end
        else 
            table.insert(current, line) 
        end
    end
    return blocks
end

--- Strips <think> tags generated by reasoning models
--- @param text string The raw output
--- @return string The output without thinking steps
local function strip_thinking(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("<think>.-</think>%s*", "")
    text = text:gsub("</think>%s*", "")
    return text
end





-- ===================================
-- ===================================
-- ======= 6/ API Communication ======
-- ===================================
-- ===================================

--- Constructs the payload options targeting the Ollama API
--- @param temperature number The AI creativity metric
--- @param num_predict_tokens number Max token output
--- @param model_name string Model identifier
--- @return table The configuration object
local function build_options(temperature, num_predict_tokens, model_name)
    local opts = {
        temperature = tonumber(temperature) or 0.1,
        num_predict = tonumber(num_predict_tokens) or 40,
        stop        = { "\n\n\n\n" },
    }
    
    if is_thinking_model(model_name) then
        opts.think           = false
        opts.thinking_budget = 0
        -- We do not restrict tokens on reasoning models to give them space to process
        opts.num_predict = math.max(opts.num_predict, 400)
    end
    
    return opts
end

--- Resolves the appropriate system prompt template based on profile
--- @param profile table Active profile definition
--- @param n number Number of predictions requested
--- @param model_name string Target model
--- @return string The raw prompt template
local function resolve_system_prompt(profile, n, model_name)
    if type(profile) ~= "table" then return SIMPLE_PROMPT_SINGLE end
    
    if type(profile.raw_prompt) == "string" then
        return profile.raw_prompt
    end
    
    if n == 1 then
        if type(profile.system_single) == "string" then return profile.system_single end
    else
        if type(profile.system_multi) == "function" then return profile.system_multi(n) end
        if type(profile.system_multi) == "string"   then return profile.system_multi    end
    end
    
    return n == 1 and SIMPLE_PROMPT_SINGLE or SIMPLE_PROMPT_BATCH(n)
end

--- Executes the HTTP POST request to Ollama and triggers the parsing callbacks
local function post_and_parse(model_name, system_prompt, full_text, tail_text,
                               temperature, num_predict_tokens, num_predictions,
                               on_success, on_fail)
    
    local context_str = (type(full_text) == "string" and full_text or "") .. (type(tail_text) == "string" and tail_text or "")
    local messages = {}

    -- Check if it’s a raw prompt encapsulating context directly
    if type(system_prompt) == "string" and system_prompt:find("{context}", 1, true) then
        local final_prompt = system_prompt:gsub("%{context%}", function() return context_str end)
        table.insert(messages, { role = "user", content = final_prompt })
    else
        table.insert(messages, { role = "system", content = system_prompt })
        table.insert(messages, { role = "user",   content = context_str })
    end

    local payload = {
        model    = tostring(model_name),
        messages = messages,
        stream   = false,
        options  = build_options(temperature, num_predict_tokens, model_name),
    }

    local ok, encoded = pcall(hs.json.encode, payload)
    if not ok or not encoded then 
        if type(on_fail) == "function" then pcall(on_fail) end
        return 
    end

    hs.http.asyncPost(
        "http://127.0.0.1:11434/api/chat",
        encoded,
        { ["Content-Type"] = "application/json" },
        function(status, body, _)
            if status ~= 200 then 
                if type(on_fail) == "function" then pcall(on_fail) end
                return 
            end
            
            local ok_dec, resp = pcall(hs.json.decode, body)
            if not ok_dec or type(resp) ~= "table" or type(resp.message) ~= "table" or type(resp.message.content) ~= "string" then
                if type(on_fail) == "function" then pcall(on_fail) end
                return
            end

            local raw     = strip_thinking(resp.message.content)
            local results = {}

            if num_predictions == 1 then
                local pred = process_prediction(context_str, tail_text, extract_tc(raw, tail_text), extract_nw(raw))
                if pred then table.insert(results, pred) end
            else
                for _, block in ipairs(split_blocks(raw)) do
                    if #results >= num_predictions then break end
                    local pred = process_prediction(context_str, tail_text, extract_tc(block, tail_text), extract_nw(block))
                    if pred then table.insert(results, pred) end
                end
                
                -- Fallback if the model completely failed the batch formatting instructions
                if #results == 0 then
                    local pred = process_prediction(context_str, tail_text, extract_tc(raw, tail_text), extract_nw(raw))
                    if pred then table.insert(results, pred) end
                end
            end

            if #results == 0 then 
                if type(on_fail) == "function" then pcall(on_fail) end
                return 
            end
            
            if keylogger and type(keylogger.log_llm) == "function" then
                pcall(keylogger.log_llm, context_str, results)
            end

            if type(on_success) == "function" then pcall(on_success, results) end
        end
    )
end





-- ===================================
-- ===================================
-- ======= 7/ Fetch Strategies =======
-- ===================================
-- ===================================



-- =========================================
-- ===== 7.1) Batch Mode (1 Request) =======
-- =========================================

local function fetch_batch(full_text, tail_text, model_name, temperature,
                             max_predict, num_predictions, profile,
                             on_success, on_fail)
                             
    local effective_temp = tonumber(temperature) or 0.1
    local system_prompt  = resolve_system_prompt(profile, num_predictions, model_name)
    local tokens         = (tonumber(max_predict) or 40) * num_predictions + 20

    local t0 = hs.timer.secondsSinceEpoch()
    post_and_parse(model_name, system_prompt, full_text, tail_text,
                   effective_temp, tokens, num_predictions,
                   function(results)
                       local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
                       if type(on_success) == "function" then pcall(on_success, results, ms) end
                   end,
                   on_fail)
end



-- ==============================================
-- ===== 7.2) Parallel Mode (N Requests) ========
-- ==============================================

local function fetch_parallel(full_text, tail_text, model_name, temperature,
                                max_predict, num_predictions, profile,
                                on_success, on_fail)
                                
    local system_prompt = resolve_system_prompt(profile, 1, model_name)
    local t0            = hs.timer.secondsSinceEpoch()
    local results       = {}
    local done_count    = 0
    local finished      = false
    
    local base_temp     = tonumber(temperature) or 0.1

    local function finish()
        if finished then return end
        finished = true
        
        if #results == 0 then 
            if type(on_fail) == "function" then pcall(on_fail) end
            return 
        end
        
        local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
        if type(on_success) == "function" then pcall(on_success, results, ms) end
    end

    local temp_steps = {}
    for i = 1, num_predictions do
        temp_steps[i] = (i == 1) and base_temp
                        or math.min(1.0, base_temp + (i - 1) * 0.15)
    end

    for i = 1, num_predictions do
        post_and_parse(model_name, system_prompt, full_text, tail_text,
                       temp_steps[i], (tonumber(max_predict) or 40) + 10, 1,
                       function(preds)
                           if finished then return end
                           if type(preds) == "table" and type(preds[1]) == "table" then
                               local dup = false
                               for _, ex in ipairs(results) do
                                   if ex.to_type == preds[1].to_type then dup = true; break end
                               end
                               if not dup then table.insert(results, preds[1]) end
                           end
                           
                           done_count = done_count + 1
                           if done_count >= num_predictions then finish() end
                       end,
                       function()
                           if finished then return end
                           done_count = done_count + 1
                           if done_count >= num_predictions then finish() end
                       end)
    end
end





-- =============================
-- =============================
-- ======= 8/ Public API =======
-- =============================
-- =============================

--- Entry point to dispatch an LLM prediction request
--- Automatically checks disabled app rules before firing
function M.fetch_llm_prediction(full_text, tail_text, model_name, temperature,
                                  max_predict, num_predictions,
                                  on_success, on_fail,
                                  _legacy_sequential_mode)

    local ok_front, front = pcall(hs.application.frontmostApplication)
    if ok_front and front then
        local config_path = hs.configdir and (hs.configdir .. "/config.json")
        local disabled = nil
        
        if config_path then
            local ok_fh, fh = pcall(io.open, config_path, "r")
            if ok_fh and fh then
                local content = fh:read("*a")
                pcall(function() fh:close() end)
                
                local ok_cfg, cfg = pcall(hs.json.decode, content)
                if ok_cfg and type(cfg) == "table" and type(cfg.llm_disabled_apps) == "table" then
                    disabled = cfg.llm_disabled_apps
                end
            end
        end
        
        if not disabled then 
            disabled = hs.settings.get("llm_disabled_apps") 
        end
        
        if type(disabled) == "table" then
            local bid  = type(front.bundleID) == "function" and front:bundleID() or ""
            local path = type(front.path) == "function" and front:path() or ""
            
            for _, app in ipairs(disabled) do
                if type(app) == "table" then
                    if (app.bundleID and app.bundleID == bid) or (app.appPath and app.appPath == path) then
                        if type(on_fail) == "function" then pcall(on_fail) end
                        return
                    end
                end
            end
        end
    end

    num_predictions = math.max(1, math.floor(tonumber(num_predictions) or 1))

    local profile = M.get_active_profile()

    if type(profile) == "table" and (not profile.batch) and num_predictions > 1 then
        fetch_parallel(full_text, tail_text, model_name, temperature,
                       max_predict, num_predictions, profile, on_success, on_fail)
    else
        fetch_batch(full_text, tail_text, model_name, temperature,
                    max_predict, num_predictions, profile, on_success, on_fail)
    end
end

--- Utility to correctly match current keyboard modifiers from an event
--- @param eventFlags table The flags from event:getFlags()
--- @param targetMods table The configured modifiers array (e.g. {"alt"} or {"none"})
--- @return boolean True if it perfectly matches
function M.check_modifiers(eventFlags, targetMods)
    if type(targetMods) ~= "table" then return false end
    if #targetMods == 1 and targetMods[1] == "none" then return false end
    
    -- We create a strict map of target modifiers to evaluate ONLY these 4 keys
    -- This allows us to ignore the "fn" or "numericpad" flags often sent by macOS with arrow keys
    local target_map = { cmd = false, alt = false, shift = false, ctrl = false }
    for _, mod in ipairs(targetMods) do
        if target_map[mod] ~= nil then target_map[mod] = true end
    end
    
    -- We verify strictly that the event state matches the desired state for each modifier
    if (eventFlags.cmd or false)   ~= target_map.cmd   then return false end
    if (eventFlags.alt or false)   ~= target_map.alt   then return false end
    if (eventFlags.shift or false) ~= target_map.shift then return false end
    if (eventFlags.ctrl or false)  ~= target_map.ctrl  then return false end
    
    return true
end

return M
