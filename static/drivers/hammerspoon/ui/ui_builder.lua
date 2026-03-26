-- ui/ui_builder.lua

-- ===========================================================================
-- UI Builder Utility.
--
-- Provides helper functions to build standalone HTML strings by injecting
-- CSS and JS files directly into the HTML template. 
--
-- Logic: Uses case-insensitive pattern matching to find injection points
-- and escapes special characters to ensure JS/CSS integrity.
-- ===========================================================================

local M = {}

--- Reads a file and escapes "%" for Lua string substitution (gsub)
--- @param path string Full path to the file
--- @return string The escaped file content
local function read_and_escape(path)
    local ok, fh = pcall(io.open, path, "r")
    if not ok or not fh then return "" end
    local content = fh:read("*a")
    fh:close()
    -- Double "%" to prevent Lua pattern matching errors during injection
    return content:gsub("%%", "%%%%")
end

--- Builds a self-contained HTML string from separate assets
--- @param assets_dir string The directory containing the assets
--- @param html_name string (Optional) Default: "index.html"
--- @param css_name string (Optional) Default: "style.css"
--- @param js_name string (Optional) Default: "script.js"
--- @return string The complete HTML with injected styles and scripts
function M.build_injected_html(assets_dir, html_name, css_name, js_name)
    html_name = html_name or "index.html"
    css_name  = css_name  or "style.css"
    js_name   = js_name   or "script.js"

    local html_path = assets_dir .. html_name
    local ok, fh = pcall(io.open, html_path, "r")
    if not ok or not fh then 
        -- User-facing error in French
        return "<html><body><h1>Erreur de construction : " .. html_name .. " introuvable</h1></body></html>" 
    end
    local html = fh:read("*a")
    fh:close()

    local css = read_and_escape(assets_dir .. css_name)
    local js  = read_and_escape(assets_dir .. js_name)

    -- Case-insensitive injection before </head>
    if css ~= "" then
        -- [Hh][Ee][Aa][Dd] matches head in any case
        html = html:gsub("(</[Hh][Ee][Aa][Dd]>)", "<style>" .. css .. "</style>%1")
    end

    -- Case-insensitive injection before </body>
    if js ~= "" then
        html = html:gsub("(</[Bb][Oo][Dd][Yy]>)", "<script>" .. js .. "</script>%1")
    end

    return html
end

return M
