-- ===========================================================================
-- modules/llm.lua
-- ===========================================================================

local M = {}
local utils = require("lib.text_utils")

-- ==========================================
-- Default Configuration
-- ==========================================
M.DEFAULT_LLM_ENABLED         = false
M.DEFAULT_LLM_MODEL           = "llama3.1"
M.DEFAULT_LLM_DEBOUNCE        = 0.5
M.DEFAULT_LLM_NUM_PREDICTIONS = 3
M.DEFAULT_LLM_SEQUENTIAL_MODE = false  -- kept for backward-compat

-- ==========================================
-- Built-in Prompt Profiles
-- ==========================================

local SIMPLE_PROMPT_SINGLE = [[Tu es un assistant de frappe au clavier.
Voici le texte que je suis en train de taper : {context}

Prédis UNIQUEMENT la suite directe (1 à 5 mots).
RÈGLES ABSOLUES :
- NE RÉPÈTE PAS le texte déjà écrit. Donne uniquement la suite.
- N'écris jamais de points de suspension (...).
- Ne fais aucun commentaire, pas de guillemets.]]

local function SIMPLE_PROMPT_BATCH(n)
    return [[Tu es un assistant de frappe au clavier.
Voici le texte que je suis en train de taper : {context}

Tu dois proposer EXACTEMENT ]] .. n .. [[ suites directes possibles (de 1 à 5 mots).
RÈGLES ABSOLUES :
- NE RÉPÈTE PAS le texte déjà écrit. Donne uniquement la suite.
- N'écris jamais de points de suspension (...).
- Sépare chaque proposition par une ligne "---".
Exemple :
suite une
---
suite deux
---
suite trois]]
end

local ADVANCED_PROMPT_SINGLE = [[Tu es un assistant strict d'autocomplétion. NE FAIS AUCUN COMMENTAIRE.
Voici le texte saisi jusqu'à présent : {context}

Réponds UNIQUEMENT sous ce format exact :
TAIL_CORRECTED: <réécris le dernier mot/fragment si mal orthographié, sinon recopie-le>
NEXT_WORDS: <suite prédite (1 à 5 mots), ou vide>

RÈGLE : NEXT_WORDS ne doit JAMAIS répéter le contexte, juste la suite. Ne mets pas de points de suspension.]]

local function ADVANCED_PROMPT_BATCH(n)
    return [[Tu es un assistant strict d'autocomplétion. NE FAIS AUCUN COMMENTAIRE.
Voici le texte saisi jusqu'à présent : {context}

Tu dois produire EXACTEMENT ]] .. n .. [[ continuations DIFFÉRENTES.
FORMAT STRICTEMENT REQUIS (répété ]] .. n .. [[ fois, séparé par une ligne "---"):
TAIL_CORRECTED: <réécris le dernier mot/fragment si mal orthographié, sinon recopie-le>
NEXT_WORDS: <suite prédite différente à chaque fois>
---

RÈGLE : NEXT_WORDS ne doit JAMAIS répéter le contexte, juste la suite. Ne mets pas de points de suspension (...).]]
end

-- NOUVEAU : Prompt pur pour les modèles de complétion (Base/Coder)
local BASE_PROMPT_SINGLE = [[{context}]]

M.BUILTIN_PROFILES = {
    {
        id          = "parallel_simple",
        label       = "Parallèle (Simple) — N req. de 1 prédiction",
        description = "Prédiction directe, très rapide, pour tous modèles",
        batch       = false,
        system_single = SIMPLE_PROMPT_SINGLE,
        system_multi  = nil,
    },
    {
        id          = "parallel_advanced",
        label       = "Parallèle (Avancé) — N req. de 1 prédiction",
        description = "Correction + Prédiction, modèles performants",
        batch       = false,
        system_single = ADVANCED_PROMPT_SINGLE,
        system_multi  = nil,
    },
    {
        id          = "base_completion",
        label       = "Complétion Pure (Base) — 1 prédiction",
        description = "Idéal pour modèles de complétion pure. Aucun prompt système.",
        batch       = false,
        system_single = BASE_PROMPT_SINGLE,
        system_multi  = nil,
    },
    {
        id          = "batch_simple",
        label       = "Batch (Simple) — 1 req. de N prédictions",
        description = "Plusieurs suggestions en 1 seul appel",
        batch       = true,
        system_single = SIMPLE_PROMPT_SINGLE,
        system_multi  = SIMPLE_PROMPT_BATCH,
    },
    {
        id          = "batch_advanced",
        label       = "Batch (Avancé) — 1 req. de N prédictions",
        description = "Correction + N suggestions en 1 appel",
        batch       = true,
        system_single = ADVANCED_PROMPT_SINGLE,
        system_multi  = ADVANCED_PROMPT_BATCH,
    },
}

