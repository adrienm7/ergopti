--- tests/unit/modules/keymap/test_star_validation_beats_repeat_key.lua

--- ==============================================================================
--- MODULE: Regression — pressing ★ must expand what the tooltip showed
--- DESCRIPTION:
--- The tooltip displayed a hotstring expansion for a ★ trigger, the user pressed
--- ★ to accept it, and got the last letter doubled instead. Intermittently — it
--- depended on how long the pause before ★ was.
---
--- ROOT CAUSE ENCODED:
--- run_trigger_checks has three branches, tried in order:
---   1. auto candidates      — gated by mapping_fires() (typing-speed delay)
---   2. terminator candidates — gated by mapping_fires() UNLESS ★ was typed
---   3. try_repeat_feature   — the "double the last letter" fallback
--- Branch 2 already bypassed the delay when the typed character is the magic key,
--- with the rationale spelled out in its own comment: pressing ★ is an explicit
--- validation of the displayed tooltip, so a slow typist must not get a repeat-key
--- instead of the intended expansion. Branch 1 — which is the branch that owns
--- has_magic triggers, since their tail codepoint IS ★ — never got that bypass.
---
--- So a ★ trigger typed after a pause failed mapping_fires (DELAYS.STAR_TRIGGER,
--- 2 s by default, scaled by the complex-keystroke multiplier), fell through
--- branch 2 (which buckets on the character BEFORE the terminator and therefore
--- cannot contain a has_magic mapping), and landed in branch 3, which doubled the
--- last letter.
---
--- WHY THE TOOLTIP DISAGREED:
--- llm_bridge.update_preview collects star matches with NO delay gate at all — it
--- checks group membership, the star_base suffix and the repetition guard, but
--- never consults typing speed. The preview therefore promised an expansion the
--- engine had already decided not to perform. The tooltip was not wrong about the
--- mapping; the two sides simply disagreed about whether it would fire.
---
--- WHY A SOURCE GUARD:
--- The branch chain lives in run_trigger_checks, a local function inside the
--- eventtap callback: reaching it behaviourally means driving a real CGEventTap
--- with real timing. What is decidable, and what was actually wrong, is that the
--- star bypass is applied to BOTH branches from a single shared decision — so the
--- two can never again be updated apart.
--- ==============================================================================

local helpers = require("tests.helpers")

local STAR = utf8.char(0x2605)
local KEYCODE_LETTER = 0
local SLOW_REPLACEMENT = "SLOW_STAR"
local LITERAL_REPLACEMENT = "LITERAL_FOLD"
local NBSP = string.char(0xC2, 0xA0)
local NNBSP = string.char(0xE2, 0x80, 0xAF)

