--- tests/unit/modules/keymap/test_emit_tokens_key_echo.lua

--- ==============================================================================
--- MODULE: Regression — every emit_tokens key carries transaction provenance
--- DESCRIPTION:
--- Text, Enter, Tab, navigation, deletion, and Escape tokens all produce Quartz
--- key events. Character content cannot identify their origin: named keys may
--- have no Unicode payload, and a physical key can have exactly the same payload
--- as an injected one. This test executes the production emitter inside one real
--- SyntheticInput transaction and proves every returned event is owned by that
--- exact replacement generation.
--- ==============================================================================

local helpers = require("tests.helpers")
local SyntheticStack = require("tests.support.synthetic_input_stack")


--- Emits tokens through the production adapter inside an eventtap callback.
--- @param tokens table
--- @return table fixture
local function emit_tokens(tokens)
	local KU, SyntheticInput = SyntheticStack.load("modules.keymap.utils")
	SyntheticInput.enter_callback()
	local transaction = SyntheticInput.begin("test.emit_tokens", "replacement")
	local count, _, logical_text = SyntheticInput.with_transaction(transaction, function()
		return KU.emit_tokens(tokens)
	end)
	helpers.assert_true(SyntheticInput.seal(transaction))
	local consume, events = SyntheticInput.leave_callback(true)
	helpers.assert_true(consume)
	helpers.assert_not_nil(events)
	if hs and hs.timer and hs.timer.__fire_all then hs.timer.__fire_all() end
	helpers.assert_eq(SyntheticInput.stats().active_transactions, 0,
		"the explicit replacement transaction must finish after callback handoff")
	return {
		count = count,
		logical_text = logical_text,
		events = events,
		synthetic = SyntheticInput,
	}
end


--- Proves all events form ordered pairs from one owned transaction.
--- @param fixture table
local function assert_owned_pairs(fixture)
	local property = hs.eventtap.event.properties.eventSourceUserData
	local generation = nil
	for index, event in ipairs(fixture.events) do
		local metadata = fixture.synthetic.lookup_tag(event:getProperty(property))
		helpers.assert_true(metadata and metadata.owned,
			"every emitted phase must carry an Ergopti-owned Quartz tag")
		helpers.assert_eq(metadata.owner, "test.emit_tokens")
		helpers.assert_eq(metadata.effect, "replacement")
		generation = generation or metadata.generation
		helpers.assert_eq(metadata.generation, generation,
			"one token sequence must not be split across transaction generations")
		helpers.assert_eq(metadata.ordinal, math.floor((index + 1) / 2))
		helpers.assert_eq(metadata.phase, event.isDown and "down" or "up")
	end
end


--- Renders keyDown events into a compact observable sequence.
--- @param events table
--- @return string signature
local function down_signature(events)
	local parts = {}
	for _, event in ipairs(events) do
		if event.isDown then
			parts[#parts + 1] = event.unicode or ("{" .. tostring(event.key) .. "}")
		end
	end
	return table.concat(parts)
end


helpers.describe("emit_tokens exact event provenance", function()
	helpers.it("tags text and {Enter} as one replacement", function()
		local fixture = emit_tokens({
			{ kind = "text", value = "line one" },
			{ kind = "key",  value = "return" },
			{ kind = "text", value = "line two" },
		})
		assert_owned_pairs(fixture)
		helpers.assert_eq(down_signature(fixture.events), "line one{return}line two")
		helpers.assert_eq(fixture.count, #fixture.events / 2)
		helpers.assert_eq(fixture.logical_text, "line one\rline two")
	end)

	helpers.it("tags text and {Tab} as one replacement", function()
		local fixture = emit_tokens({
			{ kind = "text", value = "col a" },
			{ kind = "key",  value = "tab" },
			{ kind = "text", value = "col b" },
		})
		assert_owned_pairs(fixture)
		helpers.assert_eq(down_signature(fixture.events), "col a{tab}col b")
		helpers.assert_eq(fixture.count, #fixture.events / 2)
		helpers.assert_eq(fixture.logical_text, "col a\tcol b")
	end)

	helpers.it("tags navigation, deletion, and Escape even without Unicode content", function()
		local fixture = emit_tokens({
			{ kind = "text", value = "abc" },
			{ kind = "key",  value = "left" },
			{ kind = "key",  value = "delete" },
			{ kind = "key",  value = "escape" },
		})
		assert_owned_pairs(fixture)
		helpers.assert_eq(down_signature(fixture.events), "abc{left}{delete}{escape}")
		helpers.assert_eq(fixture.count, #fixture.events / 2)
		helpers.assert_eq(fixture.logical_text, "abc",
			"navigation keys affect focus/cursor state but do not insert logical text")
	end)
end)
