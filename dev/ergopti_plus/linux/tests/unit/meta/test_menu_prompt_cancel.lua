--- tests/unit/meta/test_menu_prompt_cancel.lua
---
--- ==============================================================================
--- MODULE: Menu Prompt Cancel Regression Guard (Linux driver)
--- DESCRIPTION:
--- A zenity Cancel treated as an empty answer on LuaJIT.
---
--- ROOT CAUSE ENCODED:
--- Production runs LuaJIT (Lua 5.1 semantics): io.popen's close() and
--- os.execute() return a NUMBER, 0 for success. A bare `if not status` is
--- therefore never true on LuaJIT — not even for a failure — so in
--- ui/menu/menu_builder.lua prompt_text() read Cancel (exit 1) as success and
--- returned "" instead of nil. Every caller treats "" as a value: cancelling
--- the tap-hold prompt CLEARED the key's tap action, cancelling a delay or
--- magic-key prompt wrote a value the user never entered, and show_error()'s
--- zenity-absent fallback never fired.
---
--- Fixed by routing every zenity exit status through one succeeded() helper
--- accepting `true` (Lua 5.2+) and 0 (LuaJIT). This test drives the real
--- tap-prompt row with a stubbed zenity: Cancel (close -> 1, the LuaJIT
--- numeric spelling) must leave the writer untouched, while confirming an
--- empty answer must still clear the tap action.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Calls the writer records while a scenario runs. Reset before each click.
local writer_calls = {}

--- Installs a fake tap-hold writer through the package cache and returns the
--- previous entry for unconditional restore. _tap_hold_writer() requires the
--- module at click time, so the click reaches this spy instead of the
--- filesystem and kanata.
--- @return any Previous package.loaded entry (possibly nil).
local function install_fake_writer()
	local previous = package.loaded["platform.remap.tap_hold_writer"]
	package.loaded["platform.remap.tap_hold_writer"] = {
		set_field = function(...)
			writer_calls[#writer_calls + 1] = { ... }
			return true
		end,
		clear_key = function(...) return true end,
		is_overridden = function() return false end,
	}
	return previous
end

--- Runs fn with io.popen stubbed as a zenity dialog whose output is
--- `read_body` and whose exit status is `close_status` (a NUMBER, the LuaJIT
--- spelling: 0 for OK, 1 for Cancel). Restores io.popen even on failure.
--- @param read_body string Dialog stdout.
--- @param close_status number Exit status number.
--- @param fn function Body to run inside the sandbox.
--- @return table Commands handed to io.popen.
local function with_zenity(read_body, close_status, fn)
	local real_popen = io.popen
	local commands = {}
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

--- Finds the tap-prompt row's callback: the direct leaf row of a per-key
--- Kanata submenu whose click shells out to `zenity --entry`. Hold-option
--- rows live one level deeper and set the writer without prompting, so only
--- direct leaf rows are clicked here.
--- @param mb table The loaded menu builder.
--- @return function|nil The tap-prompt callback, or nil when not found.
local function find_tap_row(mb)
	local items = mb.build({ _version = "test", on_quit = function() end })
	local kanata = nil
	for _, item in ipairs(items) do
		local title = item.title or item.label or ""
		if type(title) == "string" and title:find("Kanata", 1, true) then
			kanata = item
			break
		end
	end
	helpers.assert_true(kanata ~= nil, "Kanata section present in menu")
	for _, sub in ipairs(children_of(kanata) or {}) do
		local leafs = children_of(sub)
		if type(leafs) == "table" then
			for _, row in ipairs(leafs) do
				local cb = callback_of(row)
				if cb and not row.disabled and children_of(row) == nil then
					local commands = with_zenity("", 0, function() pcall(cb) end)
					for _, cmd in ipairs(commands) do
						if cmd:find("zenity", 1, true) and cmd:find("--entry", 1, true) then
							return cb
						end
					end
				end
			end
		end
	end
	return nil
end

helpers.describe("menu_builder: zenity Cancel changes nothing (prompt-cancel)", function()

	helpers.it("prompt-cancel: cancelling the tap-hold prompt keeps the writer untouched", function()
		local previous = install_fake_writer()
		local ok, err = pcall(function()
			local mb = helpers.load_module("ui.menu.menu_builder")
			local tap = find_tap_row(mb)
			helpers.assert_true(tap ~= nil,
				"a tap-prompt row shelling out to zenity --entry must exist — "
					.. "without it this test proves nothing")
			-- Cancel on LuaJIT: close() returns the NUMBER 1, never false.
			writer_calls = {}
			with_zenity("", 1, function() pcall(tap) end)
			helpers.assert_eq(#writer_calls, 0,
				"Cancel is not an empty answer — it must change nothing")
		end)
		package.loaded["platform.remap.tap_hold_writer"] = previous
		if not ok then error(err, 0) end
	end)

	helpers.it("prompt-cancel: confirming an empty answer still clears the tap action", function()
		local previous = install_fake_writer()
		local ok, err = pcall(function()
			local mb = helpers.load_module("ui.menu.menu_builder")
			local tap = find_tap_row(mb)
			helpers.assert_true(tap ~= nil,
				"a tap-prompt row shelling out to zenity --entry must exist — "
					.. "without it this test proves nothing")
			-- OK with empty output: the documented clear-the-tap-action path.
			writer_calls = {}
			with_zenity("", 0, function() pcall(tap) end)
			helpers.assert_eq(#writer_calls, 1,
				"an empty confirmed answer must clear the tap action exactly once")
			helpers.assert_eq(writer_calls[1][2], "tap_action",
				"the write must target the tap action field")
			helpers.assert_true(writer_calls[1][3] == nil,
				"an empty answer clears the field rather than storing a blank")
		end)
		package.loaded["platform.remap.tap_hold_writer"] = previous
		if not ok then error(err, 0) end
	end)

end)
