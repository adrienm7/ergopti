-- modules/llm.lua
local M = {}
local utils = require("lib.text_utils")

-- ==========================================
-- Default Configuration
-- ==========================================
M.DEFAULT_LLM_ENABLED         = false
M.DEFAULT_LLM_MODEL           = "llama3.1"
M.DEFAULT_LLM_DEBOUNCE        = 0.4
M.DEFAULT_LLM_NUM_PREDICTIONS = 3   -- 3 prédictions par défaut

local SYSTEM_PROMPT_SINGLE = [[You are a strict text autocorrection and completion engine.
CRITICAL RULES:
1. You receive a PREFIX (full context) and a TAIL (the last ~5-7 words).
2. Format: Two lines starting with "TAIL_CORRECTED:" and "NEXT_WORDS:".
3. TAIL_CORRECTED: Fix spelling, grammar, and accents ONLY in the current, incomplete sentence. Do NOT alter completed sentences, and NEVER change terminal punctuation (like periods) into commas. Do not change the meaning.
4. NEXT_WORDS: Predict 1 to 5 words to continue the thought. If the sentence is complete, leave it empty.
5. Code/Technical: If the context is code, maintain strict syntax.

EXAMPLES:

Example 1:
PREFIX: "Il est aller à Paris"
TAIL: "est aller à Paris"
TAIL_CORRECTED: est allé à Paris
NEXT_WORDS: 

Example 2:
PREFIX: "Je vous envoit ce mail pour vous dir"
TAIL: "envoit ce mail pour vous dir"
TAIL_CORRECTED: envoie ce mail pour vous dire
NEXT_WORDS: que tout est prêt.

Example 3:
PREFIX: "Salut, comment ça"
TAIL: "Salut, comment ça"
TAIL_CORRECTED: Salut, comment ça
NEXT_WORDS: va ?
]]

local SYSTEM_PROMPT_MULTI_TEMPLATE = [[You are a strict text autocorrection and completion engine.
You must produce exactly %d DIFFERENT predictions. Use this format, repeating the block %d times:

TAIL_CORRECTED: <corrected tail>
NEXT_WORDS: <1-5 next words, or empty if sentence is complete>
---
TAIL_CORRECTED: <different corrected tail or different continuation>
NEXT_WORDS: <different next words>
---
(etc.)

RULES:
- TAIL_CORRECTED: fix spelling/grammar/accents in the current incomplete sentence only. Do not change completed sentences or terminal punctuation.
- NEXT_WORDS: each prediction MUST offer a meaningfully different continuation. Do NOT repeat.
- Order from most likely to least likely.
- Separate each prediction block with a line containing only "---".
- Do NOT add any commentary, numbering, or extra text.

EXAMPLE (for N=3):
PREFIX: "Je vous envoit ce mail pour vous dir"
TAIL: "envoit ce mail pour vous dir"
TAIL_CORRECTED: envoie ce mail pour vous dire
NEXT_WORDS: que tout est prêt.
---
TAIL_CORRECTED: envoie ce mail pour vous dire
NEXT_WORDS: que la réunion est confirmée.
---
TAIL_CORRECTED: envoie ce courriel pour vous informer
NEXT_WORDS: de la situation actuelle.
---
]]

-- ==========================================
-- Availability Check
-- ==========================================

