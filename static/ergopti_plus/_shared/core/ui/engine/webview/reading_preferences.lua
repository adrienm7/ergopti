--- _shared/core/ui/engine/webview/reading_preferences.lua

--- ==============================================================================
--- MODULE: Webview Reading Preferences (Shared)
--- DESCRIPTION:
--- The reader's choices for the app's own windows, `script.reading_font` and
--- `script.reading_spacing` (Configuration menu), and what a macOS or Linux
--- host adds to every page it builds so they apply before the first paint:
--- the seed `window.__ergopti_reading` that _shared/ui/a11y_prefs.js reads,
--- and the chosen font's faces inlined as data: URLs.
---
--- FEATURES & RATIONALE:
--- 1. One owner per choice: new_owner() builds the native field owner the
---    script scope binds (core.ui.engine.webview.reading_font and
---    reading_spacing), on the shared scope protocol (settings/engine/scope/
---    owner.lua). Its value comes from the driver's settings store, else the
---    features manifest's default; an unknown stored value reads as the
---    default, so a hand-edited store cannot put the windows in an undefined
---    look.
--- 2. Inline fonts: both hosts load a page as an inline string with no base
---    URL, so a11y_prefs.js cannot link fonts/<folder>/font.css as it does on
---    the site and on Windows. font_style() reads that same stylesheet and
---    writes each url() it names as a data: URL (the shared document policy
---    allows font-src data:). A missing font file is an error, never a page
---    silently left in the default font.
--- 3. Same names and values as a11y_prefs.js: the seed's keys are its
---    preference names, the features' enum values its value lists; the
---    default (first) value is left out of the seed, as the script ignores it.
--- 4. Script-safe: the seed lands in an inline <script>, so every "<" is
---    written as the JSON escape, as in i18n_seed.lua.
--- 5. Open windows follow: push_script() is what a host runs in each window
---    still open once a choice is saved (the Configuration menu, the setup
---    wizard), the font inlined as in the page's own head.
--- ==============================================================================

local M = {}

local ConfigKeys = require("settings.engine.keys")
local Json = require("core.text.engine.json")

-- Each preference: the a11y_prefs.js name it seeds, the feature path that
-- holds it and the Configuration menu row that sets it. The order is the
-- seed's and the cache key's.
M.PREFERENCES = {
	{
		name = "font", path = ConfigKeys.KEY.SCRIPT_READING_FONT,
		command = ConfigKeys.COMMAND.READING_FONT, module = "core.ui.engine.webview.reading_font",
	},
	{
		name = "spacing", path = ConfigKeys.KEY.SCRIPT_READING_SPACING,
		command = ConfigKeys.COMMAND.READING_SPACING, module = "core.ui.engine.webview.reading_spacing",
	},
}

--- The preference a Configuration menu row sets. Each driver names its rows'
--- command ids itself, so the menu handler gate sees a handler for each row.
--- @param command string Menu command id (`ConfigKeys.COMMAND.READING_FONT`).
--- @return table The PREFERENCES entry.
function M.for_command(command)
	for _, preference in ipairs(M.PREFERENCES) do
		if preference.command == command then return preference end
	end
	error("no reading preference owns the menu command " .. tostring(command), 2)
end

--- The preference a page names (a11y_prefs.js), as the setup wizard posts it.
--- @param name any The page's name (`font`, `spacing`).
--- @return table|nil The PREFERENCES entry, nil for an unknown name.
function M.for_name(name)
	for _, preference in ipairs(M.PREFERENCES) do
		if preference.name == name then return preference end
	end
	return nil
end

-- The folder of each reading font under _shared/ui/fonts/, as a11y_prefs.js
-- names it (FONT_FOLDERS there).
M.FONT_FOLDERS = { hyperlegible = "atkinson-hyperlegible", dyslexic = "opendyslexic" }

-- Built styles, by font folder path: a page build must not re-encode the faces.
local _styles = {}





-- ==================================
-- ==================================
-- ======= 1/ Field Owners ==========
-- ==================================
-- ==================================

--- Builds the native owner module of one preference. Called once, by that
--- preference's module file, which returns the result as itself.
--- @param path string Feature path (`script.reading_font`).
--- @param name string The module's package.loaded key.
--- @return table owner get(), set(value) and the six scope methods.
function M.new_owner(path, name)
	local owner = {}
	local scope = require("settings.engine.scope.owner").new({ name = name, module = owner })
	local Manifest = require("menu.engine.manifest_reader")
	local value = nil

	--- The feature's accepted values, first one its default.
	local function values()
		local entry = Manifest.find_entry_by_path(path)
		if type(entry) ~= "table" or type(entry.enum_values) ~= "table" or entry.enum_values[1] ~= entry.default then
			error("the features manifest declares no enum with its default first for " .. path)
		end
		return entry.enum_values
	end

	--- Whether a value is one of the feature's.
	local function accepted(candidate)
		for _, allowed in ipairs(values()) do
			if candidate == allowed then return true end
		end
		return false
	end

	--- The current choice: the published one, else the stored one, else the default.
	--- @return string
	function owner.get()
		if value ~= nil then return value end
		local stored = require("core.fs.adapters.storage").get(path, nil)
		if stored ~= nil and accepted(stored) then return stored end
		return values()[1]
	end

	--- Persists a menu choice, then publishes it. Linux commits config.toml
	--- and its store as one transaction (script_scope.edit_setting), which
	--- publishes through scope_apply; macOS rewrites the configured row, then
	--- stores the value, as its other script rows do.
	--- @param candidate any The chosen value.
	--- @return boolean saved
	function owner.set(candidate)
		if not accepted(candidate) then return false end
		local ScriptScope = require("settings.engine.scope.script_scope")
		if type(ScriptScope.edit_setting) == "function" then
			if not ScriptScope.retry_edit(path) or not scope.admit_change() then return false end
			return ScriptScope.edit_setting(path, candidate) == true
		end
		if not scope.admit_change() then return false end
		if not ScriptScope.rewrite_configured(path, candidate) then return false end
		if require("core.fs.adapters.storage").set(path, candidate) ~= true then return false end
		value = candidate
		return true
	end

	--- Test seam: forgets the published value.
	function owner._reset()
		if not scope.admit_change() then return false end
		value = nil
		return true
	end

	scope.install({
		-- Reads only the choice this module owns; no persistence occurs here.
		state = function() return { value = value } end,
		published = { "value" },
		accept = function(candidate)
			if not accepted(candidate) then return nil end
			return { value = candidate }
		end,
		publish = function(target) value = target.value end,
	})
	return owner
