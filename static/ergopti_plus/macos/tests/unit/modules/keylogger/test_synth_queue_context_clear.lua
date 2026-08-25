--- tests/unit/modules/keylogger/test_synth_queue_context_clear.lua

--- ==============================================================================
--- MODULE: Privacy Context Provenance Regression Tests
--- DESCRIPTION:
--- Privacy context changes must clear sensitive logical buffers,
--- but they must neither create nor erase physical-event ownership. Ownership is
--- an immutable tag on each emitted event, so an identical untagged key remains
--- physical across secure-field and application boundaries.
--- ==============================================================================

local helpers = require("tests.helpers")
local provenance_fixture = require("tests.support.keylogger_provenance_fixture")

local function load_tracker(focused_element)
	local observer_callback
	local observer = {
		addWatcher = function() end,
		removeWatcher = function() end,
		callback = function(_self, fn) observer_callback = fn end,
		start = function() end,
		stop = function() end,
	}
	local app_element = {
		attributeValue = function(_self, attr)
			if attr == "AXFocusedUIElement" then return focused_element end
			return nil
		end,
	}
	package.loaded["adapters.secure_field_detector"] = {
		refresh = function() end,
		isSecureField = function() return false end,
		isSecureApp = function() return false end,
		isElementSecure = function(element)
			return element:attributeValue("AXRole") == "AXSecureTextField"
		end,
	}
	local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
		application = { watcher = { activated = 1 } },
		axuielement = {
			observer = { new = function() return observer end },
			applicationElement = function() return app_element end,
			windowElement = function() return nil end,
		},
	})
	local state = {
		active_app_name = "TextEdit",
		active_app_start = 0,
		is_secure_field = false,
		is_private_window = false,
		buffer_events = { { "secret" } },
		buffer_text = "secret",
		rich_chunks = { { type = "physical", text = "secret" } },
		last_time = 0,
	}
	tracker.init(state, {
		append_log = function() end,
		flush_buffer = function() end,
		log_app_switch = function() end,
	}, function() return false end)
	return tracker, state, function() return observer_callback end
end

local function make_event_pair(owner)
	local synthetic_input = require("adapters.synthetic_input")
	local provenance = require("adapters.event_provenance")
	return {
		synthetic_input = synthetic_input,
		provenance = provenance,
		tagged = provenance_fixture.tagged_key(
			synthetic_input, owner, "replacement", "x"),
		physical = provenance_fixture.physical_key(_G.hs, "x"),
	}
end

local function assert_exact_pair(pair, consumer, owner)
	local metadata = pair.provenance.classify(pair.tagged, consumer .. ".tagged")
	helpers.assert_not_nil(metadata)
	helpers.assert_eq(metadata.owner, owner)
	helpers.assert_eq(metadata.effect, "replacement")
	helpers.assert_nil(pair.provenance.classify(pair.physical, consumer .. ".physical"),
		"the same-process, same-key physical event has no ownership tag")
end

helpers.describe("context tracker: exact provenance across privacy boundaries", function()
	helpers.it("secure-field entry clears sensitive buffers but preserves event identity", function()
		local secure_field = {
			attributeValue = function(_self, attr)
				if attr == "AXRole" then return "AXSecureTextField" end
				if attr == "AXValue" then return "" end
				return nil
			end,
		}
		local tracker, state = load_tracker(secure_field)
		local pair = make_event_pair("test.secure-boundary")
		local records_before = pair.synthetic_input.stats().records

		tracker.update_ax_observer(42)

		helpers.assert_true(state.is_secure_field)
		helpers.assert_eq(#state.buffer_events, 0)
		helpers.assert_eq(state.buffer_text, "")
		helpers.assert_eq(#state.rich_chunks, 0)
		helpers.assert_eq(pair.synthetic_input.stats().records, records_before)
		assert_exact_pair(pair, "test.secure-boundary", "test.secure-boundary")
	end)

	helpers.it("application activation updates context without mutating ownership", function()
		local tracker, state = load_tracker(nil)
		local pair = make_event_pair("test.app-boundary")
		local stats_before = pair.synthetic_input.stats()

		tracker.app_watcher_cb("Terminal", _G.hs.application.watcher.activated, {
			bundleID = function() return "com.apple.Terminal" end,
			path = function() return "/System/Applications/Utilities/Terminal.app" end,
			pid = function() return 73 end,
		})

		helpers.assert_eq(state.active_app_name, "Terminal")
		helpers.assert_eq(state.active_app_bundle, "com.apple.Terminal")
		helpers.assert_eq(state.active_app_pid, 73)
		local stats_after = pair.synthetic_input.stats()
		helpers.assert_eq(stats_after.records, stats_before.records)
		helpers.assert_eq(stats_after.generation, stats_before.generation)
		assert_exact_pair(pair, "test.app-boundary", "test.app-boundary")
	end)

	helpers.it("a focus callback cannot turn an untagged key into an owned echo", function()
		local plain_field = {
			attributeValue = function(_self, attr)
				if attr == "AXRole" then return "AXTextField" end
				if attr == "AXValue" then return "plain" end
				return nil
			end,
		}
		local tracker, _, get_observer_callback = load_tracker(nil)
		local pair = make_event_pair("test.focus-boundary")
		tracker.update_ax_observer(91)
		local callback = get_observer_callback()
		helpers.assert_type(callback, "function")

		callback(plain_field, "AXFocusedUIElementChanged", {
			addWatcher = function() end,
			removeWatcher = function() end,
		})

		assert_exact_pair(pair, "test.focus-boundary", "test.focus-boundary")
	end)
end)
