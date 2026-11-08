--- apps/app_strings.lua

--- ==============================================================================
--- MODULE: Bundled App Strings (Linux)
--- DESCRIPTION:
--- Loads the user-facing text of a bundled app (Encryptor, App Cloner) from the
--- shared locale catalogue, as the macOS bundles do: the tray hands the app the
--- active locale code and the locales folder, and a key the locale lacks is read
--- from English.
---
--- FEATURES & RATIONALE:
--- 1. The apps run as their own processes, outside the daemon's infra/i18n, so
---    they read the shared JSON directly; adding a locale needs no app change.
--- 2. A key English lacks too is a programming error and raises: an app that
---    showed a raw key or an empty dialog would hide the missing string.
--- ==============================================================================

local M = {}

local Json = require("json")

--- Reads and decodes one locale file.
--- @param path string Absolute path of a locale JSON file.
--- @return table|nil strings Nil when the file is missing or unreadable.
local function read_catalogue(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local raw = file:read("*a")
	file:close()
	local ok, decoded = pcall(Json.decode, raw)
	if not ok or type(decoded) ~= "table" then return nil end
	return decoded
end

--- Builds the string accessor of one locale.
--- @param locales_dir string Folder holding <code>.json files.
--- @param locale string|nil Two-letter locale code; nil or unknown reads English.
--- @return function get get(key, ...) returns the text with {1}, {2}… replaced.
function M.load(locales_dir, locale)
	assert(type(locales_dir) == "string" and locales_dir:sub(1, 1) == "/", "the locales folder must be absolute")
	local english = read_catalogue(locales_dir .. "/en.json")
	assert(english, "the English locale catalogue is unreadable: " .. locales_dir .. "/en.json")
	local active = english
	if type(locale) == "string" and locale:match("^[a-z][a-z]$") and locale ~= "en" then
		active = read_catalogue(locales_dir .. "/" .. locale .. ".json") or english
	end
	return function(key, ...)
		local text = active[key]
		if type(text) ~= "string" then text = english[key] end
		assert(type(text) == "string", "missing locale key: " .. tostring(key))
		local values = { ... }
		return (text:gsub("{(%d+)}", function(index)
			local value = values[tonumber(index)]
			if value == nil then return "{" .. index .. "}" end
			return tostring(value)
		end))
	end
end

return M
