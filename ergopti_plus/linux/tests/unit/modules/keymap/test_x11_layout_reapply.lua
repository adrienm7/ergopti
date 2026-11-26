--- tests/unit/modules/keymap/test_x11_layout_reapply.lua

--- ==============================================================================
--- MODULE: X11 User-Tree Layout Re-Apply (Linux) Tests
--- DESCRIPTION:
--- A layout loaded live on X11 is loaded again when the desktop puts its own
--- layouts back (W4: GNOME Shell and Plasma under X11 on a new keyboard), once
--- per settled burst of keymap events, never when the server still holds it,
--- and at most three times a minute; a failed read, re-apply or worker stops
--- it for the session. The worker, the keymap read, the timer and the layout
--- manager are fakes.
--- ==============================================================================

local helpers = require("tests.helpers")
local Reapply = require("modules.keymap.x11_layout_reapply")

local BEPO = 'xkb_symbols "pc+bepo+inet(evdev)" { };'
local DESKTOP = 'xkb_symbols "pc+us+fr:2+inet(evdev)" { };'

--- Fakes: a worker the test feeds, a keymap the test sets, a manual timer.
local function fakes(options)
	options = options or {}
	local state = { held = BEPO, reapplies = 0, reads = 0, timers = {}, now = 0, spawned = {} }
	local worker
	local deps = {
		settle_ms = 750, window_ms = 60000, read_timeout_ms = 5000,
		now_ms = function() return state.now end,
		command = function() return "luajit", { "fake-keymap-watch-worker", "libX11.so.6", "1" } end,
		display = function() return ":5" end,
		start_process = function(program, args, opts, on_done)
			state.spawned[#state.spawned + 1] = { program = program, args = args, owner = opts.owner }
			if program == "xkbcomp" then
				state.reads = state.reads + 1
				helpers.assert_eq(args, { "-xkb", ":5", "-" })
				helpers.assert_eq(opts.timeout_ms, 5000, "the read is bounded")
				-- A real server keymap is about 120 KB; the default child bound is 64 KiB.
				helpers.assert_true(opts.max_output_bytes >= 4 * 120000, "the read admits a whole keymap")
				if options.read_fails then on_done({ ok = false, error = "exit 1" })
				else on_done({ ok = true, stdout = state.held }) end
				return { started = true }
			end
			worker = { on_output = opts.on_output, on_done = on_done, cancelled = false }
			return {
				started = true,
				is_settled = function() return worker.cancelled end,
				cancel = function() worker.cancelled = true; return true end,
			}
		end,
		after = function(ms, fn)
			local timer = { ms = ms, fn = fn, cancelled = false }
			state.timers[#state.timers + 1] = timer
			return function() timer.cancelled = true end
		end,
		reapply = function(on_done)
			state.reapplies = state.reapplies + 1
			if options.reapply_fails then on_done(false, "not_loaded")
			else
				state.held = BEPO
				on_done(true, nil)
			end
			return true
		end,
	}
	local function feed(text) worker.on_output(text, "stdout") end
	local function fire()
		for _, timer in ipairs(state.timers) do
			if not timer.cancelled and not timer.fired then timer.fired = true; timer.fn() end
		end
	end
	local function worker_state() return worker end
	return deps, state, feed, fire, worker_state
end

--- An owner already watching bepo.
local function watching(options)
	local deps, state, feed, fire, worker = fakes(options)
	local owner = Reapply.new(deps)
	helpers.assert_true(owner.arm("bepo"))
	feed("ready\n")
	helpers.assert_eq(owner.status(), "watching")
	return owner, state, feed, fire, worker
end

helpers.describe("X11 user-tree layout re-apply (Linux)", function()
	helpers.it("names the layouts of a keymap's symbols section (x11-layout-reapply)", function()
		helpers.assert_true(Reapply.keymap_holds(BEPO, "bepo"))
		helpers.assert_true(Reapply.keymap_holds('xkb_symbols "pc+us+bepo:2+inet(evdev)" {', "bepo"))
		helpers.assert_eq(Reapply.keymap_holds(DESKTOP, "bepo"), false)
		helpers.assert_eq(Reapply.keymap_holds('xkb_symbols "pc+bepo_live+inet(evdev)" {', "bepo"), false,
			"another id that starts with the same name")
		helpers.assert_eq(Reapply.keymap_holds("", "bepo"), false)
	end)

	helpers.it("loads the layout again once the desktop's burst settles (x11-layout-reapply)", function()
		local owner, state, feed, fire = watching()
		state.held = DESKTOP
		feed("keymap\nkeymap\nkey")
		feed("map\n")
		helpers.assert_eq(state.reads, 0, "nothing is read before the burst settles")
		helpers.assert_eq(#state.timers, 3, "each event restarts the settle timer")
		helpers.assert_eq(state.timers[3].ms, 750)
		fire()
		helpers.assert_eq(state.reads, 1, "one read per settled burst")
		helpers.assert_eq(state.reapplies, 1)
		-- The re-apply's own upload is one more burst: the server then holds the layout.
		feed("keymap\n")
		fire()
		helpers.assert_eq(state.reads, 2)
		helpers.assert_eq(state.reapplies, 1, "the daemon's own upload is not re-applied")
		helpers.assert_eq(owner.reapplies(), 1)
		helpers.assert_eq(owner.status(), "watching")
	end)

	helpers.it("leaves a keymap that still holds the layout alone (x11-layout-reapply)", function()
		local _, state, feed, fire = watching()
		feed("keymap\n")
		fire()
		helpers.assert_eq(state.reapplies, 0, "a layout switch keeps the loaded keymap")
	end)

	helpers.it("stops after three re-applies within the window (x11-layout-reapply)", function()
		local owner, state, feed, fire = watching()
		for round = 1, 4 do
			state.held = DESKTOP
			state.now = round * 1000
			feed("keymap\n")
			fire()
		end
		helpers.assert_eq(state.reapplies, 3)
		helpers.assert_eq(owner.status(), "stopped", "a desktop that keeps replacing it ends the re-apply")
		-- A window later the budget would be free again; a stopped owner stays stopped.
		helpers.assert_eq(owner.arm("bepo"), false)
	end)

	helpers.it("frees the budget once the window has passed (x11-layout-reapply)", function()
		local owner, state, feed, fire = watching()
		for round = 1, 5 do
			state.held = DESKTOP
			state.now = round * 30000
			feed("keymap\n")
			fire()
		end
		helpers.assert_eq(state.reapplies, 5)
		helpers.assert_eq(owner.status(), "watching")
	end)

	helpers.it("stops on a failed re-apply, a failed read or an ended worker (x11-layout-reapply)", function()
		local owner, state, feed, fire = watching({ reapply_fails = true })
		state.held = DESKTOP
		feed("keymap\n")
		fire()
		helpers.assert_eq(state.reapplies, 1)
		helpers.assert_eq(owner.status(), "stopped")
		owner, state, feed, fire = watching({ read_fails = true })
		feed("keymap\n")
		fire()
		helpers.assert_eq(state.reapplies, 0)
		helpers.assert_eq(owner.status(), "stopped")
		local worker
		owner, state, feed, fire, worker = watching()
		worker().on_done({ ok = false, stderr = "X display unavailable\n" })
		helpers.assert_eq(owner.status(), "stopped")
	end)

	helpers.it("refuses a malformed worker line and a worker that never got ready (x11-layout-reapply)", function()
		local deps, state, feed, _, worker = fakes()
		local owner = Reapply.new(deps)
		owner.arm("bepo")
		feed("keymap\n")
		helpers.assert_eq(owner.status(), "stopped", "an event before readiness")
		helpers.assert_true(worker().cancelled, "the worker is ended")
		helpers.assert_eq(state.reads, 0)
		local noisy, _, feed_noisy = watching()
		feed_noisy("noise\n")
		helpers.assert_eq(noisy.status(), "stopped", "a line that is neither ready nor keymap")
		owner = watching()
		owner.shutdown()
		helpers.assert_eq(owner.status(), "stopped")
	end)

	helpers.it("keeps one worker and follows the latest layout (x11-layout-reapply)", function()
		local deps, state, feed, fire = fakes()
		local owner = Reapply.new(deps)
		owner.arm("bepo")
		feed("ready\n")
		owner.arm("ergol")
		helpers.assert_eq(#state.spawned, 1, "a second apply reuses the watch")
		helpers.assert_eq(owner.layout(), "ergol")
		feed("keymap\n")
		fire()
		helpers.assert_eq(state.reapplies, 1, "bepo held, ergol wanted")
	end)
end)

return true
