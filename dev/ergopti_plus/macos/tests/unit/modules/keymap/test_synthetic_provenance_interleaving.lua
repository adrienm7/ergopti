--- tests/unit/modules/keymap/test_synthetic_provenance_interleaving.lua

--- ==============================================================================
--- MODULE: Synthetic Input Transaction Interleaving Regression Tests
--- DESCRIPTION:
--- Drives the production keymap eventtap with events built by the production
--- SyntheticInput adapter. The tests exercise immutable Quartz user-data tags,
--- transaction reordering, ledger eviction, and edit shortcuts end to end: an
--- untagged physical event always reaches buffer tracking, while an explicitly
--- owned event never mutates that buffer even when delivery order or diagnostic
--- source PID differs from construction order.
--- ==============================================================================

local helpers = require("tests.helpers")

local CURRENT_PID = 7001
local FOREIGN_PID = 8002
local KEYCODE_A = 0
local KEYCODE_V = 9
local KEYCODE_BACKSPACE = 51
local KEYCODE_F16 = 106


--- Converts the modifier list accepted by newKeyEvent into keymap flags.
--- @param modifiers table
--- @return table flags
local function modifier_flags(modifiers)
	local flags = {}
	for key, value in pairs(modifiers or {}) do
		if type(key) == "number" then
			flags[value] = true
		elseif value == true then
			flags[key] = true
		end
	end
	return flags
end


--- Adds the native accessors used by the production keymap to adapter events.
--- @param event table
--- @param key string|number
--- @param is_down boolean
--- @return table event
local function decorate_key_event(event, key, is_down)
	event.getType = function()
		return is_down and hs.eventtap.event.types.keyDown
			or hs.eventtap.event.types.keyUp
	end
	event.getKeyCode = function(self)
		if type(key) == "number" then return key end
		if key == "delete" then return KEYCODE_BACKSPACE end
		if key == "v" then return KEYCODE_V end
		if key == "f16" then return KEYCODE_F16 end
		return KEYCODE_A
	end
	event.getFlags = function(self)
		return modifier_flags(self.mods)
	end
	event.getCharacters = function(self)
		if self.unicode ~= nil then return self.unicode end
		return type(key) == "string" and #key == 1 and key or ""
	end
	return event
end


