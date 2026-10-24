--- tests/unit/modules/hotstrings/injector/test_ordinary_injection_destination.lua

--- ==============================================================================
--- MODULE: Main Ordinary Hotstring Destination Wiring
--- DESCRIPTION:
--- Executes Main's actual character-handler body with the real focus guard.
--- An ordinary expansion must carry the owner captured before its match log.
--- ==============================================================================
local helpers = require("tests.helpers")
local fixture = require("tests.support.text_owner_fixture")

helpers.describe("Main retains the ordinary expansion target", function()
	for _, moved in ipairs({ false, true }) do
		helpers.it("passes the original fifth argument with " .. (moved and "a later focus change" or "stable focus"), function()
			fixture.with(function(guard, state)
				local calls, owner, captured_current, argc, count, text = 0, nil, nil, nil, nil, nil
				local errors = {}
				local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
				logger.set_sink(function(line)
					if moved and line:find("Match fired", 1, true) then state.path = "/field/successor" end
				end)
				logger.set_error_observer(function(_, template) errors[#errors + 1] = template end)
				local environment = setmetatable({
					secure_focus_guard = guard, script_actions = { is_paused = function() return false end },
					-- Bare keys: the shared expansion delay reads the held modifiers per key.
					keyboard_hook = { held_modifiers = function() return {} end },
					Monotonic = { now_ms = function() return state.now end }, _cached_app_id = "owned-editor",
					WordReset = { observe_key = function() return false end, apply_typed_newline = function() return false end },
					terminators_mod = { is_terminator = function() return false end },
					RepeatKey = { is_enabled = function() return false end }, opts = { dry_run = false },
					keystats = { is_password_app = function() return false end, is_unrecorded_app = function() return false end, suppress = function() end,
						unsuppress = function() end, on_keydown = function() end },
					engine = { reset = function() end, on_char = function()
						return { trigger = "btw", replacement = "☃", backspace_count = 3 }
					end },
					Logger = logger,
					injector = { _is_injecting = function() return false end, _begin_injection = function() end,
						_end_injection = function() return {} end, inject = function(...)
							calls = calls + 1
							argc = select("#", ...)
							local bc, value, _, _, publication = ...
							count, text, owner = bc, value, publication
							captured_current = type(owner) == "table" and owner.current()
							return { ok = false, cleanup_ok = true, error = moved and "programmable publication is no longer current" or "controlled output refused" }
						end },
				}, { __index = _G })
				local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
				local source = file:read("*a"); assert(file:close())
				local first = assert(source:find("\tlocal function handle_char(", 1, true))
				local last = assert(source:find("\n\ton_char = input_capture_gate.guard(handle_char)", first, true))
				local body = source:sub(first, last - 1) .. "\nreturn handle_char"
				local chunk
				if loadstring then chunk = assert(loadstring(body)); setfenv(chunk, environment)
				else chunk = assert(load(body, "actual ordinary Main callback", "t", environment)) end
				chunk()("x", 30)
				helpers.assert_eq(calls, 1)
				helpers.assert_eq(argc, 5, "ordinary Main must carry its retained admission")
				helpers.assert_eq(count, 3); helpers.assert_eq(text, "☃")
				helpers.assert_type(owner, "table")
				helpers.assert_eq(captured_current, not moved, "a match log cannot retarget the already captured destination")
				helpers.assert_eq(#errors, moved and 0 or 1, "only a true output failure reaches the real error observer")
			end)
		end)
	end
end)
