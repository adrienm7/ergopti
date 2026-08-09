--- tests/unit/lib/test_locale_karabiner_scope_labels.lua

--- ==============================================================================
--- MODULE: Karabiner Menu Scope Locale Tests
--- DESCRIPTION:
--- Prevents user-facing lifecycle labels from implying that ErgoptiPlus owns
--- the shared Karabiner-Elements application or its stock background services.
--- Every locale must name ErgoptiPlus on managed remapping status/actions while
--- keeping the explicit stock-GUI action visibly separate.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_ONLY_KEYS = {
	"karabiner.disable_failed",
	"karabiner.enable_failed",
	"menu.karabiner.start",
	"menu.karabiner.status_active",
	"menu.karabiner.status_inactive",
	"menu.karabiner.status_not_primed",
	"menu.karabiner.status_priming",
	"menu.karabiner.stop",
}

local TRANSLATED_FAILURE_KEYS = {
	"karabiner.disable_failed",
	"karabiner.enable_failed",
	"script_control.pause_failed",
	"script_control.resume_failed",
}

--- Extracts the quoted value of one flat locale key.
--- @param raw string Locale JSON source.
--- @param key string Exact key.
--- @return string|nil value Quoted value without JSON unescaping.
local function locale_value(raw, key)
	local escaped = key:gsub("([^%w])", "%%%1")
	return raw:match('"' .. escaped .. '"%s*:%s*"([^"]*)"')
end

--- Reads one canonical shared locale file.
--- @param code string Locale code.
--- @return string|nil raw File contents.
local function read_locale(code)
	local file = io.open(helpers.shared("data/locales/" .. code .. ".json"), "r")
	if not file then return nil end
	local raw = file:read("*a")
	file:close()
	return raw
end

--- Loads locale codes from the same canonical order consumed by the product.
--- @return table codes Ordered locale identifiers; empty means unreadable/invalid.
local function read_locale_codes()
	local file = io.open(helpers.shared("data/locale_order.json"), "r")
	if not file then return {} end
	local raw = file:read("*a")
	file:close()
	local order = raw:match('"order"%s*:%s*%[(.-)%]')
	if not order then return {} end
	local codes = {}
	for code in order:gmatch('"([a-z][a-z])"') do codes[#codes + 1] = code end
	return codes
end

local LOCALE_CODES = read_locale_codes()
local ENGLISH = read_locale("en")





-- ===============================================
-- ===============================================
-- ======= 1/ Managed-vs-Stock UI Boundary =======
-- ===============================================
-- ===============================================

helpers.describe("Karabiner menu locales identify the owned remapping scope", function()
	helpers.it("uses every locale from the canonical locale order", function()
		helpers.assert_eq(#LOCALE_CODES, 21,
			"locale_order.json must yield every shipped locale before per-locale tests are registered")
		helpers.assert_true(type(ENGLISH) == "string", "en.json must be readable")
	end)

	for _, code in ipairs(LOCALE_CODES) do
		helpers.it(code .. ".json distinguishes ErgoptiPlus remapping from stock Karabiner", function()
			local raw = read_locale(code)
			helpers.assert_true(type(raw) == "string", code .. ".json must be readable")

			for _, key in ipairs(OWNED_ONLY_KEYS) do
				local value = locale_value(raw, key)
				helpers.assert_true(type(value) == "string" and value ~= "",
					key .. " must exist in " .. code .. ".json")
				helpers.assert_true(value:find("ErgoptiPlus", 1, true) ~= nil,
					key .. " must name the owned ErgoptiPlus remapping scope (" .. code .. "): " .. value)
				helpers.assert_true(value:find("Karabiner", 1, true) == nil,
					key .. " must not imply stock Karabiner process ownership (" .. code .. "): " .. value)
			end

			local no_daemon = locale_value(raw, "menu.karabiner.status_no_daemon")
			helpers.assert_true(type(no_daemon) == "string"
				and no_daemon:find("ErgoptiPlus", 1, true) ~= nil
				and no_daemon:find("Karabiner", 1, true) ~= nil,
				"the unavailable status must name both owned remapping and the stock service boundary ("
					.. code .. "): " .. tostring(no_daemon))

			if code ~= "en" then
				for _, key in ipairs(TRANSLATED_FAILURE_KEYS) do
					local value = locale_value(raw, key)
					local english = locale_value(ENGLISH, key)
					helpers.assert_true(type(value) == "string" and value ~= "" and value ~= english,
						key .. " must be translated instead of copied from English (" .. code .. ")")
				end
			end

			for index = 1, 4 do
				local retired_key = "menu.karabiner.disabled_warning_" .. index
				helpers.assert_nil(locale_value(raw, retired_key),
					retired_key .. " must stay retired; disabling ErgoptiPlus never requires "
						.. "quitting or removing stock Karabiner (" .. code .. ")")
			end

			local open_gui = locale_value(raw, "menu.karabiner.open_gui")
			helpers.assert_true(type(open_gui) == "string" and open_gui:find("Karabiner", 1, true) ~= nil,
				"the separate explicit GUI action must still name stock Karabiner (" .. code .. ")")
			helpers.assert_true(open_gui:find("ErgoptiPlus", 1, true) == nil,
				"opening stock Karabiner must not be presented as an ErgoptiPlus-owned process action ("
					.. code .. "): " .. open_gui)
		end)
	end
end)