--- Loads fresh production keymap/provenance/transaction modules and captures
--- the real keyDown eventtap callback.
--- @return table fixture
local function load_fixture()
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap")
			or name:match("^modules%.llm")
			or name:match("^modules%.keylogger")
			or name:match("^ui%.tooltip")
			or name == "adapters.synthetic_input"
			or name == "adapters.event_provenance"
		) then
			package.loaded[name] = nil
		end
	end

	package.loaded["tests.stubs.hs"] = nil
	local base_hs = require("tests.stubs.hs")
	local base_eventtap = base_hs.eventtap
	local base_new_key_event = base_eventtap.event.newKeyEvent
	local taps = {}
	local eventtap = {}
	for key, value in pairs(base_eventtap) do eventtap[key] = value end
	eventtap.event = {}
	for key, value in pairs(base_eventtap.event) do eventtap.event[key] = value end
	eventtap.event.newKeyEvent = function(modifiers, key, is_down)
		return decorate_key_event(base_new_key_event(modifiers, key, is_down), key, is_down)
	end
	eventtap.new = function(types, callback)
		local tap = {
			types = types,
			callback = callback,
			enabled = false,
			start = function(self) self.enabled = true; return self end,
			stop = function(self) self.enabled = false; return self end,
			isEnabled = function(self) return self.enabled end,
		}
		taps[#taps + 1] = tap
		return tap
	end

	local keymap = helpers.load_with_stubs("modules.keymap", {
		eventtap = eventtap,
		processInfo = { processID = CURRENT_PID },
	})
	-- This test owns event provenance, not asynchronous AX classification. Make
	-- the already-loaded keymap utility report a known-normal window so invoking
	-- the captured callback models the reachable post-prewarm runtime state.
	local Utils = require("modules.keymap.utils")
	Utils.is_ignored_window = function() return false, 1 end
	Utils.is_secure_field = function() return false, 1 end
	local hs_stub = require("hs")
	local synthetic = require("adapters.synthetic_input")
	local keydown_tap = nil
	for _, tap in ipairs(taps) do
		if #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyDown then
			keydown_tap = tap
			break
		end
	end
	helpers.assert_not_nil(keydown_tap,
		"the production keymap keyDown eventtap must be created")
	return {
		keymap = keymap,
		synthetic = synthetic,
		handle = keydown_tap.callback,
		hs = hs_stub,
	}
end


--- Builds an untagged physical keyDown event.
--- Source PID is supplied only so tests can prove it is never consulted as an
--- ownership fallback when the explicit user-data tag is absent.
--- @param fixture table
--- @param chars string
--- @param keycode number|nil
--- @param flags table|nil
--- @param user_data number|nil
--- @param source_pid number|nil
--- @return table event
local function physical_event(fixture, chars, keycode, flags, user_data, source_pid)
	local properties = fixture.hs.eventtap.event.properties
	local event = { pid_reads = 0 }
	event.getType = function() return fixture.hs.eventtap.event.types.keyDown end
	event.getKeyCode = function() return keycode or KEYCODE_A end
	event.getFlags = function() return flags or {} end
	event.getCharacters = function() return chars end
	event.getProperty = function(self, property)
		if property == properties.eventSourceUserData then return user_data or 0 end
		if property == properties.eventSourceUnixProcessID then
			self.pid_reads = self.pid_reads + 1
			return source_pid or CURRENT_PID
		end
		return 0
	end
	return event
end


--- Makes PID diagnostics disagree with an adapter event's explicit ownership.
--- @param fixture table
--- @param event table
local function set_foreign_diagnostic_pid(fixture, event)
	local source_pid_property = fixture.hs.eventtap.event.properties.eventSourceUnixProcessID
	local original_get_property = event.getProperty
	event.getProperty = function(self, property)
		if property == source_pid_property then return FOREIGN_PID end
		return original_get_property(self, property)
	end
end


--- Creates and hands off one real replacement transaction.
--- @param fixture table
--- @param build function(table, table)
--- @return table events
local function replacement_events(fixture, build)
	local tx = fixture.synthetic.begin("test.interleaving", "replacement")
	local batch = fixture.synthetic.begin_callback(tx)
	build(fixture.synthetic, batch)
	local consume, events = fixture.synthetic.finish_callback(batch, true)
	helpers.assert_true(consume)
	helpers.assert_not_nil(events)
	helpers.assert_true(fixture.synthetic.seal(tx))
	return events
end


--- Runs a sequence, then observes the buffer immediately before a sentinel key.
--- @param setup function(table)
--- @return string buffer
--- @return table fixture
local function observed_buffer_after(setup)
	local fixture = load_fixture()
	local observed = nil
	fixture.keymap.register_interceptor(function(_event, buffer, context)
		if context and context.chars == "~" then observed = buffer end
		return nil
	end)
	setup(fixture)
	fixture.handle(physical_event(fixture, "~"))
	return observed, fixture
end


helpers.describe("keymap synthetic provenance: explicit transactions under interleaving", function()
	helpers.it("keeps identical same-process physical input while filtering reordered owned echoes", function()
		local physical_a = nil
		local buffer = observed_buffer_after(function(fixture)
			local events = replacement_events(fixture, function(synthetic, batch)
				helpers.assert_true(synthetic.keyStrokes(batch, "AB"))
			end)
			-- Deliver B first and make PID diagnostics disagree. The immutable tags,
			-- not character order or PID, still identify both adapter events.
			set_foreign_diagnostic_pid(fixture, events[3])
			fixture.handle(events[3])
			physical_a = physical_event(fixture, "A", KEYCODE_A, nil, 0, CURRENT_PID)
			fixture.handle(physical_a)
			set_foreign_diagnostic_pid(fixture, events[1])
			fixture.handle(events[1])
		end)
		helpers.assert_eq(buffer, "A",
			"an identical untagged physical A must survive reordered tagged A/B echoes")
		helpers.assert_eq(physical_a.pid_reads, 0,
			"an absent explicit tag must not fall back to a same-process PID heuristic")
	end)

	helpers.it("filters an evicted tag instead of reclassifying it as physical", function()
		local stale_metadata = nil
		local buffer = observed_buffer_after(function(fixture)
			-- Keep the production eviction algorithm but shrink its public bound so
			-- this regression test reaches the stale-tag path with three key pairs.
			fixture.synthetic.RECORD_LIMIT = 4
			local events = replacement_events(fixture, function(synthetic, batch)
				helpers.assert_true(synthetic.keyStrokes(batch, "ABC"))
			end)
			local tag_property = fixture.hs.eventtap.event.properties.eventSourceUserData
			stale_metadata = fixture.synthetic.lookup_tag(events[1]:getProperty(tag_property))
			fixture.handle(physical_event(fixture, "x"))
			fixture.handle(events[1])
		end)
		helpers.assert_true(stale_metadata and stale_metadata.owned)
		helpers.assert_true(stale_metadata and stale_metadata.stale,
			"the first tag must actually be evicted before exercising keymap")
		helpers.assert_eq(buffer, "x",
			"a decodable evicted Ergopti tag must fail closed and leave the buffer unchanged")
	end)

	helpers.it("consumes a stale loopback signal without restoring loopback authority", function()
		local fixture = load_fixture()
		local tx = fixture.synthetic.begin("test.stale-loopback", "action")
		local batch = fixture.synthetic.begin_callback(tx)
		fixture.synthetic.loopbackKeyStroke(batch, {}, "f16")
		local stale_f16 = batch.events[1]
		fixture.synthetic.cancel(tx) -- delivery after cancellation/reload has no enrichment
		local epoch_before = fixture.synthetic.current_action_epoch()

		local tag_property = fixture.hs.eventtap.event.properties.eventSourceUserData
		local metadata = fixture.synthetic.lookup_tag(stale_f16:getProperty(tag_property))
		helpers.assert_true(metadata.stale_loopback)
		helpers.assert_true(not metadata.loopback,
			"stale metadata must never regain live LLM loopback authority")

		fixture.keymap.pause_processing()
		local consume, returned_events = fixture.handle(stale_f16)
		helpers.assert_true(consume,
			"the internal F16 keyDown must not leak into the frontmost application")
		helpers.assert_nil(returned_events)
		helpers.assert_true(fixture.synthetic.current_action_epoch() == epoch_before,
			"a stale internal loopback is not an observable user action")
	end)

	helpers.it("does not let a physical Cmd+V consume a tagged paste event", function()
		local buffer = observed_buffer_after(function(fixture)
			fixture.handle(physical_event(fixture, "q"))
			local events = replacement_events(fixture, function(synthetic, batch)
				helpers.assert_true(synthetic.keyStroke(batch, { "cmd" }, "v"))
			end)
			fixture.handle(physical_event(fixture, "v", KEYCODE_V, { cmd = true }))
			fixture.handle(physical_event(fixture, "z"))
			fixture.handle(events[1])
		end)
		helpers.assert_eq(buffer, "z",
			"physical paste must invalidate prior context while the tagged echo stays filtered")
	end)

	helpers.it("does not let a physical Backspace consume a tagged delete event", function()
		local buffer = observed_buffer_after(function(fixture)
			fixture.handle(physical_event(fixture, "q"))
			local events = replacement_events(fixture, function(synthetic, batch)
				helpers.assert_true(synthetic.keyStroke(batch, {}, "delete"))
			end)
			fixture.handle(physical_event(fixture, "", KEYCODE_BACKSPACE))
			fixture.handle(physical_event(fixture, "x"))
			fixture.handle(events[1])
		end)
		helpers.assert_eq(buffer, "x",
			"physical Backspace must edit the buffer while the tagged delete stays filtered")
	end)
end)
