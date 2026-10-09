--- tests/unit/meta/test_menu_prompt_cancel.lua
---
--- ==============================================================================
--- MODULE: Menu Prompt Cancel Regression Guard (Linux driver)
--- DESCRIPTION:
--- A zenity Cancel treated as an empty answer on LuaJIT.
---
--- ROOT CAUSE ENCODED:
--- A native Cancel must remain nil rather than an accepted empty string. Real
--- LuaJIT pipe close acknowledgements can be true despite a non-zero child exit;
--- ui/text_prompt.lua delegates that distinction to the checked shell owner.
--- This integration test retains the real rendered tap-hold delay callback:
--- cancellation never writes, while a confirmed 300 ms answer writes 0.3 s.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Calls the writer records while a scenario runs. Reset before each click.
local writer_calls = {}

--- Installs a fake tap-hold writer through the package cache and returns the
--- previous entry for unconditional restore. The menu requires the module at
--- build time, so the click reaches this spy instead of the filesystem.
--- @return any Previous package.loaded entry (possibly nil).
local function install_fake_writer()
	local previous = package.loaded["platform.remap.tap_hold_writer"]
	package.loaded["platform.remap.tap_hold_writer"] = {
		set_threshold = function(...)
			writer_calls[#writer_calls + 1] = { ... }
			return true
		end,
	}
	return previous
end

--- Runs fn with native dialog boundaries recording stdout and child exit status.
--- The public text prompt uses the checked shell authority; other dialog callers
--- keep their pipe seam. Both authorities are restored even on failure.
--- @param read_body string Dialog stdout.
--- @param close_status number Exit status number.
--- @param fn function Body to run inside the sandbox.
--- @return table Commands handed to io.popen.
local function with_zenity(read_body, close_status, fn)
	local real_popen = io.popen
	local shell = require("adapters.shell_runner")
	local real_checked = shell.exec_checked
	local commands = {}
	shell.exec_checked = function(command)
		if not command:find("zenity --entry", 1, true) then return real_checked(command) end
		commands[#commands + 1] = command
		return close_status == 0, read_body, close_status == 0 and nil or "command exited with status " .. close_status
	end
	io.popen = function(cmd)
		commands[#commands + 1] = tostring(cmd)
		return {
			read = function() return read_body end,
			lines = function()
				return function() return nil end
			end,
			close = function() return close_status end,
		}
	end
	local ok, err = pcall(fn)
	io.popen = real_popen
	shell.exec_checked = real_checked
	if not ok then error(err, 0) end
	return commands
end

--- Rendered-row children across the shapes the manifest renderer emits.
local function children_of(row)
	if type(row.menu) == "table" then return row.menu end
	if type(row.items) == "table" then return row.items end
	if type(row.submenu) == "table" then return row.submenu end
	return nil
end

--- Rendered-row callback across the shapes the manifest renderer emits.
local function callback_of(row)
	if type(row.fn) == "function" then return row.fn end
	if type(row.action) == "function" then return row.action end
	return nil
end

--- Finds the delay row's callback: the one leaf of a per-key submenu, two
--- levels down, whose click shells out to `zenity --entry`.
--- @param mb table The loaded menu builder.
--- @param manager table An initialised tap-hold manager.
--- @return function|nil
local function find_delay_row(mb, manager)
	local items = mb.build({ _version = "test", on_quit = function() end, tap_holds = manager })
	local title = require("infra.i18n").get("menu.tapholds.title")
	local section = nil
	for _, item in ipairs(items) do
		if item.title == title then section = item end
	end
	helpers.assert_true(section ~= nil, "Tap-Holds section present in menu")
	for _, key_row in ipairs(children_of(section) or {}) do
		for _, sub in ipairs(children_of(key_row) or {}) do
			for _, row in ipairs(children_of(sub) or {}) do
				local cb = callback_of(row)
				if cb and children_of(row) == nil then
					local commands = with_zenity("", 1, function() pcall(cb) end)
					for _, cmd in ipairs(commands) do
						if cmd:find("zenity", 1, true) and cmd:find("--entry", 1, true) then return cb end
					end
				end
			end
		end
	end
	return nil
end

--- A tap-hold manager on the shared defaults.
local function manager()
	local Manager = helpers.load_module("platform.remap.tap_hold_manager")
	local user_path = os.tmpname()
	os.remove(user_path)
	Manager.init({
		keyboard_hook = { set_remapper = function() end, key_text = function() return nil end,
			held_modifiers = function() return {} end,
			held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end },
		execute_action = function() end,
		on_text_injected = function() end,
		action_names = function() return {} end,
		defaults_path = require("infra.paths").shared("tap_hold/defaults.toml"),
		user_path = user_path,
	})
	return Manager
end

helpers.describe("menu_builder: zenity Cancel changes nothing (prompt-cancel)", function()

	helpers.it("prompt-cancel: cancelling the tap-hold delay prompt keeps the writer untouched", function()
		local previous = install_fake_writer()
		local th = manager()
		local ok, err = pcall(function()
			-- The builder captures TextPrompt at load time. Earlier adapter tests
			-- reload Shell, so bind this public owner to the current authority.
			helpers.load_module("ui.text_prompt")
			local mb = helpers.load_module("ui.menu.menu_builder")
			local delay = find_delay_row(mb, th)
			helpers.assert_true(delay ~= nil,
				"a delay row shelling out to zenity --entry must exist — "
					.. "without it this test proves nothing")
			-- The checked authority reports the real native exit-one cancellation.
			writer_calls = {}
			with_zenity("", 1, function() pcall(delay) end)
			helpers.assert_eq(#writer_calls, 0,
				"Cancel is not an empty answer — it must change nothing")
		end)
		th._reset_for_test()
		package.loaded["platform.remap.tap_hold_writer"] = previous
		if not ok then error(err, 0) end
	end)

	helpers.it("prompt-cancel: a confirmed delay is written in seconds", function()
		local previous = install_fake_writer()
		local th = manager()
		local ok, err = pcall(function()
			-- The builder captures TextPrompt at load time. Earlier adapter tests
			-- reload Shell, so bind this public owner to the current authority.
			helpers.load_module("ui.text_prompt")
			local mb = helpers.load_module("ui.menu.menu_builder")
			local delay = find_delay_row(mb, th)
			helpers.assert_true(delay ~= nil, "a delay row must exist")
			writer_calls = {}
			with_zenity("300\n", 0, function() pcall(delay) end)
			helpers.assert_eq(#writer_calls, 1, "one write for one confirmed answer")
			helpers.assert_eq(writer_calls[1][2], 0.3, "300 ms is 0.3 s in the file")
		end)
		th._reset_for_test()
		package.loaded["platform.remap.tap_hold_writer"] = previous
		if not ok then error(err, 0) end
	end)

end)
