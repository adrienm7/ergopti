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

--- Exercises the real preference owner and shared feature row on a private file.
--- @param body function Receives manager, row finder, and external observations.
local function with_wrap_feature(body)
	local manager_name, builder_name = "modules.shortcuts.manager", "ui.menu.menu_builder"
	local previous_manager, previous_builder = package.loaded[manager_name], package.loaded[builder_name]
	local writer = require("toml_codec.writer")
	local original_batch = writer.batch_write
	local sandbox = require("test.config_unused_keys_contract").sandbox
	local ok, err = pcall(function()
		sandbox.with_config('[shortcuts]\nenabled = true\nwrap_text_if_selected = false\n[foreign]\nvalue = "keep"\n',
			function(path)
				local manager = helpers.load_module(manager_name)
				manager.init({ persist = true, config_path = path })
				local observed = { changed = 0, setter_calls = 0, path = path,
					original_bytes = sandbox.read_bytes(path) }
				local real_setter = manager.set_wrap_on_type_enabled
				manager.set_wrap_on_type_enabled = function(value)
					observed.setter_calls = observed.setter_calls + 1
					observed.desired = value
					return real_setter(value)
				end
				local builder = helpers.load_module(builder_name)
				local function row()
					local rows = builder.build({ _version = "0.0.0-dev.12", shortcuts = manager,
						paused = false, is_paused = function() return true end,
						on_quit = function() end,
						on_menu_changed = function() observed.changed = observed.changed + 1 end,
					})
					local label = require("infra.i18n").get("shortcuts.label_wrap_text")
					for _, item in ipairs(rows) do
						for _, child in ipairs(item.menu or {}) do
							if child.title == label then return child end
						end
					end
				end
				body(manager, row, observed, sandbox, writer)
			end)
	end)
	writer.batch_write = original_batch
	package.loaded[manager_name], package.loaded[builder_name] = previous_manager, previous_builder
	if not ok then error(err, 0) end
end

