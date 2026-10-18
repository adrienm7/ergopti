--- tests/unit/adapters/layout/test_keyboard_layout_terminal_plan_observation.lua

--- ==============================================================================
--- MODULE: Keyboard Layout — character to keystroke
--- DESCRIPTION:
--- The whole output chain, from the text an XKB dump prints to the keycode and
--- modifiers that type a character, driven against a French AZERTY fixture.
---
--- WHY A FRENCH FIXTURE AND NOT A US ONE:
--- On US every interesting property is invisible. "a" is keycode 30 whether or
--- not the layout was ever read, so a US fixture passes against a hardcoded
--- table, against a broken parser that silently returns nothing plus a fallback,
--- and against the correct implementation alike. On AZERTY "a" is keycode 16 and
--- "é" is an unshifted key that does not exist on US at all — so every case
--- below fails if the layout is not genuinely being read.
---
--- That is not a hypothetical preference. This driver's replacements are
--- overwhelmingly accented French, ydotool assumes US, and "expansions come out
--- as gibberish" was the whole reason the injection path had to be rewritten.
---
--- WHAT THE THREE LAYERS ARE:
---   1. infra/xkb_keymap.lua   — text to (keysym, keycode, level). Pure.
---   2. infra/keysym.lua       — keysym name to character. Pure, plus an
---                               optional libxkbcommon path.
---   3. this adapter           — the join, the cache, and the refusal to guess.
--- Each is asserted here through the layer above it, because the seam between
--- them is where a plausible-looking half-answer would survive.
--- ==============================================================================

package.loaded["tests.support.adapters.layout.keyboard_layout_fixture"] = nil
local Fixture = require("tests.support.adapters.layout.keyboard_layout_fixture")
local helpers, cohort_fixture, desktop_cohort =
	Fixture.helpers, Fixture.cohort_fixture, Fixture.desktop_cohort




helpers.describe("keyboard_layout: terminal plan observation seal", function()
	helpers.it("seals only its exact observed owner without another native callback", function()
		cohort_fixture(function(_, layout, state)
			local _, _, receipt = layout.plan("z")
			state.on_group = function() error("native reads are forbidden in the terminal RAM seal") end
			helpers.assert_true(layout.plan_current(receipt, true))
			helpers.assert_eq(layout.plan_current({}, true), false)
			helpers.assert_eq(layout.plan_current(receipt), false)
			helpers.assert_eq(layout.plan_current(receipt, true), false)
		end)
	end)
end)




