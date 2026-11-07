--- tests/unit/modules/keystats/context_tracker/test_trigger_roi_context.lua

--- ==============================================================================
--- MODULE: Trigger ROI Observed Context Boundaries
--- DESCRIPTION:
--- Drives the real window writer and native-shaped AX notifications. A trip to
--- another context and back must discard a fragment even when no key arrived.
--- ==============================================================================

local helpers = require("tests.helpers")
local Roi = require("keystats.trigger_roi")
local Native = require("tests.support.modules.keystats.context_tracker.ax_native_callback_fixture")

--- Runs the window writer against already available native window observations.
local function with_window(callback)
	return helpers.with_stub_scope({ "modules.keystats.context_tracker", "adapters.accessibility_permission" }, function()
		local native = { title = "Document", id = 42, paused = false, available = true, app_available = true }
		package.loaded["adapters.accessibility_permission"] = {
			frontmost_pid = function() return 7 end,
			is_askable = function() return true end,
			note_read = function() return false end,
		}
		local app = { name = function() return "Editor" end,
			bundleID = function() return "com.example.Editor" end,
			path = function() return "/Applications/Editor.app" end, pid = function() return 7 end }
		local tracker = helpers.load_with_stubs("modules.keystats.context_tracker", {
			application = { watcher = { activated = 1 }, frontmostApplication = function()
				if native.app_error then error("foreground application refused") end
				if native.app_available then return app end
			end },
			window = { focusedWindow = function()
				if not native.available then return nil end
				return { title = function() return native.title end,
					id = function() if native.id_error then error("window unavailable") end; return native.id end,
					isFullScreen = function() return false end }
			end },
			axuielement = { windowElement = function() return nil end, observer = { new = function() return nil end } },
		})
		local state = { active_app_name = "Editor", trigger_roi = Roi.new(0),
			buffer_events = {}, buffer_text = "", rich_chunks = {} }
		helpers.assert_true(tracker.init(state, { append_log = function() return true end, flush_buffer = function() return true end }, function() return native.paused end))
		tracker.update_private_status()
		local function text(value)
			return Roi.text(state.trigger_roi, value, { app = state.active_app_name, window = state.roi_window_id,
				title = state.active_win_title, timestamp = "stamp" }, function() return false end)
		end
		callback(tracker, state, native, text)
	end)
end

helpers.describe("macOS trigger ROI context", function()
	helpers.it("keeps a word on an identical observation and rejects title or window round trips", function()
		with_window(function(tracker, state, native, text)
			text("ordi")
			tracker.update_private_status()
			text("nary ")
			helpers.assert_eq(state.trigger_roi.words.ordinary, 1)
			for _, field in ipairs({ "title", "id" }) do
				text("secr")
				local original = native[field]
				native[field] = field == "title" and "Another document" or 43
				tracker.update_private_status()
				native[field] = original
				tracker.update_private_status()
				text("et ")
			end
			helpers.assert_nil(state.trigger_roi.words.secret)
		end)
	end)

	helpers.it("revokes a word when window identity disappears, throws or capture pauses", function()
		with_window(function(tracker, state, native, text)
			for _, field in ipairs({ "available", "id_error", "paused" }) do
				text("secr")
				native[field] = field ~= "available"
				tracker.update_private_status()
				helpers.assert_nil(state.roi_window_id)
				native[field] = field == "available"
				tracker.update_private_status()
				text("et ")
			end
			helpers.assert_nil(state.trigger_roi.words.secret)
		end)
	end)

	for _, method in ipairs({ "capture_frontmost_app", "resync_context" }) do
		helpers.it("revokes a fragment after refused " .. method .. " and recovery without a key", function()
			with_window(function(tracker, state, native, text)
				for _, failure in ipairs({ "app_available", "app_error" }) do
					text("secr")
					native[failure] = failure == "app_error"
					local called, accepted = pcall(tracker[method])
					helpers.assert_true(not called or accepted == false)
					helpers.assert_true(state.foreground_refresh_pending)
					helpers.assert_nil(state.roi_window_id)
					native[failure] = failure == "app_available"
					helpers.assert_true(tracker.capture_frontmost_app())
					text("et ")
				end
				helpers.assert_nil(state.trigger_roi.words.secret)
			end)
		end)
	end

	helpers.it("revokes fragments through the real current AX focus callback, not stale callbacks", function()
		Native.with_runtime(function(runtime)
			local roi = Roi.new(0)
			runtime.state.trigger_roi = roi
			local context = { app = "Editor", window = 42, title = "Document", timestamp = "stamp" }
			Roi.text(roi, "secr", context, function() return false end)
			runtime.ax_native.emit("AXFocusedUIElementChanged", {})
			helpers.assert_eq(table.concat(roi.word), "secr", "foreign callbacks cannot mutate the current state")
			runtime.ax_native.emit("AXFocusedUIElementChanged")
			Roi.text(roi, "et ", context, function() return false end)
			helpers.assert_nil(roi.words.secret)
			helpers.assert_eq(#runtime.observation.logs, 0)
		end)
	end)
end)