helpers.describe("wrap feature callback ownership", function()
	helpers.it("acknowledges the real durable preference before refresh (wrap-feature-owner)", function()
		with_wrap_feature(function(manager, row, observed, sandbox)
			local held = row().fn
			helpers.assert_eq(held(), true)
			helpers.assert_eq(manager.is_wrap_on_type_enabled(), true)
			helpers.assert_eq(observed.changed, 1)
			local parsed = require("toml_codec").decode(sandbox.read_bytes(observed.path))
			helpers.assert_eq(parsed.shortcuts.wrap_text_if_selected, true)
			helpers.assert_eq(parsed.foreign.value, "keep")
			helpers.assert_eq(held(), true)
			helpers.assert_eq(manager.is_wrap_on_type_enabled(), false)
			helpers.assert_eq(observed.changed, 2)
		end)
	end)

	helpers.it("toggles fresh external state rather than a held checkmark (wrap-feature-owner)", function()
		with_wrap_feature(function(manager, row, observed, sandbox)
			local held = row().fn
			helpers.assert_eq(manager.set_wrap_on_type_enabled(true), true)
			helpers.assert_eq(manager.is_wrap_on_type_enabled(), true)
			helpers.assert_eq(held(), true)
			helpers.assert_eq(manager.is_wrap_on_type_enabled(), false)
			helpers.assert_eq(observed.desired, false)
			helpers.assert_eq(observed.changed, 1)
			helpers.assert_eq(require("toml_codec").decode(sandbox.read_bytes(observed.path))
				.shortcuts.wrap_text_if_selected, false)
		end)
	end)

	helpers.it("refuses held callbacks while real configuration is reserved (wrap-feature-owner)", function()
		with_wrap_feature(function(manager, row, observed, sandbox)
			local held, owner = row().fn, {}
			helpers.assert_eq(manager.acquire_configuration(owner), true)
			helpers.assert_eq(row().disabled, true)
			helpers.assert_eq(held(), false)
			helpers.assert_eq(observed.setter_calls, 0)
			helpers.assert_eq(observed.changed, 0)
			helpers.assert_eq(sandbox.read_bytes(observed.path), observed.original_bytes)
			helpers.assert_eq(manager.configuration_snapshot(owner).wrap, false)
			helpers.assert_eq(manager.release_configuration(owner), true)
			helpers.assert_eq(held(), true)
			helpers.assert_eq(manager.is_wrap_on_type_enabled(), true)
		end)
	end)

	helpers.it("keeps refusal bytes and runtime when the actual setter cannot publish (wrap-feature-owner)", function()
		with_wrap_feature(function(manager, row, observed, sandbox, writer)
			local actual_batch, calls = writer.batch_write, 0
			writer.batch_write = function(path, operations)
				calls = calls + 1
				observed.write_path = path
				observed.operations = operations
				return false, "controlled publication refusal"
			end
			local held = row().fn
			local result = held()
			helpers.assert_eq(result, false)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(observed.write_path, observed.path)
			helpers.assert_eq(observed.operations, {
				{ section = "shortcuts", key = "wrap_text_if_selected", value = true } })
			helpers.assert_eq(manager.is_wrap_on_type_enabled(), false)
			helpers.assert_eq(observed.changed, 0)
			helpers.assert_eq(sandbox.read_bytes(observed.path), observed.original_bytes)
			writer.batch_write = actual_batch
			helpers.assert_eq(held(), true)
			helpers.assert_eq(manager.is_wrap_on_type_enabled(), true)
			helpers.assert_eq(observed.changed, 1)
		end)
	end)

	helpers.it("preserves the existing master gate after its row was retained (wrap-feature-owner)", function()
		with_wrap_feature(function(manager, row, observed, sandbox)
			local held = row().fn
			helpers.assert_eq(manager.set_enabled(false), true)
			local bytes = sandbox.read_bytes(observed.path)
			helpers.assert_eq(row().disabled, true)
			helpers.assert_eq(held(), false)
			helpers.assert_eq(observed.setter_calls, 0)
			helpers.assert_eq(observed.changed, 0)
			helpers.assert_eq(manager.is_wrap_on_type_enabled(), false)
			helpers.assert_eq(sandbox.read_bytes(observed.path), bytes)
		end)
	end)

	for _, receipt in ipairs({ { name = "false", value = false }, { name = "nil" },
		{ name = "numeric", value = 1 }, { name = "truthy", value = "ack" } }) do
		helpers.it("refuses the setter's " .. receipt.name .. " receipt (wrap-feature-owner)", function()
			with_wrap_feature(function(manager, row, observed, sandbox)
				manager.set_wrap_on_type_enabled = function()
					observed.setter_calls = observed.setter_calls + 1
					return receipt.value
				end
				helpers.assert_eq(row().fn(), false)
				helpers.assert_eq(observed.setter_calls, 1)
				helpers.assert_eq(observed.changed, 0)
				helpers.assert_eq(manager.is_wrap_on_type_enabled(), false)
				helpers.assert_eq(sandbox.read_bytes(observed.path), observed.original_bytes)
			end)
		end)
	end

	helpers.it("rejects missing or malformed live readiness without a setter call (wrap-feature-owner)", function()
		with_wrap_feature(function(manager, row, observed, sandbox)
			local real_admission, real_enabled = manager.configuration_admitted, manager.is_enabled
			for _, invalid in ipairs({ {}, { value = false }, { value = function() return 1 end } }) do
				manager.configuration_admitted = invalid.value
				local item = row()
				helpers.assert_eq(item.disabled, true)
				helpers.assert_eq(item.fn(), false)
			end
			manager.configuration_admitted = real_admission
			manager.is_enabled = function() return 1 end
			helpers.assert_eq(row().disabled, true)
			helpers.assert_eq(row().fn(), false)
			manager.is_enabled = real_enabled
			manager.set_wrap_on_type_enabled = nil
			helpers.assert_eq(row().disabled, true)
			helpers.assert_eq(row().fn(), false)
			helpers.assert_eq(observed.setter_calls, 0)
			helpers.assert_eq(observed.changed, 0)
			helpers.assert_eq(sandbox.read_bytes(observed.path), observed.original_bytes)
		end)
	end)

	helpers.it("refuses malformed wrap preference instead of inventing its opposite (wrap-feature-owner)", function()
		with_wrap_feature(function(manager, row, observed, sandbox)
			local held = row().fn
			manager.is_wrap_on_type_enabled = function() return "true" end
			helpers.assert_eq(row().disabled, true)
			helpers.assert_eq(held(), false)
			helpers.assert_eq(observed.setter_calls, 0)
			helpers.assert_eq(observed.changed, 0)
			helpers.assert_eq(sandbox.read_bytes(observed.path), observed.original_bytes)
		end)
	end)

	helpers.it("rechecks reservation acquired by the current preference getter (wrap-feature-owner)", function()
		with_wrap_feature(function(manager, row, observed, sandbox)
			local held, owner = row().fn, {}
			manager.is_wrap_on_type_enabled = function()
				observed.acquired = manager.acquire_configuration(owner)
				return false
			end
			local result = held()
			helpers.assert_eq(observed.acquired, true)
			helpers.assert_eq(result, false)
			helpers.assert_eq(observed.setter_calls, 0)
			helpers.assert_eq(observed.changed, 0)
			helpers.assert_eq(sandbox.read_bytes(observed.path), observed.original_bytes)
			helpers.assert_eq(manager.release_configuration(owner), true)
		end)
	end)
end)