-- Active profile id (can be overridden from menu)
M.active_profile_id = "parallel_simple"

-- User custom profiles (loaded from config.json by menu.lua)
M.user_profiles = {}

local function get_all_profiles()
    local all = {}
    for _, p in ipairs(M.BUILTIN_PROFILES) do table.insert(all, p) end
    for _, p in ipairs(M.user_profiles)    do table.insert(all, p) end
    return all
end

function M.get_active_profile()
    local id = M.active_profile_id
    -- Auto-migration depuis les anciens profils
    if id == "parallel" then id = "parallel_simple" end
    if id == "batch" then id = "batch_simple" end
    
    for _, p in ipairs(get_all_profiles()) do
        if p.id == id then return p end
    end
    return M.BUILTIN_PROFILES[1]  -- fallback: parallel_simple
end

function M.set_active_profile(id)
    M.active_profile_id = id
    local p = M.get_active_profile()
    M.DEFAULT_LLM_SEQUENTIAL_MODE = (p and not p.batch) or false
end

-- ==========================================
-- Small / Thinking model detection
-- ==========================================
local function is_small_model(name)
    name = (name or ""):lower()
    if name:match("0%.[0-9]+b") or name:match(":0%.[0-9]") or name:match("^0%.[0-9]") then return true end
    for _, tag in ipairs({"%-tiny",":tiny","%-mini",":mini","%-nano",":nano","%-small",":small"}) do
        if name:match(tag) then return true end
    end
    return false
end
M.is_small_model = is_small_model

local function is_thinking_model(name)
    name = (name or ""):lower()
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

-- ==========================================
-- Availability check
-- ==========================================
function M.check_availability(model_name, on_available, on_missing)
    hs.http.asyncGet("http://127.0.0.1:11434/api/tags", {}, function(status, body)
        if status ~= 200 then return on_missing(true) end
        local ok, tags = pcall(hs.json.decode, body)
        if ok and tags and tags.models then
            local found = false
            for _, m in ipairs(tags.models) do
                if m.name:find(model_name, 1, true) then found = true; break end
            end
            if found then
                if on_available then on_available() end
            else
                if on_missing then on_missing(false) end
            end
        else
            if on_missing then on_missing(false) end
        end
    end)
end

-- ==========================================
-- Internal: Hybrid Token/Char Diff Engine
-- ==========================================

local function chars_match(c1, c2)
    if c1 == c2 then return true end
    local function is_sp(c) return c == " " or c == "\194\160" or c == "\226\128\175" end
    return is_sp(c1) and is_sp(c2)
end

local function tokenize(text)
    local tokens, cur, is_w = {}, "", nil
    for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local w = c:match("[%w\128-\255]") ~= nil
        if is_w == nil then is_w = w; cur = c
        elseif is_w == w then cur = cur .. c
        else table.insert(tokens, cur); is_w = w; cur = c end
    end
    if cur ~= "" then table.insert(tokens, cur) end
    return tokens
end

