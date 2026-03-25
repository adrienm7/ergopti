-- lib/text_utils.lua

-- ===========================================================================
-- Text Utilities Module.
--
-- Provides robust UTF-8 string manipulation, advanced surgical diffing
-- for AI text prediction, and complex case-conversion logic for hotstrings.
-- Designed to fail safely (using pcall and type checks) even with 
-- malformed strings or invalid byte sequences.
-- ===========================================================================

local M = {}





-- =======================================
-- =======================================
-- ======= 1/ UTF-8 Core Utilities =======
-- =======================================
-- =======================================

--- Safely splits a UTF-8 string into a table of individual characters
--- @param s string The input string
--- @return table An array of UTF-8 characters
function M.utf8_chars(s)
    local chars = {}
    if type(s) ~= "string" then return chars end
    
    -- Wrap in pcall because utf8.codes throws an error on invalid byte sequences
    pcall(function()
        for _, c in utf8.codes(s) do
            table.insert(chars, utf8.char(c))
        end
    end)
    
    return chars
end

--- Calculates the length of a common prefix between two UTF-8 strings
--- @param s1 string First string
--- @param s2 string Second string
--- @return number The length of the common prefix in characters
function M.get_common_prefix_utf8(s1, s2)
    if type(s1) ~= "string" or type(s2) ~= "string" then return 0 end
    
    -- Normalize apostrophes to typographic ones for accurate comparison
    local c1 = M.utf8_chars(s1:gsub("'", "’"))
    local c2 = M.utf8_chars(s2:gsub("'", "’"))
    
    local i = 1
    while i <= #c1 and i <= #c2 and c1[i] == c2[i] do
        i = i + 1
    end
    
    return i - 1
end

--- Safely extracts a substring using UTF-8 character indexing
--- @param s string The input string
--- @param i number The starting index (supports negative indexing)
--- @param j number|nil The ending index (supports negative indexing)
--- @return string The extracted substring
function M.utf8_sub(s, i, j)
    if type(s) ~= "string" then return "" end
    
    local chars = M.utf8_chars(s)
    local n = #chars
    
    local start_idx = tonumber(i) or 1
    local end_idx   = tonumber(j) or n
    
    -- Handle negative indices
    if start_idx < 0 then start_idx = n + start_idx + 1 end
    if end_idx < 0 then end_idx = n + end_idx + 1 end
    
    -- Clamp to bounds
    start_idx = math.max(1, math.min(start_idx, n))
    end_idx   = math.max(1, math.min(end_idx, n))
    
    if start_idx > end_idx then return "" end

    local res = {}
    for k = start_idx, end_idx do
        table.insert(res, chars[k])
    end
    
    return table.concat(res)
end

--- Safely measures the length of a UTF-8 string
--- @param s string The input string
--- @return number The length in characters (or bytes if malformed)
function M.utf8_len(s) 
    if type(s) ~= "string" then return 0 end
    
    -- utf8.len returns nil on invalid UTF-8 sequences, fallback to raw length
    local ok, len = pcall(utf8.len, s)
    return (ok and len) and len or #s 
end

--- Checks if a string ends with a specific UTF-8 suffix
--- @param s string The target string
--- @param suffix string The suffix to check for
--- @return boolean True if the string ends with the suffix
function M.utf8_ends_with(s, suffix)
    if type(s) ~= "string" or type(suffix) ~= "string" then return false end
    if s == "" or suffix == "" then return false end
    
    local n = M.utf8_len(suffix)
    local ok, start_idx = pcall(utf8.offset, s, -n)
    
    return (ok and start_idx) and (s:sub(start_idx) == suffix) or false
end

--- Checks if a string contains characters requiring more than 2 bytes
--- @param s string The input string
--- @return boolean True if high unicode characters are found (e.g. emojis)
function M.contains_high_unicode(s)
    if type(s) ~= "string" then return false end
    
    local found = false
    pcall(function()
        for _, c in utf8.codes(s) do
            if c > 0xFFFF then 
                found = true 
                break 
            end
        end
    end)
    
    return found
end





-- =======================================
-- =======================================
-- ======= 2/ Surgical Diff Engine =======
-- =======================================
-- =======================================

