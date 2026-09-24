--- tests/unit/modules/shortcuts/test_wrap_on_type.lua

--- ==============================================================================
--- MODULE: Typing A Wrap Symbol Over A Selection Wraps It (Linux)
--- DESCRIPTION:
--- The decision behind shortcuts.wrap_text_if_selected, which Linux marked
--- "Deferred" until now: with a live selection, typing a symbol of a wrap pair
--- replaces the selection with left + selection + right and the symbol never
--- reaches the application; otherwise the symbol types exactly once. Also pins
--- the probe (PRIMARY only, no Ctrl+C, no clipboard write) and the tray row.
--- ==============================================================================

local helpers = require("tests.helpers")

local WrapOnType = helpers.load_module("modules.shortcuts.wrap_on_type")

local KEY_LEFT = 105
local KEY_9 = 10
local PAIRS = { ["("] = { left = "(", right = ")" }, ["«"] = { left = "« ", right = " »" } }

--- A controller over recording doubles.
--- @param state table|nil { active, primary, type_ok }
--- @return table controller, table log
local function controller_with(state)
	state = state or {}
	local log = { reads = 0, typed = {} }
	local controller = WrapOnType.new({
		is_active = function() return state.active ~= false end,
		get_pair = function(char) return PAIRS[char] end,
		read_primary = function()
			log.reads = log.reads + 1
			return true, state.primary or ""
		end,
		type_text = function(text)
			if state.type_ok == false then return false end
			log.typed[#log.typed + 1] = text
			return true
		end,
	})
	return controller, log, state
end

--- A symbol key press as the hook reports it.
--- @param char string
--- @param mods table|nil
--- @return table
local function symbol(char, mods)
	return { char = char, code = KEY_9, mods = mods or { shift = true } }
end

helpers.describe("wrap on type (linux): the decision", function()
	helpers.it("wraps a mouse selection and swallows the symbol", function()
		local controller, log, state = controller_with({ primary = "old" })
		controller.on_pointer_down()
		state.primary = "hello"
		helpers.assert_true(controller.on_key(symbol("(")), "the symbol must not reach the application")
		helpers.assert_eq(log.typed, { "(hello)" })
	end)

	helpers.it("wraps a Shift+Arrow selection with a multi-byte pair", function()
		local controller, log, state = controller_with({ primary = "" })
		helpers.assert_true(not controller.on_key({ code = KEY_LEFT, mods = { shift = true } }))
		state.primary = "mot"
		helpers.assert_true(controller.on_key(symbol("«", { altgr = true })))
		helpers.assert_eq(log.typed, { "« mot »" })
	end)

	helpers.it("types the symbol with no selection, without reading anything", function()
		local controller, log = controller_with({ primary = "stale" })
		helpers.assert_true(not controller.on_key(symbol("(")), "no selection: the symbol types normally")
		helpers.assert_eq(log.reads, 0, "a symbol typed mid-sentence must cost no subprocess")
		helpers.assert_eq(log.typed, {})
	end)

	helpers.it("types the symbol after a deselecting click (stale PRIMARY)", function()
		local controller, log = controller_with({ primary = "was selected" })
		controller.on_pointer_down()
		helpers.assert_true(not controller.on_key(symbol("(")),
			"PRIMARY unchanged since the click is an old selection, not a live one")
		helpers.assert_eq(log.typed, {})
	end)

	helpers.it("types the symbol once any other key ended the selection", function()
		local controller, log, state = controller_with({ primary = "" })
		controller.on_pointer_down()
		state.primary = "hello"
		controller.on_key({ char = "x", code = 45, mods = {} })
		helpers.assert_true(not controller.on_key(symbol("(")))
		helpers.assert_eq(log.typed, {})
	end)

	helpers.it("passes the symbol through while disabled or paused", function()
		local controller, log, state = controller_with({ primary = "" })
		controller.on_pointer_down()
		state.primary = "hello"
		state.active = false
		helpers.assert_true(not controller.on_key(symbol("(")))
		helpers.assert_eq(log.typed, {})
	end)

	helpers.it("leaves a modifier chord alone", function()
		local controller, log, state = controller_with({ primary = "" })
		controller.on_pointer_down()
		state.primary = "hello"
		helpers.assert_true(not controller.on_key(symbol("(", { ctrl = true })))
		helpers.assert_eq(log.typed, {})
	end)

	helpers.it("types the symbol when the wrap could not be typed", function()
		local controller, log, state = controller_with({ primary = "", type_ok = false })
		controller.on_pointer_down()
		state.primary = "hello"
		helpers.assert_true(not controller.on_key(symbol("(")),
			"a refused wrap must hand the key back so it is typed exactly once")
		helpers.assert_eq(log.typed, {})
	end)
end)

helpers.describe("wrap on type (linux): the probe never types into the window", function()
	helpers.it("reads PRIMARY with no key sent and no clipboard write", function()
		local names = { shell = "adapters.shell_runner", display = "infra.display_server", clip = "adapters.clipboard" }
		local previous = {}
		for key, name in pairs(names) do previous[key] = package.loaded[name] end
		local shell = { commands = {}, writes = 0 }
		function shell.has_command() return true end
		function shell.exec_checked(command)
			shell.commands[#shell.commands + 1] = command
			return true, "hello", nil
		end
		function shell.run() shell.writes = shell.writes + 1 return true end
		function shell.with_exact_stdin(command) return command end
		package.loaded[names.shell] = shell
		package.loaded[names.display] = {
			UNKNOWN = "unknown",
			is_wayland = function() return false end,
			is_x11 = function() return true end,
			kind = function() return "x11" end,
		}
		package.loaded[names.clip] = nil
		local ok, err = pcall(function()
			local Clipboard = require(names.clip)
			local read_ok, text = Clipboard.read_primary()
			helpers.assert_true(read_ok)
			helpers.assert_eq(text, "hello")
			helpers.assert_eq(#shell.commands, 1)
			helpers.assert_true(shell.commands[1]:find("primary", 1, true) ~= nil,
				"the probe reads the PRIMARY selection: " .. shell.commands[1])
			helpers.assert_eq(shell.writes, 0, "the clipboard is never written, so nothing needs restoring")
		end)
		for key, name in pairs(names) do package.loaded[name] = previous[key] end
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("wrap on type (linux): the tray row", function()
	helpers.it("draws the wrap-on-type toggle in the shortcuts submenu", function()
		local shortcuts = helpers.load_module("modules.shortcuts.manager")
		shortcuts.init({ enabled = true, persist = false })
		local mb = helpers.load_module("ui.menu.menu_builder")
		local items = mb.build({ _version = "0.0.0-dev.12", shortcuts = shortcuts, on_quit = function() end })
		local i18n = require("infra.i18n")
		local title = i18n.get("menu.shortcuts.title")
		local label = i18n.get("shortcuts.label_wrap_text")
		local row = nil
		for _, item in ipairs(items) do
			if type(item.title) == "string" and item.title:find(title, 1, true) then
				for _, child in ipairs(item.menu or {}) do
					if child.title == label then row = child end
				end
			end
		end
		helpers.assert_true(row ~= nil, "the manifest's wrap_text_if_selected row must be drawn on Linux")
		helpers.assert_eq(row.checked, shortcuts.is_wrap_on_type_enabled())
		helpers.assert_eq(type(row.fn), "function")
		local before = shortcuts.is_wrap_on_type_enabled()
		row.fn()
		helpers.assert_eq(shortcuts.is_wrap_on_type_enabled(), not before, "the row toggles the switch")
		shortcuts.set_wrap_on_type_enabled(before)
	end)

	helpers.it("matches a multi-byte wrap symbol from the shared catalogue", function()
		local shortcuts = helpers.load_module("modules.shortcuts.manager")
		local pair = shortcuts.get_wrap_pair("‘")
		helpers.assert_true(pair ~= nil and pair.right == "’",
			"‘ is a catalogue pair; a byte-length test dropped every multi-byte symbol")
		helpers.assert_true(shortcuts.get_wrap_pair("(") ~= nil)
	end)
end)
