--- tests/unit/core/lifecycle/engine/test_accessibility_wait.lua

--- ==============================================================================
--- MODULE: Accessibility wait (accessibility-wait-resumes)
--- DESCRIPTION:
--- A packaged build signed ad hoc gets a new code identity on every build, so
--- macOS kept the previous switch checked in System Settings while refusing
--- the new binary. Boot then exited asking for a permission the user believed
--- granted. The wait must reset that stale entry before prompting, open the
--- exact pane, and continue the boot by itself once trust arrives. The reset
--- runs once per install: resetting at every reload erased the entry the user
--- had just added (field report 2026-11-05). When another copy signed
--- differently is registered, its switch can be the one the user turned on:
--- the entry is then left alone and a dialog names those copies.
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
		-- A lone copy by default: the probe answers at once with no other copy.
		other_copies = function(on_done)
			event("copies")
			h.copies_done = on_done
			if not h.copies_pending then on_done({}) end
			return true
		end,
	}
	for name, fn in pairs(overrides or {}) do h.permission[name] = fn end
	package.loaded["onboarding.engine.accessibility_wait"] = nil
	h.wait = require("onboarding.engine.accessibility_wait")
	h.opts = {
		permission = h.permission,
		every = function(_, fn) h.ticks = fn; return "timer", true end,
		cancel = function(handle) h.cancelled = handle; return true end,
		watch_reopen = function(on_reopen)
			h.reopen = on_reopen
			return function() event("unwatch") end
		end,
		name_other_copies = function(paths)
			event("name:" .. table.concat(paths, ","))
			return function() event("close_copies") end
		end,
		on_trusted = function() event("trusted") end,
		on_timeout = function(elapsed) event("timeout:" .. tostring(elapsed)) end,
		install_identity = "0.0.0-dev.162:16777230:4242",
		reset_memory = {
			get = function() return h.remembered end,
			set = function(identity) event("remember:" .. identity); h.remembered = identity; return true end,
		},
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
		helpers.assert_eq(h.remembered, "0.0.0-dev.162:16777230:4242", "the reset is remembered by install")
	end)

	helpers.it("a reload of the same install keeps the user's entry and only prompts", function()
		local h = harness()
		h.remembered = "0.0.0-dev.162:16777230:4242"
		helpers.assert_eq(h.wait.start(h.opts), true)
		helpers.assert_eq(h.reset_done, nil, "the entry the user just added must not be reset again")
		helpers.assert_true(h.index("prompt") ~= nil and h.index("settings") ~= nil, table.concat(h.events, ","))
	end)

	helpers.it("a new install resets once more", function()
		local h = harness()
		h.remembered = "0.0.0-dev.161:16777230:4100"
		h.wait.start(h.opts)
		helpers.assert_true(h.reset_done ~= nil, "a reinstall can carry a new code identity")
		h.reset_done(true)
		helpers.assert_eq(h.remembered, "0.0.0-dev.162:16777230:4242")
	end)

	helpers.it("a failed reset is not remembered", function()
		local h = harness()
		h.wait.start(h.opts)
		h.reset_done(false, "tccutil exited with 1")
		helpers.assert_eq(h.remembered, nil)
	end)

	helpers.it("still prompts when the reset fails or cannot start", function()
		local h = harness()
		h.wait.start(h.opts)
		h.reset_done(false, "tccutil exited with 1")
		helpers.assert_true(h.index("prompt") ~= nil and h.index("settings") ~= nil)
		local h2 = harness({ reset_grant = function() return false end })
		h2.wait.start(h2.opts)
		helpers.assert_true(h2.index("prompt") ~= nil and h2.index("settings") ~= nil)
		h2.trusted = true
		h2.ticks()
		helpers.assert_true(h2.index("trusted") ~= nil, "a refused reset must not block a later grant")
	end)

	helpers.it("resumes the boot once trusted, exactly once", function()
		local h = harness()
		h.wait.start(h.opts)
		h.reset_done(true)
		h.ticks()
		helpers.assert_eq(h.index("trusted"), nil, "no resume while untrusted")
		h.trusted = true
		h.ticks()
		h.ticks()
		local count = 0
		for _, e in ipairs(h.events) do if e == "trusted" then count = count + 1 end end
		helpers.assert_eq(count, 1)
		helpers.assert_eq(h.cancelled, "timer")
		helpers.assert_eq(h.wait.is_waiting(), false)
	end)

	helpers.it("waits for the grant reset before resuming a trusted boot (accessibility-reset-race)", function()
		local h = harness()
		h.wait.start(h.opts)
		h.trusted = true
		h.ticks()
		helpers.assert_nil(h.index("trusted"), "an in-flight reset can still revoke this grant")
		h.reset_done(true)
		h.trusted = false
		h.ticks()
		helpers.assert_nil(h.index("trusted"), "the reset revoked the previously observed grant")
		h.trusted = true
		h.ticks()
		helpers.assert_true(h.index("trusted") ~= nil)
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
		h.opts.install_identity = ""
		local _, identity_refusal = pcall(h.wait.start, h.opts)
		helpers.assert_contains(tostring(identity_refusal), "install_identity must be a non-empty string")
	end)

	helpers.it("asks macOS for its prompt again each time ErgoptiPlus is reopened while waiting", function()
		local h = harness()
		h.wait.start(h.opts)
		h.reset_done(true)
		local function prompts()
			local count = 0
			for _, e in ipairs(h.events) do if e == "prompt" then count = count + 1 end end
			return count
		end
		helpers.assert_eq(prompts(), 1)
		h.reopen()
		h.reopen()
		helpers.assert_eq(prompts(), 3, "a dismissed prompt is not a dead end")
		h.trusted = true
		h.ticks()
		helpers.assert_true(h.index("unwatch") ~= nil and h.index("unwatch") < h.index("trusted"),
			"the boot resumes without the reopen watch")
		h.reopen()
		helpers.assert_eq(prompts(), 3, "a reopen after the grant asks nothing")
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

	helpers.it("names the other copies instead of resetting the switch they can hold", function()
		local h = harness()
		h.copies_pending = true
		helpers.assert_eq(h.wait.start(h.opts), true)
		helpers.assert_nil(h.index("prompt"), "no prompt before the copies are known")
		h.trusted = true
		h.ticks()
		helpers.assert_nil(h.index("trusted"), "the probe can still lead to a reset that revokes trust")
		h.trusted = false
		h.copies_done({ "/Applications/ErgoptiPlus.app", "/Users/me/build/macos/ErgoptiPlus.app" })
		helpers.assert_eq(h.reset_done, nil, "resetting erased the switch the other copy holds, at every reload")
		helpers.assert_eq(h.remembered, nil)
		helpers.assert_true(h.index("prompt") ~= nil and h.index("settings") ~= nil, table.concat(h.events, ","))
		helpers.assert_true(h.index("name:/Applications/ErgoptiPlus.app,/Users/me/build/macos/ErgoptiPlus.app") ~= nil,
			table.concat(h.events, ","))
		h.reopen()
		local named = 0
		for _, e in ipairs(h.events) do if e:sub(1, 5) == "name:" then named = named + 1 end end
		helpers.assert_eq(named, 2, "reopening ErgoptiPlus shows the copies again")
		h.trusted = true
		h.ticks()
		helpers.assert_true(h.index("close_copies") ~= nil and h.index("close_copies") < h.index("trusted"),
			"the dialog closes before the boot resumes")
	end)

	helpers.it("resets as for a lone copy when the copies cannot be listed", function()
		for _, refusal in ipairs({ "answer", "start" }) do
			local h = harness({
				other_copies = function(on_done)
					if refusal == "start" then return false, "no bundle path" end
					on_done(nil, "the copy probe exited with 1")
					return true
				end,
			})
			h.wait.start(h.opts)
			helpers.assert_true(h.reset_done ~= nil, refusal .. ": a lone copy still needs its stale entry cleared")
			h.reset_done(true)
			helpers.assert_true(h.index("prompt") ~= nil)
			helpers.assert_nil(h.index("name:"), "nothing to name")
		end
	end)

	helpers.it("a dialog that raises costs only the paths", function()
		local h = harness()
		h.copies_pending = true
		h.opts.name_other_copies = function() error("WebKit unavailable") end
		h.wait.start(h.opts)
		h.copies_done({ "/Applications/ErgoptiPlus.app" })
		helpers.assert_true(h.index("prompt") ~= nil and h.index("settings") ~= nil)
		h.trusted = true
		h.ticks()
		helpers.assert_true(h.index("trusted") ~= nil)
	end)

	helpers.it("ignores a probe that answers after the wait ended", function()
		local h = harness()
		h.copies_pending = true
		h.opts.deadline_seconds = 1
		h.wait.start(h.opts)
		h.ticks()
		helpers.assert_true(h.index("timeout:1") ~= nil, table.concat(h.events, ","))
		h.copies_done({ "/Applications/ErgoptiPlus.app" })
		helpers.assert_nil(h.index("prompt"), "a finished wait prompts nothing")
		helpers.assert_eq(h.reset_done, nil)
	end)

	helpers.it("reports a timer that did not arm without side effects", function()
		local h = harness()
		h.opts.every = function() return nil, false end
		local started = h.wait.start(h.opts)
		helpers.assert_eq(started, false)
		helpers.assert_eq(#h.events, 0)
	end)
end)
