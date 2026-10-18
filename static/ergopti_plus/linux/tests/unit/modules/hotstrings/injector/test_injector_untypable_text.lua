--- tests/unit/modules/hotstrings/injector/test_injector_untypable_text.lua

--- ==============================================================================
--- MODULE: Delivering a Replacement the Layout Cannot Type
--- DESCRIPTION:
--- A Spanish hotstring pack on a French keyboard. A Greek one on a US keyboard.
--- The replacement contains characters that exist on NO key of the layout the
--- user is actually typing on, at any level.
---
--- WHY THIS IS A TEST AND NOT A COMMENT:
--- The driver now types replacements as real keystrokes, resolved against the
--- user's real XKB layout, which is what made accented French text work without a
--- clipboard round-trip. That same change is what creates this case: keystroke
--- synthesis can only produce characters the layout has a key for. `ñ` on an
--- AZERTY layout has none — not unshifted, not shifted, not on AltGr — so there
--- is no keycode to press and the layout path cannot deliver it at all.
---
--- The dangerous failure is not "nothing is typed". It is "half is typed".
--- `inject()` erases the trigger BEFORE sending the replacement, so a planner
--- that emitted the characters it could and skipped the rest would leave the user
--- with `seor` where they had typed a trigger — text destroyed, silently, and
--- only for people whose language is not the layout's. Hence plan() is
--- all-or-nothing and the clipboard carries the whole string or nothing does.
---
--- These tests pin the three outcomes in order: typable → keystrokes and no
--- clipboard; untypable → clipboard, whole and unsplit; untypable with no
--- clipboard tool → an ERROR before the trigger is erased. Clipboard capability
--- alone cannot guarantee a later snapshot or paste will succeed.
--- ==============================================================================

local helpers = require("tests.helpers")


-- A layout with no Spanish letters: exactly what a French or US keymap gives a
-- user who installs the Spanish hotstring pack.
local LAYOUT_WITHOUT_SPANISH = {
	["s"] = { keycode = 31, mods = {} },
	["e"] = { keycode = 18, mods = {} },
	["o"] = { keycode = 24, mods = {} },
	["r"] = { keycode = 19, mods = {} },
	["S"] = { keycode = 31, mods = { "shift" } },
}


