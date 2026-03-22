-- lib/toml_writer.lua
-- Serialise a hotstrings data structure back to the TOML format used by
-- toml_reader.lua and generate_hotstrings.py.
--
-- Public API:
--   M.write(path, data) → true | false, err_string
--
-- Expected `data` shape:
--   {
--     meta           = { description = "..." },          -- optional
--     sections_order = { "name1", "name2", ... },        -- order for [[]] headers
--     sections       = {
--       name1 = { description = "...", entries = [
--         { trigger, output, is_word, auto_expand, is_case_sensitive, final_result }
--       ]},
--       ...
--     },
--   }

local M = {}

-- Token alias normalisation map (canonical names stored in TOML)
local TOKEN_CANONICAL = {
    esc = "Escape", escape = "Escape",
    bs  = "BackSpace", backspace = "BackSpace",
    del = "Delete", delete = "Delete",
    ["return"] = "Enter", enter = "Enter",
    left = "Left", right = "Right", up = "Up", down = "Down",
    home = "Home", ["end"] = "End", tab = "Tab",
}

-- Escape a value for TOML double-quoted strings.
-- Also normalises literal newlines to {Enter} and token aliases.
local function esc(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"',  '\\"')
    -- Normalise literal newlines → {Enter} (never store raw \n in TOML)
    s = s:gsub("\r\n", "{Enter}")
    s = s:gsub("\r",   "{Enter}")
    s = s:gsub("\n",   "{Enter}")
    s = s:gsub("\t", "\\t")
    -- Normalise token aliases  e.g. {Esc} → {Escape}, {return} → {Enter}
    s = s:gsub("{([^}]+)}", function(name)
        local canon = TOKEN_CANONICAL[name:lower()]
        return "{" .. (canon or (name:sub(1,1):upper() .. name:sub(2):lower())) .. "}"
    end)
    return s
end

--- Write a TOML file from a hotstrings data structure.
---@param  path string   Destination file path.
---@param  data table    See module header for shape.
---@return boolean, string|nil   true on success; false + error string on failure.
function M.write(path, data)
    data = data or {}
    local order    = data.sections_order or {}
    local sections = data.sections       or {}
    local meta_desc = (data.meta and data.meta.description) or "Hotstrings personnels"

    local L = {}
    local function w(line) L[#L + 1] = line end

    w("# custom.toml — Hotstrings personnels")
    w("# Géré automatiquement par l'éditeur de hotstrings personnels.")
    w("# Ne pas modifier manuellement sauf si vous savez ce que vous faites.")
    w("")

    -- [_meta] ----------------------------------------------------------
    w("[_meta]")
    w(string.format('description = "%s"', esc(meta_desc)))

    if #order > 0 then
        local parts = {}
        for _, name in ipairs(order) do
            parts[#parts + 1] = '"' .. esc(name) .. '"'
        end
        w("sections_order = [" .. table.concat(parts, ", ") .. "]")
    else
        w("sections_order = []")
    end
    w("")

    -- [_meta.sections] ------------------------------------------------
    local has_sections = false
    for _, name in ipairs(order) do
        if name ~= "-" and sections[name] then has_sections = true; break end
    end

    if has_sections then
        w("[_meta.sections]")
        for _, name in ipairs(order) do
            if name ~= "-" and sections[name] then
                local desc = sections[name].description or name
                w(string.format('%s = "%s"', name, esc(desc)))
            end
        end
        w("")
    end

    -- [[section]] blocks -----------------------------------------------
    for _, name in ipairs(order) do
        if name ~= "-" and sections[name] then
            local sec = sections[name]
            w(string.format("[[%s]]", name))
            for _, e in ipairs(sec.entries or {}) do
                w(string.format(
                    '"%s" = { output = "%s", is_word = %s, auto_expand = %s, '
                    .. 'is_case_sensitive = %s, final_result = %s }',
                    esc(e.trigger),
                    esc(e.output),
                    e.is_word           and "true" or "false",
                    e.auto_expand       and "true" or "false",
                    e.is_case_sensitive and "true" or "false",
                    e.final_result      and "true" or "false"
                ))
            end
            w("")
        end
    end

    local fh = io.open(path, "w")
    if not fh then
        return false, "Impossible d'ouvrir le fichier en écriture : " .. path
    end
    fh:write(table.concat(L, "\n"))
    fh:close()
    return true
end

return M