function M.check_availability(model_name, on_available, on_missing)
    hs.http.asyncGet("http://127.0.0.1:11434/api/tags", {}, function(status, body)
        if status ~= 200 then return on_missing(true) end
        local ok, tags = pcall(hs.json.decode, body)
        if ok and tags and tags.models then
            local found = false
            for _, m in ipairs(tags.models) do
                if m.name:find(model_name) then found = true; break end
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
-- Internal: process one raw TC/NW pair (Char-by-Char LCS Diff)
-- ==========================================

-- Utile pour contourner les espaces invisibles imposés par macOS
local function is_word_boundary(c)
    return c:match("%s") or c == "\194\160" or c == "\226\128\175"
end

local function chars_match(c1, c2)
    if c1 == c2 then return true end
    if is_word_boundary(c1) and is_word_boundary(c2) then return true end
    return false
end

local function process_prediction(tail_text, tc_raw, nw_raw)
    if not tc_raw or not nw_raw then return nil end

    local tc = tc_raw:gsub('^"', ""):gsub('"$', ""):gsub("^%s+", ""):gsub("%s+$", "")
    local nw = nw_raw:gsub("^%s+", ""):gsub("%s+$", "")

    if tc == "" and nw == "" then return nil end

    local tail_trailing_space = tail_text:match("(%s+)$")
    if tail_trailing_space and not tc:match("%s$") then
        tc = tc .. tail_trailing_space
    end

    local last_char  = utils.utf8_sub(tc, -1)
    local first_char = utils.utf8_sub(nw, 1, 1)
    local needs_space = not (
        last_char:match("[%s''%-]")
        or first_char:match("[%s.,;)%}%%%]]")
        or nw == ""
    )
    if needs_space then nw = " " .. nw end

    local tail_len = utils.utf8_len(tail_text)
    local tc_len   = utils.utf8_len(tc)
    if tc_len < tail_len * 0.7 then return nil end

    -- Toujours strict pour la suppression effective des caractères dans l'éditeur
    local common_len_calc = utils.get_common_prefix_utf8(tail_text, tc)
    local deletes    = tail_len - common_len_calc
    local to_type    = utils.utf8_sub(tc, common_len_calc + 1) .. nw

    -- Conversion en tableaux de caractères UTF-8
    local t1, t2 = {}, {}
    for c in tail_text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do table.insert(t1, c) end
    for c in tc:gmatch("[%z\1-\127\194-\244][\128-\191]*") do table.insert(t2, c) end

    -- Trouver la première différence en ignorant les différences d'espaces (classique vs insécable)
    local first_diff = 1
    while first_diff <= #t1 and first_diff <= #t2 and chars_match(t1[first_diff], t2[first_diff]) do
        first_diff = first_diff + 1
    end

    local has_corrections = (first_diff <= #t1)

    -- S'il n'y a eu absolument aucune faute dans la phrase tapée, 
    -- on renvoie les next_words et on n'affiche rien du tout de l'existant.
    if not has_corrections then
        local extra_tc = ""
        for i = #t1 + 1, #t2 do extra_tc = extra_tc .. t2[i] end
        
        return { deletes = deletes, to_type = to_type, nw = extra_tc .. nw, chunks = {},
                 tc = tc, tc_part = "", common_len = common_len_calc, has_corrections = false }
    end

    -- On remonte pour trouver le début EXCLUSIF du mot (le dernier espace avant la faute)
    local trim_idx = 1
    for i = math.min(first_diff, #t1), 1, -1 do
        if is_word_boundary(t1[i]) then
            trim_idx = i + 1
            break
        end
    end

    -- Troncation de tout le préfixe inutile ("Charles de Gaulle " disparaît ici)
    local t1_trunc, t2_trunc = {}, {}
    for i = trim_idx, #t1 do table.insert(t1_trunc, t1[i]) end
    for i = trim_idx, #t2 do table.insert(t2_trunc, t2[i]) end

    -- Algorithme LCS (Longest Common Subsequence) exact
    local dp = {}
    for i = 0, #t1_trunc do dp[i] = {[0] = 0} end
    for j = 0, #t2_trunc do dp[0][j] = 0 end

    for i = 1, #t1_trunc do
        for j = 1, #t2_trunc do
            if chars_match(t1_trunc[i], t2_trunc[j]) then
                dp[i][j] = dp[i-1][j-1] + 1
            else
                dp[i][j] = math.max(dp[i-1][j], dp[i][j-1])
            end
        end
    end

    -- Reconstruction arrière pour obtenir le script de diff optimal
    local i, j = #t1_trunc, #t2_trunc
    local diff = {}
    while i > 0 or j > 0 do
        if i > 0 and j > 0 and chars_match(t1_trunc[i], t2_trunc[j]) and dp[i][j] > dp[i][j-1] then
            table.insert(diff, 1, {type="equal", text=t2_trunc[j]})
            i, j = i - 1, j - 1
        elseif j > 0 and (i == 0 or dp[i][j-1] >= dp[i-1][j]) then
            table.insert(diff, 1, {type="insert", text=t2_trunc[j]})
            j = j - 1
        elseif i > 0 and (j == 0 or dp[i][j-1] < dp[i-1][j]) then
            i = i - 1
        end
    end

    -- Fusion des morceaux adjacents du même type pour l'interface UI
    local merged = {}
    for _, op in ipairs(diff) do
        if #merged > 0 and merged[#merged].type == op.type then
            merged[#merged].text = merged[#merged].text .. op.text
        else
            table.insert(merged, {type = op.type, text = op.text})
        end
    end

    -- Supprimer les chunks "equal" en tête qui forment des mots entiers non modifiés.
    -- Un mot entier = le chunk se termine par une espace (ou espace insécable).
    -- On garde les chunks partiels (ex: "étai" avant le "t" corrigé) pour le contexte,
    -- mais on vire "Gaulle " ou "Charles de Gaulle " qui n'ont pas changé.
    while #merged > 0 and merged[1].type == "equal" do
        local text = merged[1].text
        if text:match("[%s\194\160\226\128\175]$") then
            table.remove(merged, 1)
        else
            break
        end
    end

    -- Si le LLM a inséré tout un nouveau mot/bloc à la fin de la correction (vert), 
    -- on le bascule intelligemment dans Next Words (orange).
    local spilled_nw = ""
    if #merged > 0 and merged[#merged].type == "insert" then
        local text = merged[#merged].text
        local space_idx = text:find("[%s]")
        local nbsp_idx  = text:find("\194\160")
        local nnbsp_idx = text:find("\226\128\175")
        
        local min_idx = space_idx
        if nbsp_idx and (not min_idx or nbsp_idx < min_idx) then min_idx = nbsp_idx end
        if nnbsp_idx and (not min_idx or nnbsp_idx < min_idx) then min_idx = nnbsp_idx end

        if min_idx == 1 then
            spilled_nw = text
            table.remove(merged, #merged)
        elseif min_idx then
            merged[#merged].text = text:sub(1, min_idx - 1)
            spilled_nw = text:sub(min_idx)
        end
    end

    return { deletes = deletes, to_type = to_type, nw = spilled_nw .. nw, chunks = merged,
             tc = tc, tc_part = "", common_len = common_len_calc, has_corrections = has_corrections }
end

-- ==========================================
-- Internal: parse multi-block response
-- ==========================================

local function split_blocks(raw)
    local text = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    local blocks = {}
    local current = {}
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

local function parse_block(block)
    local tc = block:match("TAIL_CORRECTED:%s*([^\n]+)")
    local nw = block:match("NEXT_WORDS:%s*([^\n]*)")
    return tc, nw
end

-- ==========================================
-- Public: fetch_llm_prediction
-- ==========================================


function M.fetch_llm_prediction(
    full_text, tail_text,
    model_name, temperature, max_predict,
    num_predictions,
    on_success, on_fail
)
    -- Lire la liste d'exclusion depuis config.json (source de vérité du menu)
    local llm_disabled_apps = nil
    local config_path = (hs and hs.configdir and (hs.configdir .. "/config.json")) or nil
    if config_path then
        local fh = io.open(config_path, "r")
        if fh then
            local ok, cfg = pcall(function() return hs.json.decode(fh:read("*a")) end)
            fh:close()
            if ok and type(cfg) == "table" and type(cfg.llm_disabled_apps) == "table" then
                llm_disabled_apps = cfg.llm_disabled_apps
            end
        end
    end
    -- Fallback sur hs.settings si besoin
    if not llm_disabled_apps then
        llm_disabled_apps = hs.settings.get("llm_disabled_apps")
    end
    if type(llm_disabled_apps) == "table" then
        local front = hs.application.frontmostApplication()
        if front then
            local bid = front:bundleID() or ""
            local path = front:path() or ""
            for _, app in ipairs(llm_disabled_apps) do
                if (app.bundleID and app.bundleID == bid) or (app.appPath and app.appPath == path) then
                    if on_fail then on_fail() end
                    return
                end
            end
        end
    end

    num_predictions = math.max(1, math.floor(tonumber(num_predictions) or 1))

    local system_prompt
    if num_predictions == 1 then
        system_prompt = SYSTEM_PROMPT_SINGLE
    else
        system_prompt = string.format(SYSTEM_PROMPT_MULTI_TEMPLATE,
            num_predictions, num_predictions)
    end

    local effective_temperature = temperature
    if num_predictions > 1 then
        effective_temperature = math.max(temperature, 0.55)
    end

    local user_prompt = string.format('PREFIX: "%s"\nTAIL: "%s"', full_text, tail_text)
    local payload = {
        model    = model_name,
        messages = {
            { role = "system", content = system_prompt },
            { role = "user",   content = user_prompt  },
        },
        stream  = false,
        options = {
            temperature = effective_temperature,
            num_predict = max_predict * num_predictions + 20,
            stop        = { "\n\n\n\n" },
        },
    }

    hs.http.asyncPost(
        "http://127.0.0.1:11434/api/chat",
        hs.json.encode(payload),
        { ["Content-Type"] = "application/json" },
        function(status, body, _)
            if status ~= 200 then return on_fail() end

            local decode_ok, resp = pcall(hs.json.decode, body)
            if not decode_ok or not resp or not resp.message or not resp.message.content then
                return on_fail()
            end

            local raw     = resp.message.content
            local results = {}

            if num_predictions == 1 then
                local tc_raw = raw:match("TAIL_CORRECTED:%s*(.-)[\r\n]+")
                            or  raw:match("TAIL_CORRECTED:%s*(.-)$")
                local nw_raw = raw:match("NEXT_WORDS:%s?(.-)\n*$")
                local pred   = process_prediction(tail_text, tc_raw, nw_raw)
                if pred then table.insert(results, pred) end
            else
                local blocks = split_blocks(raw)
                for _, block in ipairs(blocks) do
                    if #results >= num_predictions then break end
                    local tc_raw, nw_raw = parse_block(block)
                    local pred = process_prediction(tail_text, tc_raw, nw_raw)
                    if pred then table.insert(results, pred) end
                end
                if #results == 0 then
                    local tc_raw = raw:match("TAIL_CORRECTED:%s*(.-)[\r\n]+")
                                or  raw:match("TAIL_CORRECTED:%s*(.-)$")
                    local nw_raw = raw:match("NEXT_WORDS:%s?(.-)\n*$")
                    local pred   = process_prediction(tail_text, tc_raw, nw_raw)
                    if pred then table.insert(results, pred) end
                end
            end

            if #results == 0 then return on_fail() end
            on_success(results)
        end
    )
end

return M
