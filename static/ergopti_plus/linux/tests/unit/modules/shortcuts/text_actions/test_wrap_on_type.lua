--- tests/unit/modules/shortcuts/text_actions/test_wrap_on_type.lua

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
	local controller
	controller = WrapOnType.new({
		context_epoch = state.context_epoch,
		is_active = function()
			if state.on_active then state.on_active(controller, log, state) end
			return state.active ~= false
		end,
		get_pair = function(char) return state.pair or PAIRS[char] end,
		read_primary = function()
			log.reads = log.reads + 1
			if state.on_read then state.on_read(controller, log, state) end
			return true, state.primary or ""
		end,
		type_text = function(text)
			if state.type_ok == false then return false end
			log.typed[#log.typed + 1] = text
			if state.on_type then state.on_type(controller, log, state) end
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

helpers.describe("wrap selection read owner", function()
	helpers.it("revokes output when PRIMARY reading pauses the feature", function()
		local controller, log, state = controller_with({ primary = "old", on_read = function(_, observed, current)
			if observed.reads == 2 then current.active = false end
		end })
		controller.on_pointer_down()
		state.primary = "selected"
		helpers.assert_eq(controller.on_key(symbol("(")), false)
		helpers.assert_eq(log.typed, {})
	end)
	for _, boundary in ipairs({ "baseline", "selected" }) do
		helpers.it("explicit retirement during " .. boundary .. " read cannot resurrect or type", function()
			local controller, log, state = controller_with({ primary = "old", on_read = function(owner, observed)
				if observed.reads == (boundary == "baseline" and 1 or 2) then owner.end_selection_window() end
			end })
			controller.on_pointer_down()
			if boundary == "baseline" then helpers.assert_eq(controller.selection_window_open(), false) end
			state.primary = "selected"
			helpers.assert_eq(controller.on_key(symbol("(")), false)
			helpers.assert_eq(log.typed, {})
		end)
	end
	helpers.it("a newer ordinary key during PRIMARY reading retires the older wrap", function()
		local controller, log, state = controller_with({ primary = "old", on_read = function(owner, observed)
			if observed.reads == 2 then owner.on_key({ char = "x", code = 45, mods = {} }) end
		end })
		controller.on_pointer_down()
		state.primary = "selected"
		helpers.assert_eq(controller.on_key(symbol("(")), false)
		helpers.assert_eq(log.typed, {})
	end)
	helpers.it("an older baseline read cannot replace a nested pointer's baseline", function()
		local controller, log, state = controller_with({ primary = "old", on_read = function(owner, observed, current)
			if observed.reads == 1 then
				current.primary = "new baseline"
				owner.on_pointer_down()
				current.primary = "old baseline"
			end
		end })
		controller.on_pointer_down()
		state.primary = "new baseline"
		helpers.assert_eq(controller.selection_window_open(), true)
		helpers.assert_eq(controller.on_key(symbol("(")), false, "PRIMARY still equals the newer pointer's baseline")
		helpers.assert_eq(log.typed, {})
	end)
	helpers.it("a nested selection opening during a wrap read survives the old request", function()
		local controller, log, state = controller_with({ primary = "old", on_read = function(owner, observed, current)
			if observed.reads == 2 then
				current.primary = "successor baseline"
				owner.on_pointer_down()
				current.primary = "old selected"
			end
		end })
		controller.on_pointer_down()
		state.primary = "old selected"
		helpers.assert_eq(controller.on_key(symbol("(")), false)
		helpers.assert_eq(log.typed, {})
		helpers.assert_eq(controller.selection_window_open(), true)
		state.primary = "new selected"
		helpers.assert_eq(controller.on_key(symbol("(")), true)
		helpers.assert_eq(log.typed, { "(new selected)" })
	end)
	for _, boundary in ipairs({ "baseline", "selected" }) do
		helpers.it("rechecks ownership after the " .. boundary .. " activity callback itself retires it", function()
			local callbacks = 0
			local controller, log, state = controller_with({ primary = "old", on_active = function(owner, observed)
				if observed.reads == (boundary == "baseline" and 1 or 2) then
					callbacks = callbacks + 1
					owner.end_selection_window()
				end
			end })
			controller.on_pointer_down()
			state.primary = "selected"
			helpers.assert_eq(controller.on_key(symbol("(")), false)
			helpers.assert_eq(log.typed, {})
			helpers.assert_eq(controller.selection_window_open(), false)
			helpers.assert_eq(callbacks, 1)
		end)
	end
	helpers.it("captures the typed pair before PRIMARY reading can mutate its shared table", function()
		local pair = { left = "(", right = ")" }
		local controller, log, state = controller_with({ primary = "old", pair = pair, on_read = function(_, observed)
			if observed.reads == 2 then pair.left, pair.right = "[", "]" end
		end })
		controller.on_pointer_down()
		state.primary = "selected"
		helpers.assert_eq(controller.on_key(symbol("(")), true)
		helpers.assert_eq(log.typed, { "(selected)" })
	end)
	helpers.it("acknowledged typing consumes the symbol while preserving a newly opened selection", function()
		local controller, log, state = controller_with({ primary = "old", on_type = function(owner, _, current)
			current.primary = "successor baseline"
			owner.on_pointer_down()
		end })
		controller.on_pointer_down()
		state.primary = "selected"
		helpers.assert_eq(controller.on_key(symbol("(")), true, "Already emitted output cannot also pass the physical symbol through")
		helpers.assert_eq(log.typed, { "(selected)" })
		helpers.assert_eq(controller.selection_window_open(), true)
		state.on_type = nil
		state.primary = "next"
		helpers.assert_eq(controller.on_key(symbol("(")), true)
		helpers.assert_eq(log.typed, { "(selected)", "(next)" })
	end)
	helpers.it("Ctrl+A opens a fresh owned window and Shift navigation extends it without rereading", function()
		local controller, log, state = controller_with({ primary = "old" })
		helpers.assert_eq(controller.on_key({ char = "a", code = 30, mods = { ctrl = true } }), false)
		helpers.assert_eq(log.reads, 1)
		helpers.assert_eq(controller.on_key({ code = KEY_LEFT, mods = { shift = true } }), false)
		helpers.assert_eq(log.reads, 1)
		state.primary = "selected"
		helpers.assert_eq(controller.on_key(symbol("(")), true)
		helpers.assert_eq(log.typed, { "(selected)" })
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

--- Keeps the real source readers/decoder and controls only private file routing.
local function with_wrap_inventory(body, options)
	options = options or {}
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	local Routes, Paths = require("infra.config_paths"), require("infra.paths")
	local name = "modules.shortcuts.manager"
	local prior, route, shared, open = package.loaded[name], Routes.config, Paths.shared, io.open
	local catalogue_path = os.tmpname()
	local original = assert(open(shared("modules/wrap_symbols/wrap_symbols.json"), "rb"))
	local original_bytes = assert(original:read("*a")); assert(original:close() == true)
	Sandbox.write_bytes(catalogue_path, original_bytes)
	local passed, failure = pcall(function()
		Sandbox.with_config(options.source or '[shortcuts]\nenabled = true\nwrap_text_if_selected = true\n', function(path)
			Routes.config = function(file) assert(file == "config.toml"); return path end
			Paths.shared = function(relative)
				if relative == "modules/wrap_symbols/wrap_symbols.json" then return catalogue_path end
				return shared(relative)
			end
			if options.close_target then
				local target = options.close_target == "catalogue" and catalogue_path or path
				io.open = function(file, mode)
					local handle, detail, code = open(file, mode)
					if file ~= target or not handle then return handle, detail, code end
					return {
						read = function(_, ...) return handle:read(...) end,
						close = function() assert(handle:close() == true); return options.close_ack end,
					}
				end
			end
			local manager = helpers.load_module(name)
			manager.init({ persist = true, config_path = path })
			io.open = open
			body(manager, path, catalogue_path, Sandbox)
		end)
	end)
	io.open, Routes.config, Paths.shared, package.loaded[name] = open, route, shared, prior
	local removed, detail = os.remove(catalogue_path)
	helpers.assert_eq(removed, true, "owned catalogue cleanup: " .. tostring(detail))
	if not passed then error(failure, 0) end
end

helpers.describe("configured wrap-symbol collision reservations", function()
	helpers.it("(wrap-configured-reservation) emits genuine plain/Shift trigger claims without reading PRIMARY", function()
		with_wrap_inventory(function(manager)
			local frame = assert(manager.capture_collision_inventory())
			local observed = {}
			for _, claim in ipairs(frame.claims) do
				helpers.assert_eq(claim.kind, "logical")
				helpers.assert_eq(claim.mods.ctrl, nil); helpers.assert_eq(claim.mods.alt, nil)
				helpers.assert_eq(claim.mods.super, nil); helpers.assert_eq(claim.mods.altgr, nil)
				if claim.key == "(" then observed[claim.mods.shift] = true end
			end
			helpers.assert_eq(observed, { [false] = true, [true] = true })
			helpers.assert_eq(frame.current(), true); helpers.assert_eq(frame.sealed(), true)
			local controller, log, state = controller_with({ primary = "before" })
			helpers.assert_eq(controller.on_key(symbol("(", {})), false)
			helpers.assert_eq(log.reads, 0, "configured eligibility does not assert an active selection")
			controller.on_pointer_down(); state.primary = "selection"
			helpers.assert_eq(controller.on_key(symbol("(", {})), true)
		end)
	end)

	for _, setting in ipairs({ "enabled", "wrap_text_if_selected" }) do
		helpers.it("(wrap-configured-reservation) proves empty configured claims when " .. setting .. " is off", function()
			with_wrap_inventory(function(manager)
				local frame = assert(manager.capture_collision_inventory())
				helpers.assert_eq(frame.claims, {}); helpers.assert_eq(frame.current(), true)
			end, { source = ('[shortcuts]\nenabled = true\nwrap_text_if_selected = true\n'):gsub(setting .. ' = true', setting .. ' = false') })
		end)
	end

	helpers.it("(wrap-configured-reservation) invalidates an old frame after a real switch round trip", function()
		with_wrap_inventory(function(manager)
			local frame = assert(manager.capture_collision_inventory())
			helpers.assert_eq(manager.set_wrap_on_type_enabled(false), true)
			helpers.assert_eq(manager.set_wrap_on_type_enabled(true), true)
			helpers.assert_eq(frame.current(), false); helpers.assert_eq(frame.sealed(), false)
			helpers.assert_true(manager.capture_collision_inventory() ~= nil)
		end)
	end)

	helpers.it("(wrap-configured-reservation) refuses changed genuine catalogue bytes without adopting a new baseline", function()
		with_wrap_inventory(function(manager, _, catalogue_path, Sandbox)
			local frame = assert(manager.capture_collision_inventory())
			Sandbox.write_bytes(catalogue_path, '{"groups":[]}')
			helpers.assert_eq(frame.current(), false)
			helpers.assert_eq(manager.capture_collision_inventory(), nil)
		end)
	end)

	helpers.it("(wrap-configured-reservation) refuses a changed actual map or replaced dispatch getter", function()
		with_wrap_inventory(function(manager)
			local frame = assert(manager.capture_collision_inventory())
			local pair = manager.get_wrap_pairs()["("]
			local right = pair.right; pair.right = "changed"
			helpers.assert_eq(frame.sealed(), false)
			helpers.assert_eq(manager.capture_collision_inventory(), nil)
			pair.right = right
			local getter = manager.get_wrap_pair
			manager.get_wrap_pair = function() return nil end
			helpers.assert_eq(frame.current(), false)
			manager.get_wrap_pair = getter
		end)
	end)

	helpers.it("(wrap-configured-reservation) refuses stale configured switches rather than rereading them as runtime", function()
		with_wrap_inventory(function(manager, path, _, Sandbox)
			local frame = assert(manager.capture_collision_inventory())
			Sandbox.write_bytes(path, '[shortcuts]\nenabled = true\nwrap_text_if_selected = false\n')
			helpers.assert_eq(manager.is_wrap_on_type_enabled(), true)
			helpers.assert_eq(frame.current(), false); helpers.assert_eq(manager.capture_collision_inventory(), nil)
		end)
	end)

	for _, target in ipairs({ "catalogue", "configuration" }) do
		for _, ack in ipairs({ { name = "false", value = false }, { name = "nil" } }) do
			helpers.it("(wrap-configured-reservation) original " .. target .. " load refuses a " .. ack.name .. " close ACK", function()
				with_wrap_inventory(function(manager)
					if target == "catalogue" then
						helpers.assert_eq(manager.get_wrap_pair("("), nil, "unacknowledged catalogue must not become active")
					else
						helpers.assert_eq(manager.is_enabled(), false)
						helpers.assert_eq(manager.is_wrap_on_type_enabled(), false)
					end
					helpers.assert_eq(manager.capture_collision_inventory(), nil, "a later valid read cannot authorize the refused original load")
				end, { close_target = target, close_ack = ack.value })
			end)
		end
	end

	helpers.it("(wrap-configured-reservation) configuration ownership revokes a previously captured frame", function()
		with_wrap_inventory(function(manager)
			local frame, owner = assert(manager.capture_collision_inventory()), {}
			helpers.assert_eq(manager.acquire_configuration(owner), true)
			helpers.assert_eq(frame.current(), false); helpers.assert_eq(manager.capture_collision_inventory(), nil)
			helpers.assert_eq(manager.release_configuration(owner), true)
			helpers.assert_eq(frame.sealed(), false)
		end)
	end)
end)


helpers.describe("Corrupt wrap reservation configuration refusal", function()
	helpers.it("(wrap-configured-reservation) corrupt actual config refuses rather than manufacturing empty claims", function()
		with_wrap_inventory(function(manager, path, _, Sandbox)
			local original = assert(manager.capture_collision_inventory())
			Sandbox.write_bytes(path, "[shortcuts\n")
			helpers.assert_eq(original.current(), false)
			local acknowledged, frame = pcall(manager.capture_collision_inventory)
			helpers.assert_eq(acknowledged, true, "public capture must classify corrupt-source refusal")
			helpers.assert_eq(frame, nil, "corrupt source is never an empty free inventory")
		end)
	end)
end)


--- Executes actual daemon constructors and callbacks over explicit boundary ports.
--- The real ScriptActions, capture gate and Wrap owners retain their own state.
--- @param body function|string Assertion over the connected owners, or early-startup probe.
--- @param options table|nil Explicit manager initialization for persisted transitions.
local function with_daemon_wrap(body, options)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local source = file:read("*a"); assert(file:close())
	local function span(first_marker, last_marker)
		local first = assert(source:find(first_marker, 1, true), first_marker)
		local last = assert(source:find(last_marker, first + #first_marker, true), last_marker)
		return source:sub(first, last - 1)
	end
	local function evaluate(code, environment)
		local chunk
		if loadstring then
			chunk = assert(loadstring(code, "genuine-daemon-wrap")); setfenv(chunk, environment)
		else
			chunk = assert(load(code, "genuine-daemon-wrap", "t", environment))
		end
		return chunk()
	end
	local manager_name, clipboard_name = "modules.shortcuts.manager", "adapters.clipboard"
	local previous_manager, previous_clipboard = package.loaded[manager_name], package.loaded[clipboard_name]
	local ok, err = pcall(function()
		local state = { primary = "baseline", typed = {}, reads = 0, resets = 0, invalidations = 0, automation = 0 }
		local shortcuts = helpers.load_module(manager_name)
		shortcuts.init(options and options.manager_init or { enabled = true, persist = false })
		assert(shortcuts.set_wrap_on_type_enabled(true))
		local noop = function() end
		local env = {
			type = type, math = math, tostring = tostring, require = require, package = { loaded = {} },
			LOG = "Main.fixture", Logger = helpers.make_logger_stub(), privacy_owners = {},
			opts = { dry_run = false }, shortcuts = shortcuts,
			ScriptActions = require("modules.shortcuts.script_actions"), InputCaptureGate = require("infra.input_capture_gate"),
			keylogger = { cancel_hold_intervals = noop, set_private_window = noop,
				is_private_window = function() return false end, set_window_title = noop, on_app_focus = noop,
				observe_hold_focus = function()
					if state.on_focus_observe then state.on_focus_observe() end
				end },
			MagicKeySource = { cancel_capture = noop, on_key = function()
				state.automation = state.automation + 1; return false
			end },
			TapHold = { set_paused = noop }, shutdown = { request = noop }, perform_reload = noop,
			engine = { reset = function() state.resets = state.resets + 1 end },
			Monotonic = { now_ms = function() return 1000 end },
			WordReset = { click_resets_word = function() return true end },
			injector = { inject = function(_, text) state.typed[#state.typed + 1] = text; return { ok = true } end },
			script_chords = { on_key = function() return false end },
			tap_keys = { on_key = function() return false end }, consume_bound_chord = function() return false end,
		}
		env.script_actions = evaluate(span("local script_actions = ScriptActions.new({", "\n\t-- A control can change")
			.. "\nreturn script_actions", env)
		local reset = assert(source:match("reset_text = function(.-)\n\t\tend,"))
		local reset_text = evaluate("return function" .. reset .. "\nend", env)
		env.secure_focus_guard = { blocks_text = function() return false end, prime = reset_text,
			capture_text_owner = function() return { current = function() return true end, cached = function() return true end } end,
			invalidate = function() state.invalidations = state.invalidations + 1; reset_text() end }
		evaluate(span("input_capture_gate = InputCaptureGate.new({", "\n\tlocal on_char"), env)
		state.early_pause = function() env.script_actions.toggle_pause() end
		state.early_gate = env.input_capture_gate
		if body == "early" then
			state.early_pause(); state.early_pause()
			assert(state.early_gate.acquire("settings", 1)); assert(state.early_gate.release("settings", 1))
			return
		end
		package.loaded[clipboard_name] = { read_primary = function()
			state.reads = state.reads + 1
			if state.on_read then state.on_read() end
			return true, state.primary
		end }
		env.wrap_on_type = evaluate(span('local wrap_on_type = require("modules.shortcuts.wrap_on_type").new({',
			"\n\t-- The script-management chords") .. "\nreturn wrap_on_type", env)
		local focus = assert(source:match("process_lifecycle%.onFocusChange%((function%(appName, windowTitle%).-\n\t\tend)%)"))
		state.focus = evaluate("return " .. focus, env)
		state.click = evaluate(span("local function on_click()", "\n\t-- 8.7b) Restore") .. "\nreturn on_click", env)
		state.consume = evaluate(span("local on_consume = input_capture_gate.guard(function(detail)",
			"\n\t-- Bind the same privacy owner") .. "\nreturn on_consume", env)
		state.wrap, state.actions, state.gate, state.shortcuts = env.wrap_on_type, env.script_actions, env.input_capture_gate, shortcuts
		body(state)
	end)
	package.loaded[manager_name], package.loaded[clipboard_name] = previous_manager, previous_clipboard
	if not ok then error(err, 0) end
end

helpers.describe("wrap on type: genuine daemon lifetime wiring", function()
	helpers.it("keeps normal mouse selection through the actual privacy reset callback", function()
		with_daemon_wrap(function(state)
			state.click()
			helpers.assert_eq(state.invalidations, 1)
			helpers.assert_true(state.resets >= 1)
			helpers.assert_true(state.wrap.selection_window_open())
			state.primary = "selected"
			helpers.assert_true(state.consume(symbol("(")))
			helpers.assert_eq(state.typed, { "(selected)" })
		end)
	end)

	helpers.it("retires the pre-pause window and admits a fresh mouse selection after resume", function()
		with_daemon_wrap(function(state)
			state.click(); state.primary = "previous selection"
			state.actions.toggle_pause(); state.actions.toggle_pause()
			helpers.assert_eq(state.actions.is_paused(), false)
			helpers.assert_eq(state.wrap.on_key(symbol("(")), false)
			helpers.assert_eq(state.typed, {})
			state.click(); state.primary = "fresh selection"
			helpers.assert_true(state.wrap.on_key(symbol("(")))
			helpers.assert_eq(state.typed, { "(fresh selection)" })
		end)
	end)

	helpers.it("retires the previous application's window before the first focus observer", function()
		with_daemon_wrap(function(state)
			state.click(); state.primary = "previous application"
			state.on_focus_observe = function() helpers.assert_eq(state.wrap.selection_window_open(), false) end
			state.focus("org.example.next", "Normal editor")
			helpers.assert_eq(state.wrap.on_key(symbol("(")), false)
			helpers.assert_eq(state.typed, {})
			state.click(); state.primary = "new application"
			helpers.assert_true(state.wrap.on_key(symbol("(")))
			helpers.assert_eq(state.typed, { "(new application)" })
		end)
	end)

	helpers.it("retires the pre-capture window and preserves exact capture release ownership", function()
		with_daemon_wrap(function(state)
			state.click(); state.primary = "previous global selection"
			helpers.assert_true(state.gate.acquire("settings", 2))
			helpers.assert_eq(state.gate.release("settings", 1), false)
			helpers.assert_true(state.gate.blocks_text())
			local reads, automation = state.reads, state.automation
			local consumed, reason = state.consume(symbol("("))
			helpers.assert_nil(consumed)
			helpers.assert_eq(reason, "input capture blocked")
			helpers.assert_eq(state.reads, reads)
			helpers.assert_eq(state.automation, automation)
			helpers.assert_true(state.gate.release("settings", 2))
			helpers.assert_eq(state.gate.blocks_text(), false)
			helpers.assert_eq(state.wrap.on_key(symbol("(")), false)
			helpers.assert_eq(state.typed, {})
			state.click(); state.primary = "fresh global selection"
			helpers.assert_true(state.consume(symbol("(")))
			helpers.assert_eq(state.typed, { "(fresh global selection)" })
		end)
	end)

	helpers.it("does not read PRIMARY or open a global window for a pointer inside captured UI", function()
		with_daemon_wrap(function(state)
			helpers.assert_true(state.gate.acquire("settings", 1))
			state.click()
			helpers.assert_eq(state.reads, 0)
			helpers.assert_eq(state.wrap.selection_window_open(), false)
			state.primary = "UI selection"
			helpers.assert_true(state.gate.release("settings", 1))
			helpers.assert_eq(state.wrap.on_key(symbol("(")), false)
			helpers.assert_eq(state.typed, {})
		end)
	end)

	helpers.it("allows early pause and capture callbacks before the Wrap owner is published", function()
		with_daemon_wrap("early")
	end)
end)


helpers.describe("wrap on type: committed shortcut context epochs", function()
	local function with_persisted_wrap(body)
		require("test.config_unused_keys_contract").sandbox.with_config(
			'[shortcuts]\nenabled = true\nwrap_text_if_selected = true\n', function(path)
				with_daemon_wrap(body, { manager_init = { persist = true, config_path = path } })
			end)
	end
	local function roundtrip(state)
		helpers.assert_true(state.shortcuts.set_wrap_on_type_enabled(false))
		helpers.assert_true(state.shortcuts.set_wrap_on_type_enabled(true))
	end
	local function open(state)
		state.click(); state.primary = "selected"
	end
	local function refuses(state)
		helpers.assert_eq(state.wrap.on_key(symbol("(")), false)
		helpers.assert_eq(state.typed, {})
	end

	for _, transition in ipairs({ "wrap switch", "master switch", "configuration reservation", "configuration rollback", "initialization" }) do
		helpers.it("retires the previous window after a committed " .. transition, function()
			with_persisted_wrap(function(state)
				open(state)
				if transition == "wrap switch" then roundtrip(state)
				elseif transition == "master switch" then
					helpers.assert_true(state.shortcuts.set_enabled(false)); helpers.assert_true(state.shortcuts.set_enabled(true))
				elseif transition == "initialization" then
					state.shortcuts.init({ persist = false, enabled = true })
					helpers.assert_true(state.shortcuts.set_wrap_on_type_enabled(true))
				else
					local owner = {}
					helpers.assert_true(state.shortcuts.acquire_configuration(owner))
					if transition == "configuration rollback" then
						local original = assert(state.shortcuts.configuration_snapshot(owner))
						helpers.assert_true(state.shortcuts.apply_configuration(owner, state.shortcuts.configuration_candidate(
							{ shortcuts = { enabled = false, wrap_text_if_selected = false } })))
						helpers.assert_true(state.shortcuts.apply_configuration(owner, original))
					end
					helpers.assert_true(state.shortcuts.release_configuration(owner))
				end
				refuses(state)
				state.click(); state.primary = "fresh"
				helpers.assert_true(state.wrap.on_key(symbol("(")))
				helpers.assert_eq(state.typed, { "(fresh)" })
			end)
		end)
	end

	for _, callback in ipairs({ "opening activity", "opening PRIMARY", "selected PRIMARY", "pair lookup", "final activity" }) do
		helpers.it("refuses a committed roundtrip during " .. callback, function()
			with_persisted_wrap(function(state)
				if callback == "selected PRIMARY" or callback == "pair lookup" or callback == "final activity" then open(state) end
				if callback == "opening activity" or callback == "final activity" then
					local original = state.shortcuts.is_enabled
					state.shortcuts.is_enabled = function()
						if callback ~= "final activity" or state.reads >= 2 then
							state.shortcuts.is_enabled = original
							roundtrip(state)
						end
						return original()
					end
				elseif callback == "pair lookup" then
					local original = state.shortcuts.get_wrap_pair
					state.shortcuts.get_wrap_pair = function(char)
						state.shortcuts.get_wrap_pair = original
						roundtrip(state)
						return original(char)
					end
				else
					state.on_read = function() state.on_read = nil; roundtrip(state) end
				end
				if callback == "opening activity" or callback == "opening PRIMARY" then
					state.click()
					helpers.assert_eq(state.wrap.selection_window_open(), false)
				else refuses(state) end
			end)
		end)
	end

	helpers.it("keeps the epoch and admitted selection when durable publication refuses", function()
		with_persisted_wrap(function(state)
			open(state)
			local epoch = state.shortcuts.wrap_selection_epoch()
			local open_file, process = io.open, io.popen
			io.open, io.popen = function() error("epoch getter must not read files") end,
				function() error("epoch getter must not launch a process") end
			local read_ok, current = pcall(state.shortcuts.wrap_selection_epoch)
			io.open, io.popen = open_file, process
			helpers.assert_true(read_ok); helpers.assert_eq(current, epoch)
			local writer = require("toml_codec.writer")
			local write = writer.batch_write
			writer.batch_write = function() return false, "controlled durable refusal" end
			local ok, err = pcall(function()
				helpers.assert_eq(state.shortcuts.set_wrap_on_type_enabled(false), false)
				helpers.assert_eq(state.shortcuts.wrap_selection_epoch(), epoch)
				helpers.assert_true(state.shortcuts.is_wrap_on_type_enabled())
				helpers.assert_true(state.wrap.on_key(symbol("(")))
				helpers.assert_eq(state.typed, { "(selected)" })
			end)
			writer.batch_write = write
			if not ok then error(err, 0) end
		end)
	end)

	for _, invalid in ipairs({ { name = "nil" }, { name = "false", value = false }, { name = "string", value = "1" },
		{ name = "negative", value = -1 }, { name = "fraction", value = 0.5 }, { name = "NaN", value = 0/0 },
		{ name = "infinity", value = math.huge }, { name = "table", value = {} } }) do
		helpers.it("refuses an explicitly supplied " .. invalid.name .. " context epoch before PRIMARY", function()
			local controller, log = controller_with({ context_epoch = function() return invalid.value end })
			controller.on_pointer_down()
			helpers.assert_eq(controller.selection_window_open(), false)
			helpers.assert_eq(log.reads, 0)
			helpers.assert_eq(controller.on_key(symbol("(")), false)
			helpers.assert_eq(log.typed, {})
		end)
	end

	helpers.it("rejects a malformed optional context getter", function()
		local built = pcall(controller_with, { context_epoch = true })
		helpers.assert_eq(built, false)
	end)

	helpers.it("preserves a successor opened reentrantly by the context getter", function()
		local controller, log, once
		controller, log = controller_with({ context_epoch = function()
			if not once then once = true; controller.on_pointer_down() end
			return 1
		end })
		controller.on_pointer_down()
		helpers.assert_true(controller.selection_window_open())
		helpers.assert_eq(log.reads, 1, "retired outer getter must not read over its successor")
	end)

	helpers.it("does not open after its context getter revokes the local selection owner", function()
		local controller
		controller = controller_with({ context_epoch = function()
			controller.end_selection_window(); return 0
		end })
		controller.on_pointer_down()
		helpers.assert_eq(controller.selection_window_open(), false)
	end)

	helpers.it("discards an admitted window when its context becomes unavailable", function()
		local epoch = 1
		local controller, log, state = controller_with({ context_epoch = function() return epoch end })
		controller.on_pointer_down(); state.primary = "selected"; epoch = nil
		helpers.assert_eq(controller.on_key(symbol("(")), false)
		helpers.assert_eq(log.reads, 1)
		epoch = 1
		helpers.assert_eq(controller.on_key(symbol("(")), false)
		helpers.assert_eq(log.typed, {})
	end)

	helpers.it("still consumes confirmed output if its callback advances the context", function()
		local epoch = 0
		local controller, log, state = controller_with({ context_epoch = function() return epoch end,
			on_type = function() epoch = epoch + 1 end })
		controller.on_pointer_down(); state.primary = "selected"
		helpers.assert_true(controller.on_key(symbol("(")))
		helpers.assert_eq(log.typed, { "(selected)" })
	end)
end)
