--- tests/unit/adapters/synthetic_input/test_key_up_fence_pairing.lua

--- ==============================================================================
--- MODULE: Key-up fence pairing (key-up-fence-pairing)
--- DESCRIPTION:
--- A physical event that arrives while Ergopti output is still being typed is
--- consumed and replayed behind it, so typing order holds. A key-up whose
--- key-down had already reached the application was held back the same way:
--- the application then saw that key down for as long as the expansion took to
--- type, long enough for the macOS press-and-hold accent popup on a plain tap
--- (issue #100). A key-up now waits only behind its own consumed key-down, and
--- every replayed key-down is still followed by exactly one key-up.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_input_fixture")

local KEY_DOWN = Fixture.KEY_DOWN
local KEY_UP = Fixture.KEY_UP
local KEYCODE_A = 0
local KEYCODE_E = 14

--- Queues one paced terminal replacement and leaves it typing.
--- @return table fixture
--- @return table synthetic
local function typing_expansion()
	local fixture = Fixture.make({ frontmost_app = { id = "terminal-app" } })
	local synthetic = fixture.load()
	synthetic.enter_callback()
	local tx = synthetic.begin("unit.key-up-fence", "replacement")
	synthetic.with_transaction(tx, function()
		synthetic.emit_key_stroke({}, "delete", 0)
		synthetic.emit_key_stroke({}, "delete", 0)
		synthetic.emit_key_strokes("XY")
	end)
	local owner = synthetic.prepare_collected_paced(tx, 2, 12000, { id = "terminal-app" })
	helpers.assert_not_nil(owner)
	helpers.assert_true(synthetic.seal(tx))
	helpers.assert_true(synthetic.authorize_collected_paced(owner))
	helpers.assert_true(synthetic.commit_collected_paced(owner))
	local consume = synthetic.leave_callback(true)
	helpers.assert_true(consume)
	helpers.assert_true(synthetic.stats().pending > 0, "the expansion is still typing")
	return fixture, synthetic
end

--- Builds one physical key edge.
--- @param fixture table
--- @param keycode number
--- @param is_down boolean
--- @return table event
local function physical(fixture, keycode, is_down)
	local event = fixture.external_event(nil, 42)
	event.type = is_down and KEY_DOWN or KEY_UP
	event.keycode = keycode
	return event
end

--- Pumps every timer until the FIFO is empty.
--- @param fixture table
--- @param synthetic table
local function drain(fixture, synthetic)
	local guard = 0
	while synthetic.stats().pending > 0 and #fixture.timers > 0 do
		fixture.fire_next_timer()
		guard = guard + 1
		helpers.assert_true(guard < 120, "the FIFO must drain")
	end
	helpers.assert_eq(synthetic.stats().pending, 0)
end

helpers.describe("synthetic input: a key-up waits only behind its own key-down (key-up-fence-pairing)", function()
	helpers.it("releases a key-up at once when its key-down already reached the application", function()
		local fixture, synthetic = typing_expansion()
		local fence = synthetic.claim_physical_fence(physical(fixture, KEYCODE_A, false))
		helpers.assert_true(fence == nil or fence.consume_original ~= true,
			"a release behind a typing expansion keeps the key held for the application")
		drain(fixture, synthetic)
	end)

	helpers.it("keeps a key-up behind its own replayed key-down, each posted exactly once", function()
		local fixture, synthetic = typing_expansion()
		local posted = {}
		fixture.global_key_observer = function(event)
			posted[#posted + 1] = { type = event.type, keycode = event.keycode }
		end
		local down = synthetic.claim_physical_fence(physical(fixture, KEYCODE_A, true))
		helpers.assert_true(down ~= nil and down.consume_original == true,
			"a key-down behind typing output is replayed after it")
		local up = synthetic.claim_physical_fence(physical(fixture, KEYCODE_A, false))
		helpers.assert_true(up ~= nil and up.consume_original == true,
			"its key-up must not overtake the replayed key-down")
		local other_up = synthetic.claim_physical_fence(physical(fixture, KEYCODE_E, false))
		helpers.assert_true(other_up == nil or other_up.consume_original ~= true,
			"another key's release has no key-down to wait for")
		drain(fixture, synthetic)
		helpers.assert_eq(#posted, 2, "one replayed key-down, one replayed key-up")
		helpers.assert_eq(posted[1].type, KEY_DOWN)
		helpers.assert_eq(posted[2].type, KEY_UP)
		helpers.assert_eq(posted[1].keycode, KEYCODE_A)
		helpers.assert_eq(posted[2].keycode, KEYCODE_A)
	end)

	helpers.it("lets a key-up go once its replayed key-down has been posted", function()
		local fixture, synthetic = typing_expansion()
		helpers.assert_true(synthetic.claim_physical_fence(physical(fixture, KEYCODE_A, true)).consume_original)
		drain(fixture, synthetic)
		-- A second expansion is typing when the key is released.
		local fixture_two = fixture
		local tx = synthetic.begin("unit.key-up-fence.second", "replacement")
		synthetic.enter_callback()
		synthetic.with_transaction(tx, function()
			synthetic.emit_key_stroke({}, "delete", 0)
			synthetic.emit_key_strokes("Z")
		end)
		local owner = synthetic.prepare_collected_paced(tx, 1, 12000, { id = "terminal-app" })
		helpers.assert_true(synthetic.seal(tx))
		helpers.assert_true(synthetic.authorize_collected_paced(owner))
		helpers.assert_true(synthetic.commit_collected_paced(owner))
		synthetic.leave_callback(true)
		local up = synthetic.claim_physical_fence(physical(fixture_two, KEYCODE_A, false))
		helpers.assert_true(up == nil or up.consume_original ~= true,
			"the key-down already reached the application: its release is not held")
		drain(fixture_two, synthetic)
	end)
end)
