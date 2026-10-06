--- tests/unit/infra/test_global_scope.lua

--- ==============================================================================
--- MODULE: Global Scope (Linux)
--- DESCRIPTION:
--- Configuration › « Restore recommended values » and « Clear all » compose
--- the daemon's live scope owners, all or nothing and without a question:
--- they register only the owners the daemon runs, report the categories they
--- have no owner for, and revert a real committed owner when a later category
--- refuses.
--- ==============================================================================

local helpers = require("tests.helpers")
local Codec = require("toml_codec")

local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")
local OWNER_MODULES = { "infra.tap_hold_scope", "infra.shortcuts_scope", "infra.llm_scope", "infra.metrics_scope",
	"infra.hotstrings_scope", "infra.script_scope" }

--- A stub participant journaling into a shared trace.
local function stub(trace, name, refuse)
	local participant = {}
	function participant.apply(mode, done)
		trace[#trace + 1] = name .. ":" .. mode
		if refuse then return done(false, name .. " refused") end
		return done(true)
	end
	function participant.revert(done) trace[#trace + 1] = name .. ":revert"; return done(true) end
	function participant.release() trace[#trace + 1] = name .. ":release" end
	function participant.pending() return false end
	function participant.retry_restore(done) return done(true) end
	return participant
end

--- Runs body with fresh global and owner modules, restoring them afterwards.
local function with_modules(body)
	local saved = {}
	for _, name in ipairs(OWNER_MODULES) do saved[name] = package.loaded[name] end
	saved["infra.global_scope"] = package.loaded["infra.global_scope"]
	package.loaded["infra.global_scope"] = nil
	local ok, err = pcall(body)
	for _, name in ipairs(OWNER_MODULES) do package.loaded[name] = saved[name] end
	package.loaded["infra.global_scope"] = saved["infra.global_scope"]
	if not ok then error(err, 0) end
end

helpers.describe("Linux global scope: registry and composition", function()
	helpers.it("registers only the owners the daemon runs", function()
		with_modules(function()
			local trace = {}
			for _, name in ipairs(OWNER_MODULES) do
				package.loaded[name] = { participant = function(is_paused)
					helpers.assert_eq(is_paused(), false)
					return stub(trace, name)
				end }
			end
			local GlobalScope = require("infra.global_scope")
			local registry = GlobalScope.participants({ tap_holds = {}, llm = {}, is_paused = function() return false end })
			local ids = {}
			for id in pairs(registry) do ids[#ids + 1] = id end
			table.sort(ids)
			helpers.assert_eq(ids, { "global", "llm", "tap_holds" })
			local gestures = { scope_participant = function() return stub(trace, "gestures") end,
				scope_available = function() return true end }
			registry = GlobalScope.participants({ shortcuts = {}, gestures = gestures, keylogger = {} })
			ids = {}
			for id in pairs(registry) do ids[#ids + 1] = id end
			table.sort(ids)
			helpers.assert_eq(ids, { "gestures", "metrics", "shortcuts" })
		end)
	end)

	helpers.it("skips the gestures of a machine without a touchpad instead of refusing the row", function()
		local names = { "modules.gestures.touchpad_finder", "modules.gestures.manager" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		package.loaded["modules.gestures.touchpad_finder"] = {
			find = function() return nil, "no device reports multitouch slots" end,
		}
		package.loaded["modules.gestures.manager"] = nil
		local ok, err = pcall(with_modules, function()
			package.loaded["infra.script_scope"] = { participant = function() return stub({}, "global") end }
			local Manager = require("modules.gestures.manager")
			helpers.assert_eq(Manager.scope_available(), false)
			local GlobalScope = require("infra.global_scope")
			local registry = GlobalScope.participants({ gestures = Manager, is_paused = function() return false end })
			helpers.assert_nil(registry.gestures, "a gesture reader that cannot start refuses every restore")
			registry.tap_holds = stub({}, "tap_holds")
			local committed, report = GlobalScope.apply("recommended", registry)
			helpers.assert_eq(committed, true, report.detail)
			helpers.assert_eq(report.skipped[2], "gestures")
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)

	helpers.it("applies the manifest order and reports every category without an owner", function()
		with_modules(function()
			local trace = {}
			local GlobalScope = require("infra.global_scope")
			local committed, report = GlobalScope.apply("recommended", {
				metrics = stub(trace, "metrics"), tap_holds = stub(trace, "tap_holds"), llm = stub(trace, "llm") })
			helpers.assert_eq(committed, true, report.detail)
			helpers.assert_eq(trace, { "tap_holds:recommended", "llm:recommended", "metrics:recommended",
				"tap_holds:release", "llm:release", "metrics:release" })
			helpers.assert_eq(report.skipped, { "shortcuts", "gestures", "keyboard_layout", "hotstrings", "global" })
		end)
	end)

	helpers.it("retries a pending rollback before the next request and refuses while it stays", function()
		with_modules(function()
			local trace, stuck = {}, true
			local GlobalScope = require("infra.global_scope")
			local tap_holds = stub(trace, "tap_holds")
			tap_holds.revert = function(done) trace[#trace + 1] = "tap_holds:revert"; return done(not stuck) end
			local committed, report = GlobalScope.apply("clear", { tap_holds = tap_holds, llm = stub(trace, "llm", true) })
			helpers.assert_eq(committed, false)
			helpers.assert_eq(report.reverted, false)
			committed, report = GlobalScope.apply("clear", { tap_holds = stub(trace, "other") })
			helpers.assert_eq(committed, false)
			helpers.assert_true(report.detail:find("pending", 1, true) ~= nil, report.detail)
			stuck = false
			committed = GlobalScope.apply("clear", { tap_holds = stub(trace, "fresh") })
			helpers.assert_eq(committed, true)
			helpers.assert_eq(trace, { "tap_holds:clear", "llm:clear", "tap_holds:revert", "tap_holds:revert",
				"tap_holds:revert", "fresh:clear", "fresh:release" })
		end)
	end)
end)

helpers.describe("Linux global scope: hotstrings", function()
	-- The interim participant only reopened the category gates; the real owner
	-- restores both hotstring files and needs the daemon's live runtimes.
	helpers.it("registers the hotstrings scope owner with the daemon's runtimes", function()
		with_modules(function()
			local seen, participant = nil, stub({}, "hotstrings")
			package.loaded["infra.hotstrings_scope"] = {
				participant = function(is_paused, ports)
					seen = { paused = is_paused(), ports = ports }
					return participant
				end,
			}
			local dynamic, preview = {}, {}
			local registry = require("infra.global_scope").participants({ config = {}, dyn_hotstrings = dynamic,
				tooltip_preview = preview, is_paused = function() return false end })
			helpers.assert_true(registry.hotstrings == participant, "hotstrings take part through their scope owner")
			helpers.assert_not_nil(seen, "the owner's participant was asked for")
			helpers.assert_eq(seen.paused, false)
			helpers.assert_true(seen.ports.dynamic == dynamic, "the dynamic runtime reaches the owner")
			helpers.assert_true(seen.ports.preview == preview, "the preview runtime reaches the owner")
		end)
	end)

	helpers.it("leaves hotstrings out when the daemon runs none", function()
		with_modules(function()
			package.loaded["infra.hotstrings_scope"] = {
				participant = function() error("no hotstrings owner without a hotstrings configuration") end,
			}
			local registry = require("infra.global_scope").participants({ is_paused = function() return false end })
			helpers.assert_nil(registry.hotstrings)
		end)
	end)
end)

helpers.describe("Linux global scope: the Configuration row", function()
	--- Builds the tray and returns the Configuration restore row, with zenity
	--- answering `answer` and the global scope recorded.
	local function restore_row(ctx, calls)
		package.loaded["infra.global_scope"] = {
			participants = function() calls[#calls + 1] = "participants"; return {} end,
			apply = function(mode) calls[#calls + 1] = mode; return true, { reverted = nil } end,
		}
		package.loaded["ui.menu.menu_builder"] = nil
		local items = require("ui.menu.menu_builder").build(ctx)
		local i18n = require("infra.i18n")
		for _, item in ipairs(items) do
			if item.title == i18n.get("menu.configuration.title") then
				for _, row in ipairs(item.menu or {}) do
					if row.title == i18n.get("common.restore_recommended") then return row end
				end
			end
		end
		return nil
	end

	-- The restore used to ask a default-No question first; the maintainer
	-- retired it (restore-recommended-no-confirm). Zenity answers No here, so a
	-- question that came back would also stop the composition.
	helpers.it("composes at once and asks nothing", function()
		local saved_builder, saved_global = package.loaded["ui.menu.menu_builder"], package.loaded["infra.global_scope"]
		local execute, asked, calls = os.execute, {}, {}
		local ok, err = pcall(function()
			local row = restore_row({ _version = "test", on_quit = function() end,
				is_paused = function() return false end }, calls)
			helpers.assert_not_nil(row, "the Configuration restore row")
			os.execute = function(command)
				if command:find("command -v zenity", 1, true) then return 0 end
				if command:find("zenity --question", 1, true) then asked[#asked + 1] = command; return 1 end
				return execute(command)
			end
			row.fn()
		end)
		os.execute = execute
		package.loaded["ui.menu.menu_builder"], package.loaded["infra.global_scope"] = saved_builder, saved_global
		if not ok then error(err, 0) end
		helpers.assert_eq(#asked, 0, "restoring the recommended values asks nothing")
		helpers.assert_eq(calls, { "participants", "recommended" })
	end)

	helpers.it("refuses while paused without asking", function()
		local saved_builder, saved_global = package.loaded["ui.menu.menu_builder"], package.loaded["infra.global_scope"]
		local execute, calls, asked = os.execute, {}, 0
		local ok, err = pcall(function()
			local row = restore_row({ _version = "test", on_quit = function() end,
				is_paused = function() return true end }, calls)
			os.execute = function(command)
				if command:find("zenity", 1, true) then asked = asked + 1; return 0 end
				return execute(command)
			end
			row.fn()
		end)
		os.execute = execute
		package.loaded["ui.menu.menu_builder"], package.loaded["infra.global_scope"] = saved_builder, saved_global
		if not ok then error(err, 0) end
		helpers.assert_eq(asked, 0)
		helpers.assert_eq(calls, {})
	end)
end)

--- Runs body with the real tap-hold manager over an isolated configuration
--- folder whose tap_hold.toml holds `source`.
--- @param source string The tap-hold file's bytes.
--- @param body function Receives the manager, the folder, tap_hold.toml's path and config.toml's path.
local function with_real_tap_holds(source, body)
	local names = { "platform.remap.tap_hold_manager", "platform.remap.tap_hold_loader",
		"platform.remap.tap_hold_writer", "infra.tap_hold_scope", "infra.config_paths", "infra.global_scope",
		"ui.menu.menu_builder" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local dir = os.tmpname()
	os.remove(dir)
	local made = os.execute('mkdir "' .. dir .. '"')
	assert(made == true or made == 0, "the isolated configuration folder must exist")
	local tap_path, config_path = dir .. "/tap_hold.toml", dir .. "/config.toml"
	local fh = assert(io.open(tap_path, "w"))
	fh:write(source)
	fh:close()
	local ok, err = pcall(function()
		-- Only config.toml's folder moves; the tray's other readers keep the real paths.
		local real_paths = require("infra.config_paths")
		package.loaded["infra.config_paths"] = setmetatable(
			{ config = function(name) return dir .. "/" .. name end }, { __index = real_paths })
		local Manager = require("platform.remap.tap_hold_manager")
		Manager.init({
			keyboard_hook = { set_remapper = function() end, key_text = function() return nil end,
				held_modifiers = function() return {} end, held_text_modifier_codes = function() return {} end,
				held_shortcut_modifier_codes = function() return {} end },
			execute_action = function() end, on_text_injected = function() end,
			action_names = function() return {} end, defaults_path = DEFAULTS, user_path = tap_path,
		})
		body(Manager, dir, tap_path, config_path)
		Manager._reset_for_test()
	end)
	os.execute('rm -f "' .. dir .. '"/* && rmdir "' .. dir .. '"')
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Reads one whole file.
--- @param path string
--- @return string|nil content
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

helpers.describe("Linux global scope: the Configuration clear", function()
	-- « Tout effacer » beside the restore since 2026-09-30: the same
	-- composition in clear mode, one transaction whose owners back up first.
	helpers.it("clears the real tap-hold file to neutral after its backup, without a question", function()
		local source = '[tap_hold]\ninherit_defaults = true\n[other]\nkeep = true\n'
		with_real_tap_holds(source, function(Manager, dir, tap_path)
			local execute, asked = os.execute, 0
			local ran, raised = pcall(function()
				os.execute = function(command)
					if command:find("zenity", 1, true) then asked = asked + 1; return 1 end
					return execute(command)
				end
				local i18n = require("infra.i18n")
				local items = require("ui.menu.menu_builder").build({ _version = "test", on_quit = function() end,
					is_paused = function() return false end, tap_holds = Manager })
				local rows
				for _, item in ipairs(items) do
					if item.title == i18n.get("menu.configuration.title") then rows = item.menu end
				end
				helpers.assert_true(type(rows) == "table", "the Configuration submenu")
				helpers.assert_eq(rows[1].title, i18n.get("common.restore_recommended"))
				helpers.assert_eq(rows[2].title, i18n.get("common.clear_to_system"))
				rows[2].fn()
			end)
			os.execute = execute
			if not ran then error(raised, 0) end
			helpers.assert_eq(asked, 0, "the global clear asks nothing")
			local after = Codec.decode(read_file(tap_path))
			helpers.assert_true(after.tap_hold == nil or after.tap_hold.inherit_defaults ~= true,
				"the preset is no longer inherited")
			helpers.assert_true(after.tap_hold == nil or after.tap_hold.keys == nil or next(after.tap_hold.keys) == nil,
				"no key is remapped any more")
			helpers.assert_eq(after.other.keep, true)
			local listing = io.popen('ls "' .. dir .. '"')
			local backups = {}
			for name in listing:lines() do
				if name:find("^tap_hold%.toml%.tap_holds%-.*%.bak$") then backups[#backups + 1] = name end
			end
			listing:close()
			helpers.assert_eq(#backups, 1, "the tap-hold file is backed up before the clear")
			helpers.assert_eq(read_file(dir .. "/" .. backups[1]), source)
		end)
	end)

	helpers.it("puts the cleared tap-hold file back byte for byte when a later category refuses", function()
		local source = '[tap_hold]\ninherit_defaults = true\n[other]\nkeep = true\n'
		with_real_tap_holds(source, function(_, _, tap_path, config_path)
			local trace = {}
			local GlobalScope = require("infra.global_scope")
			local committed, report = GlobalScope.apply("clear", {
				tap_holds = require("infra.tap_hold_scope").participant(function() return false end),
				llm = stub(trace, "llm", true),
			})
			helpers.assert_eq(committed, false)
			helpers.assert_eq(report.failed, "llm")
			helpers.assert_eq(report.applied, { "tap_holds" })
			helpers.assert_eq(report.reverted, true)
			helpers.assert_eq(read_file(tap_path), source, "the cleared tap-hold file is put back")
			helpers.assert_nil(read_file(config_path), "config.toml was never created")
		end)
	end)
end)

helpers.describe("Linux global scope: a real owner is reverted", function()
	helpers.it("puts the real tap-hold files and engine back when a later category refuses", function()
		local names = { "platform.remap.tap_hold_manager", "platform.remap.tap_hold_loader",
			"platform.remap.tap_hold_writer", "infra.tap_hold_scope", "infra.config_paths", "infra.global_scope" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		local dir = os.tmpname()
		os.remove(dir)
		local made = os.execute('mkdir "' .. dir .. '"')
		assert(made == true or made == 0, "the isolated configuration folder must exist")
		local tap_path, config_path = dir .. "/tap_hold.toml", dir .. "/config.toml"
		local source = '[tap_hold]\nenabled = false\n[other]\nkeep = true\n'
		local fh = assert(io.open(tap_path, "w"))
		fh:write(source)
		fh:close()
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function(name) return dir .. "/" .. name end }
			local Manager = require("platform.remap.tap_hold_manager")
			Manager.init({
				keyboard_hook = { set_remapper = function() end, key_text = function() return nil end,
					held_modifiers = function() return {} end, held_text_modifier_codes = function() return {} end,
					held_shortcut_modifier_codes = function() return {} end },
				execute_action = function() end, on_text_injected = function() end,
				action_names = function() return {} end, defaults_path = DEFAULTS, user_path = tap_path,
			})
			local trace = {}
			local GlobalScope = require("infra.global_scope")
			local committed, report = GlobalScope.apply("recommended", {
				tap_holds = require("infra.tap_hold_scope").participant(function() return false end),
				llm = stub(trace, "llm", true),
			})
			helpers.assert_eq(committed, false)
			helpers.assert_eq(report.failed, "llm")
			helpers.assert_eq(report.applied, { "tap_holds" })
			helpers.assert_eq(report.reverted, true)
			local check = assert(io.open(tap_path, "r"))
			local after = check:read("*a")
			check:close()
			helpers.assert_eq(after, source, "the committed tap-hold file is put back byte for byte")
			helpers.assert_eq(Manager.file_enabled(), false)
			helpers.assert_eq(Manager.is_active(), false)
			helpers.assert_nil(io.open(config_path, "r"), "config.toml was never created")
			helpers.assert_eq(Codec.decode(after).other.keep, true)
			Manager._reset_for_test()
		end)
		os.execute('rm -f "' .. dir .. '"/* && rmdir "' .. dir .. '"')
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end)

return true
