--- tests/unit/ui/menu/test_quit_layout.lua

--- ==============================================================================
--- MODULE: Quitting Applies The Pause Layout
--- DESCRIPTION:
--- Approved behaviour: quitting ErgoptiPlus leaves the keyboard on the input
--- source a pause selects (« Disposition quand script en pause »); there is no
--- separate « layout when closed » setting. Before, the pause switch ran only on
--- pause and resume, so quitting left the Ergopti layout active.
---
--- Three layers are checked:
---   1. menu_keyboard_layout.apply_quit_layout picks the SAME target as a pause.
---   2. The quit_layout teardown step applies it on exit only, awaits an
---      asynchronous switch through the readiness callback, and never blocks the
---      quit on a failure.
---   3. The root teardown runs that step before any owner stops.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==========================================
-- ==========================================
-- ======= 1/ The target is the pause =======
-- ==========================================
-- ==========================================

helpers.describe("quit layout: the target is the pause layout", function()
	local function with_layout(body)
		local layout = helpers.load_with_stubs("ui.menu.menu_keyboard_layout")
		local saved = layout.set_layout_by_kl_name_async
		local calls = {}
		layout.set_layout_by_kl_name_async = function(name, on_done)
			calls[#calls + 1] = { name = name, on_done = on_done }
			return true
		end
		local ok, err = xpcall(function() body(layout, calls) end, debug.traceback)
		layout.set_layout_by_kl_name_async = saved
		if not ok then error(err, 0) end
	end

	helpers.it("switches to the pause layout when pause switching is on", function()
		with_layout(function(layout, calls)
			local done = function() end
			local state = { layout_pause_switch_enabled = true, layout_on_pause = "French", layout_on_resume = "Ergopti" }
			helpers.assert_eq(layout.apply_quit_layout(state, done), "pending")
			helpers.assert_eq(#calls, 1)
			helpers.assert_eq(calls[1].name, "French", "quitting uses the pause target, not the resume one")
			helpers.assert_true(calls[1].on_done == done, "the completion is handed to the switch")
			local scheduled = layout.schedule_pause_layout_switch(true, state, function() return true end)
			helpers.assert_eq(scheduled, "French", "pause and quit agree on the target")
		end)
	end)

	helpers.it("does nothing when pause switching is off or set to « no change »", function()
		with_layout(function(layout, calls)
			helpers.assert_eq(layout.apply_quit_layout({ layout_pause_switch_enabled = false, layout_on_pause = "French" }), "none")
			helpers.assert_eq(layout.apply_quit_layout({ layout_pause_switch_enabled = true, layout_on_pause = false }), "none")
			helpers.assert_eq(layout.apply_quit_layout({ layout_pause_switch_enabled = true, layout_on_pause = "" }), "none")
			helpers.assert_eq(#calls, 0, "no switch may be started")
		end)
	end)
end)





-- ====================================
-- ====================================
-- ======= 2/ The teardown step =======
-- ====================================
-- ====================================

--- A quit step over a fake menu module.
--- @param apply function|nil The fake apply_quit_layout, nil for no menu.
--- @return table step, table errors
local function make_step(apply)
	local QuitLayout = helpers.load_with_stubs("ui.menu.quit_layout")
	local errors = {}
	local logger = helpers.make_logger_stub()
	logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
	local step = QuitLayout.create({
		resolve_menu = function()
			if apply == nil then return nil end
			return { apply_quit_layout = apply }
		end,
		logger = logger,
	})
	return step, errors
end

helpers.describe("quit layout: the teardown step", function()
	helpers.it("does nothing on a reload", function()
		local applied = 0
		local step = make_step(function() applied = applied + 1; return "pending" end)
		helpers.assert_nil(step.run("reload", function() end))
		helpers.assert_eq(applied, 0, "a reload keeps the session's layout")
	end)

	helpers.it("goes on at once when nothing is configured, and only asks once", function()
		local applied = 0
		local step = make_step(function() applied = applied + 1; return "none" end)
		helpers.assert_nil(step.run("exit", function() end))
		helpers.assert_nil(step.run("exit", function() end))
		helpers.assert_eq(applied, 1)
	end)

	helpers.it("goes on without a callback when the switch settled synchronously", function()
		local readiness = 0
		local step = make_step(function(on_done) on_done(true); return "pending" end)
		helpers.assert_nil(step.run("exit", function() readiness = readiness + 1 end))
		helpers.assert_eq(readiness, 0, "nothing was retained, so nothing is signalled")
	end)

	helpers.it("awaits an asynchronous switch and resumes the teardown through its callback", function()
		local owed = nil
		local applied = 0
		local readiness = {}
		local step = make_step(function(on_done) applied = applied + 1; owed = on_done; return "pending" end)
		local ready = function(settled, detail) readiness[#readiness + 1] = { settled, detail } end
		local accepted, state = step.run("exit", ready)
		helpers.assert_eq(accepted, true)
		helpers.assert_eq(state, "pending", "the teardown must wait for the switch")
		local again_accepted, again_state = step.run("exit", ready)
		helpers.assert_eq(again_state, "pending")
		helpers.assert_eq(again_accepted, true)
		helpers.assert_eq(applied, 1, "a pending switch is not started twice")
		owed(true)
		helpers.assert_eq(#readiness, 1, "the settled switch resumes the teardown once")
		helpers.assert_eq(readiness[1][1], true)
		helpers.assert_nil(step.run("exit", ready), "the retried teardown goes on")
	end)

	helpers.it("reports a failed switch and still lets the quit finish", function()
		local owed = nil
		local readiness = 0
		local step, errors = make_step(function(on_done) owed = on_done; return "pending" end)
		step.run("exit", function(settled) if settled == true then readiness = readiness + 1 end end)
		owed(false, nil, "timeout")
		helpers.assert_eq(readiness, 1, "a failed switch must not hold the quit")
		helpers.assert_eq(#errors, 1, "the failure must be an ERROR")
	end)

	helpers.it("reports a switch that raises and goes on", function()
		local step, errors = make_step(function() error("boom") end)
		helpers.assert_nil(step.run("exit", function() end))
		helpers.assert_eq(#errors, 1)
	end)

	helpers.it("starts the switch without waiting when no callback can be retained", function()
		local applied = {}
		local step = make_step(function(on_done) applied[#applied + 1] = on_done == nil; return "pending" end)
		helpers.assert_nil(step.run("exit", nil))
		helpers.assert_eq(applied, { true })
	end)

	helpers.it("goes on when the menubar never started", function()
		local step = make_step(nil)
		helpers.assert_nil(step.run("exit", function() end))
	end)
end)





-- ============================================
-- ============================================
-- ======= 3/ The root teardown runs it =======
-- ============================================
-- ============================================

helpers.describe("quit layout: the root teardown runs the step first", function()
	helpers.it("teardown_all_resources awaits the quit layout before the MLX phase and every owner", function()
		local src, err = helpers.read_driver_unit("local function teardown_all_resources(")
		helpers.assert_true(type(src) == "string", "the root teardown must be found: " .. tostring(err))
		local body_start = src:find("local function teardown_all_resources(", 1, true)
		helpers.assert_true(body_start ~= nil, "init.lua must define teardown_all_resources")
		local body = src:sub(body_start, body_start + 6000)
		local run_at = body:find("quit_layout_step.run(termination_kind, on_teardown_ready)", 1, true)
		local pending_at = body:find('if layout_state == "pending" then', 1, true)
		local mlx_at = body:find("_mlx_teardown_settled", 1, true)
		local steps_at = body:find("local steps = {", 1, true)
		helpers.assert_true(run_at ~= nil, "the teardown must run the quit layout step")
		helpers.assert_true(pending_at ~= nil and pending_at > run_at, "and return while the switch is pending")
		helpers.assert_true(mlx_at ~= nil and run_at < mlx_at and run_at < steps_at,
			"the layout is applied before the MLX phase and before any owner stops")
	end)
end)
