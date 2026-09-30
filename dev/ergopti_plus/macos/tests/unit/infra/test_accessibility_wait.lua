--- tests/unit/infra/test_accessibility_wait.lua

--- ==============================================================================
--- MODULE: Accessibility wait (accessibility-wait-resumes)
--- DESCRIPTION:
--- A packaged build signed ad hoc gets a new code identity on every build, so
--- macOS kept the previous switch checked in System Settings while refusing
--- the new binary. Boot then exited asking for a permission the user believed
--- granted. The wait must reset that stale entry before prompting, open the
--- exact pane, and continue the boot by itself once trust arrives.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds a wait harness with a manual timer and a scripted trust state.
--- @param overrides table|nil Permission functions to replace.
--- @return table harness
local function harness(overrides)
	local h = { events = {}, trusted = false, ticks = nil, cancelled = false, reset_done = nil }
	local function event(name) h.events[#h.events + 1] = name end
	h.permission = {
		is_trusted = function() return h.trusted end,
		request_prompt = function() event("prompt"); return true end,
		bundle_id = function() return "com.ergoptiplus.app.hammerspoon" end,
		reset_grant = function(bundle_id, on_done)
			event("reset:" .. bundle_id)
			h.reset_done = on_done
			return true
		end,
		open_settings = function() event("settings"); return true end,
	}
	for name, fn in pairs(overrides or {}) do h.permission[name] = fn end
	package.loaded["infra.accessibility_wait"] = nil
	h.wait = require("infra.accessibility_wait")
	h.opts = {
		permission = h.permission,
		every = function(_, fn) h.ticks = fn; return "timer", true end,
		cancel = function(handle) h.cancelled = handle; return true end,
		show_guidance = function() event("show") end,
		close_guidance = function() event("close") end,
		watch_reopen = function(on_reopen)
			h.reopen = on_reopen
			return function() event("unwatch") end
		end,
		on_trusted = function() event("trusted") end,
		on_timeout = function(elapsed) event("timeout:" .. tostring(elapsed)) end,
		poll_seconds = 1,
		deadline_seconds = 3,
	}
	--- @param name string Event to look up.
	--- @return integer|nil index
	function h.index(name)
		for i, e in ipairs(h.events) do if e == name then return i end end
		return nil
	end
	return h
end

helpers.describe("accessibility wait (accessibility-wait-resumes)", function()
	helpers.it("resets the stale entry before prompting and opening the pane", function()
		local h = harness()
		helpers.assert_eq(h.wait.start(h.opts), true)
		helpers.assert_eq(h.index("prompt"), nil, "no prompt before the stale entry is cleared")
		h.reset_done(true)
		local reset_at = h.index("reset:com.ergoptiplus.app.hammerspoon")
		helpers.assert_true(reset_at ~= nil and reset_at < h.index("prompt")
			and h.index("prompt") < h.index("settings"), table.concat(h.events, ","))
		helpers.assert_true(h.index("show") ~= nil, "the banner names the entry to turn on")
	end)

	helpers.it("still prompts when the reset fails or cannot start", function()
		local h = harness()
		h.wait.start(h.opts)
		h.reset_done(false, "tccutil exited with 1")
		helpers.assert_true(h.index("prompt") ~= nil and h.index("settings") ~= nil)
		local h2 = harness({ reset_grant = function() return false end })
		h2.wait.start(h2.opts)
		helpers.assert_true(h2.index("prompt") ~= nil and h2.index("settings") ~= nil)
	end)

	helpers.it("resumes the boot once trusted, exactly once, and closes the banner", function()
		local h = harness()
		h.wait.start(h.opts)
		h.ticks()
		helpers.assert_eq(h.index("trusted"), nil, "no resume while untrusted")
		h.trusted = true
		h.ticks()
		h.ticks()
		local count = 0
		for _, e in ipairs(h.events) do if e == "trusted" then count = count + 1 end end
		helpers.assert_eq(count, 1)
		helpers.assert_eq(h.cancelled, "timer")
		helpers.assert_true(h.index("close") < h.index("trusted"), "banner closes before the boot resumes")
		helpers.assert_eq(h.wait.is_waiting(), false)
	end)

	helpers.it("gives up with the elapsed time at the deadline", function()
		local h = harness()
		h.wait.start(h.opts)
		h.ticks(); h.ticks(); h.ticks()
		helpers.assert_true(h.index("timeout:3") ~= nil, table.concat(h.events, ","))
		helpers.assert_eq(h.index("trusted"), nil)
	end)

	helpers.it("refuses a second concurrent wait and invalid options", function()
		local h = harness()
		helpers.assert_eq(h.wait.start(h.opts), true)
		local started, detail = h.wait.start(h.opts)
		helpers.assert_eq(started, false)
		helpers.assert_contains(detail, "already running")
		local _, refusal = pcall(h.wait.start, { permission = h.permission })
		helpers.assert_contains(tostring(refusal), "every must be a function")
	end)

	helpers.it("shows the steps again each time ErgoptiPlus is reopened while waiting", function()
		local h = harness()
		h.wait.start(h.opts)
		local function shown()
			local count = 0
			for _, e in ipairs(h.events) do if e == "show" then count = count + 1 end end
			return count
		end
		helpers.assert_eq(shown(), 1)
		h.reopen()
		h.reopen()
		helpers.assert_eq(shown(), 3, "a dialog closed with Later is not a dead end")
		h.trusted = true
		h.ticks()
		helpers.assert_true(h.index("unwatch") ~= nil and h.index("unwatch") < h.index("trusted"),
			"the boot resumes without the reopen watch")
		h.reopen()
		helpers.assert_eq(shown(), 3, "a reopen after the grant shows nothing")
	end)

	helpers.it("keeps waiting when reopening cannot be watched", function()
		local h = harness()
		h.opts.watch_reopen = function() return nil, "no launcher is being watched" end
		helpers.assert_eq(h.wait.start(h.opts), true)
		h.reset_done(true)
		helpers.assert_true(h.index("prompt") ~= nil and h.index("settings") ~= nil)
		h.trusted = true
		h.ticks()
		helpers.assert_true(h.index("trusted") ~= nil)
	end)

	helpers.it("reports a timer that did not arm without side effects", function()
		local h = harness()
		h.opts.every = function() return nil, false end
		local started = h.wait.start(h.opts)
		helpers.assert_eq(started, false)
		helpers.assert_eq(#h.events, 0)
	end)
end)
