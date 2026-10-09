--- _shared/lua/webview/i18n_seed.lua

--- ==============================================================================
--- MODULE: Webview Locale Seed (Shared)
--- DESCRIPTION:
--- Builds the boot-script statement that hands a shared page its strings
--- together with the page itself, as window._i18n_strings, before any of the
--- page's scripts run. _shared/ui/i18n.js applies a seeded store at once and
--- fetches nothing when it resolves the page.
---
--- FEATURES & RATIONALE:
--- 1. No fetch to lose: macOS loads each page inline, and WKWebView refuses
---    file:// fetches from that page; WebKitGTK refuses them too unless a
---    setting the Linux driver never enables. A host that delivers strings
---    only after the page has loaded leaves the first render untranslated and
---    races the page's own failed fetch.
--- 2. One encoder for both drivers: the shared pure-Lua JSON module, so the
---    seed is byte-identical on macOS and Linux and does not depend on a
---    native encoder a test or a host may replace.
--- 3. Script-safe: the catalogue lands in an inline <script>, so every "<" is
---    written as the JSON escape <. A translation containing "</script>"
---    or "<!--" can then never end or comment out the element early.
--- ==============================================================================

local M = {}

local Json = require("json")




-- ==================================
-- ==================================
-- ======= 1/ Seed Statement ========
-- ==================================
-- ==================================

--- Builds the JavaScript statement that seeds a page's string store.
--- @param catalogue table Flat key → string map, as the locale core's catalogue() returns it.
--- @return string|nil statement The statement, to place inside the boot <script>.
--- @return string|nil error Exact reason when the catalogue cannot be seeded.
function M.statement(catalogue)
	if type(catalogue) ~= "table" then return nil, "catalogue is not a table" end
	if next(catalogue) == nil then return nil, "catalogue is empty" end
	local ok, json = pcall(Json.encode, catalogue)
	if not ok or type(json) ~= "string" or json:sub(1, 1) ~= "{" then
		return nil, "catalogue could not be encoded as a JSON object (" .. tostring(json) .. ")"
	end
	local escaped = json:gsub("<", "\\u003c")
	return "window._i18n_strings=" .. escaped .. ";", nil
end

return M