end

--- The current choices, by a11y_prefs.js name.
--- @return table preferences { font = "...", spacing = "..." }.
function M.current()
	local preferences = {}
	for _, preference in ipairs(M.PREFERENCES) do
		preferences[preference.name] = require(preference.module).get()
	end
	return preferences
end





-- ==================================
-- ==================================
-- ======= 2/ Page Additions ========
-- ==================================
-- ==================================

--- The part of a page cache key the choices change.
--- @param preferences table From current().
--- @return string
function M.cache_key(preferences)
	local parts = {}
	for _, preference in ipairs(M.PREFERENCES) do
		parts[#parts + 1] = preference.name .. "=" .. tostring(preferences[preference.name])
	end
	return table.concat(parts, ";")
end

--- The boot-script statement seeding the non-default choices.
--- @param preferences table From current().
--- @return string statement `window.__ergopti_reading={...};`.
function M.statement(preferences)
	local seed = {}
	for _, preference in ipairs(M.PREFERENCES) do
		local chosen = preferences[preference.name]
		if type(chosen) == "string" and chosen ~= "default" then seed[preference.name] = chosen end
	end
	local json = next(seed) == nil and "{}" or Json.encode(seed)
	return "window.__ergopti_reading=" .. json:gsub("<", "\\u003c") .. ";"
end

--- The chosen font's stylesheet with every face inlined, or "" for the
--- default font.
--- @param preferences table From current().
--- @param fonts_dir string Path of _shared/ui/fonts, without a trailing slash.
--- @param read_file function Returns a file's bytes, or nil when unreadable.
--- @return string|nil style A `<style>` element, or "".
--- @return string|nil error Exact reason when a font file cannot be read.
function M.font_style(preferences, fonts_dir, read_file)
	local font = preferences.font
	if font == nil or font == "default" then return "", nil end
	local folder = M.FONT_FOLDERS[font]
	if folder == nil then return nil, "unknown reading font " .. tostring(font) end
	local base = fonts_dir .. "/" .. folder .. "/"
	if _styles[base] then return _styles[base], nil end
	local css = read_file(base .. "font.css")
	if type(css) ~= "string" or css == "" then return nil, "cannot read " .. base .. "font.css" end
	local Base64 = require("core.lifecycle.engine.compat.base64")
	local missing = nil
	local inlined = css:gsub("url%('([^']+)'%)", function(file)
		local bytes = read_file(base .. file)
		if type(bytes) ~= "string" or bytes == "" then
			missing = missing or base .. file
			return "url('')"
		end
		return "url('data:font/woff2;base64," .. Base64.encode(bytes) .. "')"
	end)
	if missing then return nil, "cannot read " .. missing end
	if not inlined:find("data:font/woff2", 1, true) then return nil, base .. "font.css names no font file" end
	_styles[base] = "<style>" .. inlined .. "</style>"
	return _styles[base], nil
end

--- The script a host runs in each window still open after a choice is saved,
--- so the change shows at once (a11y_prefs.js receiveHost): the new seed and,
--- the page having no address to link a font from, the chosen font's faces
--- inlined ("" for the default font, which drops the previous one's).
--- @param preferences table From current().
--- @param fonts_dir string Path of _shared/ui/fonts.
--- @param read_file function Returns a file's bytes, or nil.
--- @return string|nil script The statement.
--- @return string|nil error Why the chosen font cannot be inlined.
function M.push_script(preferences, fonts_dir, read_file)
	local style, err = M.font_style(preferences, fonts_dir, read_file)
	if style == nil then return nil, err end
	local css = style:gsub("^<style>", ""):gsub("</style>$", "")
	local seed = M.statement(preferences):match("^window%.__ergopti_reading=(.*);$")
	return "window.ErgoptiA11yPrefs&&window.ErgoptiA11yPrefs.receiveHost(" .. seed .. "," .. Json.encode(css) .. ");", nil
end

--- Everything a host inserts right after <head>: the seed, then the font.
--- @param preferences table From current().
--- @param fonts_dir string Path of _shared/ui/fonts.
--- @param read_file function Returns a file's bytes, or nil.
--- @return string|nil html The fragment.
--- @return string|nil error Why the chosen font cannot be inlined.
function M.head_fragment(preferences, fonts_dir, read_file)
	local style, err = M.font_style(preferences, fonts_dir, read_file)
	if style == nil then return nil, err end
	return "<script>" .. M.statement(preferences) .. "</script>" .. style, nil
end

return M
