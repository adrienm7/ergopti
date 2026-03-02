-- toml_reader.lua
-- Parses the hotstrings TOML format produced by generate_hotstrings.py.
--
-- Supports the following constructs:
--   [_meta]              file-level description
--   [_meta.sections]     per-section descriptions (key = "description")
--   [[section_name]]     start of a hotstring section
--   "trigger" = { output = "...", is_word = bool, auto_expand = bool, is_case_sensitive = bool }
--
-- Public API:
--   M.parse(path)
--       → { meta = {description, sections = {[name]=desc}},
--            sections_order = {"name1","name2",...},
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
        return { meta = { description = '', sections = {} }, sections_order = {}, sections = {} }
    end

    local result = {
        meta           = { description = '', sections = {} },
        sections_order = {},
        sections       = {},
    }

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
                table.insert(result.sections_order, current_sec)
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
            local key, val = parse_kv_string(line)
            if key == 'description' and val then
                result.meta.description = val
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
