--- static/ergopti_plus/macos/tests/unit/menu/ui/about/test_log_level_emojis.lua
---
--- DESCRIPTION:
--- « Detailed log » replaced the log-level selector of the Debug menu
--- (maintainer, 2026-11-24): the real builder ticks it from the shared
--- detailed_log cases and a click asks the actual settings owner for DEBUG or
--- the default. The settings owner keeps its threshold and cached menu on a
--- refusal.

local helpers = require("tests.helpers")

--- The « Detailed log » cases the three drivers replay.
--- @return table cases
local function detailed_cases()
	local file = assert(io.open(helpers.shared("tests/corpus/logger/parity_vectors.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("core.fs.adapters.json_codec").decode(raw)).detailed_log.cases
end

--- Builds the actual Debug « Detailed log » row with its real logger threshold.
--- @param value string Severity name.
--- @param setter function Existing native assignment owner.
--- @return table row
local function detailed_row(value, setter)
	local logger = require("core.logger.engine.logger")
	helpers.admit_logger_privacy(logger)
	logger.set_level(value)
	local rows = helpers.load_with_stubs("menu.ui.builder.builder").generate({}, {}, { set_log_level = setter })
	local label = require("core.i18n.engine.i18n").get("menu.debug.detailed_log")
	for _, top in ipairs(rows) do
		for _, row in ipairs(top.menu or {}) do
			if row.title == label then return row end
		end
	end
	error("the declared Debug « Detailed log » row is missing")
end

helpers.describe("macOS Debug « Detailed log » switch", function()
	local LevelSetting = require("core.logger.engine.level_setting")
	local entry = require("menu.engine.manifest_reader").find_entry_by_path("script.log_level")
	for _, case in ipairs(detailed_cases()) do
		-- The live level is always a declared name: replay the cases that name one.
		local selected = type(case.stored) == "string" and LevelSetting.canonical(case.stored, entry) or nil
		if selected then
			helpers.it("ticks and asks for the shared level: " .. case.id, function()
				local logger, observed = require("core.logger.engine.logger"), {}
				local previous = logger.current_level
				local ok, detail = pcall(function()
					local row = detailed_row(selected, function(value) observed[#observed + 1] = value; return true end)
					helpers.assert_nil(row.menu, "the detailed log is one switch, not a submenu")
					helpers.assert_eq(row.checked == true, case.ticked)
					helpers.assert_eq(row.fn(), true)
					helpers.assert_eq(observed, { case.click_stores })
				end)
				logger.current_level = previous
				if not ok then error(detail, 0) end
			end)
		end
	end

	helpers.it("returns the settings owner's refusal without moving the threshold", function()
		local logger, requested = require("core.logger.engine.logger"), nil
		local previous = logger.current_level
		local ok, detail = pcall(function()
			local row = detailed_row("INFO", function(value) requested = value; return false end)
			helpers.assert_eq(row.checked == true, false, "INFO reads as an unticked detailed log")
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(requested, "DEBUG")
			helpers.assert_eq(logger.current_level, logger.LEVELS.INFO)
		end)
		logger.current_level = previous
		if not ok then error(detail, 0) end
	end)
end)

--- Exercises the action captured from the real ui.menu.start over isolated settings.
--- @param receipt string Settings receipt mode.
local function check_log_commit(receipt)
	local saved = {}
	for key, value in pairs(package.loaded) do saved[key] = value end
	local saved_hs = _G.hs
	local storage_owner, previous_storage_set
	local ok, detail = pcall(function()
		local fixture = require("tests.support.menu_boot_fixture").boot()
		local actions = fixture.global_actions()
		local logger, storage = require("core.logger.engine.logger"), require("core.fs.adapters.storage")
		storage_owner, previous_storage_set = storage, storage.set
		local threshold, writes, published, rebuilt = "INFO", 0, 0, 0
		local stored_key, stored_value, detached_threshold
		local bytes = 'log_level = "INFO"\nfuture = 42\n'
		local before = bytes
		logger.set_level = function(value) threshold = value; published = published + 1 end
		storage.set = function(key, value)
			writes = writes + 1
			stored_key, stored_value, detached_threshold = key, value, threshold
			if receipt == "throw" then error("settings unavailable") end
			if receipt == "false" then return false end
			if receipt == "nil" then return nil end
			bytes = 'log_level = "ERROR"\nfuture = 42\n'
			return true
		end
		local builder = package.loaded["menu.ui.builder.builder"]
		builder.generate = function() rebuilt = rebuilt + 1; return {} end
		-- Prime the cached tree before this click: a refused owner must keep it.
		fixture.menu_provider()
		rebuilt = 0
		local result = actions.set_log_level("ERROR")
		local observed = { result = result, threshold = threshold, writes = writes,
			published = published, bytes = bytes }
		fixture.menu_provider()
		helpers.assert_eq(observed.writes, 1)
		helpers.assert_eq(stored_key, "log_level")
		helpers.assert_eq(stored_value, "ERROR")
		helpers.assert_eq(detached_threshold, "INFO", "candidate threshold stays detached during durable I/O")
		if receipt == "true" then
			helpers.assert_eq(observed.result, true)
			helpers.assert_eq(observed.threshold, "ERROR")
			helpers.assert_eq(observed.published, 1)
			helpers.assert_eq(observed.bytes, 'log_level = "ERROR"\nfuture = 42\n')
			helpers.assert_eq(rebuilt, 1, "an acknowledged choice invalidates the cached tree")
		else
			helpers.assert_eq(observed.result, false)
			helpers.assert_eq(observed.threshold, "INFO")
			helpers.assert_eq(observed.published, 0)
			helpers.assert_eq(observed.bytes, before)
			helpers.assert_eq(rebuilt, 0, "a refused choice preserves the cached tree")
		end
	end)
	if storage_owner then storage_owner.set = previous_storage_set end
	for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(saved) do package.loaded[key] = value end
	_G.hs = saved_hs
	if not ok then error(detail, 0) end
end

helpers.describe("macOS actual Debug settings owner", function()
	for _, receipt in ipairs({ "false", "nil", "throw" }) do
		helpers.it("preserves threshold and cached UI on settings " .. receipt, function() check_log_commit(receipt) end)
	end
	helpers.it("publishes the threshold and invalidates UI only after acknowledged settings", function() check_log_commit("true") end)
end)


--- Runs the shared source-presence contract through the actual complete native tray.
--- @param body function Independent native row/source assertions.
local function debug_parent_fixture(body)
	local saved = {}
	for _, name in ipairs({ "menu.ui.builder.builder", "core.i18n.engine.i18n", "core.i18n.engine.locale", "menu.engine.manifest_menu" }) do saved[name] = package.loaded[name] end
	helpers.load_with_stubs("core.fs.engine.paths")
	for _, name in ipairs({ "menu.ui.builder.builder", "core.i18n.engine.i18n", "core.i18n.engine.locale", "menu.engine.manifest_menu" }) do package.loaded[name] = nil end
	local native = require("menu.ui.builder.builder")
	local renderer, locale = require("menu.engine.manifest_menu"), require("core.i18n.engine.locale")
	local language = locale.current_locale()
	local callbacks = {}
	local function setter(value) callbacks[#callbacks + 1] = value; return false end
	local logger = require("core.logger.engine.logger")
	helpers.admit_logger_privacy(logger)
	local threshold = logger.current_level
	logger.set_level("INFO")
	local actions = { set_log_level = setter }
	for _, name in ipairs({ "open_console", "open_logs", "open_today_log", "open_error_log", "toggle_error_dialog" }) do
		local action = name
		actions[action] = function() callbacks[#callbacks + 1] = action; return false end
	end
	local function build(paused) return native.generate({ paused = paused }, {}, actions) end
	local ok, detail = xpcall(function() body(renderer, build, callbacks, locale, logger) end, debug.traceback)
	locale.set_locale(language)
	logger.current_level = threshold
	for _, name in ipairs({ "menu.ui.builder.builder", "core.i18n.engine.i18n", "core.i18n.engine.locale", "menu.engine.manifest_menu" }) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
end

local debug_parent_file = assert(io.open(require("core.fs.engine.paths").shared("tests/corpus/menus/debug_parent.json"), "rb"))
local debug_parent_raw = debug_parent_file:read("*a")
debug_parent_file:close()
require("tests.lua.debug_parent_contract").register(helpers, debug_parent_fixture,
	assert(require("core.fs.adapters.json_codec").decode(debug_parent_raw)), "hs")