--- Computes a Wagner-Fischer edit distance diff to display UI text prediction overlays
--- @param old_str string The original user text
--- @param new_str string The predicted text
--- @return table An array of styled text chunks
function M.diff_strings(old_str, new_str)
    if type(old_str) ~= "string" or type(new_str) ~= "string" then return {} end

    -- Normalize apostrophes to typographic ones to avoid "fake" differences in the UI
    local t1 = M.utf8_chars(old_str:gsub("'", "’"))
    local t2 = M.utf8_chars(new_str:gsub("'", "’"))
    
    -- Find common prefix
    local p = 0
    while p < #t1 and p < #t2 and t1[p+1] == t2[p+1] do
        p = p + 1
    end
    
    local out = {}
    for i = 1, p do table.insert(out, {char=t1[i], color="grey"}) end
    
    -- If string 1 is fully contained in string 2
    if p == #t1 then
        for i = p + 1, #t2 do table.insert(out, {char=t2[i], color="orange"}) end
    else
        -- Extract remaining differing segments
        local rem_t1, rem_t2 = {}, {}
        for i = p + 1, #t1 do table.insert(rem_t1, t1[i]) end
        for i = p + 1, #t2 do table.insert(rem_t2, t2[i]) end
        local len1, len2 = #rem_t1, #rem_t2
        
        -- Wagner-Fischer matrix initialization
        local m = {}
        for i = 0, len1 do
            m[i] = {}
            for j = 0, len2 do
                if i == 0 then m[i][j] = j
                elseif j == 0 then m[i][j] = i
                else m[i][j] = 0 end
            end
        end

        -- Compute distances
        for i = 1, len1 do
            for j = 1, len2 do
                if rem_t1[i] == rem_t2[j] then
                    m[i][j] = m[i-1][j-1]
                else
                    m[i][j] = math.min(m[i-1][j-1], m[i-1][j], m[i][j-1]) + 1
                end
            end
        end

        -- Backtrack to find operations
        local i, j = len1, len2
        local rev_ops = {}
        while i > 0 or j > 0 do
            if i > 0 and j > 0 and rem_t1[i] == rem_t2[j] then
                table.insert(rev_ops, {type="eq", char=rem_t2[j]})
                i, j = i - 1, j - 1
            elseif i > 0 and j > 0 and m[i][j] == m[i-1][j-1] + 1 then
                table.insert(rev_ops, {type="sub", char=rem_t2[j]})
                i, j = i - 1, j - 1
            elseif j > 0 and (i == 0 or m[i][j] == m[i][j-1] + 1) then
                table.insert(rev_ops, {type="ins", char=rem_t2[j], is_tail=(i == len1)})
                j = j - 1
            elseif i > 0 and (j == 0 or m[i][j] == m[i-1][j] + 1) then
                table.insert(rev_ops, {type="del", char=rem_t1[i]})
                i = i - 1
            end
        end

        -- Apply colors based on operations
        for k = #rev_ops, 1, -1 do
            local op = rev_ops[k]
            if op.type == "eq" then
                table.insert(out, {char=op.char, color="grey"})
            elseif op.type == "sub" then
                table.insert(out, {char=op.char, color="green"})
            elseif op.type == "ins" then
                table.insert(out, {char=op.char, color=op.is_tail and "orange" or "green"})
            elseif op.type == "del" then
                -- Convert preceding grey characters to green if they are adjacent to a deletion
                if #out > 0 and out[#out].color == "grey" and not op.char:match("%s") then
                    out[#out].color = "green"
                end
            end
        end
    end

    -- UI Cleaning: Find the first differing character to trim irrelevant context
    local first_diff_idx = 0
    for idx, item in ipairs(out) do
        if item.color ~= "grey" then
            first_diff_idx = idx
            break
        end
    end

    if first_diff_idx > 0 then
        local start_idx = first_diff_idx
        -- Backtrack to the start of the current word to provide enough context
        while start_idx > 1 do
            if out[start_idx - 1].char:match("[%s'’]") then break end
            start_idx = start_idx - 1
        end
        
        local new_out = {}
        for idx = start_idx, #out do table.insert(new_out, out[idx]) end
        out = new_out
    else
        out = {} 
    end

    -- Compile contiguous characters of the same color into chunks
    local chunks, cur_color, cur_str = {}, nil, ""
    for _, item in ipairs(out) do
        if item.color ~= cur_color then
            if cur_color ~= nil then table.insert(chunks, {text=cur_str, color=cur_color}) end
            cur_color = item.color
            cur_str = item.char
        else
            cur_str = cur_str .. item.char
        end
    end
    
    if cur_str ~= "" then 
        table.insert(chunks, {text=cur_str, color=cur_color}) 
    end

    return chunks
end





-- =========================================
-- =========================================
-- ======= 3/ Case Mapping Constants =======
-- =========================================
-- =========================================

-- Capitalization logic restricted strictly to letters to avoid emoji/symbol conflicts.
M.UPPER_LETTERS = {
    ["à"]="À", ["â"]="Â", ["ä"]="Ä", ["é"]="É", ["è"]="È", ["ê"]="Ê", ["ë"]="Ë",
    ["î"]="Î", ["ï"]="Ï", ["ô"]="Ô", ["ö"]="Ö", ["ù"]="Ù", ["û"]="Û", ["ü"]="Ü",
    ["ç"]="Ç", ["œ"]="Œ", ["æ"]="Æ"
}

M.LOWER_LETTERS = {}
for k, v in pairs(M.UPPER_LETTERS) do M.LOWER_LETTERS[v] = k end

M.UPPER_TRIGGERS = {}
for k, v in pairs(M.UPPER_LETTERS) do M.UPPER_TRIGGERS[k] = v end

-- Ergopti-specific French punctuation layer triggers mappings
M.UPPER_TRIGGERS["'"] = " ?" 
M.UPPER_TRIGGERS[","] = {" :", " ;"} 
M.UPPER_TRIGGERS["."] = " :" 





-- ===========================================
-- ===========================================
-- ======= 4/ Case Conversion Routines =======
-- ===========================================
-- ===========================================

--- Checks if a character is considered a valid letter (handles French accents)
--- @param c string The character to test
--- @return boolean True if it’s a letter
function M.is_letter_char(c)
    if type(c) ~= "string" or c == "" then return false end
    if c:match("[%w]") then return true end
    if M.UPPER_LETTERS[c] or M.LOWER_LETTERS[c] then return true end
    return string.upper(c) ~= string.lower(c)
end

--- Safely converts a trigger string to lowercase
--- @param s string The string to convert
--- @return string The lowercase string
function M.trig_lower(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return M.LOWER_LETTERS[c] or string.lower(c)
    end))
