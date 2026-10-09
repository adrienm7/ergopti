--- tests/unit/modules/test_caps_word_native_owner.lua

--- ==============================================================================
--- MODULE: Persistent CapsWord Software Owner Tests
--- DESCRIPTION:
--- Independently authored expectations exercise the actual engine and shared
--- policy. Controlled semantic ports prove software transitions, not native IO.
--- ==============================================================================

local h = require("tests.helpers")
local Engine = require("platform.remap.tap_hold_engine")
local Policy = require("tap_hold.caps_word")
local letters = { [30] = "a", [48] = "b", [46] = "c", [32] = "d", [18] = "e", [33] = "f",
	[2] = "1", [51] = ",", [52] = ".", [57] = " " }
local native_plans = { A = 30, B = 48, C = 46, D = 32, E = 18, F = 33 }

local function owner(options)
	options = options or {}
	local mode = { current = true, plan_current = true, requested = {} }
	local engine = Engine.new({ keys = options.keys or {}, tap_min_ms = 0, one_shot_timeout_ms = 1000,
		key_text = function(code)
			if options.on_text then options.on_text(mode) end
			return letters[code]
		end,
		plan_text = function() error("CapsWord must never call the OneShot planner") end,
		one_shot_result = function() error("CapsWord must never call magic-key substitutions") end,
		held_text_modifier_codes = options.held_levels,
		caps_word_plan = function(text)
			mode.requested[#mode.requested + 1] = text
			if options.on_plan then options.on_plan(mode) end
			local code = native_plans[text]
			if not code then return nil end
			return { { keycode = code, mods = { "shift" } } }, function() return mode.plan_current end
		end })
	mode.engine = engine
	mode.guard = function() return mode.current end
	return mode
end

local function wire(rows)
	local result = {}
	for _, row in ipairs(rows) do result[#result + 1] = row.code .. ":" .. row.value end
	return table.concat(result, ",")
end

h.describe("persistent CapsWord software ownership", function()
h.it("keeps whole-word custody and rejects semantic/output reentry", function()
h.assert_eq(Policy.uppercase("abc"), "ABC", "whole word uppercase, not first-character title")
h.assert_eq(Policy.uppercase("éß"), "ÉSS", "independent Unicode uppercase expansion")
for _, text in ipairs({ "1", ",", ".", "-", "A" }) do
	h.assert_nil(Policy.uppercase(text), "digits/punctuation/already-capital text never request Shift")
end
for _, control in ipairs({ "space", "enter", "tab", "escape", "delete", "left", "right", "up", "down", "home", "end", "pageup", "pagedown" }) do
	h.assert_true(Policy.cancels(control), "explicit conservative control boundary: " .. control)
end
h.assert_true(not Policy.cancels("backspace"), "backspace keeps the current word")

local s = owner()
h.assert_true(s.engine:arm_caps_word(s.guard), "persistent word arms with a software-only retained guard")
h.assert_nil(s.engine.one_shot_until, "persistent owner has no OneShot deadline")
for _, code in ipairs({ 30, 48, 46 }) do
	local out = s.engine:process(code, 1, 20000)
	local expected = ({ [30] = "42:1,30:1,30:0,42:0", [48] = "42:1,48:1,48:0,42:0", [46] = "42:1,46:1,46:0,42:0" })[code]
	h.assert_eq(wire(out), expected, "each whole-word letter has an independently expected complete output")
	h.assert_eq(s.engine:input_arm_state(), "consumed", "prepared output needs the original ACK")
	h.assert_true(not s.engine:ack_caps_word({}), "copied/fabricated batch cannot acknowledge output")
	h.assert_true(s.engine:ack_caps_word(out), "original delivered batch acknowledgement")
	h.assert_eq(s.engine:input_arm_state(), "armed", "word persists after acknowledged character")
	h.assert_eq(wire(s.engine:process(code, 0, 20001)), "", "suppressed physical release cannot leak")
end
h.assert_eq(table.concat(s.requested), "ABC", "independent abc request sequence")
h.assert_nil(s.engine:process(57, 1, 20002), "Space cancels and passes unmodified")
h.assert_nil(s.engine:input_arm_state(), "word ends at Space")
h.assert_nil(s.engine:process(57, 0, 20003), "original Space release passes")
h.assert_nil(s.engine:process(32, 1, 20004), "next word is lowercase physical input")

s = owner(); assert(s.engine:arm_caps_word(s.guard))
local out = s.engine:process(30, 1, 0); assert(s.engine:ack_caps_word(out))
out = s.engine:process(30, 2, 1)
h.assert_eq(wire(out), "42:1,30:1,30:0,42:0", "repeat is a complete uppercase native request")
assert(s.engine:ack_caps_word(out))
h.assert_eq(wire(s.engine:process(30, 0, 2)), "", "repeat keeps ownership of its physical UP")
for _, code in ipairs({ 2, 51, 52 }) do
	h.assert_nil(s.engine:process(code, 1, 3), "punctuation/digit DOWN preserved")
	h.assert_nil(s.engine:process(code, 0, 4), "punctuation/digit UP preserved")
	h.assert_eq(s.engine:input_arm_state(), "armed", "punctuation/digit does not spend the word")
end
s.engine:activity(); h.assert_nil(s.engine:input_arm_state(), "pointer activity cancels")

s = owner({ on_text = function(state) state.current = false end }); assert(s.engine:arm_caps_word(s.guard))
h.assert_eq(wire(s.engine:process(30, 1, 0)), "", "getter reentry cannot issue uppercase output")
h.assert_nil(s.engine:input_arm_state(), "getter reentry withdraws logical mode")
s = owner({ on_plan = function(state) state.plan_current = false end }); assert(s.engine:arm_caps_word(s.guard))
h.assert_nil(s.engine:process(30, 1, 0), "unverified plan passes original input without case injection")
h.assert_nil(s.engine:input_arm_state(), "unverified plan closes mode")

for _, withdrawn in ipairs({ "getter-error", "planner-error", "plan-refused" }) do
	local fail = false
	local options = {
		on_text = function() if fail and withdrawn == "getter-error" then error("controlled getter refusal") end end,
		on_plan = function(state)
			if fail and withdrawn == "planner-error" then error("controlled planner refusal") end
			if fail and withdrawn == "plan-refused" then state.plan_current = false end
		end,
	}
	s = owner(options); assert(s.engine:arm_caps_word(s.guard))
	out = s.engine:process(30, 1, 0); assert(s.engine:ack_caps_word(out))
	fail = true
	h.assert_eq(wire(s.engine:process(30, 2, 1)), "", "owned physical repeat cannot leak after " .. withdrawn)
	h.assert_nil(s.engine:input_arm_state(), "withdrawn repeat closes mode: " .. withdrawn)
	h.assert_eq(wire(s.engine:process(30, 0, 2)), "", "withdrawn repeat retains exact physical UP custody: " .. withdrawn)
end

s = owner({ keys = { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = .3 } } })
assert(s.engine:arm_caps_word(s.guard))
s.engine:process(58, 1, 0)
h.assert_eq(s.engine:input_arm_state(), "armed", "a swallowed trigger key cannot cancel the word before its ordered pair")
local boundary = s.engine:process(58, 0, 1)
local enters = 0
for _, row in ipairs(boundary) do if row.code == 28 then enters = enters + 1 end end
h.assert_eq(enters, 2, "configured tap really emits original Enter DOWN and UP")
h.assert_nil(s.engine:input_arm_state(), "actual configured Enter output cancels the word")

s = owner({ held_levels = function() return { 54, 100 } end }); assert(s.engine:arm_caps_word(s.guard))
out = s.engine:process(30, 1, 0)
h.assert_eq(wire(out), "54:0,100:0,42:1,30:1,30:0,42:0,100:1,54:1", "genuine Shift/AltGr levels are explicitly suspended and restored")
h.assert_true(not s.engine:arm_caps_word(s.guard), "pending native character forbids toggle/rearm")
h.assert_true(not s.engine:clear_input_arm(), "pending output cannot be logically acknowledged away")
h.assert_true(s.engine:ack_caps_word(out), "captured original ACK retires cancelled pending batch")
h.assert_nil(s.engine:input_arm_state(), "cancelled mode remains off after retirement")
s.engine:release_all(); h.assert_nil(s.engine:input_arm_state(), "release_all retires the persistent source")

s = owner(); assert(s.engine:arm_caps_word(s.guard))
out = s.engine:process(30, 1, 0, { source = "original-A" }); assert(s.engine:ack_caps_word(out))
s.engine:clear_input_arm()
h.assert_nil(s.engine:process(30, 1, 1, { source = "other-B" }), "other original keyboard DOWN passes after mode cancellation")
h.assert_nil(s.engine:process(30, 0, 2, { source = "other-B" }), "same-code other keyboard UP cannot consume original A custody")
h.assert_eq(wire(s.engine:process(30, 0, 3, { source = "original-A" })), "", "original A still owns its suppressed physical release")

s = owner({ on_text = function(state) state.engine:process(48, 1, 1) end }); assert(s.engine:arm_caps_word(s.guard))
h.assert_eq(wire(s.engine:process(30, 1, 0)), "", "recursive getter event closes mode before any output")
h.assert_nil(s.engine:input_arm_state(), "recursive semantic event cannot revive the owner")

local Fixture = require("tests.support.input_owner_fixture")
Fixture.with_session({}, function(session)
	h.assert_true(not session.hook.arm_caps_word({}), "detached public table cannot arm native CapsWord")
	h.assert_nil(session.hook.plan_caps_word("A"), "lookup outside original physical processing has no native plan")
	local base = session.base
	base.caps_word_plan = session.hook.plan_caps_word
	local Pair = require("modules.shortcuts.key_combinations").new({
		keys = { { id = "caps_lock", key = "caps_lock" }, { id = "tab", key = "tab" } },
		hold_picker = { modifiers = { "ctrl", "shift" }, layers = { "nav" } },
		files = { read_with_status = function() return '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "caps_word"\n', "ok" end },
		route = function() return "/controlled/caps-word.toml" end,
		is_paused = function() return false end, changed = function() return true end,
		-- Logical software fixture only; no desktop source or public action is admitted.
		actions = { is_assignable = function(action) return action == "caps_word" end } })
	local installed = require("platform.remap.key_combination_engine").new(base,
		Pair.engine_options({ caps_lock = 300, tab = 300 }))
	local callbacks = 0
	assert(session.hook.set_remapper(installed, function(action)
		callbacks = callbacks + 1
		h.assert_eq(action, "caps_word", "original software-controlled pair selects its own logical action")
		local lease = session.hook.capture_input_owner()
		h.assert_not_nil(lease, "original live CapsWord frame supplies only a logical lease")
		h.assert_true(not session.hook.arm_one_shot(lease), "CapsWord lease cannot alias the OneShot arm")
		h.assert_true(not session.hook.arm_caps_word(lease), "controlled capture supplies no genuine CapsWord desktop proof")
		return action
	end))
	session.pair()
	h.assert_eq(callbacks, 1, "actual registered callback ran once")
	h.assert_nil(base:input_arm_state(), "logical callback alone cannot publish native mode")
	for _, row in ipairs(session.rows) do
		h.assert_true(row[1] ~= 42 and row[1] ~= 30, "no shifted letter is emitted by controlled semantic admission")
	end
end)

end)
end)
return true
