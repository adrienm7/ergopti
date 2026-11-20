--- _shared/tests/lua/reading_preferences_contract.lua

--- ==============================================================================
--- MODULE: Webview Reading Preferences Contract
--- DESCRIPTION:
--- Pins core/ui/engine/webview/reading_preferences.lua on both Lua runners:
--- its names, values and font folders are a11y_prefs.js's and the features
--- manifest's, the seed carries only the non-default choices and cannot end
--- its <script>, the chosen font's faces are inlined from the shipped files,
--- a missing font file is an error, and each choice's owner reads the
--- driver's store and refuses an unknown value. register_host() builds a real
--- page through the driver's own builder and requires the seed and the font
--- before a11y_prefs.js runs.
--- ==============================================================================

local M = {}
local Reading = require("core.ui.engine.webview.reading_preferences")

--- Reads a file's bytes.
--- @param path string
--- @return string|nil
local function read_bytes(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Runs a callback with a store holding the given values, then puts the
--- driver's store back.
--- @param values table Feature path -> stored value.
--- @param callback function
local function with_store(values, callback)
	-- An earlier scope transaction of the suite may have published a value
	-- into an owner; the store is then not what get() reads.
	for _, preference in ipairs(Reading.PREFERENCES) do
		assert(require(preference.module)._reset(), "the reading owner must accept the reset")
	end
	local saved = package.loaded["core.fs.adapters.storage"]
	package.loaded["core.fs.adapters.storage"] = {
		get = function(key, default)
			if values[key] ~= nil then return values[key] end
			return default
		end,
	}
	local ok, err = pcall(callback)
	package.loaded["core.fs.adapters.storage"] = saved
	if not ok then error(err, 0) end
end
M.with_store = with_store

--- Registers the shared vectors in a driver suite.
--- @param helpers table Driver test API.
--- @param shared_root string Path of static/ergopti_plus/_shared.
function M.register(helpers, shared_root)
	local fonts_dir = shared_root .. "/ui/fonts"
	helpers.describe("shared webview reading preferences (reading-preferences-seed)", function()
		helpers.it("names a11y_prefs.js's preferences, values and font folders", function()
			local script = assert(read_bytes(shared_root .. "/ui/a11y_prefs.js"))
			local Manifest = require("menu.engine.manifest_reader")
			for _, preference in ipairs(Reading.PREFERENCES) do
				local list = script:match(preference.name .. ": { attribute: '[^']+', values: %[([^%]]+)%]")
				helpers.assert_true(list ~= nil, "a11y_prefs.js has the preference " .. preference.name)
				local values = {}
				for value in list:gmatch("'([^']+)'") do values[#values + 1] = value end
				local entry = Manifest.find_entry_by_path(preference.path)
				helpers.assert_true(type(entry) == "table", preference.path .. " is a feature")
				helpers.assert_eq(table.concat(entry.enum_values, ","), table.concat(values, ","),
					preference.path .. " has a11y_prefs.js's values in its order")
				helpers.assert_eq(entry.default, values[1], preference.path .. " defaults to the script's default")
			end
			local folders = assert(script:match("FONT_FOLDERS = {([^}]+)}"))
			local count = 0
			for font, folder in folders:gmatch("(%w+): '([^']+)'") do
				helpers.assert_eq(Reading.FONT_FOLDERS[font], folder, "the folder of " .. font)
				count = count + 1
			end
			helpers.assert_eq(count, 2, "two reading fonts")
		end)

		helpers.it("seeds only the non-default choices, script-safe", function()
			helpers.assert_eq(Reading.statement({ font = "default", spacing = "default" }), "window.__ergopti_reading={};")
			local seed = Reading.statement({ font = "dyslexic", spacing = "wide" })
			helpers.assert_true(seed:find('"font":"dyslexic"', 1, true) ~= nil, seed)
			helpers.assert_true(seed:find('"spacing":"wide"', 1, true) ~= nil, seed)
			helpers.assert_true(Reading.statement({ font = "</script>" }):find("<", 1, true) == nil,
				"a value can never close the boot script")
			helpers.assert_true(Reading.cache_key({ font = "dyslexic", spacing = "default" })
				~= Reading.cache_key({ font = "default", spacing = "default" }), "the cache key follows the font")
		end)

		helpers.it("inlines the chosen font's faces from the shipped files", function()
			helpers.assert_eq(Reading.font_style({ font = "default" }, fonts_dir, read_bytes), "")
			for font, folder in pairs(Reading.FONT_FOLDERS) do
				local style, err = Reading.font_style({ font = font }, fonts_dir, read_bytes)
				helpers.assert_true(style ~= nil, tostring(err))
				helpers.assert_true(style:find("^<style>") ~= nil and style:find("</style>$") ~= nil, folder)
				local _, faces = style:gsub("@font%-face", "")
				local _, inlined = style:gsub("url%('data:font/woff2;base64,[A-Za-z0-9+/=]+'%)", "")
				helpers.assert_true(faces > 0 and inlined == faces, folder .. ": every face is a data: URL")
				helpers.assert_true(style:find("%.woff2") == nil, folder .. ": no file name is left to fetch")
			end
		end)

		helpers.it("refuses a font whose files are missing", function()
			local style, err = Reading.font_style({ font = "dyslexic" }, shared_root .. "/ui/missing_fonts", read_bytes)
			helpers.assert_nil(style)
			helpers.assert_true(tostring(err):find("cannot read", 1, true) ~= nil, tostring(err))
			local unknown, why = Reading.font_style({ font = "comic" }, fonts_dir, read_bytes)
			helpers.assert_nil(unknown)
			helpers.assert_true(tostring(why):find("unknown reading font", 1, true) ~= nil, tostring(why))
		end)

		helpers.it("reads each choice from the store, an unknown value as the default", function()
			with_store({ ["script.reading_font"] = "dyslexic", ["script.reading_spacing"] = "comic" }, function()
				local current = Reading.current()
				helpers.assert_eq(current.font, "dyslexic")
				helpers.assert_eq(current.spacing, "default", "an unknown stored value reads as the default")
			end)
			with_store({}, function()
				helpers.assert_eq(Reading.current().font, "default", "nothing stored reads as the default")
			end)
			helpers.assert_eq(require("core.ui.engine.webview.reading_font").set("comic"), false,
				"a value outside the enum is refused before anything is written")
		end)
	end)
end

--- Requires the driver's page builder to carry the choices.
--- @param helpers table Driver test API.
--- @param label string The builder's name in the test titles.
--- @param build function Returns a built page (string) for a real app.
function M.register_host(helpers, label, build)
	helpers.describe(label .. " seeds the reading preferences (reading-preferences-seed)", function()
		helpers.it("puts the seed and the inlined font before a11y_prefs.js", function()
			with_store({ ["script.reading_font"] = "dyslexic", ["script.reading_spacing"] = "wide" }, function()
				local html = build()
				local seed_at = html:find("window.__ergopti_reading=", 1, true)
				local font_at = html:find("data:font/woff2;base64,", 1, true)
				local prefs_at = html:find("window.ErgoptiA11yPrefs", 1, true)
				helpers.assert_true(seed_at ~= nil, "the page carries the seed")
				helpers.assert_true(html:find('"font":"dyslexic"', 1, true) ~= nil, "the seed names the font")
				helpers.assert_true(html:find('"spacing":"wide"', 1, true) ~= nil, "the seed names the spacing")
				helpers.assert_true(font_at ~= nil, "the page carries the font inline")
				helpers.assert_true(prefs_at ~= nil and seed_at < prefs_at and font_at < prefs_at,
					"both come before a11y_prefs.js reads them")
			end)
			with_store({}, function()
				local html = build()
				helpers.assert_true(html:find("window.__ergopti_reading={};", 1, true) ~= nil, "no choice seeds none")
				helpers.assert_true(html:find("data:font/woff2", 1, true) == nil, "the default font inlines nothing")
			end)
		end)
	end)
end

return M