helpers.describe("keyboard_layout: startup-capture-publication", function()
	helpers.it("startup-capture-publication repairs only the actual reset cohort and keeps CapsLock state", function()
		cohort_fixture(function(capture, layout, state, _, path)
			local before, _, previous = layout.plan("ZZ")
			helpers.assert_true(before ~= nil)
			helpers.assert_true(capture.reset_state())
			state.caps = true
			helpers.assert_eq(layout.plan_current(previous), false)
			helpers.assert_true(layout.publish_current_capture(path))
			helpers.assert_true(capture.caps_locked(), "publication never recreates or resets capture")
			local plan, _, fresh = layout.plan("ZZ")
			helpers.assert_eq(#plan, 2)
			helpers.assert_true(fresh ~= previous and layout.plan_current(fresh))
			helpers.assert_eq(layout.plan_current(previous), false)
		end)
	end)
	helpers.it("startup-capture-publication refuses a different loaded map", function()
		cohort_fixture(function(capture, layout, _, _, path)
			helpers.assert_true(capture.load("different-owner"))
			helpers.assert_eq(layout.publish_current_capture(path), false)
			helpers.assert_nil(layout.plan("ZZ"))
		end)
	end)
	helpers.it("startup-capture-publication preserves a reentrant newer selection without borrowing it", function()
		cohort_fixture(function(capture, layout, state, _, path)
			helpers.assert_true(capture.reset_state())
			state.on_inverse = function() state.on_inverse = nil; helpers.assert_true(layout.refresh(path)) end
			helpers.assert_eq(layout.publish_current_capture(path), false)
			helpers.assert_true(layout.is_ready(), "the outer refusal must not erase a newer owner")
		end)
	end)
	helpers.it("startup-capture-publication refuses rebound receipt issuer", function()
		cohort_fixture(function(capture, layout, _, _, path)
			helpers.assert_true(capture.reset_state())
			capture.inverse_republish = function() return {}, nil, {} end
			helpers.assert_eq(layout.publish_current_capture(path), false)
			helpers.assert_nil(layout.plan("ZZ"))
		end)
	end)
	for _, mutation in ipairs({ "unavailable", "generation", "reentry" }) do
		helpers.it("startup-capture-publication refuses changed desktop " .. mutation, function()
			cohort_fixture(function(capture, layout, state, backend)
				desktop_cohort(layout, backend, state, function()
					helpers.assert_true(capture.reset_state())
					if mutation == "unavailable" then state.acknowledged = false
					elseif mutation == "generation" then state.native_generation = state.native_generation + 1
					else state.on_source = function() state.on_source = nil; capture.reset_state() end end
					helpers.assert_eq(layout.publish_current_capture(), false)
					helpers.assert_nil(layout.plan("ZZ"))
				end)
			end)
		end)
	end
end)




helpers.describe("keyboard_layout: startup-capture-publication route", function()
	helpers.it("startup-capture-publication refuses a retargeted override before native enumeration", function()
		cohort_fixture(function(capture, layout, state, _, path)
			helpers.assert_true(capture.reset_state())
			state.on_inverse = function() error("a retargeted route must not acquire a new inverse") end
			helpers.assert_eq(layout.publish_current_capture(path .. ".retargeted"), false)
		end)
	end)
end)




-- New source-bound typing requests only; these controlled Capture ports do not
-- qualify a native desktop, physical press, uinput output or installed daemon.
helpers.describe("keyboard_layout: automatic different-group inverse renewal", function()
	helpers.it("renews character resolution through the original issuer after a different desktop group", function()
		cohort_fixture(function(capture, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				helpers.assert_eq(layout.resolve("z").keycode, 44)
				capture.process(99, 1); state.native_generation = 8
				helpers.assert_eq(layout.is_ready(), false, "old cohort is retired before any new request")
				local next_step = layout.resolve("z")
				helpers.assert_true(type(next_step) == "table")
				helpers.assert_eq(next_step.keycode, 21); helpers.assert_eq(next_step.mods, {})
				helpers.assert_true(layout.is_ready())
				state.on_inverse = function() error("an unchanged current lookup must not enumerate again") end
				helpers.assert_eq(layout.resolve("z").keycode, 21)
			end)
		end)
	end)
	helpers.it("a new plan never revives the prior group plan across observed ABA", function()
		cohort_fixture(function(capture, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				local old_steps, _, old = layout.plan("z")
				helpers.assert_eq(old_steps[1].keycode, 44); helpers.assert_true(layout.plan_current(old))
				capture.process(99, 1); state.native_generation = 8
				local next_steps, reason, next_plan = layout.plan("z")
				helpers.assert_nil(reason); helpers.assert_eq(next_steps[1].keycode, 21)
				helpers.assert_true(type(next_plan) == "table"); helpers.assert_true(next_plan ~= old)
				helpers.assert_eq(layout.plan_current(old), false); helpers.assert_nil(layout.plan_view(old))
				helpers.assert_true(layout.plan_current(next_plan))
				capture.process(99, 1); state.native_generation = 9
				local again, _, third = layout.plan("z")
				helpers.assert_eq(again[1].keycode, 44); helpers.assert_true(layout.plan_current(third))
				helpers.assert_eq(layout.plan_current(old), false); helpers.assert_eq(layout.plan_current(next_plan), false)
				helpers.assert_nil(layout.plan_view(old)); helpers.assert_nil(layout.plan_view(next_plan))
			end)
		end)
	end)
	helpers.it("explicit override retirement never acquires an automatic desktop inverse", function()
		cohort_fixture(function(capture, layout, state)
			capture.process(99, 1)
			state.on_inverse = function() error("an override cannot borrow the automatic source") end
			helpers.assert_nil(layout.resolve("z")); helpers.assert_nil(layout.plan("z"))
		end)
	end)
	helpers.it("an equal-group source replacement does not renew an old plan", function()
		cohort_fixture(function(_, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				state.native_generation = 8
				local enumerations = 0
				state.on_inverse = function() enumerations = enumerations + 1 end
				helpers.assert_nil(layout.resolve("z")); helpers.assert_nil(layout.plan("z"))
				helpers.assert_eq(enumerations, 0)
			end)
		end)
	end)
	helpers.it("a same-map capture reset cannot borrow a different-group renewal", function()
		cohort_fixture(function(capture, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				helpers.assert_true(capture.reset_state())
				capture.process(99, 1); state.native_generation = 8
				local enumerations = 0
				state.on_inverse = function() enumerations = enumerations + 1 end
				helpers.assert_nil(layout.resolve("z")); helpers.assert_nil(layout.plan("z"))
				helpers.assert_eq(enumerations, 0)
			end)
		end)
	end)
	helpers.it("unacknowledged native source cannot provide a replacement cohort", function()
		cohort_fixture(function(capture, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				capture.process(99, 1); state.native_generation = 8; state.acknowledged = false
				local enumerations = 0
				state.on_inverse = function() enumerations = enumerations + 1 end
				helpers.assert_nil(layout.resolve("z")); helpers.assert_nil(layout.plan("z"))
				helpers.assert_eq(enumerations, 0)
				helpers.assert_eq(layout.is_ready(), false)
			end)
		end)
	end)
	helpers.it("source mutation during actual inverse enumeration denies publication", function()
		cohort_fixture(function(capture, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				capture.process(99, 1); state.native_generation = 8
				state.on_inverse = function() state.native_generation = 9 end
				helpers.assert_nil(layout.resolve("z")); helpers.assert_eq(layout.is_ready(), false)
			end)
		end)
	end)
	helpers.it("a reentrant selection retirement cannot publish the captured old request", function()
		cohort_fixture(function(capture, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				capture.process(99, 1); state.native_generation = 8
				local retired = false
				state.on_inverse = function() retired = true; layout._set_table_for_test(nil) end
				helpers.assert_nil(layout.resolve("z")); helpers.assert_true(retired)
				helpers.assert_eq(layout.is_ready(), false)
			end)
		end)
	end)
	helpers.it("nested character lookup cannot borrow an in-flight renewal", function()
		cohort_fixture(function(capture, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				capture.process(99, 1); state.native_generation = 8
				local entered, nested = 0, true
				state.on_inverse = function() entered = entered + 1; nested = layout.resolve("z") end
				local current = layout.resolve("z")
				helpers.assert_eq(entered, 1); helpers.assert_nil(nested)
				helpers.assert_eq(current.keycode, 21); helpers.assert_true(layout.is_ready())
			end)
		end)
	end)
	helpers.it("a foreign renewal export is never invoked by the captured layout owner", function()
		cohort_fixture(function(capture, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				capture.process(99, 1); state.native_generation = 8
				local original, foreign_calls = capture.inverse_retarget, 0
				capture.inverse_retarget = function() foreign_calls = foreign_calls + 1; return {}, nil, {} end
				local value = layout.resolve("z")
				capture.inverse_retarget = original
				helpers.assert_nil(value); helpers.assert_eq(foreign_calls, 0)
			end)
		end)
	end)
	helpers.it("lost fresh map size cannot publish a partial replacement", function()
		cohort_fixture(function(capture, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				capture.process(99, 1); state.native_generation = 8
				local old = backend.inverse
				-- Mutate the actual returned enumeration, keeping the original issuer.
				state.on_inverse = function()
					for key in pairs(state.rows) do state.rows[key] = nil end
					state.rows.z = { keycode = 21, level = 1, mods = {} }
				end
				helpers.assert_nil(layout.resolve("z")); helpers.assert_eq(layout.is_ready(), false)
				helpers.assert_true(backend.inverse == old)
			end)
		end)
	end)
	helpers.it("retiring the actual layout issuer during enumeration refuses its old lookup", function()
		cohort_fixture(function(capture, layout, state, backend)
			desktop_cohort(layout, backend, state, function()
				capture.process(99, 1); state.native_generation = 8
				local original, retired = package.loaded["adapters.keyboard_layout"], false
				state.on_inverse = function() retired = true; package.loaded["adapters.keyboard_layout"] = {} end
				local value = layout.resolve("z")
				package.loaded["adapters.keyboard_layout"] = original
				helpers.assert_true(retired); helpers.assert_nil(value); helpers.assert_eq(layout.is_ready(), false)
			end)
		end)
	end)
end)

