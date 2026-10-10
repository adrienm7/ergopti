--- static/ergopti_plus/macos/tests/unit/ui/menu/test_log_level_emojis.lua
---
--- DESCRIPTION:
--- Verifies that log level menu items include their respective emojis.

local helpers = require("tests.helpers")

helpers.describe("Menu — log level emojis", function()
	local builder = helpers.load_with_stubs("ui.menu.builder")
	local i18n    = require("infra.i18n")
	local Logger  = require("infra.logger")

	helpers.admit_logger_privacy(Logger)
	helpers.it("includes correct emojis in log level selection labels", function()
		local old_level = Logger.current_level
		Logger.set_level("INFO")

		-- We need to mock the environment for build_debug_menu
		local actions = {
			set_log_level = function() end,
			open_logs = function() end,
			open_today_log = function() end,
			open_error_log = function() end,
			open_console = function() end,
			open_today_log = function() end,
			open_error_log = function() end,
			show_setup_wizard = function() end,
			open_paths = function() end,
			reload = function() end,
			quit = function() end,
		}
		
		-- Mock i18n.get to return keys for easier verification
		local i18n = require("infra.i18n")
		local old_get = i18n.get
		i18n.get = function(k) return k end
		-- Also need this for builder.lua line 488
		i18n.build_language_menu_items = function() return {} end
		
		-- Trigger menu building via M.generate
		local ctx = {
			config = { log_level = 2 }, -- INFO
		}
		local menu_mods = {}
		local menu = builder.generate(ctx, menu_mods, actions)
		
		-- Find the Debug menu first
		local debug_menu_item = nil
		for _, item in ipairs(menu) do
			if item.title == "menu.debug.title" then
				debug_menu_item = item
				break
			end
		end
		helpers.assert_true(debug_menu_item ~= nil, "debug menu item should exist")

		-- Find the Log level item within the Debug menu
		local log_level_item = nil
		-- In builder.lua, load_debug_menu falls back to DEBUG_MENU_FALLBACK
		-- which has "log_level" at index 3 (after console and ---)
		for _, item in ipairs(debug_menu_item.menu) do
			if item.title:find("menu.debug.log_level") then
				log_level_item = item
				break
			end
		end
		
		helpers.assert_true(log_level_item ~= nil, "log level submenu item should exist")
		
		-- Check the parent label (it should now have an emoji)
		local current_lvl_name = "INFO" -- Default in logger.lua mock or real
		local expected_parent_prefix = "menu.debug.log_level : "
		helpers.assert_true(log_level_item.title:find(expected_parent_prefix) ~= nil, "parent label should contain the key")
		helpers.assert_true(log_level_item.title:find("ℹ️") ~= nil, "parent label should contain the emoji for INFO")
		
		-- Check submenu items
		local sub_menu = log_level_item.menu
		local found = { DEBUG = false, INFO = false, WARNING = false, ERROR = false }
		local emojis = { DEBUG = "🐛", INFO = "ℹ️", WARNING = "⚠️", ERROR = "❌" }
		
		for _, item in ipairs(sub_menu) do
			for lvl, emoji in pairs(emojis) do
				if item.title:find(lvl) then
					helpers.assert_true(item.title:find(emoji) ~= nil, "item " .. lvl .. " should have emoji " .. emoji)
					found[lvl] = true
				end
			end
		end
		
		for lvl, ok in pairs(found) do
			helpers.assert_true(ok, "log level " .. lvl .. " item was not found in submenu")
		end
		
		i18n.get = old_get
		Logger.current_level = old_level
	end)
end)

--- Reads the independent four-state presentation captured before migration.
--- @return table corpus
local function log_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/log_level_rows.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("adapters.json_codec").decode(raw))
end

--- Builds the actual Debug row with its real logger threshold.
--- @param value string Severity name.
--- @param setter function Existing native assignment owner.
--- @return table row
local function log_row(value, setter)
	local logger = require("infra.logger")
	helpers.admit_logger_privacy(logger)
	logger.set_level(value)
	local rows = helpers.load_with_stubs("ui.menu.builder").generate({}, {}, { set_log_level = setter })
	local label = require("infra.i18n").get("menu.debug.log_level")
	for _, top in ipairs(rows) do
		for _, row in ipairs(top.menu or {}) do
			if row.title and row.title:find(label, 1, true) == 1 then return row end
		end
	end
	error("the declared Debug log-level parent is missing")
