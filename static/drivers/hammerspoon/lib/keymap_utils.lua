-- lib/keymap_utils.lua

-- ===========================================================================
-- Keymap Utilities Module.
--
-- Provides helper functions for the main keymap engine, offloading
-- complex logic such as text emission (simulated keystrokes vs clipboard paste),
-- token parsing, LLM prediction overlap resolution, and ignored window detection.
-- ===========================================================================

local M = {}

local text_utils = require("lib.text_utils")
local eventtap   = hs.eventtap
local keyStrokes = hs.eventtap.keyStrokes
local keyStroke  = hs.eventtap.keyStroke





-- =======================================
-- =======================================
-- ======= 1/ Constants & Settings =======
-- =======================================
-- =======================================

local PASTE_THRESHOLD = 30

local KEY_COMMANDS = {
    Left = "left", Right = "right", Up = "up", Down = "down",
    Home = "home", End = "end",
    Delete = "forwarddelete", Del = "forwarddelete",
    Backspace = "delete", BackSpace = "delete", BS = "delete",
    Tab = "tab", Enter = "return", Return = "return",
    Escape = "escape", Esc = "escape",
}





-- ==========================================
-- ==========================================
-- ======= 2/ Text Emission Utilities =======
-- ==========================================
-- ==========================================

--- Determines whether a string should be pasted via clipboard rather than typed
--- @param text string The text to evaluate
--- @return boolean True if the text is long or contains complex unicode
function M.should_paste(text)
    if type(text) ~= "string" then return false end
    if text_utils.utf8_len(text) > PASTE_THRESHOLD then return true end
    return text_utils.contains_high_unicode(text)
end

--- Internal helper to extract plain text and newlines into actionable tokens
--- @param tokens table The target table
--- @param text string The string to parse
local function push_text_tokens(tokens, text)
    if type(text) ~= "string" or type(tokens) ~= "table" then return end
    
    local first = true
    for segment in (text .. "\n"):gmatch("([^\n]*)\n") do
        if not first then table.insert(tokens, { kind = "key", value = "return" }) end
        if segment ~= "" then table.insert(tokens, { kind = "text", value = segment }) end
        first = false
    end
end

--- Parses a replacement string into keystrokes and plain text segments
--- @param repl string The raw replacement string (e.g. "Hello {Enter} World")
--- @return table A list of parsed tokens
function M.tokens_from_repl(repl)
    local tokens = {}
    if type(repl) ~= "string" then return tokens end
    
    local i = 1
    while i <= #repl do
        local s, e, name = repl:find("{(%w+)}", i)
        if s then
            if s > i then push_text_tokens(tokens, repl:sub(i, s - 1)) end
            local title  = name:sub(1,1):upper() .. name:sub(2):lower()
            local hs_key = KEY_COMMANDS[name] or KEY_COMMANDS[title]
            if hs_key then
                table.insert(tokens, { kind = "key", value = hs_key })
            else
                table.insert(tokens, { kind = "text", value = "{" .. name .. "}" })
            end
            i = e + 1
        else
            push_text_tokens(tokens, repl:sub(i))
            break
        end
    end
    
    return tokens
end

--- Emits a sequence of parsed tokens (typing or pasting as necessary)
--- @param tokens table The tokens to emit
--- @return number, string The total characters emitted and the raw string representation
function M.emit_tokens(tokens)
    local count = 0
    local emitted_str = ""
    if type(tokens) ~= "table" then return count, emitted_str end

    for _, tok in ipairs(tokens) do
        if type(tok) == "table" then
            if tok.kind == "key" then
                keyStroke({}, tok.value, 0)
                count = count + 1
            elseif M.should_paste(tok.value) then
                local prev = hs.pasteboard.getContents()
                hs.pasteboard.setContents(tok.value)
                keyStroke({ "cmd" }, "v", 0)
                count = count + 1
                
                -- Restore user clipboard safely
                hs.timer.doAfter(0.5, function() 
                    pcall(function() hs.pasteboard.setContents(prev or "") end)
                end)
            else
                keyStrokes(tok.value)
                count = count + text_utils.utf8_len(tok.value)
                emitted_str = emitted_str .. tok.value
            end
        end
    end
    
    return count, emitted_str
end

--- Emits a raw string (typing or pasting as necessary)
--- @param text string The text to emit
--- @return number, string The total characters emitted and the string itself
function M.emit_text(text)
    if type(text) ~= "string" then return 0, "" end
    
    if M.should_paste(text) then
        local prev = hs.pasteboard.getContents()
        hs.pasteboard.setContents(text)
        keyStroke({ "cmd" }, "v", 0)
        
        -- Restore user clipboard safely
        hs.timer.doAfter(0.5, function() 
            pcall(function() hs.pasteboard.setContents(prev or "") end)
        end)
        
        return 1, ""
    end
    
    keyStrokes(text)
    return text_utils.utf8_len(text), text
end

