--- tests/unit/modules/keystats/privacy/test_focus_guard_app_context.lua

--- ==============================================================================
--- MODULE: Native Field and Application Privacy Context Tests
--- DESCRIPTION:
--- Runs the actual daemon callbacks with real privacy consumers. A fresh ordinary
--- field cannot borrow the previous application's or window's privacy policy.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs real privacy consumers against controlled native observations.
--- @param body function Fixture assertions.
local function fixture(body)
	local names = { "modules.keystats.keystats", "modules.keystats.focus_guard", "adapters.secure_field_detector" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local called, detail = pcall(function()
		local logger = require("modules.keystats.keystats")
		local configuration = assert(logger.configuration_snapshot())
		configuration.enabled = true
		helpers.assert_true(logger.apply_configuration(configuration))
		local state = { now = 1000, bus = ":1.10", path = "/field/one", role = 61,
			app = "code", title = "Ordinary editor", reads = 0, publications = 0, depth = 0, max_depth = 0 }
		local listener, guard
		local environment = setmetatable({ _cached_app_id = "code", keystats = logger,
			-- Bare keys: the shared expansion delay reads the held modifiers per key.
			keyboard_hook = { held_modifiers = function() return {} end },
			InputEvent = require("infra.input_event"), Monotonic = { now_ms = function() return state.now end },
			injector = { _is_injecting = function() return false end },
			script_actions = { is_paused = function() return false end },
			WordReset = { observe_key = function() return false end, apply_typed_newline = function() return false end },
			terminators_mod = { is_terminator = function() return false end,
				terminator_is_consumed = function() return false end },
			engine = { on_char = function() state.engine_calls = (state.engine_calls or 0) + 1; return nil end },
			RepeatKey = { is_enabled = function() return false end },
		}, { __index = _G })
		local function snapshot()
			if state.unknown then return nil end
			return { bus = state.bus, path = state.path, role = state.role }
		end
		local watch = {
			on_change = function(fn) listener = fn end,
			invalidate = function() listener(nil) end,
			pump = function()
				state.pumping = true
				if state.changed then state.changed = false; listener(snapshot()) end
				state.pumping = false
			end,
			barrier = function()
				state.depth = state.depth + 1; state.max_depth = math.max(state.max_depth, state.depth)
				local result = snapshot()
				listener(result)
				state.depth = state.depth - 1
				return result
			end,
		}
		guard = require("modules.keystats.focus_guard").new({
			watch = watch, detector = require("adapters.secure_field_detector"), keystats = logger,
			now_ms = function() return state.now end, settle_ms = 250,
			capture_context = function()
				helpers.assert_eq(state.pumping == true, false, "context must not query from watch callbacks")
				helpers.assert_eq(state.depth, 0, "context must not query inside native admission")
				state.reads = state.reads + 1
				if state.capture then return state.capture(guard, state) end
				return { app_id = state.app, title = state.title, native_identity = "controlled-window" }
			end,
			publish_context = function(context)
				helpers.assert_true(logger.get_privacy_state().secure_field,
					"application/title policy must precede secure-field release")
				state.publications = state.publications + 1
				environment._cached_app_id = context.app_id
				logger.set_private_window(logger.is_private_window(context.title))
				if logger.is_password_app(context.app_id) then logger.suppress() else logger.unsuppress() end
				return true, logger.is_context_protected(context.app_id, context.title)
			end,
		})
		environment.secure_focus_guard = guard
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = file:read("*a"); file:close()
		local first = assert(source:find("\tlocal function handle_char(", 1, true))
		local last = assert(source:find("\n\ton_char = input_capture_gate.guard(handle_char)", first, true))
		local physical = assert(source:find("\tlocal capture_owned_scancodes = {}", last, true))
		local physical_end = assert(source:find("\n\tlocal on_physical =", physical, true))
		local code = source:sub(first, last - 1) .. "\n" .. source:sub(physical, physical_end - 1)
			.. "\nreturn { char = handle_char, physical = handle_physical }"
		local chunk
		if loadstring then chunk = assert(loadstring(code)); setfenv(chunk, environment)
		else chunk = assert(load(code, "actual daemon callbacks", "t", environment)) end
		local callbacks = chunk()
		function state.press(char, scan)
			callbacks.physical(scan, "fixture", char, environment.InputEvent.VALUE_DOWN)
			callbacks.char(char, scan)
		end
		function state.change(app, title)
			state.app, state.title, state.path, state.changed = app, title, state.path .. "_next", true
			state.now = state.now + 1
		end
		body(guard, logger, state, environment)
	end)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not called then error(detail, 0) end
end

helpers.describe("Native field application privacy context", function()
	for _, policy in ipairs({ "password application", "private window" }) do
		helpers.it("(focus-context-join) " .. policy .. " cannot borrow the previous ordinary context", function()
			fixture(function(guard, logger, state, environment)
				helpers.assert_true(guard.prime())
				state.press("A", 30)
				helpers.assert_eq(logger._pending_buffer_count_for_test(), 1)
				if policy == "password application" then state.change("bitwarden", "Vault")
				else state.change("firefox", "Private Browsing") end
				state.press("B", 31)
				helpers.assert_eq(logger._pending_buffer_count_for_test(), 1, "new owner must close persistence immediately")
				helpers.assert_eq(logger.get_app_stats().code.physical_scancodes[31], nil)
				helpers.assert_eq(state.reads, 1, "input callbacks cannot query context")
				helpers.assert_true(guard.refresh(false))
				helpers.assert_eq(environment._cached_app_id, state.app)
				state.press("C", 32)
				helpers.assert_eq(logger._pending_buffer_count_for_test(), 1, "role 61 cannot override app/window privacy")
				helpers.assert_eq(state.engine_calls, 1, "protected input cannot reach the text engine")
				helpers.assert_true(guard.blocks_text(), "manual consumers must see protected context before physical input")
				helpers.assert_true(require("adapters.secure_field_detector").isSecureField())
				helpers.assert_eq(state.reads, 2)
				helpers.assert_eq(state.max_depth, 1)
			end)
		end)
	end

	helpers.it("(focus-context-join) same validated owner does not query context per character", function()
		fixture(function(guard, logger, state)
			helpers.assert_true(guard.prime())
			for _ = 1, 20 do state.press("a", 30); guard.refresh(false) end
			helpers.assert_eq(state.reads, 1)
			helpers.assert_eq(logger._pending_buffer_count_for_test(), 20)
		end)
	end)

	for _, refusal in ipairs({ "nil", "throw", "changed", "unknown", "reenter" }) do
		helpers.it("(focus-context-join) context admission refuses " .. refusal, function()
			fixture(function(guard, logger, state)
				helpers.assert_true(guard.prime())
				state.change("new-app", "New window")
				state.capture = function(owner)
					if refusal == "throw" then error("controlled context refusal") end
					if refusal == "nil" then return nil end
					if refusal == "changed" then state.path = "/another/field"; state.changed = true end
					if refusal == "unknown" then state.unknown = true end
					if refusal == "reenter" then helpers.assert_eq(owner.refresh(true), false); owner.invalidate() end
					return { app_id = "new-app", title = "New window", native_identity = "controlled-window" }
				end
				helpers.assert_eq(guard.refresh(false), false)
				state.press("X", 30)
				helpers.assert_eq(logger._pending_buffer_count_for_test(), 0)
				helpers.assert_eq(state.publications, 1, "refused context must never publish")
			end)
		end)
	end

	helpers.it("(focus-context-join) a title-only invalidation replaces policy on the same native field", function()
		fixture(function(guard, logger, state)
			helpers.assert_true(guard.prime())
			local path = state.path
			state.title = "Private Browsing"
			guard.invalidate()
			helpers.assert_eq(guard.current_context(), nil)
			state.now = state.now + 250
			helpers.assert_true(guard.refresh(false))
			helpers.assert_eq(state.path, path)
			state.press("X", 30)
			helpers.assert_eq(logger._pending_buffer_count_for_test(), 0)
			helpers.assert_true(guard.blocks_text())
			helpers.assert_eq(state.reads, 2)
		end)
	end)

	for _, filter in ipairs({ "secure_filter_enabled", "private_filter_enabled" }) do
		helpers.it("(focus-context-join) live " .. filter .. " applies without another metadata query", function()
			fixture(function(guard, logger, state)
				if filter == "secure_filter_enabled" then state.app = "bitwarden"
				else state.title = "Private Browsing" end
				helpers.assert_true(guard.prime())
				helpers.assert_true(guard.blocks_text())
				local configuration = logger.configuration_snapshot()
				configuration[filter] = false
				helpers.assert_true(logger.apply_configuration(configuration))
				helpers.assert_eq(guard.blocks_text(), false)
				configuration[filter] = true
				helpers.assert_true(logger.apply_configuration(configuration))
				helpers.assert_true(guard.blocks_text())
				helpers.assert_eq(state.reads, 1)
				local context = guard.current_context()
				context.app_id = "tampered"
				helpers.assert_eq(guard.current_context().app_id, state.app)
			end)
		end)
	end

	helpers.it("(focus-context-join) password role closes without a context query", function()
		fixture(function(guard, logger, state)
			helpers.assert_true(guard.prime())
			state.role, state.changed = 40, true
			state.press("X", 30)
			helpers.assert_eq(logger._pending_buffer_count_for_test(), 0)
			helpers.assert_true(guard.blocks_text())
			helpers.assert_eq(state.reads, 1)
		end)
	end)
end)
