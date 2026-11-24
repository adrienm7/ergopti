--- tests/unit/menu/about/test_log_level_choices.lua

--- ==============================================================================
--- MODULE: Debug « Detailed log » Switch (Linux)
--- DESCRIPTION:
--- « Detailed log » replaced the log-level selector (maintainer, 2026-11-24).
--- The real tray builder ticks it from the shared detailed_log cases, and a
--- click asks the existing acknowledged persistence owner for DEBUG or the
--- default, returning that owner's refusal.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

--- The « Detailed log » cases the three drivers replay.
--- @return table cases
local function cases()
	local file = assert(io.open(require("core.fs.engine.paths").shared("tests/corpus/logger/parity_vectors.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(Json.decode(raw)).detailed_log.cases
end

--- Finds the real native « Detailed log » row without assuming its position.
--- @param selected string Current durable severity.
--- @param setter function Existing native assignment owner.
--- @return table row
local function build(selected, setter)
	local config = {
		get_groups = function() return {} end,
		get_categories = function() return {} end,
		language_packs = function() return {} end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_base_delay = function() return 0.75 end,
		has_base_delay_override = function() return false end,
	}
	local rows = helpers.load_module("menu.ui.builder.builder").build({
		config = config, log_level = selected, on_set_log_level = setter,
		on_toggle_pause = function() end, on_quit = function() end,
	})
	local label = require("core.i18n.engine.i18n").get("menu.debug.detailed_log")
	for _, top in ipairs(rows) do
		for _, row in ipairs(top.menu or {}) do
			if row.title == label then return row end
		end
	end
	error("the declared Debug « Detailed log » row is missing")
end

--- Compiles the actual daemon callback and binds the real script-settings owner.
--- The daemon cannot boot an evdev grab in headless tests; this bounded closure
--- is taken from its production source instead of reimplementing its behavior.
--- @param receipt string Storage refusal mode.
--- @return function setter, table observations
local function native_owner(receipt)
	local previous = { storage = package.loaded["core.fs.adapters.storage"], logger = package.loaded["core.logger.engine.shim"],
		settings = package.loaded["settings.engine.scope.script_settings"] }
	local observed = { selected = "INFO", durable = { ["script.log_level"] = "INFO", future = 42 }, rebuilds = 0 }
	local source = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local raw = source:read("*a")
	source:close()
	local body = assert(raw:match("on_set_log_level = function%(lvl%)(.-)\n\t\t\tend,"),
		"the actual daemon log-level callback must be captured")
	local logger = { info = function() end, error = function() end, warn = function() end,
		level_of = require("core.logger.engine.shim").level_of,
		set_level = function(value) observed.threshold = value end,
		get_level = function() return observed.threshold end }
	package.loaded["core.logger.engine.shim"] = logger
	local storage = {
		get = function(key, default) local value = observed.durable[key]; if value == nil then return default end; return value end,
		set = function(key, value)
			observed.requested, observed.detached = value, observed.threshold
			if receipt == "false" then return false end
			if receipt == "nil" then return nil end
			observed.durable[key] = value
			return true
		end,
	}
	package.loaded["core.fs.adapters.storage"] = storage
	package.loaded["settings.engine.scope.script_settings"] = nil
	local settings = require("settings.engine.scope.script_settings")
	settings.apply("INFO")
	local factory = assert(load("return function(ScriptSettings, Logger, rebuild_tray_menu) local LOG = 'menu'; return function(lvl)"
		.. body .. "\nend end", "actual-daemon-log-level"))()
	local callback = factory(settings, logger, function() observed.rebuilds = observed.rebuilds + 1 end)
	for key, name in pairs({ storage = "core.fs.adapters.storage", logger = "core.logger.engine.shim", settings = "settings.engine.scope.script_settings" }) do
		package.loaded[name] = previous[key]
	end
	return function(value)
		local saved_scope, saved_settings = package.loaded["settings.engine.scope.script_scope"], package.loaded["settings.engine.scope.script_settings"]
		local saved_shim, saved_logger = package.loaded["core.logger.engine.shim"], package.loaded["core.logger.engine"]
		package.loaded["settings.engine.scope.script_settings"], package.loaded["core.logger.engine.shim"], package.loaded["core.logger.engine"] = settings, logger, logger
		-- The transaction owns persistence followed by publication to the real settings owner.
		package.loaded["settings.engine.scope.script_scope"] = { retry_edit = function() return true end, edit_setting = function(key, level)
			if storage.set(key, level) ~= true then return false end
			local token = { pending = function() return false end }
			assert(settings.scope_acquire(token))
			local captured = assert(settings.scope_capture(token))
			local applied = settings.scope_apply(token, captured, level)
			assert(settings.scope_release(token)); assert(settings.scope_forget(token, captured))
			return applied
		end }
		local ok, result = pcall(callback, value)
		package.loaded["settings.engine.scope.script_scope"], package.loaded["settings.engine.scope.script_settings"] = saved_scope, saved_settings
		package.loaded["core.logger.engine.shim"], package.loaded["core.logger.engine"] = saved_shim, saved_logger
		if not ok then error(result, 0) end
		observed.selected = settings.current()
		return result
	end, observed
end

helpers.describe("Linux Debug « Detailed log » switch", function()
	local LevelSetting = require("core.logger.engine.level_setting")
	local entry = require("menu.engine.manifest_reader").find_entry_by_path("script.log_level")
	for _, case in ipairs(cases()) do
		-- The live level is always a declared name: replay the cases that name one.
		local selected = type(case.stored) == "string" and LevelSetting.canonical(case.stored, entry) or nil
		if selected then
			helpers.it("ticks and asks for the shared level: " .. case.id, function()
				local observed = {}
				local row = build(selected, function(value) observed[#observed + 1] = value; return true end)
				helpers.assert_nil(row.menu, "the detailed log is one switch, not a submenu")
				helpers.assert_eq(row.checked == true, case.ticked)
				helpers.assert_eq(row.fn(), true)
				helpers.assert_eq(observed, { case.click_stores })
			end)
		end
	end

	for _, receipt in ipairs({ "false", "nil", "true" }) do
		helpers.it("returns the actual daemon owner receipt for storage " .. receipt, function()
			local setter, observed = native_owner(receipt)
			local row = build(observed.selected, setter)
			helpers.assert_eq(row.checked == true, false, "INFO reads as an unticked detailed log")
			helpers.assert_eq(row.fn(), receipt == "true")
			helpers.assert_eq(observed.requested, "DEBUG")
			helpers.assert_eq(observed.detached, 20)
			helpers.assert_eq(observed.selected, receipt == "true" and "DEBUG" or "INFO")
			helpers.assert_eq(observed.threshold, receipt == "true" and 10 or 20)
			helpers.assert_eq(observed.durable["script.log_level"], observed.selected)
			helpers.assert_eq(observed.durable.future, 42)
			helpers.assert_eq(observed.rebuilds, receipt == "true" and 1 or 0)
		end)
	end

end)



--- Runs the shared source-presence contract through the actual complete native tray.
--- @param body function Independent native row/source assertions.
local function debug_parent_fixture(body)
	-- These real modules capture one another. A preceding registered fixture may
	-- reload locale alone; retain a fresh coherent native chain for this case.
	local names = { "core.i18n.engine.core", "core.i18n.engine.locale", "core.i18n.engine.i18n", "menu.engine.manifest_menu", "menu.ui.builder.builder" }
	local previous, original_i18n_safe = {}, rawget(_G, "i18n_safe")
	for module, value in pairs(package.loaded) do previous[module] = value end
	for _, module in ipairs(names) do rawset(package.loaded, module, nil) end
	local completed, failure = xpcall(function()
	-- Complete the genuine discovery/read phase before a requested test locale;
	-- the Language child must not lazily initialize it back to the saved locale.
	require("core.i18n.engine.i18n").init()
	local native = helpers.load_module("menu.ui.builder.builder")
	local renderer, locale = require("menu.engine.manifest_menu"), require("core.i18n.engine.locale")
	local language = locale.current_locale()
	local callbacks = {}
	local function setter(value) callbacks[#callbacks + 1] = value; return false end
	local context = { log_level = "INFO", on_set_log_level = setter,
		on_toggle_pause = function() end, on_quit = function() end,
		config = { get_groups = function() return {} end, get_categories = function() return {} end,
			language_packs = function() return {} end, resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
			get_base_delay = function() return 0.75 end, has_base_delay_override = function() return false end } }
	local function build(paused) context.paused = paused; return native.build(context) end
	local ok, detail = xpcall(function() body(renderer, build, callbacks, locale) end, debug.traceback)
	locale.set_locale(language)
	if not ok then error(detail, 0) end
	end, debug.traceback)
	for module in pairs(package.loaded) do if previous[module] == nil then rawset(package.loaded, module, nil) end end
	for module, value in pairs(previous) do rawset(package.loaded, module, value) end
	rawset(_G, "i18n_safe", original_i18n_safe)
	helpers.assert_true(rawequal(rawget(_G, "i18n_safe"), original_i18n_safe))
	for _, module in ipairs(names) do helpers.assert_true(rawequal(rawget(package.loaded, module), previous[module]), module) end
	if not completed then error(failure, 0) end
end

local debug_parent_file = assert(io.open(require("core.fs.engine.paths").shared("tests/corpus/menus/debug_parent.json"), "rb"))
local debug_parent_raw = debug_parent_file:read("*a")
debug_parent_file:close()
require("tests.lua.debug_parent_contract").register(helpers, debug_parent_fixture,
	assert(require("core.text.engine.json").decode(debug_parent_raw)), "linux")

return true
