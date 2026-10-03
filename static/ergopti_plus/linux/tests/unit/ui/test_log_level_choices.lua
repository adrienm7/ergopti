--- tests/unit/ui/test_log_level_choices.lua

--- ==============================================================================
--- MODULE: Shared Debug Log Choices (Linux)
--- DESCRIPTION:
--- Replays an independently captured four-state presentation through the real
--- tray builder. Moving the shared choices must move the native leaves and their
--- callbacks without bypassing the existing acknowledged persistence owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Reads expectations that are independent of the generated menu manifest.
--- @return table corpus
local function corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/log_level_rows.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(Json.decode(raw))
end

--- Finds the real native log-level parent without assuming its position.
--- @param selected string Current durable severity.
--- @param setter function Existing native assignment owner.
--- @return table row
local function build(selected, setter)
	local config = {
		get_groups = function() return {} end,
		get_categories = function() return {} end,
		language_packs = function() return {} end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
	}
	local rows = helpers.load_module("ui.menu.menu_builder").build({
		config = config, log_level = selected, on_set_log_level = setter,
		on_toggle_pause = function() end, on_quit = function() end,
	})
	local label = require("infra.i18n").get("menu.debug.log_level")
	for _, top in ipairs(rows) do
		for _, row in ipairs(top.menu or {}) do
			if row.title and row.title:find(label, 1, true) == 1 then return row end
		end
	end
	error("the declared Debug log-level parent is missing")
end

--- Compiles the actual daemon callback and binds the real script-settings owner.
--- The daemon cannot boot an evdev grab in headless tests; this bounded closure
--- is taken from its production source instead of reimplementing its behavior.
--- @param receipt string Storage refusal mode.
--- @return function setter, table observations
local function native_owner(receipt)
	local previous = { storage = package.loaded["adapters.storage"], logger = package.loaded["logger.shim"],
		settings = package.loaded["infra.script_settings"] }
	local observed = { selected = "INFO", durable = { ["script.log_level"] = "INFO", future = 42 }, rebuilds = 0 }
	local source = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local raw = source:read("*a")
	source:close()
	local body = assert(raw:match("on_set_log_level = function%(lvl%)(.-)\n\t\t\tend,"),
		"the actual daemon log-level callback must be captured")
	local logger = { info = function() end, error = function() end, warn = function() end,
		level_of = require("logger.shim").level_of,
		set_level = function(value) observed.threshold = value end }
	package.loaded["logger.shim"] = logger
	package.loaded["adapters.storage"] = {
		get = function(key, default) local value = observed.durable[key]; if value == nil then return default end; return value end,
		set = function(key, value)
			observed.requested, observed.detached = value, observed.threshold
			if receipt == "false" then return false end
			if receipt == "nil" then return nil end
			observed.durable[key] = value
			return true
		end,
	}
	package.loaded["infra.script_settings"] = nil
	local settings = require("infra.script_settings")
	settings.apply("INFO")
	local factory = assert(load("return function(ScriptSettings, Logger, rebuild_tray_menu) local LOG = 'menu'; return function(lvl)"
		.. body .. "\nend end", "actual-daemon-log-level"))()
	local callback = factory(settings, logger, function() observed.rebuilds = observed.rebuilds + 1 end)
	for key, name in pairs({ storage = "adapters.storage", logger = "logger.shim", settings = "infra.script_settings" }) do
		package.loaded[name] = previous[key]
	end
	return function(value)
		local result = callback(value)
		observed.selected = settings.current()
		return result
	end, observed
end

helpers.describe("Linux shared Debug log choices", function()
	for _, state in ipairs(corpus().states) do
		helpers.it("replays the independent four-state matrix for " .. state.selected, function()
			local observed = {}
			local row = build(state.selected, function(value) observed[#observed + 1] = value; return true end)
			local expected = corpus().levels
			helpers.assert_eq(#row.menu, 4)
			for index, level in ipairs(expected) do
				helpers.assert_eq(row.menu[index].title, level.label)
				helpers.assert_eq(row.menu[index].checked == true, state.checked[index])
				if level.value == state.selected then
					helpers.assert_eq(row.title, require("infra.i18n").get("menu.debug.log_level") .. " : " .. level.label)
				end
				helpers.assert_eq(row.menu[index].fn(), true)
			end
			helpers.assert_eq(observed, { "DEBUG", "INFO", "WARNING", "ERROR" })
		end)
	end

	helpers.it("follows shared ordering and returns the actual durable owner's refusal", function()
		local renderer = require("infra.manifest_menu")
		local declaration
		for _, row in ipairs(renderer.get_root().debug_menu) do if row.id == "log_level" then declaration = row end end
		local previous = declaration.choices
		local expected, labels = corpus(), {}
		for _, level in ipairs(expected.levels) do labels[level.value] = level.label end
		declaration.choices = {}
		for _, value in ipairs(expected.reordered_values) do
			declaration.choices[#declaration.choices + 1] = { value = value, label = labels[value] }
		end
		local setter, observations = native_owner("false")
		local ok, detail = pcall(function()
			local row = build(observations.selected, setter)
			for index, value in ipairs(expected.reordered_values) do
				helpers.assert_eq(row.menu[index].title, labels[value])
				helpers.assert_eq(row.menu[index].checked == true, value == "INFO")
			end
			helpers.assert_eq(row.menu[1].fn(), false)
			helpers.assert_eq(observations.requested, "ERROR")
			helpers.assert_eq(observations.selected, "INFO")
			helpers.assert_eq(observations.durable, { ["script.log_level"] = "INFO", future = 42 })
			helpers.assert_eq(observations.threshold, 20)
			helpers.assert_eq(observations.detached, 20)
			helpers.assert_eq(observations.rebuilds, 0)
		end)
		declaration.choices = previous
		if not ok then error(detail, 0) end
	end)
	for _, receipt in ipairs({ "false", "nil", "true" }) do
		helpers.it("returns the actual daemon owner receipt for storage " .. receipt, function()
			local setter, observed = native_owner(receipt)
			local row = build("INFO", setter)
			helpers.assert_eq(row.menu[4].fn(), receipt == "true")
			helpers.assert_eq(observed.requested, "ERROR")
			helpers.assert_eq(observed.detached, 20)
			helpers.assert_eq(observed.selected, receipt == "true" and "ERROR" or "INFO")
			helpers.assert_eq(observed.threshold, receipt == "true" and 40 or 20)
			helpers.assert_eq(observed.durable["script.log_level"], observed.selected)
			helpers.assert_eq(observed.durable.future, 42)
			helpers.assert_eq(observed.rebuilds, receipt == "true" and 1 or 0)
		end)
	end

end)

return true
