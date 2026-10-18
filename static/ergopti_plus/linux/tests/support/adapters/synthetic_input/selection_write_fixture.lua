--- tests/support/adapters/synthetic_input/selection_write_fixture.lua

--- ==============================================================================
--- MODULE: Selected Write Ownership Fixture
--- DESCRIPTION:
--- Runs the real range owner, focus guard, injector and clipboard with explicit
--- native-range and desktop I/O ports. These units make no native input claim.
--- ==============================================================================
local M = {}
local helpers = require("tests.helpers")
local text_owner = require("tests.support.text_owner_fixture")

--- Runs an isolated selected write with controlled native settlement boundaries.
--- @param body function Receives the state and its real selection owner.
function M.with(body)
	text_owner.with(function(guard, field)
		local names = { "adapters.selection_transaction", "adapters.atspi_focus", "modules.hotstrings.injector",
			"adapters.clipboard", "adapters.shell_runner", "infra.display_server", "adapters.keyboard_layout",
			"adapters.keyboard_hook", "logger.shim", "modules.hotstrings.selected_output", "infra.monotonic" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local state = { allowed = true, guard = guard, field = field, wire = {}, held = {}, writes = {},
			clipboard = "SAVED", starts = 0, emits = 0, resets = 0, stopped = 0, now = 0,
			selection = { first = 0, last = 3, text = "btw" }, requests = {} }
		package.loaded["infra.monotonic"] = { now_ms = function() return state.now end }
		package.loaded["modules.hotstrings.selected_output"] = nil
		local function boundary(name)
			if state.on_boundary then state.on_boundary(name) end
		end
		local native = { cached_snapshot = function()
			return { native_bus_name = field.bus, native_object_path = field.path, role = field.role }
		end }
		function native.start_selection_capture(expected, options, callback)
			state.starts = state.starts + 1
			state.requests[#state.requests + 1] = options
			local settled, listeners = false, {}
			local operation = {}
			function operation:is_settled() return settled end
			function operation:cancel() return settled end
			function operation:on_settled(fn) listeners[#listeners + 1] = fn; return true end
			state.deliver = function()
				settled = true
				local selected = options.span and state.inserted or state.selection
				if selected then callback({ bus = expected.bus, path = expected.path, role = expected.role,
					first = selected.first, last = selected.last, text = selected.text })
				else callback(nil) end
				for _, fn in ipairs(listeners) do fn() end
			end
			return operation
		end
		package.loaded["adapters.atspi_focus"], package.loaded["adapters.selection_transaction"] = native, nil
		local pending
		package.loaded["adapters.shell_runner"] = {
			has_command = function() return true end,
			exec_checked = function() boundary("read"); return true, state.clipboard end,
			with_exact_stdin = function(_, text) pending = text; return "controlled clipboard write" end,
			run = function()
				local text = pending
				state.writes[#state.writes + 1] = text
				boundary(text == "SAVED" and "restore" or "write")
				if text == "SAVED" and state.restore_refused then return false end
				state.clipboard = text
				return true
			end,
		}
		package.loaded["infra.display_server"] = {
			is_wayland = function() return false end, is_x11 = function() return true end,
			kind = function() return "x11" end,
		}
		package.loaded["adapters.keyboard_hook"] = {
			held_text_modifier_codes = function() return {} end, held_shortcut_modifier_codes = function() return {} end,
			held_forwarded_keys = function() return {} end, emergency_stop = function() state.stopped = state.stopped + 1 end,
		}
		local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
		logger.set_sink(function() end)
		package.loaded["logger.shim"] = logger
		local injector
		local ok, err = pcall(function()
			local layout = helpers.load_module("adapters.keyboard_layout")
			layout._set_table_for_test({ o = { keycode = 24, mods = {} }, k = { keycode = 37, mods = {} } })
			local lookup = layout.shortcut_keycode
			layout.shortcut_keycode = function(...) boundary("lookup"); return lookup(...) end
			helpers.load_module("adapters.clipboard")
			injector = helpers.load_module("modules.hotstrings.injector")
			injector._set_uinput({ is_open = function() return true end, emit = function(code, value)
				boundary("emit:" .. code .. ":" .. value)
				if state.refuse_up and value == 0 and code == state.refuse_up then return false end
				state.wire[#state.wire + 1] = code .. ":" .. value
				state.held[code] = value == 1 or nil
				return true
			end })
			injector._set_nanosleep_for_test(function(seconds)
				boundary(seconds == .03 and "settle" or seconds == .12 and "restore-wait" or "reselect")
			end)
			state.injector = injector
			local capture = guard.capture_text_owner
			state.owner = require("adapters.selection_transaction").new({
				focus_id = guard.focused_text_identity, privacy_guard = guard.blocks_text,
				capture_text_owner = function(focus)
					state.captured_focus = focus
					boundary("capture-owner")
					return state.capture_override and state.capture_override(focus) or capture(focus)
				end,
			})
			state.authorized = function() boundary("authorized"); return state.allowed end
			function state.staged(token, text, construct)
				text = text or "☃"
				state.inserted = { first = 0, last = assert(require("compat.utf8").len(text)), text = text }
				local called, committed, result = false, false, nil
				local accepted = state.owner.replace_staged(token, text, state.authorized, construct or injector.prepare_selected, function(value, physical)
					called, committed, result = true, value, physical
				end)
				for _ = 1, 3 do
					if called then break end
					local deliver = assert(state.deliver, "native request must be retained")
					state.deliver = nil
					deliver()
				end
				helpers.assert_true(called, "staged completion must run")
				return committed, result, accepted
			end
			function state.read()
				local token
				helpers.assert_true(state.owner.read(guard.focused_text_identity(), state.authorized, function(accepted, _, _, receipt)
					helpers.assert_true(accepted); token = receipt
				end))
				state.deliver()
				return assert(token)
			end
			function state.construct(text, publication)
				state.publication = publication
				local stage = injector.prepare_selected(text, publication)
				local payload = stage.payload
				stage.payload = function() state.emits = state.emits + 1; return payload() end
				return stage
			end
			function state.replace(token, emit, text)
				local called, committed = false, false
				text = text or "☃"
				state.inserted = { first = 0, last = assert(require("compat.utf8").len(text)), text = text }
				local construct = state.construct
				if emit then
					construct = function(value, publication)
						local known_cleanup = false
						return {
							prepare = function() return publication.current() end,
							payload = function()
								state.emits = state.emits + 1
								local result = emit(value, publication)
								known_cleanup = type(result) == "table" and result.cleanup_ok == true
									and result.failed_phase ~= "clipboard restoration"
								if type(result) == "table" and result.cleanup_ok ~= nil then
									result.native_cleanup_ok = known_cleanup
									result.payload_written = result.ok == true
								end
								return result
							end,
							reselect = function() return { ok = true, cleanup_ok = true, native_cleanup_ok = true } end,
							close = function() return known_cleanup end,
						}
					end
				end
				local accepted = state.owner.replace_staged(token, text, state.authorized, construct, function(value)
					called, committed = true, value
					if value then state.resets = state.resets + 1 end
				end)
				for _ = 1, 2 do if accepted and not called then state.deliver() end end
				helpers.assert_true(called, "replacement completion must run")
				return committed
			end
			body(state, state.owner)
		end)
		if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end

return M
