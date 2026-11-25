--- _shared/shortcuts/engine/auto_click_session.lua

--- ==============================================================================
--- MODULE: Auto-Click Session — Shared Lua Implementation
--- DESCRIPTION:
--- One run of the anti-sleep auto-clicker while the mode is on: every tick it
--- asks the policy whether the foreground window may be looked at, scans it
--- through the screen vision service, and clicks at most one target that the
--- policy admits. The macOS and Linux drivers run it with their own ports; the
--- Windows driver runs a twin pinned by the same corpus.
---
--- FEATURES & RATIONALE:
--- 1. Ports only: the foreground query, the locked/paused/secure state, the
---    scan, the click and the clock are given by the driver, so the decision
---    is the same code on both Lua drivers and is tested without a screen.
--- 2. One scan in flight: a tick that finds the previous scan unanswered does
---    nothing, so a slow OCR never piles up requests.
--- 3. A stopped session ignores a late answer (a generation counter), so a
---    scan that returns after Ctrl+M turned the mode off clicks nothing.
--- 4. At most one click per tick, image targets first then text targets, in
---    the preset's order; the clicked target then waits its cooldown.
--- 5. Logged through the driver's logger with the policy's closed reasons; a
---    refusal is logged once when it starts, not at every tick.
---
--- Pinned by _shared/tests/corpus/keep_awake/auto_click_session_vectors.json.
--- ==============================================================================

local M = {}

local Policy = require("shortcuts.engine.auto_click_policy")
local Matcher = require("shortcuts.engine.auto_click_matcher")

--- Creates a session.
--- @param ports table {
---   foreground()            -> { app_id, window } or nil;
---   state()                 -> { locked, paused, secure_field };
---   scan(window, request, callback(result|nil, reason));
---   click(x, y)             -> boolean, clicks once and puts the pointer back;
---   now_ms()                -> monotonic milliseconds;
---   log(level, message, ...) with level "info", "debug" or "warn";
---   on_click(count, target_id) optional }
--- @param plan table As keep_awake_presets.plan returns it.
--- @param settings table { options = matcher options, ocr = { layout, locale|languages }, cooldown_ms }
--- @return table session { tick(), stop(), count() }
function M.new(ports, plan, settings)
	for _, name in ipairs({ "foreground", "state", "scan", "click", "now_ms", "log" }) do
		assert(type(ports[name]) == "function", "an auto-click session needs the port " .. name)
	end
	assert(type(plan) == "table" and type(plan.allowed_apps) == "table", "an auto-click session needs a plan")
	assert(type(settings) == "table" and type(settings.cooldown_ms) == "number", "an auto-click session needs its cooldown")

	local session = {}
	local generation, busy, clicks, last_reason = 1, false, 0, nil
	local last_clicks = {}

	local function note_refusal(reason)
		if reason ~= last_reason then
			last_reason = reason
			ports.log("debug", "Auto-click waits: reason=%s.", reason)
		end
	end

	--- Tries the hits in order and clicks the first the policy admits.
	local function try_click(base, result, hits)
		for _, hit in ipairs(hits) do
			local state = {}
			for key, value in pairs(base) do state[key] = value end
			state.window = { width = result.image.width, height = result.image.height }
			state.match = { x = hit.x, y = hit.y, width = hit.width, height = hit.height }
			state.image_id = hit.id
			state.last_clicks = last_clicks
			state.now_ms = ports.now_ms()
			state.cooldown_ms = settings.cooldown_ms
			local admitted, reason = Policy.may_click(state)
			if admitted then
				local x, y = Matcher.click_point(result.image.frame, result.image.scale, hit)
				if ports.click(x, y) then
					last_clicks[hit.id] = state.now_ms
					clicks = clicks + 1
					last_reason = nil
					ports.log("info", "Auto-click on %s: reason=%s.", hit.id, reason)
					if ports.on_click then ports.on_click(clicks, hit.id) end
					return true
				end
				ports.log("warn", "Auto-click on %s could not be sent.", hit.id)
				return false
			end
			note_refusal(reason)
		end
		return false
	end

	--- Runs one tick; returns at once, the scan answers later.
	function session.tick()
		if busy or not plan.auto_click then return end
		local foreground = ports.foreground()
		local state = ports.state()
		local base = {
			app_id = foreground and foreground.app_id, has_window = foreground ~= nil and foreground.window ~= nil,
			allowed_apps = plan.allowed_apps, locked = state.locked, paused = state.paused,
			secure_field = state.secure_field,
		}
		local allowed, reason = Policy.may_capture(base)
		if not allowed then note_refusal(reason); return end
		if #plan.templates == 0 and #plan.text_targets == 0 then return end
		busy = true
		local mine = generation
		ports.scan(foreground.window, {
			templates = plan.templates, options = settings.options, text_targets = plan.text_targets,
			ocr = settings.ocr,
		}, function(result, scan_reason)
			if mine ~= generation then return end
			busy = false
			if not result then note_refusal(scan_reason or "capture_unavailable"); return end
			-- The state may have changed during the scan: ask again before a click.
			local now_state = ports.state()
			base.locked, base.paused, base.secure_field = now_state.locked, now_state.paused, now_state.secure_field
			local still = ports.foreground()
			if not still or still.window ~= foreground.window then
				note_refusal("no_foreground_window")
				return
			end
			if not try_click(base, result, result.hits or {}) then try_click(base, result, result.text_hits or {}) end
		end)
	end

	--- Stops the session; a scan still running is ignored when it answers.
	function session.stop()
		generation = generation + 1
		busy = false
	end

	--- The clicks of this session.
	function session.count()
		return clicks
	end

	return session
end

return M
