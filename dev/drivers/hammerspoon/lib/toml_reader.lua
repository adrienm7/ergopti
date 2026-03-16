-- toml_reader.lua
-- Parses the hotstrings TOML format produced by generate_hotstrings.py.
--
-- Supports the following constructs:
--   [_meta]              file-level description + optional sections_order array
--   [_meta.sections]     per-section descriptions (key = "description")
--   [[section_name]]     start of a hotstring section
--   "trigger" = { output = "...", is_word = bool, auto_expand = bool, is_case_sensitive = bool }
--
-- Public API:
--   M.parse(path)
--       → { meta = {description, sections = {[name]=desc}, sections_order = {...}},
--            sections_order = {"name1","-","name2",...},
--            sections = {name1 = {description, entries = [{...}]}, ...} }
--
--   M.load(path, keymap_module)   [backward-compatible helper]
--       Registers entries via keymap_module.add and returns total count.

local M = {}

---------------------------------------------------------------------------
-- String parser helpers
---------------------------------------------------------------------------

-- Parse a TOML double-quoted string starting at index i in s.
-- Returns (value_string, next_index) or (nil, i) on failure.
local function parse_dq_string(s, i)
    if s:sub(i, i) ~= '"' then return nil, i end
    local buf = {}
    local j = i + 1
    local n = #s
    while j <= n do
        local c = s:sub(j, j)
        if c == '\\' then
            local esc = s:sub(j + 1, j + 1)
            if     esc == '"'  then buf[#buf + 1] = '"';  j = j + 2
            elseif esc == '\\' then buf[#buf + 1] = '\\'; j = j + 2
            elseif esc == 'n'  then buf[#buf + 1] = '\n'; j = j + 2
            elseif esc == 't'  then buf[#buf + 1] = '\t'; j = j + 2
            elseif esc == 'r'  then buf[#buf + 1] = '\r'; j = j + 2
            else                    buf[#buf + 1] = esc;  j = j + 2
            end
        elseif c == '"' then
            return table.concat(buf), j + 1
        else
            buf[#buf + 1] = c
            j = j + 1
        end
    end
    return nil, i
end

-- Skip whitespace at position i and return the new position.
local function skip_ws(s, i)
    while i <= #s and s:sub(i, i):match('%s') do i = i + 1 end
    return i
end

-- Parse a TOML inline array of double-quoted strings: ["a", "-", "b", ...].
-- Returns a list (may be empty) even on partial parse.
local function parse_string_array(s)
    local result = {}
    local i = skip_ws(s, 1)
    if s:sub(i, i) ~= '[' then return result end
    i = skip_ws(s, i + 1)
    while i <= #s do
        if s:sub(i, i) == ']' then break end
        if s:sub(i, i) == ',' then
            i = skip_ws(s, i + 1)
        elseif s:sub(i, i) == '"' then
            local val, ni = parse_dq_string(s, i)
            if val then
                result[#result + 1] = val
                i = skip_ws(s, ni)
            else
                break
            end
        else
            break
        end
    end
    return result
end

---------------------------------------------------------------------------
-- Line parsers
---------------------------------------------------------------------------

-- Parse a hotstring entry line of the form:
--   "trigger" = { output = "...", is_word = bool, auto_expand = bool, is_case_sensitive = bool }
-- Returns a table or nil.
local function parse_entry(line)
    local i = skip_ws(line, 1)
    if line:sub(i, i) ~= '"' then return nil end
    local trigger, j = parse_dq_string(line, i)
    if not trigger then return nil end
    i = j
    i = skip_ws(line, i)
    if line:sub(i, i) ~= '=' then return nil end
    i = skip_ws(line, i + 1)
    if line:sub(i, i) ~= '{' then return nil end
    i = i + 1

    local result = {}
    while i <= #line do
        i = skip_ws(line, i)
        local c = line:sub(i, i)
        if c == '}' then break end
        if c == ',' then i = i + 1; i = skip_ws(line, i) end
        if line:sub(i, i) == '}' then break end

        local ks = i
        while i <= #line and line:sub(i, i):match('[%w_]') do i = i + 1 end
        local key = line:sub(ks, i - 1)
        if key == '' then break end

        i = skip_ws(line, i)
        if line:sub(i, i) ~= '=' then break end
        i = skip_ws(line, i + 1)

        if line:sub(i, i) == '"' then
            local val, ni = parse_dq_string(line, i)
            result[key] = val; i = ni
        elseif line:sub(i, i + 3) == 'true' then
            result[key] = true; i = i + 4
        elseif line:sub(i, i + 4) == 'false' then
            result[key] = false; i = i + 5
        else
            while i <= #line and line:sub(i, i) ~= ',' and line:sub(i, i) ~= '}' do
                i = i + 1
            end
        end
    end

    if not result.output then return nil end
    return {
        trigger           = trigger,
        output            = result.output,
        is_word           = result.is_word           or false,
        auto_expand       = result.auto_expand       or false,
        is_case_sensitive = result.is_case_sensitive or false,
        -- When true, the expanded text is never re-scanned for further hotstring
        -- matches.  Use this for entries whose output contains sequences that
        -- would otherwise be caught by another hotstring (e.g. e-mail addresses
        -- that contain a known abbreviation like "axa").
        final_result      = result.final_result      or false,
    }
end

-- Parse a plain key = "value" line (used for [_meta] and [_meta.sections]).
-- Returns (key_string, value_string) or (nil, nil).
local function parse_kv_string(line)
    local i = skip_ws(line, 1)
    -- key: bareword or quoted
    local key, j
    if line:sub(i, i) == '"' then
        key, j = parse_dq_string(line, i)
    else
        j = i
        while j <= #line and line:sub(j, j):match('[%w_]') do j = j + 1 end
        key = line:sub(i, j - 1)
    end
    if not key or key == '' then return nil, nil end
    i = skip_ws(line, j)
    if line:sub(i, i) ~= '=' then return nil, nil end
    i = skip_ws(line, i + 1)
    if line:sub(i, i) ~= '"' then return nil, nil end
    local val = select(1, parse_dq_string(line, i))
    return key, val
end

---------------------------------------------------------------------------
-- Public: M.parse(path)
---------------------------------------------------------------------------

-- Parse path and return a structured table:
-- {
--   meta = { description = "...", sections = { [norm_name] = "desc" } },
--   sections_order = { "name1", ... },
--   sections = { name1 = { description = "...", entries = [{...},...] }, ... },
-- }
function M.parse(path)
    local f = io.open(path, 'r')
    if not f then
        print('[toml_reader] cannot open: ' .. tostring(path))
        return { meta = { description = '', sections = {}, sections_order = {} }, sections_order = {}, sections = {} }
    end

    local result = {
        meta           = { description = '', sections = {}, sections_order = {} },
        sections_order = {},   -- final order (rebuilt after parsing)
        sections       = {},
    }
    -- Raw file order (order [[sec]] headers appear) – used as fallback.
    local file_order = {}

    -- Parser state
    local mode          = 'top'   -- 'top' | 'meta' | 'meta_sections' | 'section'
    local current_sec   = nil

    for raw_line in f:lines() do
        local line = raw_line:match('^%s*(.-)%s*$')

        -- Skip blank lines and TOML comments
        if line == '' or line:sub(1, 1) == '#' then goto continue end

        -- Detect section headers -----------------------------------------

        -- [_meta.sections]
        if line == '[_meta.sections]' then
            mode = 'meta_sections'
            goto continue
        end

        -- [_meta]
        if line == '[_meta]' then
            mode = 'meta'
            goto continue
        end

        -- [[section_name]]
        local sec_name = line:match('^%[%[(.-)%]%]$')
        if sec_name then
            mode         = 'section'
            current_sec  = sec_name
            if not result.sections[current_sec] then
                table.insert(file_order, current_sec)
                result.sections[current_sec] = {
                    description = result.meta.sections[current_sec] or '',
                    entries     = {},
                }
            end
            goto continue
        end

        -- Any other [table] header: leave meta mode
        if line:sub(1, 1) == '[' then
            mode = 'top'
            goto continue
        end

        -- Content lines ---------------------------------------------------

        if mode == 'meta' then
            -- sections_order = [...] inline array
            local arr_val = line:match('^sections_order%s*=%s*(%[.*)$')
            if arr_val then
                result.meta.sections_order = parse_string_array(arr_val)
            else
                local key, val = parse_kv_string(line)
                if key == 'description' and val then
                    result.meta.description = val
                end
            end

        elseif mode == 'meta_sections' then
            local key, val = parse_kv_string(line)
            if key and val then
                result.meta.sections[key] = val
                -- Back-fill description for already-created sections
                if result.sections[key] then
                    result.sections[key].description = val
                end
            end

        elseif mode == 'section' and current_sec then
            local entry = parse_entry(line)
            if entry then
                table.insert(result.sections[current_sec].entries, entry)
            end
        end

        ::continue::
    end

    f:close()

    -- Rebuild sections_order from TOML metadata order when available;
    -- otherwise fall back to the order sections appeared in the file.
    -- Sections not mentioned in meta.sections_order are appended at the end.
    local meta_order = result.meta.sections_order
    if meta_order and #meta_order > 0 then
        local seen = {}
        for _, item in ipairs(meta_order) do
            if item == '-' then
                table.insert(result.sections_order, '-')
            elseif result.sections[item] then
                table.insert(result.sections_order, item)
                seen[item] = true
            elseif result.meta.sections[item] then
                -- Section listed in __Order with a description but no [[]] block
                -- (no TOML entries): create an empty placeholder so keymap.lua
                -- can detect it and inject the matching Lua-module toggle.
                result.sections[item] = {
                    description = result.meta.sections[item],
                    entries     = {},
                    is_placeholder = true,
                }
                table.insert(result.sections_order, item)
                seen[item] = true
            end
        end
        -- Append sections present in the file but absent from the meta order.
        for _, name in ipairs(file_order) do
            if not seen[name] then
                table.insert(result.sections_order, name)
            end
        end
    else
        -- Fallback: use file order (no separators).
        result.sections_order = file_order
    end

    return result
end

---------------------------------------------------------------------------
-- Public: M.load(path, keymap_module)  [backward-compatible]
---------------------------------------------------------------------------

-- Load all hotstring entries from path and register them via
-- keymap_module.add(trigger, output, opts).  Returns total entry count.
function M.load(path, keymap_module)
    local data  = M.parse(path)
    local count = 0
    for _, sec_name in ipairs(data.sections_order) do
        for _, entry in ipairs(data.sections[sec_name].entries) do
            keymap_module.add(entry.trigger, entry.output, {
                is_word           = entry.is_word,
                auto_expand       = entry.auto_expand,
                is_case_sensitive = entry.is_case_sensitive,
            })
            count = count + 1
        end
    end
    return count
end

return M
