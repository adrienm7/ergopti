-- lib/text_utils.lua
local M = {}

-- UTF-8 Helpers
function M.utf8_chars(s)
    local chars = {}
    if not s then return chars end
    for p, c in utf8.codes(s) do
        table.insert(chars, utf8.char(c))
    end
    return chars
end

function M.get_common_prefix_utf8(s1, s2)
    -- Normalize for comparison
    local c1 = M.utf8_chars(s1:gsub("'", "’"))
    local c2 = M.utf8_chars(s2:gsub("'", "’"))
    local i = 1
    while i <= #c1 and i <= #c2 and c1[i] == c2[i] do
        i = i + 1
    end
    return i - 1
end

function M.utf8_sub(s, i, j)
    local chars = M.utf8_chars(s)
    j = j or #chars
    if i < 0 then i = #chars + i + 1 end
    if j < 0 then j = #chars + j + 1 end
    local res = {}
    for k = i, j do
        if chars[k] then table.insert(res, chars[k]) end
    end
    return table.concat(res)
end

function M.utf8_len(s) 
    return utf8.len(s) or #s 
end

-- Improved Surgical Diff Algorithm
function M.diff_strings(old_str, new_str)
    -- Normalize apostrophes to typographic ones to avoid "fake" diffs
    local t1 = M.utf8_chars(old_str:gsub("'", "’"))
    local t2 = M.utf8_chars(new_str:gsub("'", "’"))
    
    local p = 0
    while p < #t1 and p < #t2 and t1[p+1] == t2[p+1] do
        p = p + 1
    end
    
    local out = {}
    for i = 1, p do table.insert(out, {char=t1[i], color="grey"}) end
    
    if p == #t1 then
        for i = p + 1, #t2 do table.insert(out, {char=t2[i], color="orange"}) end
    else
        local rem_t1, rem_t2 = {}, {}
        for i=p+1, #t1 do table.insert(rem_t1, t1[i]) end
        for i=p+1, #t2 do table.insert(rem_t2, t2[i]) end
        local len1, len2 = #rem_t1, #rem_t2
        
        local m = {}
        for i = 0, len1 do
            m[i] = {}
            for j = 0, len2 do
                if i == 0 then m[i][j] = j
                elseif j == 0 then m[i][j] = i
                else m[i][j] = 0 end
            end
        end

        for i = 1, len1 do
            for j = 1, len2 do
                if rem_t1[i] == rem_t2[j] then
                    m[i][j] = m[i-1][j-1]
                else
                    m[i][j] = math.min(m[i-1][j-1], m[i-1][j], m[i][j-1]) + 1
                end
            end
        end

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

        for k = #rev_ops, 1, -1 do
            local op = rev_ops[k]
            if op.type == "eq" then
                table.insert(out, {char=op.char, color="grey"})
            elseif op.type == "sub" then
                table.insert(out, {char=op.char, color="green"})
            elseif op.type == "ins" then
                table.insert(out, {char=op.char, color=op.is_tail and "orange" or "green"})
            elseif op.type == "del" then
                if #out > 0 and out[#out].color == "grey" and not op.char:match("%s") then
                    out[#out].color = "green"
                end
            end
        end
    end

    -- UI Cleaning: Find first non-grey index
    local first_diff_idx = 0
    for idx, item in ipairs(out) do
        if item.color ~= "grey" then
            first_diff_idx = idx
            break
        end
    end

    if first_diff_idx > 0 then
        local start_idx = first_diff_idx
        -- Backtrack to the start of the current word
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
    if cur_str ~= "" then table.insert(chunks, {text=cur_str, color=cur_color}) end

    return chunks
end

-- Capitalization logic restricted strictly to letters to avoid emoji/symbol conflicts.
M.UPPER_LETTERS = {
    ['à']='À', ['â']='Â', ['ä']='Ä', ['é']='É', ['è']='È', ['ê']='Ê', ['ë']='Ë',
    ['î']='Î', ['ï']='Ï', ['ô']='Ô', ['ö']='Ö', ['ù']='Ù', ['û']='Û', ['ü']='Ü',
    ['ç']='Ç', ['œ']='Œ', ['æ']='Æ'
}
M.LOWER_LETTERS = {}
for k, v in pairs(M.UPPER_LETTERS) do M.LOWER_LETTERS[v] = k end
M.UPPER_TRIGGERS = {}
for k, v in pairs(M.UPPER_LETTERS) do M.UPPER_TRIGGERS[k] = v end
M.UPPER_TRIGGERS["'"] = " ?" 
M.UPPER_TRIGGERS[","] = {" :", " ;"} 
M.UPPER_TRIGGERS["."] = " :" 

function M.trig_lower(s)
    return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return M.LOWER_LETTERS[c] or string.lower(c)
    end))
end

function M.trig_upper(s)
    local results = {""}
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
            for _, u in ipairs(uppers) do table.insert(new_results, res .. u) end
        end
        results = new_results
    end
    return results
end

function M.trig_title(s)
    local first = s:match("^[%z\1-\127\194-\244][\128-\191]*")
    if not first then return {s} end
    local first_uppers = M.trig_upper(first)
    local rest = M.trig_lower(s:sub(#first + 1))
    local results = {}
    for _, fu in ipairs(first_uppers) do table.insert(results, fu .. rest) end
    return results
end

function M.repl_upper(s)
    return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", function(c)
        return M.UPPER_LETTERS[c] or string.upper(c)
    end))
end

function M.repl_title(s)
    local first = s:match("^[%z\1-\127\194-\244][\128-\191]*")
    if not first then return s end
    return M.repl_upper(first) .. s:sub(#first + 1)
end

function M.is_letter_char(c)
    if not c or c == "" then return false end
    if c:match("[%w]") then return true end
    if M.UPPER_LETTERS[c] or M.LOWER_LETTERS[c] then return true end
    return string.upper(c) ~= string.lower(c)
end

function M.utf8_ends_with(s, suffix)
    if not s or not suffix then return false end
    local n     = M.utf8_len(suffix)
    local start = utf8.offset(s, -n)
    return start and s:sub(start) == suffix or false
end

function M.contains_high_unicode(s)
    if not s then return false end
    for _, c in utf8.codes(s) do
        if c > 0xFFFF then return true end
    end
    return false
end

return M
