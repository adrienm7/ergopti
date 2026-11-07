--- tests/unit/modules/keystats/synthetic/test_trigger_roi_callbacks.lua

--- ==============================================================================
--- MODULE: macOS Trigger ROI Callback Admission
--- DESCRIPTION:
--- Drives the production keystats eventtap, hotstring sink, maintenance callback
--- and shutdown. The outbox accepts immutable builders; tests execute them only
--- after input returns, including refusal and retry at the queue boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixtures = require("tests.support.keystats_provenance_fixture")

--- Starts the real engine with observable persistence and native callback boundaries.
local function fixture()
	local f = Fixtures.load_keystats()
	f.hs.caffeinate = { watcher = { new = function()
		return { start = function(self) return self end, stop = function(self) return self end }
	end } }
	package.loaded["modules.keymap"] = { is_known_trigger = function(word) return word == "known" end }
	local control = { now = 1000, calls = 0, builders = {}, rows = {}, errors = {} }
	f.hs.timer.absoluteTime = function() return control.now * 1000000 end
	local log = package.loaded["modules.keystats.log_manager"]
	log.append_log = function() return true end
	log.defer_entry_builder = function(builder)
		control.calls = control.calls + 1
		if control.reject_at == control.calls then return false end
		control.builders[#control.builders + 1] = builder
		return true
	end
	package.loaded["infra.logger"].error = function(_, message) control.errors[#control.errors + 1] = message end
	f.start()
	f.state.active_app_name, f.state.session_app_name = "Editor", "Editor"
	f.state.active_win_title, f.state.roi_window_id = "Document", 42
	function control.drain()
		local queued = control.builders
		control.builders = {}
		for _, builder in ipairs(queued) do control.rows[#control.rows + 1] = builder() end
	end
	function control.roi()
		control.drain()
		local rows = {}
		for _, row in ipairs(control.rows) do
			if row.type == "roi_snapshot" or row.type == "new_trigger_candidate" or row.type == "trigger_halflife" then
				rows[#rows + 1] = row
			end
		end
		return rows
	end
	function control.key(chars, keycode, event_type)
		local event = Fixtures.physical_key(f.hs, "a")
		function event:getType() return event_type or f.hs.eventtap.event.types.keyDown end
		function event:getKeyCode() return keycode or 0 end
		function event:getCharacters() return chars end
		function event:getFlags() return {} end
		f.dispatch(event)
	end
	function control.tick()
		local delay = require("infra.timings").sec("keystats", "maintenance_interval_ms")
		for _, timer in ipairs(f.hs.timer.__timers) do
			if timer.running and timer.delay == delay then timer:fire() end
		end
	end
	return f, control
end

helpers.describe("macOS trigger ROI admission", function()
	helpers.it("publishes fifth manual words and excludes the admitted trigger registry", function()
		local f, c = fixture()
		for _ = 1, 5 do c.key("candidate known ") end
		local rows = c.roi()
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].word, "candidate")
		helpers.assert_eq(rows[1].occurrences, 5)
		helpers.assert_eq(rows[1].app, "Editor")
		helpers.assert_eq(type(rows[1].timestamp), "string")
		helpers.assert_eq(c.errors, {})
		helpers.assert_true(f.keystats.stop())
	end)

	helpers.it("never joins a fragment across synthetic, private, unknown or pointer boundaries", function()
		local f, c = fixture()
		for _, barrier in ipairs({
			function() f.keystats.notify_synthetic("output", "llm", 0) end,
			function()
				f.state.is_secure_field = true
				c.key("hidden")
				f.state.is_secure_field = false
			end,
			function()
				f.state.roi_window_id = nil
				c.key("hidden")
				f.state.roi_window_id = 42
			end,
			function() c.key("", 0, f.hs.eventtap.event.types.leftMouseDown) end,
			function() c.key("", 0, f.hs.eventtap.event.types.rightMouseDown) end,
			function() c.key("", 0, f.hs.eventtap.event.types.otherMouseDown) end,
			function() c.key("", 0, f.hs.eventtap.event.types.scrollWheel) end,
		}) do
			for _ = 1, 5 do c.key("secr"); barrier(); c.key("et ") end
		end
		helpers.assert_nil(f.state.trigger_roi.words.secret)
		helpers.assert_eq(#c.roi(), 0)
		helpers.assert_eq(c.errors, {})
		helpers.assert_true(f.keystats.stop())
	end)

	helpers.it("does not join a word across policy exclusion and readmission without a key", function()
		local f, c = fixture()
		f.state.active_app_bundle = "com.example.Editor"
		for _ = 1, 5 do
			c.key("secr")
			f.keystats.set_disabled_apps({ { bundleID = "com.example.Editor" } })
			helpers.assert_eq(f.keystats.may_persist(), false)
			f.keystats.set_disabled_apps({})
			helpers.assert_true(f.keystats.may_persist())
			c.key("et ")
		end
		helpers.assert_nil(f.state.trigger_roi.words.secret)
		helpers.assert_eq(#c.roi(), 0)
		helpers.assert_true(f.keystats.stop())
	end)

	helpers.it("counts only accepted hotstrings, keeps private savings numeric and retries ROI queue refusal", function()
		local f, c = fixture()
		c.reject_at = 1
		helpers.assert_eq(f.keystats.log_hotstring("no", "not accepted"), false)
		helpers.assert_eq(f.state.trigger_roi.fired, 0)
		c.reject_at = 12 -- ten public event builders precede the first ROI builder.
		for _ = 1, 10 do helpers.assert_true(f.keystats.log_hotstring("😀", "😀😀")) end
		helpers.assert_eq(#f.state.trigger_roi.pending, 1)
		c.reject_at = nil
		helpers.assert_true(f.keystats.log_private_hotstring("PRIVATE", "PRIVATE output"))
		local rows = c.roi()
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].session_saved, 20)
		helpers.assert_eq(rows[1].session_fired, 10)
		helpers.assert_nil(f.state.trigger_roi.last_use.private)
		helpers.assert_true(f.keystats.stop())
		rows = c.roi()
		helpers.assert_eq(#rows, 2)
		helpers.assert_eq(rows[2].session_fired, 11)
		helpers.assert_eq(rows[2].session_saved, 27)
		helpers.assert_true(f.keystats.stop())
		helpers.assert_eq(#c.roi(), 2, "idempotent shutdown emits no second final snapshot")
	end)

	helpers.it("uses the existing maintenance timer and denies private-context final snapshots", function()
		local f, c = fixture()
		helpers.assert_true(f.keystats.log_hotstring("PUBLIC", "replacement"))
		c.now = c.now + 30 * 24 * 60 * 60 * 1000
		c.tick()
		local rows = c.roi()
		helpers.assert_eq(#rows, 1)
		helpers.assert_eq(rows[1].type, "trigger_halflife")
		helpers.assert_eq(rows[1].trigger, "public")
		f.state.is_private_window = true
		c.now = c.now + 3600000
		c.tick()
		helpers.assert_eq(#c.roi(), 1)
		helpers.assert_true(f.keystats.stop())
		helpers.assert_eq(#c.roi(), 1)
		helpers.assert_eq(c.errors, {})
	end)
end)
