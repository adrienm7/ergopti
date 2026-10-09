--- tests/unit/modules/shortcuts/test_screen_recording_stale_reset.lua

--- ==============================================================================
--- MODULE: Screen Recording stale entry reset (screen-recording-stale-reset)
--- DESCRIPTION:
--- The packaged app is signed ad hoc, so each build or update has a new code
--- identity. System Settings kept the previous Screen Recording switch checked
--- while macOS refused the new binary, and every capture failed until the user
--- deleted the entry by hand. The capture gate must reset this app's own entry
--- before prompting, once per session, and only explain on later refusals.
--- ==============================================================================

local helpers = require("tests.helpers")

local BUNDLE_ID = "com.ergoptiplus.app.hammerspoon"

local SUBJECT_MODULES = {
	"adapters.screen_capture",
	"infra.notifications",
	"infra.i18n",
	"infra.logger",
	"modules.shortcuts.actions.screen_capture_flow",
}

--- Runs one scenario against the real gate and a scripted adapter.
--- @param options table|nil granted (true/false/nil), bundle_id, reset_starts.
--- @param scenario function Receives (flow, fixture).
local function with_gate(options, scenario)
	local opts = options or {}
	helpers.with_stub_scope(SUBJECT_MODULES, function()
		local f = { events = {}, notifications = {}, resets = {}, logs = { error = {}, warn = {} } }
		local function event(name) f.events[#f.events + 1] = name end

		package.loaded["adapters.screen_capture"] = {
			permission_state = function()
				if opts.granted == nil and opts.query_fails then return nil, "tcc down" end
				return opts.granted == true
			end,
			bundle_id = function()
				if opts.bundle_id == false then return nil, "hs.processInfo.bundleID is unavailable" end
				return BUNDLE_ID
			end,
			reset_permission = function(bundle_id, on_done)
				event("reset:" .. bundle_id)
				f.resets[#f.resets + 1] = on_done
				return opts.reset_starts ~= false
			end,
			request_permission = function() event("prompt"); return true end,
			open_permission_settings = function() event("settings"); return true end,
		}
		package.loaded["infra.notifications"] = {
			notify = function(title, body, kind, on_click)
				event("notice:" .. tostring(body))
				f.notifications[#f.notifications + 1] = { title = title, body = body, kind = kind,
					on_click = on_click }
				return true
			end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		local logger = helpers.make_logger_stub()
		for _, level in ipairs({ "error", "warn" }) do
			logger[level] = function(_, message, ...)
				f.logs[level][#f.logs[level] + 1] = string.format(tostring(message), ...)
			end
		end
		package.loaded["infra.logger"] = logger
		package.loaded["modules.shortcuts.actions.screen_capture_flow"] = nil

		--- @param name string Event to look up.
		--- @return integer|nil index
		function f.index(name)
			for i, e in ipairs(f.events) do if e == name then return i end end
			return nil
		end
		--- @param name string Event to count.
		--- @return integer count
		function f.count(name)
			local n = 0
			for _, e in ipairs(f.events) do if e == name then n = n + 1 end end
			return n
		end

		scenario(require("modules.shortcuts.actions.screen_capture_flow"), f)
	end)
end

helpers.describe("Screen Recording gate: stale entry reset (screen-recording-stale-reset)", function()
	helpers.it("resets this app's entry before prompting, opening the pane and naming the entry", function()
		with_gate({ granted = false }, function(flow, f)
			helpers.assert_eq(flow.ensure_permission("Interactive screenshot"), false)
			helpers.assert_eq(f.events, { "reset:" .. BUNDLE_ID },
				"no prompt may run before the stale entry is cleared")
			f.resets[1](true)
			local prompt_at = f.index("prompt")
			local notice_at = f.index("notice:shortcuts.screen_recording_reset")
			local settings_at = f.index("settings")
			helpers.assert_true(prompt_at ~= nil and notice_at ~= nil and settings_at ~= nil,
				table.concat(f.events, ","))
			helpers.assert_true(prompt_at < settings_at, table.concat(f.events, ","))
			helpers.assert_eq(f.notifications[1].title, "shortcuts.screen_recording_required_title")
			helpers.assert_eq(f.notifications[1].kind, "error")
		end)
	end)

	helpers.it("resets and prompts at most once per session; later refusals only explain", function()
		with_gate({ granted = false }, function(flow, f)
			flow.ensure_permission("Interactive screenshot")
			f.resets[1](true)
			flow.ensure_permission("Saved screenshot")
			flow.ensure_permission("Pixel color read")
			helpers.assert_eq(#f.resets, 1, "a second reset would remove the switch being turned on")
			helpers.assert_eq(f.count("prompt"), 1)
			helpers.assert_eq(f.count("settings"), 1, "later refusals do not reopen the pane by themselves")
			helpers.assert_eq(f.count("notice:shortcuts.screen_recording_required"), 2,
				"every later refusal is still explained")
			f.notifications[#f.notifications].on_click()
			helpers.assert_eq(f.count("settings"), 2, "a click on a later notice opens the pane")
		end)
	end)

	helpers.it("still prompts, without claiming a reset, when tccutil fails", function()
		with_gate({ granted = false }, function(flow, f)
			flow.ensure_permission("Interactive screenshot")
			f.resets[1](false, "tccutil exited with 1: denied")
			helpers.assert_true(f.index("prompt") ~= nil and f.index("settings") ~= nil)
			helpers.assert_eq(f.index("notice:shortcuts.screen_recording_reset"), nil)
			helpers.assert_true(f.index("notice:shortcuts.screen_recording_required") ~= nil)
			helpers.assert_contains(table.concat(f.logs.warn, "\n"), "tccutil exited with 1: denied")
		end)
	end)

	helpers.it("prompts immediately when tccutil cannot start or the bundle id is unknown", function()
		with_gate({ granted = false, reset_starts = false }, function(flow, f)
			flow.ensure_permission("Interactive screenshot")
			helpers.assert_true(f.index("prompt") ~= nil and f.index("settings") ~= nil)
			helpers.assert_true(f.index("notice:shortcuts.screen_recording_required") ~= nil)
		end)
		with_gate({ granted = false, bundle_id = false }, function(flow, f)
			flow.ensure_permission("Interactive screenshot")
			helpers.assert_eq(#f.resets, 0)
			helpers.assert_true(f.index("prompt") ~= nil and f.index("settings") ~= nil)
			helpers.assert_contains(table.concat(f.logs.warn, "\n"), "bundleID")
		end)
	end)

	helpers.it("does not reset on a failed state query, which proves nothing about the entry", function()
		with_gate({ granted = nil, query_fails = true }, function(flow, f)
			helpers.assert_eq(flow.ensure_permission("Interactive screenshot"), false)
			helpers.assert_eq(#f.resets, 0)
			helpers.assert_eq(f.count("prompt"), 1)
			helpers.assert_contains(f.logs.error[1], "tcc down")
		end)
	end)

	helpers.it("admits a granted runtime without any side effect (positive control)", function()
		with_gate({ granted = true }, function(flow, f)
			helpers.assert_eq(flow.ensure_permission("Interactive screenshot"), true)
			helpers.assert_eq(#f.events, 0)
		end)
	end)
end)
