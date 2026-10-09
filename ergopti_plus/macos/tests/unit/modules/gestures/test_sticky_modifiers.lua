--- tests/unit/modules/gestures/test_sticky_modifiers.lua

--- ==============================================================================
--- MODULE: Sticky (one-shot) Modifiers — policy contract
--- DESCRIPTION:
--- The fifteen `sticky_*` actions of the Karabiner catalogue are the ONE family a
--- gesture cannot delegate: `sticky_modifier` is a manipulator construct that
--- only exists as the `to` of a key Karabiner is already grabbing, and
--- `karabiner_cli` can set variables but cannot fire a manipulator. So macOS
--- reimplements the behaviour, and a reimplementation is only as good as its
--- fidelity to the original.
---
--- WHAT THIS PINS, AND WHY EACH ONE MATTERS:
---
--- 1. TOGGLE IS PER-MODIFIER. `sticky_cmd_shift` is TWO `sticky_modifier` entries
---    in the catalogue, not one compound. Arming cmd+shift while cmd is already
---    armed must therefore leave shift armed and cmd released. The obvious
---    implementation — "set the whole set, or clear it if it matches" — passes a
---    single-modifier test and diverges from Karabiner the moment two sticky
---    actions are used in sequence, which is exactly how people use them.
---
--- 2. NO INVENTED DELAY. The auto-cancel delay is the value the user typed into
---    the remap menu. A `timeout or 3` fallback would silently override that
---    choice on precisely the boot where the configuration failed to load — the
---    one time the user needs to be told something is wrong.
---
--- 3. AN UNKNOWN MODIFIER IS REFUSED, NOT ARMED. "command" instead of "cmd" arms
---    a flag no key event carries, so the gesture appears to do nothing at all
---    and the bug reads as gesture recognition rather than a typo.
---
--- The module is pure policy — every OS call lives in adapters/ — so this test
--- drives the real code with stub adapters and observes what it asks them to do.
--- ==============================================================================

local helpers = require("tests.helpers")

-- A one-second delay: any positive number works, and naming it keeps the intent
-- of "the caller supplied a usable value" separate from the value itself.
local TIMEOUT_SEC = 1.0




-- ==========================================================
-- ==========================================================
-- ======= 1/ Harness — stub the two adapters ===============
-- ==========================================================
-- ==========================================================

