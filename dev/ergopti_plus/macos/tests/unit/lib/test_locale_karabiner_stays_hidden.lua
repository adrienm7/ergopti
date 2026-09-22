--- tests/unit/lib/test_locale_karabiner_stays_hidden.lua

--- ==============================================================================
--- MODULE: Karabiner Stays Hidden Locale Tests
--- DESCRIPTION:
--- Karabiner is an implementation detail the macOS driver drives on its own:
--- the user must never have to care about it. So no text the macOS tray can
--- show — a row, a section header, or a dialog one of its rows opens — may name
--- it, in any locale. The keys are collected from what the tray actually draws:
--- every i18n key the menu modules pass to i18n.get, and every label key the
--- shared menu manifest declares for this platform.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The integration is always on, so these toggle-failure notices are gone.
local RETIRED_KEYS = {
	"karabiner.disable_failed",
	"karabiner.enable_failed",
}

--- Reads one file whole.
--- @param path string
--- @return string|nil
local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local raw = file:read("*a")
	file:close()
	return raw
end

--- Loads locale codes from the same canonical order consumed by the product.
--- @return table codes Ordered locale identifiers; empty means unreadable/invalid.
local function read_locale_codes()
	local raw = read(helpers.shared("data/locale_order.json"))
	local order = raw and raw:match('"order"%s*:%s*%[(.-)%]')
	if not order then return {} end
	local codes = {}
	for code in order:gmatch('"([a-z][a-z])"') do codes[#codes + 1] = code end
	return codes
end

--- Every i18n key the macOS tray can show on this platform.
--- @return table keys Sorted, unique.
local function tray_keys()
	local seen = {}
	-- Keys the tray's modules resolve themselves (rows, headers, dialogs): every
	-- file whose header names it as a ui/menu module.
	local src = helpers.read_driver_source("--- ui/menu/")
	helpers.assert_true(type(src) == "string" and src:find("function M.generate", 1, true) ~= nil,
		"the tray's menu modules must be readable")
	for key in src:gmatch('i18n%.get%(%s*"([^"]+)"') do seen[key] = true end
	for key in src:gmatch('i18n%.section%(%s*"([^"]+)"') do seen[key] = true end
	-- Keys the shared manifest declares for rows this platform renders.
	local manifest = hs.json.decode(read(helpers.shared("modules/menu/menu_manifest.json")))
	for _, rows in pairs(manifest) do
		if type(rows) == "table" and rows[1] ~= nil then
			for _, row in ipairs(rows) do
				local for_hs = type(row) == "table" and type(row.platforms) ~= "table"
				if type(row) == "table" and type(row.platforms) == "table" then
					for _, platform in ipairs(row.platforms) do
						if platform == "hs" then for_hs = true end
					end
				end
				if for_hs then
					for _, field in ipairs({ "i18n", "i18n_on", "i18n_off" }) do
						if type(row[field]) == "string" then seen[row[field]] = true end
					end
				end
			end
		end
	end
	local keys = {}
	for key in pairs(seen) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

local LOCALE_CODES = read_locale_codes()

helpers.describe("no macOS tray text names Karabiner, in any locale", function()
	helpers.it("covers every shipped locale and the tap-holds menu", function()
		helpers.assert_eq(#LOCALE_CODES, 21,
			"locale_order.json must yield every shipped locale before per-locale tests are registered")
		local keys = tray_keys()
		local has_tap_holds = false
		for _, key in ipairs(keys) do
			if key == "menu.tapholds.tap_hold_dialog_title" then has_tap_holds = true end
		end
		helpers.assert_true(has_tap_holds,
			"the scan must reach the tap-holds dialogs, or it proves nothing about them")
	end)

	for _, code in ipairs(LOCALE_CODES) do
		helpers.it(code .. ".json shows no Karabiner in the macOS tray", function()
			local locale = hs.json.decode(read(helpers.shared("data/locales/" .. code .. ".json")))
			helpers.assert_true(type(locale) == "table", code .. ".json must decode")
			for _, key in ipairs(tray_keys()) do
				local value = locale[key]
				if type(value) == "string" then
					helpers.assert_nil(value:lower():find("karabiner", 1, true),
						key .. " names the remap engine in " .. code .. ".json: " .. value)
				end
			end
			for key in pairs(locale) do
				helpers.assert_nil(key:find("^menu%.karabiner%."),
					"the Karabiner submenu is gone; " .. key .. " must not return (" .. code .. ")")
			end
			for _, key in ipairs(RETIRED_KEYS) do
				helpers.assert_nil(locale[key], key .. " belonged to the retired enable toggle (" .. code .. ")")
			end
		end)
	end
end)
