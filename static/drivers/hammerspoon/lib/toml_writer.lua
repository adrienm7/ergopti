-- lib/toml_writer.lua

-- ===========================================================================
-- TOML Writer Module.
--
-- Serializes a hotstrings data structure back to the TOML format used by
-- toml_reader.lua and generate_hotstrings.py.
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
-- ===========================================================================

local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Token alias normalization map (canonical names stored in TOML)
local TOKEN_CANONICAL = {
    esc = "Escape", escape = "Escape",
    bs  = "BackSpace", backspace = "BackSpace",
    del = "Delete", delete = "Delete",
    ["return"] = "Enter", enter = "Enter",
    left = "Left", right = "Right", up = "Up", down = "Down",
    home = "Home", ["end"] = "End", tab = "Tab",
}





-- ===================================
-- ===================================
-- ======= 2/ String Utilities =======
-- ===================================
-- ===================================

--- Escapes a value for TOML double-quoted strings.
--- Also normalizes literal newlines to {Enter} and token aliases.
--- @param s string The input string to escape
--- @return string The escaped and normalized string
local function esc(s)
    if type(s) ~= "string" then s = tostring(s or "") end
    
    s = s:gsub("\\", "\\\\")
    s = s:gsub("\"",  "\\\"")
    
    -- Normalize literal newlines → {Enter} (never store raw \n in TOML)
    s = s:gsub("\r\n", "{Enter}")
    s = s:gsub("\r",   "{Enter}")
    s = s:gsub("\n",   "{Enter}")
    s = s:gsub("\t", "\\t")
    
    -- Normalize token aliases  e.g. {Esc} → {Escape}, {return} → {Enter}
    s = s:gsub("{([^}]+)}", function(name)
        local canon = TOKEN_CANONICAL[name:lower()]
        return "{" .. (canon or (name:sub(1,1):upper() .. name:sub(2):lower())) .. "}"
    end)
    
    return s
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Writes a TOML file from a hotstrings data structure.
--- @param path string Destination file path.
--- @param data table See module header for shape.
--- @return boolean, string|nil true on success; false + error string on failure.
function M.write(path, data)
    if type(path) ~= "string" or path == "" then
        return false, "Invalid path provided."
    end
    
    data = type(data) == "table" and data or {}
    
    local order     = type(data.sections_order) == "table" and data.sections_order or {}
    local sections  = type(data.sections) == "table" and data.sections or {}
    local meta_desc = (type(data.meta) == "table" and type(data.meta.description) == "string") 
                      and data.meta.description or "Hotstrings personnels"

    local L = {}
    local function w(line) table.insert(L, line) end

    -- File headers (Kept in French as they are directly visible to the end user)
    w("# custom.toml — Hotstrings personnels")
    w("# Géré automatiquement par l’éditeur de hotstrings personnels.")
    w("# Ne pas modifier manuellement sauf si vous savez ce que vous faites.")
    w("")

    -- [_meta]
    w("[_meta]")
    w(string.format("description = \"%s\"", esc(meta_desc)))

    if #order > 0 then
        local parts = {}
        for _, name in ipairs(order) do
            if type(name) == "string" then
                table.insert(parts, "\"" .. esc(name) .. "\"")
            end
        end
        w("sections_order = [" .. table.concat(parts, ", ") .. "]")
    else
        w("sections_order = []")
    end
    w("")

    -- [_meta.sections]
    local has_sections = false
    for _, name in ipairs(order) do
        if name ~= "-" and type(sections[name]) == "table" then 
            has_sections = true
            break 
        end
    end

    if has_sections then
        w("[_meta.sections]")
        for _, name in ipairs(order) do
            if name ~= "-" and type(sections[name]) == "table" then
                local desc = type(sections[name].description) == "string" and sections[name].description or name
                w(string.format("%s = \"%s\"", name, esc(desc)))
            end
        end
        w("")
    end

    -- [[section]] blocks
    for _, name in ipairs(order) do
        if name ~= "-" and type(sections[name]) == "table" then
            local sec = sections[name]
            w(string.format("[[%s]]", name))
            
            if type(sec.entries) == "table" then
                for _, e in ipairs(sec.entries) do
                    -- Ensure required fields are valid strings before formatting
                    if type(e) == "table" and type(e.trigger) == "string" and type(e.output) == "string" then
                        w(string.format(
                            "\"%s\" = { output = \"%s\", is_word = %s, auto_expand = %s, is_case_sensitive = %s, final_result = %s }",
                            esc(e.trigger),
                            esc(e.output),
                            e.is_word           and "true" or "false",
                            e.auto_expand       and "true" or "false",
                            e.is_case_sensitive and "true" or "false",
                            e.final_result      and "true" or "false"
                        ))
                    end
                end
            end
            w("")
        end
    end

    -- Safe file writing operations
    local ok, fh = pcall(io.open, path, "w")
    if not ok or not fh then
        -- UI Error message kept in French
        return false, "Impossible d’ouvrir le fichier en écriture : " .. tostring(path)
    end
    
    local write_ok, write_err = pcall(function()
        fh:write(table.concat(L, "\n"))
    end)
    
    pcall(function() fh:close() end)
    
    if not write_ok then
        return false, "Erreur lors de l’écriture : " .. tostring(write_err)
    end
    
    return true
end

return M