--- Reconstructs the plain string representation of a token list
--- @param tokens table The token list
--- @return string The combined plain text
function M.plain_text(tokens)
    local parts = {}
    if type(tokens) == "table" then
        for _, tok in ipairs(tokens) do
            if type(tok) == "table" and tok.kind == "text" and type(tok.value) == "string" then 
                table.insert(parts, tok.value) 
            end
        end
    end
    return table.concat(parts)
end





-- ================================================
-- ================================================
-- ======= 3/ LLM Prediction Overlap Solver =======
-- ================================================
-- ================================================

--- Calculates the optimal deletion count and text to type to seamlessly insert an LLM prediction
--- @param buffer string The current typing buffer
--- @param pred_deletes number The AI’s suggested deletion count
--- @param pred_to_type string The AI’s suggested string to append
--- @return number, string The corrected deletion count and the safe string to append
function M.resolve_prediction_overlap(buffer, pred_deletes, pred_to_type)
    local deletes = tonumber(pred_deletes) or 0
    local to_type = type(pred_to_type) == "string" and pred_to_type or ""
    local buf_str = type(buffer) == "string" and buffer or ""

    if to_type ~= "" then
        -- Clean up zero-width spaces that might pollute the internal buffer
        local cb = buf_str:gsub("​", "") 
        local words = {}
        for w in cb:gmatch("%S+%s*") do table.insert(words, w) end
        
        local tt_first_word = to_type:match("^%s*([^%s]+)")
        if tt_first_word then
            local function words_are_similar(w1, w2)
                w1 = w1:lower():gsub("[%s%p]+", "")
                w2 = w2:lower():gsub("[%s%p]+", "")
                if w1 == w2 then return true end
                if #w1 < 3 or #w2 < 3 then return false end
                
                -- Check for identical start and similar length
                if w1:sub(1,1) == w2:sub(1,1) and math.abs(#w1 - #w2) <= 2 then
                    local matches = 0
                    for i = 1, math.min(#w1, #w2) do
                        if w1:sub(i,i) == w2:sub(i,i) then matches = matches + 1 end
                    end
                    if matches >= math.min(#w1, #w2) - 2 then return true end
                end
                
                -- Check for inclusion mapping
                if #w1 >= 3 and (w2:find(w1, 1, true) or w1:find(w2, 1, true)) then return true end
                
                return false
            end

            -- Compare tail end of the user’s buffer against the start of the prediction
            local tail_start = math.max(1, #words - 6)
            for i = tail_start, #words do
                if words_are_similar(words[i], tt_first_word) then
                    local del_count = 0
                    for j = i, #words do
                        del_count = del_count + text_utils.utf8_len(words[j])
                    end
                    if deletes < del_count then deletes = del_count end
                    break
                end
            end
        end
    end

    -- Fix spacing/punctuation logic if no deletions were triggered
    if deletes == 0 and to_type ~= "" then
        local clean_buf = buf_str:gsub("​", "")
        if clean_buf ~= "" then
            local ends_with_space   = clean_buf:match("%s$") or clean_buf:match("\194\160$") or clean_buf:match("\226\128\175$")
            local starts_with_space = to_type:match("^%s") or to_type:match("^\194\160") or to_type:match("^\226\128\175")
            local starts_with_punct = to_type:match("^[.,;:%?!'\"%)%]]")
            
            if not ends_with_space and not starts_with_space and not starts_with_punct then
                to_type = " " .. to_type
            end
        end
    end

    return deletes, to_type
end





-- =================================
-- =================================
-- ======= 4/ Window Ignorer =======
-- =================================
-- =================================

local _ignored_win_cache_time  = 0
local _ignored_win_cache_value = false

--- Determines if the currently active window should be ignored based on titles or regex patterns
--- @param ignored_titles table A hash map of exact window titles to ignore
--- @param ignored_patterns table A list of regex patterns matching window titles to ignore
--- @return boolean True if the window is ignored, false otherwise
function M.is_ignored_window(ignored_titles, ignored_patterns)
    local now = hs.timer.secondsSinceEpoch()
    -- Cache evaluation for half a second to prevent heavy OS querying
    if now - _ignored_win_cache_time < 0.5 then return _ignored_win_cache_value end
    _ignored_win_cache_time = now
    
    _ignored_win_cache_value = false
    
    local app = hs.application.frontmostApplication()
    if not app then return false end

    local ok, win = pcall(function() return app:focusedWindow() end)
    if not ok or not win then return false end

    local ok_title, title = pcall(function() return win:title() end)
    if not ok_title or type(title) ~= "string" then return false end

    -- Check exact titles
    if type(ignored_titles) == "table" and ignored_titles[title] then
        _ignored_win_cache_value = true
        return true
    end

    -- Check regex patterns
    if type(ignored_patterns) == "table" then
        for _, pat in ipairs(ignored_patterns) do
            if type(pat) == "string" and title:match(pat) then
                _ignored_win_cache_value = true
                return true
            end
        end
    end

    return false
end

return M
