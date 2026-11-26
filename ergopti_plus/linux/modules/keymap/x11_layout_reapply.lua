--- modules/keymap/x11_layout_reapply.lua

--- ==============================================================================
--- MODULE: X11 User-Tree Layout Re-Apply (Linux)
--- DESCRIPTION:
--- Keeps a layout the daemon loaded live on X11 (layout_registry.apply_rows,
--- the installer's apply-x11) in the X server when the desktop puts its own
--- layouts back. GNOME Shell and Plasma under X11 do so when a keyboard appears,
--- and GNOME on an input-sources setting change (W4 of
--- docs/design/layout-option-emulation.md, tests/hardware/run_x11_reapply_live.sh).
---
--- FEATURES & RATIONALE:
--- 1. Off the input path: adapters/x11_keymap_watch_worker.lua reports keymap
---    changes from a process of its own; a burst of them settles for
---    x11_layout_reapply_settle_ms, then one asynchronous xkbcomp read tells
---    whether the server still holds the layout.
--- 2. Its own upload is no event to act on: the daemon's apply loads the
---    layout, so the read that follows finds it held.
--- 3. Bounded: at most MAX_REAPPLIES re-applies within
---    x11_layout_reapply_window_ms. A desktop that keeps replacing the layout
---    beyond that, a failed re-apply, a failed read or a worker that ends stop
---    the re-apply for the session, with one warning, never a retry loop.
--- 4. One owner: arm() after each live X11 apply, shutdown() with the layout
---    manager. Every collaborator is injectable, so the tests replay the flow
---    without an X server, a worker or a Python child.
--- ==============================================================================

local M = {}

local LOG = "modules.keymap.x11_layout_reapply"
local OWNER = "x11-layout-reapply-watch"
local READ_OWNER = "x11-layout-reapply-read"
local MAX_REAPPLIES = 3
local MAX_WORKER_LINE_BYTES = 64
-- A server keymap as xkbcomp prints it is about 120 KB (evdev keycodes, every
-- type and compat entry): far above the default child output bound.
M.MAX_KEYMAP_BYTES = 1048576

--- Whether a keymap's symbols section names `layout_id` among its layouts.
--- The section is named from the layouts it was built from
--- (`pc+bepo+inet(evdev)`, `pc+us+bepo:2+inet(evdev)`).
--- @param keymap string The keymap as `xkbcomp -xkb` prints it.
--- @param layout_id string
--- @return boolean
function M.keymap_holds(keymap, layout_id)
	local name = type(keymap) == "string" and keymap:match('xkb_symbols%s+"([^"]*)"') or nil
	if name == nil then return false end
	for part in name:gmatch("[^+]+") do
		local layout = part:match("^([^(:]+)")
		if layout == layout_id then return true end
	end
	return false
end

--- The production collaborators.
--- @return table
local function production()
	local Timings = require("core.timing.engine.timings")
	local OwnedProcess = require("core.process.adapters.owned_process")
	return {
		settle_ms = Timings.ms("ui", "x11_layout_reapply_settle_ms"),
		window_ms = Timings.ms("ui", "x11_layout_reapply_window_ms"),
		read_timeout_ms = Timings.ms("ui", "x11_layout_reapply_read_timeout_ms"),
		now_ms = require("core.logger.engine.monotonic").now_ms,
		start_process = OwnedProcess.start,
		command = function()
			local uv = require("luv")
			local Paths = require("core.fs.engine.paths")
			local soname = require("_generated.native_runtime").x11
			return assert(uv.exepath(), "native interpreter identity unavailable"), {
				Paths.driver_root() .. "/adapters/x11_keymap_watch_worker.lua",
				soname, string.format("%.0f", uv.os_getpid()),
			}
		end,
		display = function() return os.getenv("DISPLAY") end,
		after = function(ms, fn)
			local uv = require("luv")
			local timer = uv.new_timer()
			timer:start(ms, 0, function()
				timer:close()
				fn()
			end)
			return function()
				if not timer:is_closing() then
					timer:stop()
					timer:close()
				end
			end
		end,
		reapply = function(on_done)
			return require("modules.keymap.number_row_live").apply_stored(function(applied, code, _, live_code)
				on_done(applied, applied and nil or tostring(live_code or code))
			end)
		end,
	}
end

--- Creates one re-apply owner.
--- @param deps table { settle_ms, window_ms, read_timeout_ms, now_ms, start_process,
---   command, display, after, reapply }
--- @return table owner
function M.new(deps)
	assert(type(deps) == "table", "the X11 layout re-apply needs its collaborators")
	for _, name in ipairs({ "settle_ms", "window_ms", "read_timeout_ms" }) do
		assert(type(deps[name]) == "number" and deps[name] > 0, "invalid " .. name)
	end
	for _, name in ipairs({ "now_ms", "start_process", "command", "display", "after", "reapply" }) do
		assert(type(deps[name]) == "function", "missing " .. name)
	end
	local Logger = require("core.logger.engine.shim")
	local owner = {}
	-- idle, starting, watching, stopped (for the session).
	local status = "idle"
	local layout_id = nil
	local operation = nil
	local pending = ""
	local cancel_settle = nil
	local busy = false
	local reapplied_at = {}
	local reapplies = 0

	local function cancel_timer()
		if cancel_settle then cancel_settle() end
		cancel_settle = nil
	end

	local function stop(reason)
		if status == "stopped" then return end
		status, layout_id, pending, busy = "stopped", nil, "", false
		cancel_timer()
		if reason then
			Logger.warn(LOG, "The X11 layout is no longer kept against the desktop (%s).", reason)
		end
		if operation and type(operation.is_settled) == "function" and not operation:is_settled() then
			operation:cancel()
		end
	end

	--- Whether one more re-apply fits within the window.
	local function within_budget(now)
		local kept = {}
		for _, at in ipairs(reapplied_at) do
			if now - at < deps.window_ms then kept[#kept + 1] = at end
		end
		reapplied_at = kept
		return #kept < MAX_REAPPLIES
	end

	local function check()
		cancel_settle = nil
		if status ~= "watching" or busy or layout_id == nil then return end
		local display = deps.display()
		if type(display) ~= "string" or display == "" then stop("no X display"); return end
		local wanted = layout_id
		busy = true
		local started, child = pcall(deps.start_process, "xkbcomp", { "-xkb", display, "-" }, {
			owner = READ_OWNER, timeout_ms = deps.read_timeout_ms, max_output_bytes = M.MAX_KEYMAP_BYTES,
		}, function(result)
			if status ~= "watching" or layout_id ~= wanted then busy = false; return end
			if type(result) ~= "table" or result.ok ~= true or type(result.stdout) ~= "string" then
				stop("the server keymap could not be read: "
					.. tostring(type(result) == "table" and result.error or result))
				return
			end
			if M.keymap_holds(result.stdout, wanted) then busy = false; return end
			local now = deps.now_ms()
			if not within_budget(now) then
				stop(string.format("the desktop replaced it %d times within %d ms", MAX_REAPPLIES + 1, deps.window_ms))
				return
			end
			reapplied_at[#reapplied_at + 1] = now
			reapplies = reapplies + 1
			Logger.start(LOG, "The desktop put its own layouts back: loading '%s' again…", wanted)
			local dispatched = deps.reapply(function(applied, code)
				if status ~= "watching" then return end
				busy = false
				if applied then
					Logger.success(LOG, "Loaded '%s' again.", wanted)
				else
					Logger.error(LOG, "'%s' could not be loaded again: %s.", wanted, tostring(code))
					stop("the re-apply failed")
				end
			end)
			if dispatched ~= true and status == "watching" then
				Logger.error(LOG, "'%s' could not be loaded again: the layout manager refused.", wanted)
				stop("the re-apply was refused")
			end
		end)
		if not started or type(child) ~= "table" then stop("the server keymap read could not start") end
	end

	local function consume(line)
		if line == "ready" then
			if status ~= "starting" then stop("duplicate worker readiness"); return end
			status = "watching"
			Logger.info(LOG, "Watching the X11 keymap for '%s'.", tostring(layout_id))
			return
		end
		if line ~= "keymap" or status ~= "watching" then stop("malformed worker line"); return end
		cancel_timer()
		cancel_settle = deps.after(deps.settle_ms, check)
	end

	local function on_output(chunk, kind)
		if kind ~= "stdout" or status == "stopped" then return end
		pending = pending .. chunk
		while true do
			local newline = pending:find("\n", 1, true)
			if not newline then break end
			local line = pending:sub(1, newline - 1)
			pending = pending:sub(newline + 1)
			consume(line)
			if status == "stopped" then return end
		end
		if #pending > MAX_WORKER_LINE_BYTES then stop("worker line exceeds its bound") end
	end

	--- Keeps `id` loaded from now on; starts the watch on the first call.
	--- @param id string The layout the X server was just given.
	--- @return boolean watching False once the re-apply stopped for the session.
	function owner.arm(id)
		assert(type(id) == "string" and id ~= "", "the X11 layout re-apply needs a layout id")
		if status == "stopped" then return false end
		layout_id = id
		if status ~= "idle" then return true end
		status = "starting"
		local commanded, executable, arguments = pcall(deps.command)
		if not commanded then stop("worker command unavailable: " .. tostring(executable)); return false end
		local spawned, child = pcall(deps.start_process, executable, arguments, {
			owner = OWNER, capture_tail = true, max_output_bytes = 4096, on_output = on_output,
		}, function(result)
			if status == "stopped" then return end
			local tail = type(result) == "table" and type(result.stderr) == "string" and result.stderr or ""
			stop("worker exited" .. (tail ~= "" and ": " .. tail:gsub("%s+$", "") or ""))
		end)
		operation = spawned and child or nil
		if not operation or operation.started ~= true then stop("worker dispatch refused"); return false end
		return status ~= "stopped"
	end

	--- The layout kept, or nil.
	--- @return string|nil
	function owner.layout() return layout_id end

	--- How many re-applies this owner started.
	--- @return integer
	function owner.reapplies() return reapplies end

	--- The owner's state: idle, starting, watching or stopped.
	--- @return string
	function owner.status() return status end

	--- Ends the watch for the session.
	function owner.shutdown() stop(nil) end

	return owner
end

local _shared = nil

--- Keeps `id` loaded with the production collaborators (the layout manager's hook).
--- @param id string
--- @return boolean watching
function M.arm(id)
	if _shared == nil then _shared = M.new(production()) end
	return _shared.arm(id)
end

--- Ends the production watch, when one was started.
function M.shutdown()
	if _shared ~= nil then _shared.shutdown() end
end

--- The production owner's state, "idle" before the first arm (live proofs).
--- @return string
function M._shared_status() return _shared ~= nil and _shared.status() or "idle" end

--- How many re-applies the production owner started (live proofs).
--- @return integer
function M._shared_reapplies() return _shared ~= nil and _shared.reapplies() or 0 end

--- Forgets the production owner (tests only).
function M._reset_for_test() _shared = nil end

return M