local function char_diff(t1_str, t2_str)
    local t1, t2 = {}, {}
    for c in t1_str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do table.insert(t1, c) end
    for c in t2_str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do table.insert(t2, c) end

    local dp = {}
    for i = 0, #t1 do dp[i] = {[0]=0} end
    for j = 0, #t2 do dp[0][j] = 0 end
    for i = 1, #t1 do for j = 1, #t2 do
        dp[i][j] = chars_match(t1[i], t2[j]) and dp[i-1][j-1]+1
                    or math.max(dp[i-1][j], dp[i][j-1])
    end end

    local diffs, i, j = {}, #t1, #t2
    while i > 0 or j > 0 do
        if i > 0 and j > 0 and chars_match(t1[i], t2[j]) then
            table.insert(diffs, 1, {type="equal",  text=t2[j]}); i,j = i-1, j-1
        elseif j > 0 and (i==0 or dp[i][j-1] >= dp[i-1][j]) then
            table.insert(diffs, 1, {type="insert", text=t2[j]}); j = j-1
        else
            i = i-1
        end
    end

    local merged = {}
    for _, d in ipairs(diffs) do
        if #merged > 0 and merged[#merged].type == d.type then
            merged[#merged].text = merged[#merged].text .. d.text
        else table.insert(merged, {type=d.type, text=d.text}) end
    end

    local max_len = math.max(#t1, #t2)
    return merged, max_len > 0 and (dp[#t1][#t2] / max_len) or 0
end

local function process_prediction(full_context, tail_text, tc_raw, nw_raw)
    if not tc_raw or not nw_raw then return nil end

    local tc = tc_raw:gsub('^"',''):gsub('"$',''):gsub("^%s+",""):gsub("%s+$",""):gsub("%s+"," ")
    local nw = nw_raw:gsub("^%s+",""):gsub("%s+$",""):gsub("%s+"," ")

    -- Suppression du chevauchement (overlap) pour éviter les répétitions 
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
    for i = 1, #tok1 do for j = 1, #tok2 do
        dp[i][j] = chars_match(tok1[i], tok2[j]) and dp[i-1][j-1]+1
                    or math.max(dp[i-1][j], dp[i][j-1])
    end end

    local diffs, i, j = {}, #tok1, #tok2
    while i > 0 or j > 0 do
        if i > 0 and j > 0 and chars_match(tok1[i], tok2[j]) then
            table.insert(diffs, 1, {type="equal",  text=tok2[j]}); i,j = i-1, j-1
        elseif j > 0 and (i==0 or dp[i][j-1] >= dp[i-1][j]) then
            table.insert(diffs, 1, {type="insert", text=tok2[j]}); j = j-1
        else
            table.insert(diffs, 1, {type="delete", text=tok1[i]}); i = i-1
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
        elseif d.type == "delete" then cur_del = cur_del .. d.text
        elseif d.type == "insert" then cur_ins = cur_ins .. d.text
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
        else table.insert(merged, {type=ch.type, text=ch.text}) end
    end

    while #merged > 0 do
        if merged[1].type == "equal" then table.remove(merged, 1)
        elseif merged[1].type == "insert" and merged[1].text:match("^[%s\194\160\226\128\175]+$") then
            table.remove(merged, 1)
        else break end
    end

    if #merged > 0 and merged[#merged].type == "insert" then
        local text = merged[#merged].text
        local sp   = text:find("[%s\194\160\226\128\175]")
        if sp == 1 then
            spilled_nw = text; table.remove(merged, #merged)
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

-- ==========================================
-- Robust parsing (case-insensitive, variants)
-- ==========================================

local function clean_model_output(text)
    if not text then return "" end
    text = text:gsub("%*%*", "")
    text = text:gsub("`", "")
    return text
end

local function extract_tc(text, default_tail)
    text = clean_model_output(text)
    local tc = text:match("[Tt][Aa][Ii][Ll][_%s]?[Cc][Oo][Rr][Rr][Ee][Cc][Tt][Ee][Dd]%s*:%s*([^\n\r]+)")
        or text:match("[Cc][Oo][Rr][Rr][Ee][Cc][Tt][Ee][Dd]%s*:%s*([^\n\r]+)")
        or text:match("[Tt][Aa][Ii][Ll]%s*:%s*([^\n\r]+)")
        or text:match("TAIL_CORRIG.E%s*:%s*([^\n\r]+)")
        or text:match("[Ll][Ii][Nn][Ee]%s*1%s*:%s*([^\n\r]+)")
        or text:match("[Ll]1%s*:%s*([^\n\r]+)")
    
    if tc then return tc end
    
    -- Fallback sur le tail d'origine (mode simple / mode base)
    return default_tail or ""
end

local function extract_nw(text)
    text = clean_model_output(text)
    local nw = text:match("[Nn][Ee][Xx][Tt][_%s]?[Ww][Oo][Rr][Dd][Ss]%s*:%s*([^\n\r]*)")
        or text:match("[Nn][Ee][Xx][Tt]%s*:%s*([^\n\r]*)")
        or text:match("[Cc][Oo][Nn][Tt][Ii][Nn][Uu][Aa][Tt][Ii][Oo][Nn]%s*:%s*([^\n\r]*)")
        or text:match("MOTS_SUIVANTS%s*:%s*([^\n\r]*)")
        or text:match("[Ll][Ii][Nn][Ee]%s*2%s*:%s*([^\n\r]*)")
        or text:match("[Ll]2%s*:%s*([^\n\r]*)")
    
    if nw then 
        -- Nettoyage des points de suspension intempestifs
        nw = nw:gsub("^%.%.%.%s*", ""):gsub("%s*%.%.%.$", "")
        return nw == "..." and "" or nw
    end
    
    -- Fallback si le format n'est pas "Avancé". 
    if not text:match("TAIL_CORRECTED") and not text:match("TAIL_CORRIG") then
        local raw_nw = text:gsub("^%s+", ""):gsub("%s+$", "")
        raw_nw = raw_nw:gsub("^%.%.%.%s*", ""):gsub("%s*%.%.%.$", "")
        if raw_nw == "..." then return "" end
        return raw_nw
    end
    return ""
end

local function split_blocks(raw)
    local text   = raw:gsub("\r\n","\n"):gsub("\r","\n")
    local blocks, current = {}, {}
    for line in (text.."\n---\n"):gmatch("([^\n]*)\n") do
        if line:match("^%s*%-%-%-+%s*$") then
            if #current > 0 then table.insert(blocks, table.concat(current,"\n")); current = {} end
        else table.insert(current, line) end
    end
    return blocks
end

local function strip_thinking(text)
    if not text then return text end
    text = text:gsub("<think>.-</think>%s*", "")
    text = text:gsub("</think>%s*", "")
    return text
end

-- ==========================================
-- Build Ollama payload options
-- ==========================================

local function build_options(temperature, num_predict_tokens, model_name)
    local opts = {
        temperature = temperature,
        num_predict = num_predict_tokens,
        stop        = { "\n\n\n\n" },
    }
    if is_thinking_model(model_name) then
        opts.think           = false
        opts.thinking_budget = 0
        -- On ne bride pas les modèles thinking pour qu'ils aient le temps de formuler leur pensée.
        opts.num_predict = math.max(num_predict_tokens, 400)
    end
    return opts
end

-- ==========================================
-- Core: single POST → list of predictions
-- ==========================================

local function resolve_system_prompt(profile, n, model_name)
    if profile.raw_prompt then
        return profile.raw_prompt
    end
    if n == 1 then
        if profile.system_single then return profile.system_single end
    else
        if type(profile.system_multi) == "function" then return profile.system_multi(n) end
        if type(profile.system_multi) == "string"   then return profile.system_multi   end
    end
    return n == 1 and SIMPLE_PROMPT_SINGLE or SIMPLE_PROMPT_BATCH(n)
end

local function post_and_parse(model_name, system_prompt, full_text, tail_text,
                               temperature, num_predict_tokens, num_predictions,
                               on_success, on_fail)
    local context_str = (full_text or "") .. (tail_text or "")
    local messages = {}

    -- Vérification si c'est un prompt qui inclut directement le contexte
    if system_prompt:find("{context}", 1, true) then
        local final_prompt = system_prompt:gsub("%{context%}", function() return context_str end)
        table.insert(messages, { role="user", content=final_prompt })
    else
        table.insert(messages, { role="system", content=system_prompt })
        table.insert(messages, { role="user", content=context_str })
    end

    local payload = {
        model    = model_name,
        messages = messages,
        stream   = false,
        options  = build_options(temperature, num_predict_tokens, model_name),
    }

    hs.http.asyncPost(
        "http://127.0.0.1:11434/api/chat",
        hs.json.encode(payload),
        { ["Content-Type"] = "application/json" },
        function(status, body, _)
            if status ~= 200 then return on_fail() end
            local ok, resp = pcall(hs.json.decode, body)
            if not ok or not resp or not resp.message or not resp.message.content then
                return on_fail()
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
                if #results == 0 then
                    local pred = process_prediction(context_str, tail_text, extract_tc(raw, tail_text), extract_nw(raw))
                    if pred then table.insert(results, pred) end
                end
            end

            if #results == 0 then return on_fail() end
            on_success(results)
        end
    )
end

-- ==========================================
-- Strategy: batch (one request, N predictions)
-- ==========================================

local function fetch_batch(full_text, tail_text, model_name, temperature,
                             max_predict, num_predictions, profile,
                             on_success, on_fail)
    local effective_temp = temperature
    local system_prompt  = resolve_system_prompt(profile, num_predictions, model_name)
    local tokens         = max_predict * num_predictions + 20

    local t0 = hs.timer.secondsSinceEpoch()
    post_and_parse(model_name, system_prompt, full_text, tail_text,
                   effective_temp, tokens, num_predictions,
                   function(results)
                       local ms = math.floor((hs.timer.secondsSinceEpoch()-t0)*1000)
                       on_success(results, ms)
                   end,
                   on_fail)
end

-- ==========================================
-- Strategy: parallel (N simultaneous requests)
-- ==========================================

local function fetch_parallel(full_text, tail_text, model_name, temperature,
                                max_predict, num_predictions, profile,
                                on_success, on_fail)
    local system_prompt = resolve_system_prompt(profile, 1, model_name)
    local t0            = hs.timer.secondsSinceEpoch()
    local results       = {}
    local done_count    = 0
    local finished      = false

    local function finish()
        if finished then return end
        finished = true
        if #results == 0 then return on_fail() end
        local ms = math.floor((hs.timer.secondsSinceEpoch()-t0)*1000)
        on_success(results, ms)
    end

    local temp_steps = {}
    for i = 1, num_predictions do
        temp_steps[i] = (i == 1) and temperature
                        or math.min(1.0, temperature + (i-1)*0.15)
    end

    for i = 1, num_predictions do
        post_and_parse(model_name, system_prompt, full_text, tail_text,
                       temp_steps[i], max_predict+10, 1,
                       function(preds)
                           if finished then return end
                           if preds[1] then
                               local dup = false
                               for _, ex in ipairs(results) do
                                   if ex.to_type == preds[1].to_type then dup=true; break end
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

-- ==========================================
-- Public entry point
-- ==========================================

function M.fetch_llm_prediction(full_text, tail_text, model_name, temperature,
                                  max_predict, num_predictions,
                                  on_success, on_fail,
                                  _legacy_sequential_mode)

    local front = hs.application.frontmostApplication()
    if front then
        local config_path = hs.configdir and (hs.configdir .. "/config.json")
        local disabled = nil
        if config_path then
            local fh = io.open(config_path, "r")
            if fh then
                local ok, cfg = pcall(function() return hs.json.decode(fh:read("*a")) end)
                fh:close()
                if ok and type(cfg) == "table" and type(cfg.llm_disabled_apps) == "table" then
                    disabled = cfg.llm_disabled_apps
                end
            end
        end
        if not disabled then disabled = hs.settings.get("llm_disabled_apps") end
        if type(disabled) == "table" then
            local bid, path = front:bundleID() or "", front:path() or ""
            for _, app in ipairs(disabled) do
                if (app.bundleID and app.bundleID == bid)
                or (app.appPath  and app.appPath  == path) then
                    if on_fail then on_fail() end; return
                end
            end
        end
    end

    num_predictions = math.max(1, math.floor(tonumber(num_predictions) or 1))

    local profile = M.get_active_profile()

    if (not profile.batch) and num_predictions > 1 then
        fetch_parallel(full_text, tail_text, model_name, temperature,
                       max_predict, num_predictions, profile, on_success, on_fail)
    else
        fetch_batch(full_text, tail_text, model_name, temperature,
                    max_predict, num_predictions, profile, on_success, on_fail)
    end
end

return M
