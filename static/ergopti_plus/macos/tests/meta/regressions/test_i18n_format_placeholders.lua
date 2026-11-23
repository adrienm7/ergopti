--- tests/meta/regressions/test_i18n_format_placeholders.lua

--- ==============================================================================
--- MODULE: Regression — i18n.format texts use {n}, never printf placeholders
---         (i18n-format-placeholders)
--- DESCRIPTION:
--- i18n.format substitutes {1}, {2}, … and leaves a printf %s untouched. The
--- owned runtime install failure therefore read « Le moteur de remappage n'a
--- pas pu être installé (%s). » with the reason lost (field report
--- 2026-11-23): its text, the service repair's and App Cloner's Python offer
--- were written with %s. Every text the macOS driver hands to i18n.format, in
--- every locale, must carry no printf placeholder. A key is found either as
--- the call's literal first argument, or, in a file that formats a key held
--- in a variable, as a literal assigned in that file (the texts tables).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local RuntimeSources = require("tests.support.runtime_source_inventory")

--- Reads every locale catalogue.
--- @return table catalogues { code = { key = text } }.
local function catalogues()
	local function read(rel)
		local file = assert(io.open(helpers.shared(rel), "rb"))
		local data = Json.decode(file:read("*a"))
		file:close()
		return data
	end
	local out = {}
	for _, code in ipairs(read("core/i18n/data/locale_order.json").order) do
		out[code] = read("core/i18n/data/locales/" .. code .. ".json")
	end
	assert(out.en, "the locale order must name English")
	return out
end

--- Collects the locale keys a source formats with i18n.format.
--- @param body string Lua source.
--- @param known table English catalogue, to tell keys from other literals.
--- @return table keys { key = true }.
local function formatted_keys(body, known)
	local keys = {}
	for key in body:gmatch("i18n%.format%s*%(%s*\"([%w_%.]+)\"") do keys[key] = true end
	if body:find("i18n%.format%s*%(%s*[%a_][%w_%.%[%]]*%s*,") then
		for key in body:gmatch("[%w_]+%s*=%s*\"([%w_]+%.[%w_%.]+)\"") do
			if known[key] ~= nil then keys[key] = true end
		end
	end
	return keys
end

helpers.describe("i18n.format texts carry no printf placeholder (i18n-format-placeholders)", function()
	local locales = catalogues()
	local units = RuntimeSources.read(helpers.driver_root())

	helpers.it("covers the owned runtime install texts of the field report", function()
		local seen = {}
		for _, unit in ipairs(units) do
			if unit.path:match("%.lua$") then
				for key in pairs(formatted_keys(unit.body, locales.en)) do seen[key] = true end
			end
		end
		for _, key in ipairs({ "karabiner.owned_install.failed", "karabiner.owned_repair.failed",
			"apps.cloner.python_offer.failed" }) do
			helpers.assert_true(seen[key] == true, key .. " must be found as an i18n.format text")
		end
	end)

	helpers.it("finds no %s or %d in any formatted text of any locale", function()
		local offenders = {}
		for _, unit in ipairs(units) do
			if unit.path:match("%.lua$") then
				for key in pairs(formatted_keys(unit.body, locales.en)) do
					for code, catalogue in pairs(locales) do
						local text = catalogue[key]
						if type(text) == "string" and text:find("%%[sd]") then
							offenders[#offenders + 1] = code .. ":" .. key .. " (" .. unit.path:match("[^/]+$") .. ")"
						end
					end
				end
			end
		end
		table.sort(offenders)
		helpers.assert_eq(#offenders, 0, "i18n.format reads {1}, {2}: " .. table.concat(offenders, ", "))
	end)
end)
