-- modules/llm.lua
local M = {}
local utils = require("lib.text_utils")

-- ==========================================
-- Default Configuration
-- ==========================================
M.DEFAULT_LLM_ENABLED = false
M.DEFAULT_LLM_MODEL = "llama3.1"
M.DEFAULT_LLM_DEBOUNCE = 0.4

-- The system prompt defines the strict behavior for the AI engine
local SYSTEM_PROMPT = [[You are a strict text autocorrection and completion engine.
CRITICAL RULES:
1. You receive a PREFIX (full context) and a TAIL (the last ~5-7 words).
2. Format: Two lines starting with "TAIL_CORRECTED:" and "NEXT_WORDS:".
3. TAIL_CORRECTED: Fix spelling, grammar, and accents in the TAIL. Do not change the meaning.
4. NEXT_WORDS: Predict 1 to 5 words to continue the thought. If the sentence is complete, leave it empty.
5. Code/Technical: If the context is code, maintain strict syntax.

EXAMPLES:

Example 1 (Grammar Correction Only):
PREFIX: "Il est aller à Paris"
TAIL: "est aller à Paris"
TAIL_CORRECTED: est allé à Paris
NEXT_WORDS: 

Example 2 (Correction + Prediction):
PREFIX: "Je vous envoit ce mail pour vous dir"
TAIL: "envoit ce mail pour vous dir"
TAIL_CORRECTED: envoie ce mail pour vous dire
NEXT_WORDS: que tout est prêt.

Example 3 (No Correction + Short Prediction):
PREFIX: "Salut, comment ça"
TAIL: "Salut, comment ça"
TAIL_CORRECTED: Salut, comment ça
NEXT_WORDS: va ?

Example 4 (No Correction + Long Prediction):
PREFIX: "Je pense qu'il est important de"
TAIL: "qu'il est important de"
TAIL_CORRECTED: qu'il est important de
NEXT_WORDS: prendre une décision rapidement.

Example 5 (Programming - Python):
PREFIX: "def calculate_total(price, tax):"
TAIL: "def calculate_total(price, tax):"
TAIL_CORRECTED: def calculate_total(price, tax):
NEXT_WORDS: return price * (1 + tax)

Example 6 (Messaging/Informal):
PREFIX: "On se voit a quelle heur"
TAIL: "voit a quelle heur"
TAIL_CORRECTED: voit à quelle heure
NEXT_WORDS: demain ?
]]

-- ==========================================
-- Availability Check (Startup / Reload)
-- ==========================================

function M.check_availability(model_name, on_available, on_missing)
    hs.http.asyncGet("http://127.0.0.1:11434/api/tags", {}, function(status, body)
        if status ~= 200 then
            return on_missing(true)
        end

        local ok, tags = pcall(hs.json.decode, body)
        if ok and tags and tags.models then
            local found = false
            for _, m in ipairs(tags.models) do
                if m.name:find(model_name) then
                    found = true
                    break
                end
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
-- LLM Prediction Logic
-- ==========================================

function M.fetch_llm_prediction(full_text, tail_text, model_name, on_success, on_fail)
    local user_prompt = string.format('PREFIX: "%s"\nTAIL: "%s"', full_text, tail_text)
    local payload = {
        model = model_name,
        messages = {
            { role = "system", content = SYSTEM_PROMPT },
            { role = "user", content = user_prompt }
        },
        stream = false,
        options = { 
            temperature = 0.1, 
            num_predict = 40, 
            stop = {"\n\n", "PREFIX:", "TAIL:"} 
        }
    }

    hs.http.asyncPost("http://127.0.0.1:11434/api/chat", hs.json.encode(payload), {["Content-Type"]="application/json"}, function(status, body, _)
        if status ~= 200 then 
            return on_fail() 
        end

        local decode_ok, resp = pcall(hs.json.decode, body)
        if not decode_ok or not resp or not resp.message or not resp.message.content then
            return on_fail()
        end

        local raw_pred = resp.message.content
        local tc = raw_pred:match("TAIL_CORRECTED:%s*(.-)[\r\n]+") or raw_pred:match("TAIL_CORRECTED:%s*(.-)$")
        local nw = raw_pred:match("NEXT_WORDS:%s?(.-)$") 
        
        if not tc or not nw then return on_fail() end
        
        -- Sanitize outputs: trim and normalize smart quotes
        tc = tc:gsub('^"', ""):gsub('"$', ""):match("^%s*(.-)%s*$"):gsub("'", "’")
        nw = nw:match("^(.-)%s*$"):gsub("'", "’")
        
        if tc == "" and nw == "" then return on_fail() end

        -- Normalize tail_text apostrophes for a fair comparison with tc
        local normalized_tail = tail_text:gsub("'", "’")
        local tail_trailing_space = tail_text:match("(%s+)$")
        if tail_trailing_space and not tc:match("%s$") then
            tc = tc .. tail_trailing_space
        end

        local last_char = utils.utf8_sub(tc, -1)
        local first_char = utils.utf8_sub(nw, 1, 1)
        local needs_space = not (last_char:match("[%s'’%-]") or first_char:match("[%s.,;)%}%%%]]") or nw == "")
        if needs_space then nw = " " .. nw end

        local tail_len = utils.utf8_len(tail_text)
        local tc_len = utils.utf8_len(tc)
        if tc_len < tail_len * 0.7 then return on_fail() end

        -- Use normalized_tail to calculate common length and deletes
        local common_len = utils.get_common_prefix_utf8(normalized_tail, tc)
        local deletes = tail_len - common_len
        local to_type = utils.utf8_sub(tc, common_len + 1) .. nw

        -- Pass normalized_tail to avoid highlights on identical apostrophes
        local chunks = utils.diff_strings(normalized_tail, tc)
        on_success(deletes, to_type, nw, chunks)
    end)
end

return M
