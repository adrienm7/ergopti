--- tests/unit/modules/hotstrings/injector/test_injector_output_observer.lua

--- ==============================================================================
--- MODULE: Injector Output Observer
--- DESCRIPTION:
--- Text the daemon types itself (a hotstring expansion, the magic key's result,
--- a send_text, a consumed key typed in its place) never reaches the keyboard
--- hook's character callback. The maintainer's rule is that ".", "," and ";"
--- end CapsWord as typed OUTPUT, whatever produced them, so the injector reports
--- every successful injection's text to one observer, and the daemon routes it
--- to the CapsWord policy. Before this, an expansion ending in "." left CapsWord
--- on and capitalised the next word.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a body with an injector over a recording channel and a stub layout.
--- @param body function body(injector)
local function with_injector(body)
	local saved_layout = package.loaded["adapters.keyboard_layout"]
	local saved_injector = package.loaded["modules.hotstrings.injector"]
	local keycodes = { ["a"] = 1001, ["."] = 1002, [","] = 1003, [";"] = 1004, ["x"] = 1005 }
	package.loaded["adapters.keyboard_layout"] = require("tests.support.layout_cohort_fixture").layout(function(char)
		return assert(keycodes[char], "unexpected text " .. tostring(char))
	end)
	local injector = helpers.load_module("modules.hotstrings.injector")
	local channel = { is_open = function() return true end, emit = function() return true end }
	injector._set_uinput(channel)
	injector._set_nanosleep_for_test(function() end)
	local ok, err = pcall(body, injector, channel)
	injector.set_output_observer(nil)
	injector._set_uinput(nil)
	injector._set_nanosleep_for_test(nil)
	package.loaded["adapters.keyboard_layout"] = saved_layout
	package.loaded["modules.hotstrings.injector"] = saved_injector
	if not ok then error(err, 0) end
end

helpers.describe("injector: output observer", function()
	helpers.it("injector output, reports the replacement and its replayed terminator", function()
		with_injector(function(injector)
			local seen = {}
			helpers.assert_true(injector.set_output_observer(function(text) seen[#seen + 1] = text end))
			helpers.assert_eq(injector.inject(2, "a.", false).ok, true)
			helpers.assert_eq(injector.inject(1, "a", false, ",").ok, true)
			helpers.assert_eq(table.concat(seen, "|"), "a.|a,")
		end)
	end)

	helpers.it("injector output, reports nothing a refused injection did not type", function()
		with_injector(function(injector, channel)
			local seen = 0
			injector.set_output_observer(function() seen = seen + 1 end)
			channel.emit = function() return false end
			helpers.assert_eq(injector.inject(0, "a.", false).ok, false)
			helpers.assert_eq(seen, 0)
		end)
	end)

	helpers.it("injector output, keeps one owner and survives a failing observer", function()
		with_injector(function(injector)
			local first = function() error("observer failure") end
			helpers.assert_true(injector.set_output_observer(first))
			helpers.assert_eq(injector.set_output_observer(function() end), false, "a second owner is refused")
			helpers.assert_eq(injector.set_output_observer("text"), false)
			helpers.assert_eq(injector.inject(0, "a", false).ok, true, "the injection still succeeds")
		end)
	end)

	helpers.it("injector output, the daemon ends CapsWord on a delimiter the daemon typed", function()
		local f = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = f:read("*a")
		f:close()
		local start = assert(source:find("injector.set_output_observer(function(text)", 1, true),
			"the daemon installs the output observer")
		local body = source:sub(start, (source:find("\tend) then", start, true)))
		helpers.assert_contains(body, "shortcuts.caps_word_observe_text(text)")
		helpers.assert_contains(body, "shortcuts.is_caps_word_active()")
	end)
end)

return true