end

helpers.describe("macOS shared Debug log choices", function()
	for _, state in ipairs(log_corpus().states) do
		helpers.it("replays the independent four-state matrix for " .. state.selected, function()
			local logger, observed = require("infra.logger"), {}
			local previous = logger.current_level
			local ok, detail = pcall(function()
				local row = log_row(state.selected, function(value) observed[#observed + 1] = value; return true end)
				helpers.assert_eq(#row.menu, 4)
				for index, level in ipairs(log_corpus().levels) do
					helpers.assert_eq(row.menu[index].title, level.label)
					helpers.assert_eq(row.menu[index].checked == true, state.checked[index])
					if level.value == state.selected then
						helpers.assert_eq(row.title, require("infra.i18n").get("menu.debug.log_level") .. " : " .. level.label)
					end
					helpers.assert_eq(row.menu[index].fn(), true)
				end
				helpers.assert_eq(observed, { "DEBUG", "INFO", "WARNING", "ERROR" })
			end)
			logger.current_level = previous
			if not ok then error(detail, 0) end
		end)
	end

	helpers.it("follows the actual shared order without treating refusal as success", function()
		local renderer, logger = require("infra.manifest_menu"), require("infra.logger")
		local declaration
		for _, row in ipairs(renderer.get_root().debug_menu) do if row.id == "log_level" then declaration = row end end
		local previous, threshold = declaration.choices, logger.current_level
		local expected, labels, requested = log_corpus(), {}, nil
		for _, level in ipairs(expected.levels) do labels[level.value] = level.label end
		declaration.choices = {}
		for _, value in ipairs(expected.reordered_values) do
			declaration.choices[#declaration.choices + 1] = { value = value, label = labels[value] }
		end
		local ok, detail = pcall(function()
			local row = log_row("INFO", function(value) requested = value; return false end)
			for index, value in ipairs(expected.reordered_values) do helpers.assert_eq(row.menu[index].title, labels[value]) end
			helpers.assert_eq(row.menu[1].fn(), false)
			helpers.assert_eq(requested, "ERROR")
			helpers.assert_eq(logger.current_level, logger.LEVELS.INFO)
		end)
		declaration.choices, logger.current_level = previous, threshold
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
		local logger, storage = require("infra.logger"), require("adapters.storage")
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
		local builder = package.loaded["ui.menu.builder"]
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
	for _, receipt in ipairs(log_corpus().refusals) do
		helpers.it("preserves threshold and cached UI on settings " .. receipt, function() check_log_commit(receipt) end)
	end
	helpers.it("publishes the threshold and invalidates UI only after acknowledged settings", function() check_log_commit("true") end)
end)


--- Runs the shared source-presence contract through the actual complete native tray.
--- @param body function Independent native row/source assertions.
local function debug_parent_fixture(body)
	local saved = {}
	for _, name in ipairs({ "ui.menu.builder", "infra.i18n", "infra.locale", "infra.manifest_menu" }) do saved[name] = package.loaded[name] end
	helpers.load_with_stubs("infra.paths")
	for _, name in ipairs({ "ui.menu.builder", "infra.i18n", "infra.locale", "infra.manifest_menu" }) do package.loaded[name] = nil end
	local native = require("ui.menu.builder")
	local renderer, locale = require("infra.manifest_menu"), require("infra.locale")
	local language = locale.current_locale()
	local callbacks = {}
	local function setter(value) callbacks[#callbacks + 1] = value; return false end
	local logger = require("infra.logger")
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
	for _, name in ipairs({ "ui.menu.builder", "infra.i18n", "infra.locale", "infra.manifest_menu" }) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
end

local debug_parent_file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/debug_parent.json"), "rb"))
local debug_parent_raw = debug_parent_file:read("*a")
debug_parent_file:close()
require("test.debug_parent_contract").register(helpers, debug_parent_fixture,
	assert(require("adapters.json_codec").decode(debug_parent_raw)), "hs")