--- Installs the external collaborators needed to drive the real keymap tap.
--- @param effects table Mutable output/tooltip capture.
local function install_collaborators(effects)
	-- This module drives the real keymap graph. Other test files initialise the
	-- registry/bridge against their own state objects, so reusing those cached
	-- singletons makes this behavioral repro depend on discovery order.
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap")
			or name:match("^adapters%.")
		) then
			package.loaded[name] = nil
		end
	end
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
		check_modifiers = function() return false end,
	}
	package.loaded["modules.llm.prediction_engine"] = {
		init = function() return true end,
		set_runtime_guard = function() end,
		get_llm_enabled = function() return false end,
		reset = function() return true end,
		handle_chain_signal = function() return false end,
		is_visible = function() return false end,
	}
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function() end,
		log_hotstring_dismissed = function() end,
		log_llm_accepted = function() end,
		log_hotstring = function() end,
		notify_synthetic = function(text, source, _deletes, variant)
			if source == "hotstring" then effects.emitted[#effects.emitted + 1] = text end
			if variant == "repeat_key" then effects.repeated = text end
		end,
		set_buffer = function() end,
	}
	package.loaded["ui.tooltip"] = {
		set_runtime_guard = function() end,
		set_accept_callback = function() end,
		set_cancel_callback = function() end,
		set_on_show_callback = function() end,
		set_timeout = function() end,
		set_colorization_enabled = function() end,
		set_accent_color = function() end,
		tint = function() return {} end,
		show_stacked = function(rows) effects.rows = rows; effects.visible = true; return true end,
		hide = function() effects.visible = false; return true end,
		hide_forced = function() effects.visible = false; return true end,
		hide_forced_silent = function() effects.visible = false; return true end,
		is_visible = function() return effects.visible == true end,
		is_hotstring_visible = function() return effects.visible == true end,
		has_visible_hotstring_lease = function(token)
			if not effects.visible then return false end
			for _, row in ipairs(effects.rows or {}) do
				if row.lease_token == token then return true end
			end
			return false
		end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = { resolve = function() return nil end }
	package.loaded["adapters.tooltip_renderer"] = { hide = function() return true end }
end

--- Finds the real key-down tap installed by modules.keymap.
--- @param hs_stub table Hammerspoon stub.
--- @return table|nil
local function find_keydown_tap(hs_stub)
	for _, tap in ipairs(hs_stub.eventtap.__taps) do
		if #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyDown then return tap end
	end
	return nil
end

--- Builds one physical character event.
--- @param character string Event text.
--- @param flags table|nil Modifier state.
--- @param keycode number|nil Quartz keycode.
--- @return table
local function physical_key(character, flags, keycode)
	return {
		getProperty = function() return 0 end,
		getFlags = function()
			return flags or { cmd = false, ctrl = false, alt = false, shift = false }
		end,
		getKeyCode = function() return keycode or KEYCODE_LETTER end,
		getCharacters = function() return character end,
	}
end

--- Holds the unrelated AX boundary in its already-classified normal state.
--- @return function restore
local function force_normal_window()
	local Utils = package.loaded["modules.keymap.utils"]
	helpers.assert_not_nil(Utils, "the real keymap must load its window-classification module")
	local original_ignored = Utils.is_ignored_window
	local original_secure = Utils.is_secure_field
	Utils.is_ignored_window = function() return false, 0 end
	Utils.is_secure_field = function() return false, 0 end
	return function()
		Utils.is_ignored_window = original_ignored
		Utils.is_secure_field = original_secure
	end
end

--- Drains only zero-delay work; production deliberately keeps a future TTL timer.
--- @param hs_stub table Hammerspoon stub.
local function drain_immediate_timers(hs_stub)
	for _ = 1, 32 do
		local snapshot = {}
		for _, timer in ipairs(hs_stub.timer.__timers) do
			if timer.running and timer.delay == 0 then snapshot[#snapshot + 1] = timer end
		end
		if #snapshot == 0 then return end
		for _, timer in ipairs(snapshot) do
			if timer.running then timer:fire() end
		end
	end
	error("immediate timer queue did not settle", 0)
end





-- =====================================================
-- =====================================================
-- ======= 1/ ★ Bypasses The Delay On Both Paths =======
-- =====================================================
-- =====================================================

--- Reads the engine's trigger-dispatch source.
--- @return string
local function dispatch_source()
	-- Selected by a declaration unique to modules/keymap/init.lua rather than by
	-- path, so moving or splitting the module cannot turn this invariant into a
	-- path error.
	local src = helpers.read_driver_source("local function run_trigger_checks")
	helpers.assert_true(src ~= nil, "modules/keymap/init.lua source must be locatable")
	return src or ""
end

helpers.describe("pressing ★ validates the tooltip on every expansion branch", function()
	helpers.it("decides 'the magic key was typed' exactly once", function()
		local src = dispatch_source()
		local _, count = src:gsub(
			"Terminators%.matches_magic_event%(chars,%s*CoreState%.magic_key%)", "")
		helpers.assert_eq(count, 1,
			"the canonical 'is this the magic action' test must be made ONCE and shared by both branches. "
			.. "Two independent copies is how the auto branch ended up without the bypass the "
			.. "terminator branch had, which is what let a ★ trigger fall through to the "
			.. "repeat-key fallback")
		helpers.assert_true(src:find("chars%s*==%s*CoreState%.magic_key") == nil,
			"raw equality rejects the NBSP/NNBSP composite payload emitted by the French layout")
	end)

	helpers.it("routes magic dispatch through the shared resolver with the ordinary timing policy", function()
		local src = dispatch_source()
		helpers.assert_true(src:find(
			"Expander%.resolve_magic_action%(%s*before_magic,%s*ordinary_magic_auto_allowed,%s*chars%s*%)") ~= nil,
			"the eventtap must ask the same resolver as the tooltip while supplying its exact "
			.. "ordinary-auto timing decision and physical payload; omitting the policy drops literal autos after a "
			.. "magic-key change, while applying it to true stars revives the slow-star bug")
	end)
end)





-- ==============================================================
-- ==============================================================
-- ======= 2/ The Repeat Key Stays A Last-Resort Fallback =======
-- ==============================================================
-- ==============================================================

helpers.describe("the repeat-key fallback runs only after every expansion attempt", function()
	helpers.it("calls try_repeat_feature after both expansion branches", function()
		local src = dispatch_source()

		-- Anchor on the CALL, not the bare name: the branch chain is documented in
		-- prose above it, and matching the name alone finds the comment first.
		local auto_at   = src:find("Expander%.try_auto_expand")
		local term_at   = src:find("Expander%.try_terminator_expand")
		local repeat_at = src:find("Expander%.try_repeat_feature")

		helpers.assert_true(auto_at ~= nil,   "the auto-expand branch must be locatable")
		helpers.assert_true(term_at ~= nil,   "the terminator branch must be locatable")
		helpers.assert_true(repeat_at ~= nil, "the repeat-key fallback must be locatable")

		helpers.assert_true(auto_at < repeat_at,
			"the repeat-key fallback must come AFTER the auto-expand branch — it is what the "
			.. "engine does when no hotstring matched, never a competitor to one that did")
		helpers.assert_true(term_at < repeat_at,
			"the repeat-key fallback must come AFTER the terminator branch, for the same reason")
	end)
end)





-- ==========================================================
-- ==========================================================
-- ======= 3/ The Preview Applies No Delay Of Its Own =======
-- ==========================================================
-- ==========================================================

helpers.describe("the tooltip's star preview does not second-guess the engine's timing", function()
	helpers.it("collects star matches without consulting the typing-speed delay", function()
		local src = helpers.read_driver_source("function M.resolve_magic_action")
		helpers.assert_true(src ~= nil, "the shared prospective resolver must be locatable")
		if not src then return end

		local resolver_at = src:find("function M.resolve_magic_action", 1, true)
		local window = src:sub(resolver_at, resolver_at + 6500)

		helpers.assert_true(window:find("mapping_fires") == nil,
			"explicit magic-key resolution must NOT apply the typing-speed delay — a second copy of that "
			.. "decision is exactly what diverged. The engine now honours ★ as an explicit "
			.. "validation, so what the preview shows is what pressing ★ produces; adding a "
			.. "delay check here would resurrect the divergence from the other side")
		helpers.assert_true(window:find("_tc_dt") == nil,
			"the prospective resolver must not read per-keystroke timing state either")
	end)
end)





-- =================================================
-- =================================================
-- ======= 4/ Real Eventtap Timing Semantics =======
-- =================================================
-- =================================================

helpers.describe("magic validation through the real keymap eventtap", function()
	helpers.it("keeps true stars delay-free and changed-key literal autos timed", function()
		local effects = { emitted = {}, visible = false }
		install_collaborators(effects)
		local Keymap = helpers.load_with_stubs("modules.keymap")
		local hs_stub = _G.hs
		local restore_normal_window = force_normal_window()
		local now = 100
		hs_stub.timer.secondsSinceEpoch = function() return now end

		Keymap.add("slow" .. STAR, SLOW_REPLACEMENT, {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Keymap.add("plain", "PLAIN_END", {
			auto_expand = false,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		-- Stored exactly as written but compared with Unicode folding. When magic
		-- later becomes lowercase `a`, the historical tail bucket still found this
		-- uppercase literal; the narrow replacement index must preserve that behavior.
		Keymap.add("litA", LITERAL_REPLACEMENT, {
			auto_expand = true,
			is_case_sensitive = true,
		})
		Keymap.sort_mappings()
		Keymap.set_preview_star_enabled(true)
		Keymap.set_preview_autocorrect_enabled(true)
		Keymap.set_repeat_feature_enabled(true)

		local tap = find_keydown_tap(hs_stub)
		helpers.assert_not_nil(tap, "the real keymap must install one key-down eventtap")
		local function press(character, elapsed, flags, keycode)
			now = now + (elapsed or 0.01)
			return tap.fn(physical_key(character, flags, keycode))
		end
		local function reset_context()
			-- Left Arrow is a real navigation action, so it clears the production
			-- buffer and any committed preview without reaching into private state.
			press("", 0.01, nil, 123)
			drain_immediate_timers(hs_stub)
			effects.rows = nil
			effects.visible = false
			effects.emitted = {}
		end

		local ok, err = xpcall(function()
			for _, character in ipairs({ "s", "l", "o", "w" }) do press(character) end
			drain_immediate_timers(hs_stub)
			helpers.assert_true(type(effects.rows) == "table" and effects.rows[1].text == SLOW_REPLACEMENT,
				"the control must prove that the tooltip advertised the true star mapping")

			local consumed = press(STAR, 3.0)
			helpers.assert_eq(consumed, true,
				"a true magic mapping must still win after STAR_TRIGGER elapsed")
			helpers.assert_eq(#effects.emitted, 1,
				"the slow magic key must commit one hotstring, not the repeat fallback")
			helpers.assert_eq(effects.emitted[1], SLOW_REPLACEMENT,
				"the delayed eventtap output must equal the previewed star replacement")

			-- The remaining scenarios isolate literal-mapping timing/provenance.
			-- Repeat was the positive fallback for the true-star scenario above;
			-- leaving it enabled would emit an unrelated repeated character when a
			-- deliberately expired literal correctly declines.
			reset_context()
			Keymap.set_repeat_feature_enabled(false)
			now = now + 1
			Keymap.set_trigger_char("a")
			Keymap.set_base_delay(0.01)
			effects.rows = nil
			effects.emitted = {}
			for _, character in ipairs({ "l", "i", "t" }) do press(character) end
			drain_immediate_timers(hs_stub)
			helpers.assert_true(type(effects.rows) == "table" and effects.rows[1].text == LITERAL_REPLACEMENT,
				"the folded literal auto must survive a case-different magic-key change")
			helpers.assert_eq(effects.rows[1].trigger_label, "a",
				"the literal auto row must name the configured magic action")
			helpers.assert_true(effects.rows[1].duration >= 0.019
				and effects.rows[1].duration <= 0.021,
				"a 10 ms ordinary gate may cover the 2x complex-key policy but must never "
					.. "be stretched to the 50 ms UI floor")
			helpers.assert_eq(press("a", 0.005), true,
				"the fast ordinary auto must remain reachable through magic dispatch")
			helpers.assert_eq(effects.emitted[1], LITERAL_REPLACEMENT,
				"the changed-key preview and eventtap output must agree")

			-- A second key change must not acquire the literal mapping by suffix.
			reset_context()
			now = now + 1
			Keymap.set_trigger_char("b")
			for _, character in ipairs({ "l", "i", "t" }) do press(character) end
			helpers.assert_eq(press("a", 0.005), true,
				"the ordinary literal trigger must retain its original final character")
			helpers.assert_eq(effects.emitted[1], LITERAL_REPLACEMENT,
				"a second magic-key change must not rename a mapping it never owned")

			-- Return to magic `a` and prove the ordinary mapping still observes its
			-- base delay, unlike true star mappings.
			reset_context()
			now = now + 1
			Keymap.set_trigger_char("a")
			effects.emitted = {}
			for _, character in ipairs({ "l", "i", "t" }) do press(character) end
			drain_immediate_timers(hs_stub)
			effects.visible = false
			press("a", 0.02)
			helpers.assert_eq(#effects.emitted, 0,
				"an ordinary literal auto must retain its typing-speed gate after the key change")

			-- If the native hide timer itself is late, the visible row becomes an
			-- explicit lease: pressing the advertised key must still commit that row,
			-- never fall through to repeat or another mapping.
			reset_context()
			now = now + 1
			effects.rows = nil
			effects.emitted = {}
			for _, character in ipairs({ "l", "i", "t" }) do press(character) end
			drain_immediate_timers(hs_stub)
			helpers.assert_eq(effects.visible, true,
				"the late-hide repro requires a physically committed visible row")
			helpers.assert_eq(press("a", 0.02), true,
				"a still-visible timed row must lease the exact advertised action")
			helpers.assert_eq(effects.emitted[1], LITERAL_REPLACEMENT,
				"a delayed visible promise must remain equal to the emitted output")

			-- Delay 0 means the ordinary mapping is always active. It must produce
			-- an infinite row rather than being mistaken for an expired deadline.
			reset_context()
			Keymap.set_base_delay(0)
			for _, character in ipairs({ "l", "i", "t" }) do press(character) end
			drain_immediate_timers(hs_stub)
			helpers.assert_true(type(effects.rows) == "table" and effects.rows[1].text == LITERAL_REPLACEMENT,
				"a zero-delay literal collision must remain visible")
			helpers.assert_eq(effects.rows[1].duration, 0,
				"delay 0 is the canonical infinite-tooltip sentinel")
			effects.visible = false
			helpers.assert_eq(press("a", 1.0), true)
			helpers.assert_eq(effects.emitted[1], LITERAL_REPLACEMENT,
				"the engine and preview must both treat zero delay as always active")

			-- Preview has to cover the widest eventtap window: the next magic event
			-- may itself carry Shift/Alt even though the preceding buffer did not.
			reset_context()
			Keymap.set_trigger_char("A")
			Keymap.set_base_delay(0.4)
			for _, character in ipairs({ "l", "i", "t" }) do press(character) end
			drain_immediate_timers(hs_stub)
			helpers.assert_true(effects.rows[1].duration >= 0.79,
				"the visible lease must survive the maximum complex-key delay window")
			helpers.assert_eq(press("A", 0.5,
				{ cmd = false, ctrl = false, alt = false, shift = true }), true)
			helpers.assert_eq(effects.emitted[1], LITERAL_REPLACEMENT,
				"Shift+magic inside the advertised window must emit the advertised row")

			-- A literal mapping registered after the custom key is already active is
			-- still literal provenance. Suffix equality must neither grant it the
			-- star delay bypass nor make a later key change rename it.
			reset_context()
			Keymap.set_trigger_char("a")
			Keymap.set_base_delay(0.01)
			Keymap.add("hota", "HOT_RELOAD_LITERAL", {
				auto_expand = true,
				is_case_sensitive = true,
				is_case_sensitive_strict = true,
			})
			Keymap.sort_mappings()
			for _, character in ipairs({ "h", "o", "t" }) do press(character) end
			drain_immediate_timers(hs_stub)
			helpers.assert_eq(effects.rows[1].text, "HOT_RELOAD_LITERAL",
				"hot-reloaded literals must be indexed as custom-key collisions")
			effects.visible = false
			press("a", 0.02)
			helpers.assert_eq(#effects.emitted, 0,
				"suffix equality at registration must not acquire magic ownership")

			reset_context()
			Keymap.set_trigger_char("b")
			for _, character in ipairs({ "h", "o", "t" }) do press(character) end
			helpers.assert_eq(press("a", 0.005), true,
				"a later key change must leave the hot-reloaded literal trigger intact")
			helpers.assert_eq(effects.emitted[1], "HOT_RELOAD_LITERAL")

			-- The bundled French layout emits these configured keys as ONE
			-- NBSP/NNBSP-prefixed event. Preview uses the logical key; commit must
			-- recognise the physical spelling without treating the carrier as trigger.
			Keymap.set_repeat_feature_enabled(true)
			for _, case in ipairs({
				{ magic = ":", raw = NBSP .. ":", flags = nil },
				{
					magic = ";",
					raw = NNBSP .. ";",
					flags = { cmd = false, ctrl = false, alt = false, shift = true },
				},
			}) do
				reset_context()
				Keymap.set_trigger_char(case.magic)
				for _, character in ipairs({ "s", "l", "o", "w" }) do press(character) end
				drain_immediate_timers(hs_stub)
				helpers.assert_true(type(effects.rows) == "table"
					and effects.rows[1].text == SLOW_REPLACEMENT,
					"the tooltip must advertise the renamed punctuation action")
				helpers.assert_eq(effects.rows[1].trigger_label, case.magic)
				helpers.assert_eq(press(case.raw, 0.01, case.flags), true,
					"the one physical composite event must commit the advertised action")
				helpers.assert_eq(#effects.emitted, 1)
				helpers.assert_eq(effects.emitted[1], SLOW_REPLACEMENT,
				"composite spelling must not change the expansion output")
			end

			reset_context()
			Keymap.set_trigger_char(":")
			for _, character in ipairs({ "p", "l", "a", "i", "n" }) do press(character) end
			drain_immediate_timers(hs_stub)
			helpers.assert_true(type(effects.rows) == "table"
				and effects.rows[1].text == "PLAIN_END",
				"preview must resolve bare punctuation for a non-Ergopti input source")
			helpers.assert_eq(press(":"), true,
				"the same bare configured action must commit after an input-source switch")
			helpers.assert_eq(effects.emitted[1], "PLAIN_END")

			reset_context()
			for _, character in ipairs({ "p", "l", "a", "i", "n" }) do press(character) end
			helpers.assert_eq(press("x:"), false,
				"an arbitrary multi-codepoint suffix must not acquire terminator or magic identity")
			helpers.assert_eq(#effects.emitted, 0,
				"rejecting magic identity must not fall through to a looser terminator tail probe")
		end, debug.traceback)

		-- The terminator catalogue is process-global; restore both runtime knobs even
		-- if a behavioral assertion fails so later files do not inherit this fixture.
		Keymap.set_trigger_char(STAR)
		Keymap.set_repeat_feature_enabled(false)
		Keymap.set_base_delay(0.4)
		restore_normal_window()
		if not ok then error(err, 0) end
	end)

end)