--- A uinput channel that records every emitted event.
--- @param open boolean Whether the channel reports itself as open.
--- @return table
local function fake_channel(open)
	local ch = { emitted = {} }
	ch.is_open = function() return open end
	ch.emit = function(code, value)
		ch.emitted[#ch.emitted + 1] = { code = code, value = value }
		return true
	end
	return ch
end


--- Installs a clipboard stub and returns it, along with a restore function.
--- @param succeeds boolean Whether paste_text reports success.
--- @return table stub, function restore
local function stub_clipboard(succeeds)
	local previous = package.loaded["adapters.clipboard"]
	local stub = { calls = {} }
	stub.is_available = function() return succeeds end
	stub.paste_text = function(text)
		stub.calls[#stub.calls + 1] = text
		return succeeds
	end
	package.loaded["adapters.clipboard"] = stub
	return stub, function() package.loaded["adapters.clipboard"] = previous end
end


--- Loads the injector with a layout table and a channel already wired in.
--- @param channel table The fake uinput channel.
--- @param prepare_layout function|nil Installs a controlled planning boundary before capture.
--- @return table injector
local function load_injector(channel, prepare_layout)
	local layout = helpers.load_module("adapters.keyboard_layout")
	layout._set_table_for_test(LAYOUT_WITHOUT_SPANISH)
	if prepare_layout then prepare_layout(layout) end
	local injector = helpers.load_module("modules.hotstrings.injector")
	injector._set_uinput(channel)
	-- Real sleeps would make this suite wait on every backspace for nothing:
	-- the delay is a property of the injection timing, not of the routing.
	injector._set_nanosleep_for_test(function() end)
	return injector
end





-- =========================================================================
-- =========================================================================
-- ======= 1/ Typable text never reaches the clipboard =====================
-- =========================================================================
-- =========================================================================

helpers.describe("injector: a replacement the layout can type is typed", function()

	helpers.it("emits keystrokes and leaves the clipboard untouched", function()
		local clip, restore = stub_clipboard(true)
		local ch = fake_channel(true)
		local injector = load_injector(ch)

		-- "señor" minus the one letter this layout lacks: every character here has
		-- a key, so the whole string must go out as keystrokes.
		injector.inject(0, "seor")

		helpers.assert_eq(#clip.calls, 0,
			"the clipboard must not be used for a string every character of which has a key")
		helpers.assert_true(#ch.emitted > 0,
			"and the replacement must have gone out as real key events")
		restore()
	end)

end)





-- =========================================================================
-- =========================================================================
-- ======= 2/ Untypable text goes out whole, through the clipboard =========
-- =========================================================================
-- =========================================================================

helpers.describe("injector: a replacement the layout cannot type is pasted whole", function()

	helpers.it("sends the entire string to the clipboard, not the typable part of it", function()
		local clip, restore = stub_clipboard(true)
		local ch = fake_channel(true)
		local injector = load_injector(ch)

		injector.inject(0, "señor")

		helpers.assert_eq(#clip.calls, 1,
			"exactly one clipboard delivery — a per-character fallback would paste five times")
		helpers.assert_eq(clip.calls[1], "señor",
			"and it carries the WHOLE replacement; a partial paste after the erase destroys text")
		restore()
	end)

	helpers.it("emits no character keystrokes for the string it could not plan", function()
		local clip, restore = stub_clipboard(true)
		local ch = fake_channel(true)
		local injector = load_injector(ch)

		injector.inject(0, "señor")

		-- The four typable letters of "señor" are s, e, o and r. If any of their
		-- keycodes was pressed, the planner ran per-character and the user got
		-- "seor" followed by a paste of "señor" — the text doubled, not fixed.
		local typable_codes = { [31] = "s", [18] = "e", [24] = "o", [19] = "r" }
		for _, event in ipairs(ch.emitted) do
			helpers.assert_true(typable_codes[event.code] == nil,
				"no character key may be pressed once the plan was refused")
		end
		restore()
	end)

end)





-- =========================================================================
-- =========================================================================
-- ======= 3/ A key typed in place of another never pastes =================
-- =========================================================================
-- =========================================================================

-- The physical magic key types ★ in place of the key the hook consumed. Through
-- inject(), a stock layout without ★ pasted it on every press — clipboard tools
-- spawned inside the hook, the clipboard history filled — and a paste that
-- failed stopped the grab.
helpers.describe("injector: a key typed in place of another is key presses or nothing", function()

	helpers.it("(magic-key-source) refuses an untypable character without sending or pasting anything", function()
		local clip, restore = stub_clipboard(true)
		local previous_hook = package.loaded["adapters.keyboard_hook"]
		local stops = {}
		package.loaded["adapters.keyboard_hook"] = {
			emergency_stop = function(reason) stops[#stops + 1] = reason end,
		}
		local ch = fake_channel(true)
		local injector = load_injector(ch)
		local ok, err = pcall(function()
			helpers.assert_eq(injector.can_type_directly("★"), false, "no key of this layout types ★")
			local result = injector.type_directly("★")
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.error, "untypable")
			helpers.assert_eq(#clip.calls, 0, "never a paste")
			helpers.assert_eq(#ch.emitted, 0, "nothing sent: the caller lets the key through")
			helpers.assert_eq(#stops, 0, "and the grab is kept")

			helpers.assert_true(injector.can_type_directly("s"))
			helpers.assert_true(injector.type_directly("s").ok)
			helpers.assert_eq(#clip.calls, 0)
			local pressed = false
			for _, event in ipairs(ch.emitted) do
				if event.code == 31 and event.value == 1 then pressed = true end
			end
			helpers.assert_true(pressed, "a typable character goes out as its key")
			helpers.assert_eq(#stops, 0)
		end)
		restore()
		package.loaded["adapters.keyboard_hook"] = previous_hook
		if not ok then error(err, 0) end
	end)

end)





-- =========================================================================
-- =========================================================================
-- ======= 4/ No clipboard route is said out loud ==========================
-- =========================================================================
-- =========================================================================

helpers.describe("injector: an undeliverable replacement is reported, not swallowed", function()

	helpers.it("(injection-route-preflight) does not commit a failed paste just because its backend exists", function()
		local previous_hook = package.loaded["adapters.keyboard_hook"]
		package.loaded["adapters.keyboard_hook"] = { emergency_stop = function() end }
		local clip, restore = stub_clipboard(false)
		clip.is_available = function() return true end
		local ok, why = pcall(function()
			local result = load_injector(fake_channel(true)).inject(3, "señor")
			helpers.assert_eq(#clip.calls, 1, "the available backend reaches the actual paste boundary")
			helpers.assert_eq(result.ok, false, "backend availability is not an output commit")
			helpers.assert_eq(result.cleanup_ok, true)
			-- This later failure may follow erasure. Clipboard snapshot preparation
			-- is a separate transaction; this preflight cannot promise its rollback.
		end)
		restore(); package.loaded["adapters.keyboard_hook"] = previous_hook
		if not ok then error(why, 0) end
	end)

	for _, boundary in ipairs({ "plan", "publication", "stable" }) do
		helpers.it("(injection-route-preflight) retains the original Writer epoch across " .. boundary, function()
			local Input = require("infra.input_event")
			local Broker = require("adapters.modifier_broker")
			local previous_writer = package.loaded["adapters.uinput_writer"]
			local previous_hook = package.loaded["adapters.keyboard_hook"]
			package.loaded["adapters.keyboard_hook"] = { emergency_stop = function() end }
			local path = os.tmpname(); local file = assert(io.open(path, "w")); assert(file:close())
			local writer, rows = helpers.load_module("adapters.uinput_writer"), {}
			writer._set_path_for_test(path)
			writer._set_backend({ open = function() return 7 end, ioctl = function() return true end,
				close = function() return true end, write = function(_, bytes)
					local event = Input.decode(bytes)
					if event.type == Input.EV_KEY then rows[#rows + 1] = { event.code, event.value } end
					return true
				end })
			local injector, armed, observed, successor
			local function intervene()
				if not armed then return end
				armed, observed = false, true
				assert(injector.close_fast_channel()); assert(injector.open_fast_channel())
				successor = assert(writer.capture_output())
			end
			injector = load_injector(writer, function(layout)
				local plan = layout.plan
				layout.plan = function(text)
					local offered, blocker, receipt = plan(text)
					if boundary == "plan" then intervene() end
					return offered, blocker, receipt
				end
			end)
			local ok, why = pcall(function()
				assert(injector.open_fast_channel())
				local original, original_broker = assert(writer.capture_output()), assert(Broker.for_channel(writer))
				local emit, open = writer.emit, writer.is_open
				armed = true
				local publication = boundary == "publication" and {
					current = function() intervene(); return true end, cached = function() return true end,
				} or nil
				local result = injector.inject(3, "seor", false, nil, publication)
				if boundary == "stable" then
					helpers.assert_eq(observed, nil, "the positive control performs no output replacement")
					helpers.assert_true(result.ok and result.cleanup_ok, "the original busy reservation remains admissible")
					helpers.assert_true(writer.output_current(original) and Broker.for_channel(writer) == original_broker)
					helpers.assert_eq(rows, { { 14, 1 }, { 14, 0 }, { 14, 1 }, { 14, 0 }, { 14, 1 }, { 14, 0 },
						{ 31, 1 }, { 31, 0 }, { 18, 1 }, { 18, 0 }, { 24, 1 }, { 24, 0 }, { 19, 1 }, { 19, 0 } })
					return
				end
				helpers.assert_true(observed, "actual channel close/reopen must occur at the original observation")
				helpers.assert_true(writer.emit == emit and writer.is_open == open, "module and API identities survive the real epoch change")
				helpers.assert_true(not writer.output_current(original) and writer.output_current(successor))
				helpers.assert_true(Broker.for_channel(writer) ~= original_broker, "the actual successor has a new custody owner")
				helpers.assert_eq(result.ok, false, "no adoption of a successor output under the old preparation")
				helpers.assert_eq(result.cleanup_ok, true)
				helpers.assert_eq(rows, {}, "neither erasure nor replacement reaches the successor Writer")
			end)
			assert(injector.close_fast_channel()); writer._reset_backend(); assert(os.remove(path))
			package.loaded["adapters.uinput_writer"], package.loaded["adapters.keyboard_hook"] = previous_writer, previous_hook
			if not ok then error(why, 0) end
		end)
	end

	for _, route in ipairs({ "native", "clipboard" }) do
		helpers.it("(injection-route-preflight) retains a complete " .. route .. " route across trigger erasure", function()
			local clip, restore = stub_clipboard(true)
			local ch, plans = fake_channel(true), 0
			local injector = load_injector(ch, function(layout)
				local plan = layout.plan
				layout.plan = function(text) plans = plans + 1; return plan(text) end
			end)
			local text = route == "native" and "seor" or "señor"
			local result = injector.inject(3, text)
			local deleted, typed = 0, {}
			for _, event in ipairs(ch.emitted) do
				if event.code == 14 and event.value == 1 then deleted = deleted + 1 end
				if event.value == 1 and event.code ~= 14 then typed[#typed + 1] = event.code end
			end
			helpers.assert_true(result.ok, "the complete route must still commit")
			helpers.assert_eq(deleted, 3)
			helpers.assert_eq(plans, 1, "retain the original plan result instead of replanning after erasure")
			helpers.assert_eq(#clip.calls, route == "native" and 0 or 1)
			if route == "native" then helpers.assert_eq(table.concat(typed, " "), "31 18 24 19")
			else helpers.assert_eq(clip.calls[1], text); helpers.assert_eq(#typed, 0) end
			restore()
		end)
	end

	for _, revoked in ipairs({ "channel", "layout", "plan-api", "current-api", "channel-api", "publication", "held-codes" }) do
		helpers.it("(injection-route-preflight) refuses " .. revoked .. " replacement during route observation", function()
			local clip, restore = stub_clipboard(true)
			local ch, successor, observed = fake_channel(true), fake_channel(true), false
			local previous_hook = package.loaded["adapters.keyboard_hook"]
			local injector, original_plan, original_current, original_emit, layout_owner
			local function intervene(layout)
				observed = true
				if revoked == "channel" or revoked == "publication" or revoked == "held-codes" then injector._set_uinput(successor)
				elseif revoked == "layout" then layout._set_table_for_test(LAYOUT_WITHOUT_SPANISH)
				elseif revoked == "plan-api" then layout.plan = function() error("successor plan must not be adopted") end
				elseif revoked == "current-api" then layout.plan_current = function() return true end
				else ch.emit = function() error("successor channel port must not be adopted") end end
			end
			injector = load_injector(ch, function(layout)
				layout_owner, original_plan, original_current, original_emit = layout, layout.plan, layout.plan_current, ch.emit
				layout.plan = function(text)
					local plan, blocker, receipt = original_plan(text)
					if revoked ~= "publication" and revoked ~= "held-codes" then intervene(layout) end
					return plan, blocker, receipt
				end
			end)
			local publication
			if revoked == "publication" then publication = {
				current = function() intervene(layout_owner); return true end,
				cached = function() return true end,
			} end
			if revoked == "held-codes" then package.loaded["adapters.keyboard_hook"] = {
				held_text_modifier_codes = function() intervene(layout_owner); return { 42 } end,
				emergency_stop = function() end,
			} end
			local ok, why = pcall(function()
				local result = injector.inject(3, "seor", false, nil, publication)
				helpers.assert_true(observed, "the original route boundary must actually reenter")
				helpers.assert_eq(result.ok, false)
				helpers.assert_eq(result.cleanup_ok, true)
				helpers.assert_eq(#ch.emitted, 0, "the original route cannot erase under a revoked observation")
				helpers.assert_eq(#successor.emitted, 0, "a successor channel cannot inherit the old expansion")
				helpers.assert_eq(#clip.calls, 0, "authority loss is not an untypable-character clipboard fallback")
			end)
			layout_owner.plan, layout_owner.plan_current, ch.emit = original_plan, original_current, original_emit
			package.loaded["adapters.keyboard_hook"] = previous_hook
			restore()
			if not ok then error(why, 0) end
		end)
	end

	helpers.it("(injection-route-preflight) preserves the trigger and grab when no complete replacement route exists", function()
		local previous_hook = package.loaded["adapters.keyboard_hook"]
		local stopped = 0
		package.loaded["adapters.keyboard_hook"] = { emergency_stop = function() stopped = stopped + 1 end }
		local clip, restore = stub_clipboard(false)
		local ch, document = fake_channel(true), "btw"
		local emit = ch.emit
		ch.emit = function(code, value)
			if code == 14 and value == 1 then document = document:sub(1, -2) end
			return emit(code, value)
		end
		local ok, why = pcall(function()
			local result = load_injector(ch).inject(3, "señor")
			helpers.assert_eq(result.ok, false, "an impossible expansion is refused")
			helpers.assert_eq(result.cleanup_ok, true, "no output debt was acquired")
			helpers.assert_eq(document, "btw", "the original trigger survives refusal")
			helpers.assert_eq(#ch.emitted, 0, "no erase or modifier neutralisation precedes route admission")
			helpers.assert_eq(#clip.calls, 0, "an unavailable clipboard is not attempted after erasing")
			helpers.assert_eq(stopped, 0, "a missing text route cannot disable a healthy grabbed keyboard")
		end)
		restore(); package.loaded["adapters.keyboard_hook"] = previous_hook
		if not ok then error(why, 0) end
	end)

	helpers.it("logs an ERROR when neither the layout nor the clipboard can deliver", function()
		-- The stub's error() is a no-op, so it is replaced with a recorder here
		-- rather than asserted through: what matters is that the ERROR variant was
		-- the one chosen, not that some line was written somewhere.
		local logger = helpers.make_logger_stub()
		local said = {}
		logger.error = function(_, fmt, ...)
			said[#said + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
		end
		local previous_logger = package.loaded["logger.shim"]
		package.loaded["logger.shim"] = logger

		local _, restore = stub_clipboard(false)
		local ch = fake_channel(true)
		local injector = load_injector(ch)

		injector.inject(0, "señor")

		local mentioned = false
		for _, line in ipairs(said) do
			if line:find("señor", 1, true) then mentioned = true end
		end
		helpers.assert_true(mentioned,
			"a replacement refused before erasure must still explain its unavailable route")

		restore()
		package.loaded["logger.shim"] = previous_logger
	end)

end)
