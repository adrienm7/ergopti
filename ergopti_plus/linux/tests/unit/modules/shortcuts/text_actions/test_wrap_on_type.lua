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
