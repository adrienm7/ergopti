--- tests/unit/modules/llm/features/test_selected_main_cache.lua

--- ==============================================================================
--- MODULE: Main Cache Invalidation At Selected Payload ACK
--- DESCRIPTION:
--- Executes the actual selected-write and control-key callbacks with the real
--- hotstring engine while the post-caret helper deliberately remains in flight.
--- ==============================================================================
local helpers = require("tests.helpers")
local Fixture = require("tests.support.adapters.synthetic_input.selection_write_fixture")

helpers.describe("Main selected payload cache boundary", function()
	helpers.it("invalidates old buffer and Undo before the post-caret wait without clearing later input", function()
		Fixture.with(function(state, owner)
			local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
			local source = file:read("*a"); file:close()
			local prefix = "replace_selection = function(text, receipt, authorized, callback)"
			local first = assert(source:find(prefix, 1, true))
			local last = assert(source:find("\n\t\t\tend,", first, true))
			local replace_source = source:sub(first + #"replace_selection = ", last + #"\n\t\t\tend" - 1)
			first = assert(source:find("local function handle_control(key_name, detail)", 1, true))
			last = assert(source:find("\n\tend\n", first, true))
			local control_source = source:sub(first, last + #"\n\tend" - 1)
			local compile = loadstring or load
			local factory = assert(compile("return function(injector,privacy_owners,opts,engine,WordReset,Monotonic,Logger,script_actions,prediction_engine) "
				.. "local _undoable={trigger='old',replacement='OLD'}; local LOG='Main cache test'; "
				.. control_source .. "; return " .. replace_source .. ",handle_control,function() return _undoable end end"))()
			local engine = require("modules.hotstrings.engine").new()
			for ch in ("btw"):gmatch(".") do engine:on_char(ch) end
			helpers.assert_eq(engine:current_buffer(), "btw")
			local reset, resets = engine.reset, 0
			engine.reset = function(self, ...) resets = resets + 1; return reset(self, ...) end
			local undo_outputs = 0
			local injector = { prepare_selected = state.injector.prepare_selected,
				inject = function() undo_outputs = undo_outputs + 1; return { ok = true } end }
			local replace, control, undo = factory(injector, { selection = owner }, { dry_run = false }, engine,
				{ observe_key = function() end }, { now_ms = function() return 0 end }, require("logger.shim"),
				{ is_paused = function() return false end }, { withdraw = function() state.allowed = false; owner.cancel() end })
			local token = state.read()
			state.inserted = { first = 0, last = 1, text = "☃" }
			local committed
			helpers.assert_true(replace("☃", token, state.authorized, function(value) committed = value end))
			state.deliver()
			helpers.assert_eq(committed, nil, "the post-caret native operation is still pending")
			helpers.assert_eq(engine:current_buffer(), "", "the payload already changed the physical document")
			helpers.assert_eq(undo(), nil)
			control("backspace", {})
			helpers.assert_eq(undo_outputs, 0, "a Backspace cannot replay the old expansion during the async wait")
			engine:on_char("x")
			state.inserted = nil
			state.deliver()
			helpers.assert_eq(committed, false)
			helpers.assert_eq(engine:current_buffer(), "x", "late failure cannot reset a newer input context")
			helpers.assert_eq(resets, 1)
			helpers.assert_true(owner.is_settled())
		end)
	end)
end)