end

--- Generates all possible uppercase variants of a trigger (handles multiple punctuation maps)
--- @param s string The string to convert
--- @return table An array of possible uppercase variants
function M.trig_upper(s)
    local results = {""}
    if type(s) ~= "string" then return results end
    
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local map_val = M.UPPER_TRIGGERS[c]
        local uppers = {}
        
        if type(map_val) == "table" then 
            uppers = map_val
        elseif type(map_val) == "string" then 
            table.insert(uppers, map_val)
        else 
            table.insert(uppers, string.upper(c)) 
        end
        
        local new_results = {}
        for _, res in ipairs(results) do
            for _, u in ipairs(uppers) do 
                table.insert(new_results, res .. u) 
            end
        end
        results = new_results
    end
    
    return results
end

--- Generates all possible Title Case variants of a trigger
--- @param s string The string to convert
--- @return table An array of possible Title Case variants
function M.trig_title(s)
    if type(s) ~= "string" then return {""} end
    
    local first = s:match("^[%z\1-\127\194-\244][\128-\191]*")
    if not first then return {s} end
    
    local first_uppers = M.trig_upper(first)
    local rest = M.trig_lower(s:sub(#first + 1))
    
    local results = {}
    for _, fu in ipairs(first_uppers) do 
        table.insert(results, fu .. rest) 
    end
    
    return results
end

--- Safely converts a replacement string to uppercase
--- @param s string The string to convert
--- @return string The uppercase string
function M.repl_upper(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return M.UPPER_LETTERS[c] or string.upper(c)
    end))
end

--- Safely converts a replacement string to Title Case
--- @param s string The string to convert
--- @return string The Title Case string
function M.repl_title(s)
    if type(s) ~= "string" then return "" end
    
    local first = s:match("^[%z\1-\127\194-\244][\128-\191]*")
    if not first then return s end
    
    return M.repl_upper(first) .. s:sub(#first + 1)
end

return M