--- Loads the module against recording stubs of its two adapters.
--- @return table Sticky module, table injector recorder, table timer recorder.
local function fresh_sticky()
	local Sticky
	local injector = {
		armed_with  = nil,
		on_applied  = nil,
		arm_calls   = 0,
		disarm_calls = 0,
		next_arm_fails = false,
		disarm_modes = {},
		reenter_clear_parent = nil,
	}
	local timers = {
		scheduled = {}, cancelled = 0, cancel_handles = {},
		next_committed = true, next_after_throws = false, cancel_results = {},
		reenter_clear_parent = nil,
	}

	package.loaded["adapters.modifier_injector"] = {
		arm = function(flags, on_applied)
			injector.arm_calls = injector.arm_calls + 1
			if injector.next_arm_fails then return false end
			local copy = {}
			for name in pairs(flags) do copy[name] = true end
			injector.armed_with = copy
			injector.on_applied = on_applied
			if injector.reenter_clear_parent ~= nil then
				local parent = injector.reenter_clear_parent
				injector.reenter_clear_parent = nil
				injector.reentrant_clear_result = Sticky.clear(parent)
			end
			return true
		end,
		disarm = function()
			injector.disarm_calls = injector.disarm_calls + 1
			local mode = table.remove(injector.disarm_modes, 1)
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			if mode == "throw" then error("synthetic disarm refusal") end
			injector.armed_with   = nil
			injector.on_applied   = nil
			return true
		end,
		is_armed = function() return injector.armed_with ~= nil end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(delay, fn)
			if timers.next_after_throws then
				timers.next_after_throws = false
				error("timer acquisition exploded")
			end
			local committed = timers.next_committed
			timers.next_committed = true
			local handle = { delay = delay, fn = fn, timer = {}, committed = committed, fired = false }
			timers.scheduled[#timers.scheduled + 1] = handle
			if timers.reenter_clear_parent ~= nil then
				local parent = timers.reenter_clear_parent
				timers.reenter_clear_parent = nil
				timers.reentrant_clear_result = Sticky.clear(parent)
			end
			return handle, committed
		end,
		cancel = function(handle)
			timers.cancelled = timers.cancelled + 1
			timers.cancel_handles[timers.cancelled] = handle
			local result = timers.cancel_results[timers.cancelled]
			if result == false then return false end
			if handle then
				handle.timer = nil
				handle.committed = false
				handle.fired = true
			end
			return true
		end,
	}

	package.loaded["modules.gestures.sticky_modifiers"] = nil
	Sticky = helpers.load_with_stubs("modules.gestures.sticky_modifiers")
	return Sticky, injector, timers
end

--- Sorted, comma-joined view of an armed set, for readable assertions.
--- @param set table|nil
--- @return string
local function describe(set)
	if not set then return "(none)" end
	local names = {}
	for name in pairs(set) do names[#names + 1] = name end
	table.sort(names)
	-- An EMPTY table is not nil, and joining it gives "" — which reads as a
	-- passing comparison against another empty result rather than as "nothing is
	-- armed". Naming the empty case keeps the failure messages legible.
	return #names > 0 and table.concat(names, ",") or "(none)"
end




-- ==========================================================
-- ==========================================================
-- ======= 2/ The contract ==================================
-- ==========================================================
-- ==========================================================

helpers.describe("gestures.sticky_modifiers", function()

	helpers.it("arms the requested modifier and schedules the auto-cancel", function()
		local Sticky, injector, timers = fresh_sticky()
		helpers.assert_true(Sticky.toggle({ "shift" }, TIMEOUT_SEC), "a valid call must be accepted")
		helpers.assert_eq(describe(injector.armed_with), "shift", "shift must reach the injector")
		helpers.assert_eq(#timers.scheduled, 1, "exactly one auto-cancel timer must be armed")
		helpers.assert_eq(timers.scheduled[1].delay, TIMEOUT_SEC,
			"the auto-cancel must use the delay the caller supplied, not one of its own")
	end)

	helpers.it("toggles each modifier independently, as Karabiner does", function()
		local Sticky, injector = fresh_sticky()
		Sticky.toggle({ "cmd" }, TIMEOUT_SEC)
		helpers.assert_eq(describe(Sticky.armed()), "cmd")

		-- The catalogue's sticky_cmd_shift is two sticky_modifier entries, so this
		-- must RELEASE cmd and ARM shift. An implementation that treats the set as
		-- one unit would answer "cmd,shift" here and pass a single-modifier test.
		Sticky.toggle({ "cmd", "shift" }, TIMEOUT_SEC)
		helpers.assert_eq(describe(Sticky.armed()), "shift",
			"cmd was already armed, so toggling cmd+shift must leave shift alone armed")
		helpers.assert_eq(describe(injector.armed_with), "shift",
			"the injector must be re-armed with the new set, not the old one")
	end)

	helpers.it("toggling the last armed modifier off disarms everything", function()
		local Sticky, injector = fresh_sticky()
		Sticky.toggle({ "alt" }, TIMEOUT_SEC)
		Sticky.toggle({ "alt" }, TIMEOUT_SEC)
		helpers.assert_eq(describe(Sticky.armed()), "(none)", "the second toggle must clear it")
		helpers.assert_true(injector.disarm_calls > 0, "the injector must be told to stand down")
	end)

	helpers.it("releases the arm when the keystroke consumes it", function()
		local Sticky, injector = fresh_sticky()
		Sticky.toggle({ "ctrl" }, TIMEOUT_SEC)
		local applied = injector.on_applied
		helpers.assert_true(type(applied) == "function",
			"the injector must be given a callback, or the module never learns the flags landed")
		applied()
		helpers.assert_eq(describe(Sticky.armed()), "(none)",
			"once the flags reach a keystroke the arm is spent — leaving it set would apply "
			.. "the modifier to every subsequent key until the timeout fired")
	end)

	helpers.it("releases the arm when the auto-cancel fires", function()
		local Sticky, _, timers = fresh_sticky()
		Sticky.toggle({ "cmd", "shift" }, TIMEOUT_SEC)
		helpers.assert_eq(#timers.scheduled, 1)
		timers.scheduled[1].fn()
		helpers.assert_eq(describe(Sticky.armed()), "(none)", "the timer must clear the arm")
	end)

	helpers.it("refuses a delay it was not given rather than inventing one", function()
		local Sticky, injector = fresh_sticky()
		helpers.assert_true(not Sticky.toggle({ "shift" }, nil), "a nil delay must be refused")
		helpers.assert_true(not Sticky.toggle({ "shift" }, 0), "a zero delay must be refused")
		helpers.assert_eq(injector.arm_calls, 0,
			"nothing may be armed on a guessed delay: the value belongs to the user's remap menu, "
			.. "and substituting one here would override their choice exactly when the config failed to load")
	end)

	helpers.it("refuses a modifier no key event carries", function()
		local Sticky, injector = fresh_sticky()
		helpers.assert_true(not Sticky.toggle({ "command" }, TIMEOUT_SEC),
			"'command' is not a flag a key event holds — arming it would produce a gesture that "
			.. "silently does nothing, which reads as a recognition bug rather than a typo")
		helpers.assert_eq(injector.arm_calls, 0)
		helpers.assert_eq(describe(Sticky.armed()), "(none)")
	end)

	helpers.it("refuses an empty modifier list", function()
		local Sticky, injector = fresh_sticky()
		helpers.assert_true(not Sticky.toggle({}, TIMEOUT_SEC))
		helpers.assert_eq(injector.arm_calls, 0)
	end)

	helpers.it("keeps no armed state when the injector refuses", function()
		local Sticky, injector = fresh_sticky()
		injector.next_arm_fails = true
		helpers.assert_true(not Sticky.toggle({ "shift" }, TIMEOUT_SEC),
			"a refused arm must be reported to the caller")
		helpers.assert_eq(describe(Sticky.armed()), "(none)",
			"believing itself armed while the tap never started would make the NEXT toggle read "
			.. "as a release, so one failed arm inverts the feature until the process restarts")
		injector.next_arm_fails = false
		helpers.assert_eq(Sticky.toggle(
			{ "shift" }, TIMEOUT_SEC, "shortcut_bindings"), true,
			"a refused gesture arm must retain no parent admission claim")
	end)

	helpers.it("clear() releases an armed set", function()
		local Sticky, injector = fresh_sticky()
		Sticky.toggle({ "cmd" }, TIMEOUT_SEC)
		helpers.assert_eq(Sticky.clear(), true,
			"clear must expose literal settlement to the gesture pause owner")
		helpers.assert_eq(describe(Sticky.armed()), "(none)")
		helpers.assert_true(injector.disarm_calls > 0)
	end)

	helpers.it("armed() hands back a copy, not the live set", function()
		local Sticky = fresh_sticky()
		Sticky.toggle({ "shift" }, TIMEOUT_SEC)
		local snapshot = Sticky.armed()
		snapshot.cmd = true
		helpers.assert_eq(describe(Sticky.armed()), "shift",
			"a caller mutating the returned table must not arm a modifier")
	end)

	helpers.it("rejects an uncommitted auto-cancel timer and disarms immediately", function()
		local Sticky, injector, timers = fresh_sticky()
		timers.next_committed = false
		helpers.assert_eq(Sticky.toggle({ "shift" }, TIMEOUT_SEC), false,
			"modifier publication requires an exactly committed auto-cancel timer")
		helpers.assert_eq(describe(Sticky.armed()), "(none)")
		helpers.assert_eq(describe(injector.armed_with), "(none)",
			"a timer refusal must not leave an arbitrarily long-lived modifier arm")
		helpers.assert_eq(timers.cancel_handles[1], timers.scheduled[1],
			"rollback must target the exact uncommitted timer candidate")
	end)

	helpers.it("contains a throwing timer acquisition without leaving the injector armed", function()
		local Sticky, injector, timers = fresh_sticky()
		timers.next_after_throws = true
		helpers.assert_eq(Sticky.toggle({ "alt" }, TIMEOUT_SEC), false)
		helpers.assert_eq(describe(Sticky.armed()), "(none)")
		helpers.assert_eq(describe(injector.armed_with), "(none)")
	end)

	helpers.it("fences a stale auto-cancel callback after a newer arm commits", function()
		local Sticky, injector, timers = fresh_sticky()
		helpers.assert_eq(Sticky.toggle({ "shift" }, TIMEOUT_SEC), true)
		local stale = timers.scheduled[1]
		helpers.assert_eq(Sticky.toggle({ "cmd" }, TIMEOUT_SEC), true)
		helpers.assert_eq(describe(Sticky.armed()), "cmd,shift")

		stale.fn()
		helpers.assert_eq(describe(Sticky.armed()), "cmd,shift",
			"a queued callback from the cancelled timer must not release its successor")
		helpers.assert_eq(describe(injector.armed_with), "cmd,shift")
	end)

	helpers.it("retains refused timer cleanup and settles it before a later retry", function()
		local Sticky, injector, timers = fresh_sticky()
		helpers.assert_eq(Sticky.toggle({ "ctrl" }, TIMEOUT_SEC), true)
		local first = timers.scheduled[1]
		timers.cancel_results[1] = false
		helpers.assert_eq(Sticky.toggle({ "shift" }, TIMEOUT_SEC), false,
			"a successor must not publish over exact timer cleanup debt")
		helpers.assert_eq(describe(Sticky.armed()), "(none)")
		helpers.assert_eq(describe(injector.armed_with), "(none)")

		helpers.assert_eq(Sticky.toggle({ "shift" }, TIMEOUT_SEC), true,
			"the next action must retry and settle prior cleanup before re-arming")
		helpers.assert_eq(timers.cancel_handles[2], first)
		helpers.assert_eq(describe(Sticky.armed()), "shift")
	end)

	helpers.it("isolates sticky admission and cleanup between gesture and shortcut parents", function()
		local Sticky, injector, timers = fresh_sticky()
		helpers.assert_eq(Sticky.toggle({ "cmd" }, TIMEOUT_SEC, "gestures"), true)
		local disarms_before = injector.disarm_calls
		helpers.assert_eq(Sticky.clear("shortcut_bindings"), true)
		helpers.assert_eq(Sticky.toggle(
			{ "shift" }, TIMEOUT_SEC, "shortcut_bindings"), false,
			"shortcut admission must refuse rather than replace a gesture-owned arm")
		helpers.assert_eq(describe(Sticky.armed()), "cmd")
		helpers.assert_eq(injector.disarm_calls, disarms_before)
		helpers.assert_eq(timers.cancelled, 0,
			"sibling cleanup must not retire the live parent's timer")
		helpers.assert_eq(Sticky.clear("gestures"), true)

		helpers.assert_eq(Sticky.toggle(
			{ "shift" }, TIMEOUT_SEC, "shortcut_bindings"), true)
		disarms_before = injector.disarm_calls
		helpers.assert_eq(Sticky.clear("gestures"), true)
		helpers.assert_eq(describe(Sticky.armed()), "shift")
		helpers.assert_eq(injector.disarm_calls, disarms_before)
		helpers.assert_eq(Sticky.clear("shortcut_bindings"), true)
		helpers.assert_eq(describe(Sticky.armed()), "(none)")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the gesture parent until disarm " .. mode
			.. " debt settles", function()
			local Sticky, injector = fresh_sticky()
			helpers.assert_eq(Sticky.toggle(
				{ "cmd" }, TIMEOUT_SEC, "gestures"), true)
			injector.disarm_modes[1] = mode
			local before = injector.disarm_calls
			helpers.assert_eq(Sticky.clear("gestures"), false)
			helpers.assert_eq(describe(Sticky.armed()), "cmd",
				"a refused native disarm must retain the exact logical identity")
			helpers.assert_eq(Sticky.clear("shortcut_bindings"), true)
			helpers.assert_eq(injector.disarm_calls, before + 1,
				"sibling cleanup may not consume another parent's disarm debt")
			helpers.assert_eq(Sticky.toggle(
				{ "shift" }, TIMEOUT_SEC, "shortcut_bindings"), false)

			helpers.assert_eq(Sticky.clear("gestures"), true)
			helpers.assert_eq(injector.disarm_calls, before + 2,
				"only the owning parent retries the exact injector debt")
			helpers.assert_eq(describe(Sticky.armed()), "(none)")
			helpers.assert_eq(Sticky.toggle(
				{ "shift" }, TIMEOUT_SEC, "shortcut_bindings"), true,
				"the sibling is admitted only after exact owner settlement")
		end)
	end

	for _, boundary in ipairs({ "arm", "timer" }) do
		for _, parent in ipairs({ "gestures", "shortcut_bindings" }) do
			helpers.it("rolls back " .. parent .. " when " .. boundary
				.. " acquisition reenters same-parent clear", function()
				local Sticky, injector, timers = fresh_sticky()
				if boundary == "arm" then
					injector.reenter_clear_parent = parent
				else
					timers.reenter_clear_parent = parent
				end
				helpers.assert_eq(Sticky.toggle(
					{ "cmd" }, TIMEOUT_SEC, parent), false)
				local nested_result
				if boundary == "arm" then
					nested_result = injector.reentrant_clear_result
				else
					nested_result = timers.reentrant_clear_result
				end
				helpers.assert_eq(nested_result, false,
					"matching cleanup cannot settle while its native acquisition is on-stack")
				helpers.assert_eq(describe(Sticky.armed()), "(none)")
				helpers.assert_eq(describe(injector.armed_with), "(none)")
				if #timers.scheduled > 0 then
					local stale = timers.scheduled[#timers.scheduled]
					stale.fn()
					helpers.assert_eq(describe(Sticky.armed()), "(none)",
						"a rolled-back timer callback must remain inert")
				end
			end)

			helpers.it("does not let sibling clear cancel " .. parent .. " "
				.. boundary .. " acquisition", function()
				local Sticky, injector, timers = fresh_sticky()
				local sibling = parent == "gestures"
					and "shortcut_bindings" or "gestures"
				if boundary == "arm" then
					injector.reenter_clear_parent = sibling
				else
					timers.reenter_clear_parent = sibling
				end
				helpers.assert_eq(Sticky.toggle(
					{ "cmd" }, TIMEOUT_SEC, parent), true)
				local nested_result
				if boundary == "arm" then
					nested_result = injector.reentrant_clear_result
				else
					nested_result = timers.reentrant_clear_result
				end
				helpers.assert_eq(nested_result, true,
					"a sibling scope remains independently settled")
				helpers.assert_eq(describe(Sticky.armed()), "cmd")
				helpers.assert_eq(Sticky.clear(parent), true)
			end)
		end
	end

	for _, boundary in ipairs({ "arm", "timer" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains matching " .. boundary .. " rollback debt after disarm "
				.. mode, function()
				local Sticky, injector, timers = fresh_sticky()
				injector.disarm_modes[1] = mode
				injector.disarm_modes[2] = mode
				if boundary == "arm" then
					injector.reenter_clear_parent = "gestures"
				else
					timers.reenter_clear_parent = "gestures"
				end

				helpers.assert_eq(Sticky.toggle(
					{ "cmd" }, TIMEOUT_SEC, "gestures"), false)
				local nested_result
				if boundary == "arm" then
					nested_result = injector.reentrant_clear_result
				else
					nested_result = timers.reentrant_clear_result
				end
				helpers.assert_eq(nested_result, false)
				helpers.assert_eq(describe(Sticky.armed()), "cmd",
					"failed on-stack inverse retains the original parent's exact debt")
				local disarms = injector.disarm_calls
				helpers.assert_eq(Sticky.clear("shortcut_bindings"), true)
				helpers.assert_eq(injector.disarm_calls, disarms,
					"sibling cleanup cannot consume the acquisition rollback debt")
				helpers.assert_eq(Sticky.clear("gestures"), true)
				helpers.assert_eq(describe(Sticky.armed()), "(none)")
			end)
		end
	end

end)
