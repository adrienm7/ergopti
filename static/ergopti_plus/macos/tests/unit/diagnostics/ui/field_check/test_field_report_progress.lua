--- tests/unit/diagnostics/ui/field_check/test_field_report_progress.lua

--- ==============================================================================
--- MODULE: Field Report Window Progress (macOS)
--- DESCRIPTION:
--- The run behind the field report progress window
--- (diagnostics/ui/field_check/field_report_progress.lua):
--- 1. a page that loads late gets the init message with the states so far,
---    then the end; each step change and the end reach a loaded page;
--- 2. Stop, Close and the close box stop a run still going on, never a
---    finished one;
--- 3. the folder, the copy and the issue act on the run's own folder and
---    report, the issue with the run's evidence line; an unknown action is
---    refused and a failing one answered.
--- ==============================================================================

local helpers = require("tests.helpers")
local Progress = require("diagnostics.ui.field_check.field_report_progress")

local RUN = {
	request_id = "app-1", dir = "/tmp/fr/app-1",
	steps = { { id = "field_network", check = "network" }, { id = "field_boot_cost", check = "boot_cost" } },
	not_run = { { step = "driver_reload", reason = "needs_collector" } },
}

local SUMMARY = {
	passed = false, interrupted = false, counts = { pass = 1, fail = 1 }, dir = "/tmp/fr/app-1",
	request_id = "app-1", not_run = { { step = "driver_reload", reason = "needs_collector", points = {} } },
	entries = { { step = "field_network", verdict = "pass" }, { step = "field_boot_cost", verdict = "fail" } },
}

--- A progress over recording effects, with its window bound.
local function fixture(overrides)
	local world = { pushed = {}, cancelled = 0, copies = {}, opened = {}, issues = {}, closed = 0 }
	local effects = {
		open_folder = function(dir, done) table.insert(world.opened, dir); done(true) end,
		copy = function(text) table.insert(world.copies, text); return true end,
		issue = function(line, text, done) table.insert(world.issues, { line = line, text = text }); done(true) end,
	}
	for name, fn in pairs(overrides or {}) do effects[name] = fn end
	local progress = Progress.new({
		open_key = "field_report.open_finder",
		title_of = function(step) return step.check == "network" and "Network" or nil end,
		cancel = function() world.cancelled = world.cancelled + 1; return true end,
		effects = effects, logger = helpers.make_logger_stub(), log = "test",
	})
	progress.bind({
		push = function(message) table.insert(world.pushed, message); return true end,
		close = function() world.closed = world.closed + 1 end,
	})
	return progress, world
end

local function last(world) return world.pushed[#world.pushed] end

helpers.describe("field report progress: the page messages", function()
	helpers.it("gives a late page the states so far, then pushes each change", function()
		local progress, world = fixture()
		progress.started(RUN.steps[1])
		progress.attach(RUN)
		helpers.assert_eq(#world.pushed, 0, "nothing reaches a page that has not loaded")
		progress.on_ready()
		helpers.assert_eq(#world.pushed, 1)
		local init = world.pushed[1]
		helpers.assert_eq(init.type, "init")
		helpers.assert_eq(init.open_key, "field_report.open_finder")
		helpers.assert_eq(init.steps[1].title, "Network")
		helpers.assert_eq(init.steps[1].state, "running", "the step started before the page loaded")
		helpers.assert_eq(init.steps[2].title, "field_boot_cost", "a step without a Tests row reads as its id")
		helpers.assert_eq(init.steps[2].state, "pending")
		helpers.assert_eq(init.not_run[1].id, "driver_reload")
		helpers.assert_eq(init.not_run[1].reason, "needs_collector")
		progress.recorded("field_network", "pass")
		helpers.assert_eq(last(world).type, "step")
		helpers.assert_eq(last(world).id, "field_network")
		helpers.assert_eq(last(world).state, "pass")
		progress.finished(SUMMARY, "the report")
		local done = last(world)
		helpers.assert_eq(done.type, "done")
		helpers.assert_eq(done.passed, false)
		helpers.assert_eq(done.interrupted, false)
		helpers.assert_eq(done.counts.fail, 1)
		helpers.assert_eq(done.folder, "/tmp/fr/app-1")
	end)

	helpers.it("brings a page that loads after the end fully up to date", function()
		local progress, world = fixture()
		progress.attach(RUN)
		progress.recorded("field_network", "pass")
		progress.finished(SUMMARY, "the report")
		progress.on_ready()
		helpers.assert_eq(#world.pushed, 2)
		helpers.assert_eq(world.pushed[1].steps[1].state, "pass")
		helpers.assert_eq(world.pushed[2].type, "done")
	end)

	helpers.it("leaves an empty list out of init", function()
		local message = Progress.init_message({ steps = {}, not_run = {} }, {}, function() return nil end, "k")
		helpers.assert_nil(message.steps)
		helpers.assert_nil(message.not_run)
	end)
end)

helpers.describe("field report progress: the actions", function()
	helpers.it("cancels a run still going on, by Stop, Close or the close box", function()
		local progress, world = fixture()
		progress.attach(RUN)
		progress.on_action("cancel")
		helpers.assert_eq(world.cancelled, 1)
		progress.on_action("close")
		helpers.assert_eq(world.cancelled, 2, "closing during the run cancels it")
		helpers.assert_eq(world.closed, 1)
		local boxed, boxed_world = fixture()
		boxed.attach(RUN)
		boxed.on_closed()
		helpers.assert_eq(boxed_world.cancelled, 1, "the close box cancels the run too")
		boxed.on_closed()
		helpers.assert_eq(boxed_world.cancelled, 1, "a second close notice is inert")
	end)

	helpers.it("does not cancel a finished run when the window closes", function()
		local progress, world = fixture()
		progress.attach(RUN)
		progress.finished(SUMMARY, "the report")
		progress.on_action("close")
		helpers.assert_eq(world.cancelled, 0)
		helpers.assert_eq(world.closed, 1)
	end)

	helpers.it("opens the run's folder, copies its report and files its issue", function()
		local progress, world = fixture()
		progress.attach(RUN)
		progress.on_ready()
		progress.finished(SUMMARY, "the report")
		progress.on_action("open_folder")
		helpers.assert_eq(world.opened[1], "/tmp/fr/app-1")
		helpers.assert_eq(last(world).action, "open_folder")
		helpers.assert_eq(last(world).ok, true)
		progress.on_action("copy")
		helpers.assert_eq(world.copies[1], "the report")
		helpers.assert_eq(last(world).ok, true)
		progress.on_action("issue")
		helpers.assert_eq(world.issues[1].text, "the report")
		helpers.assert_eq(world.issues[1].line,
			"check=field_report verdict=fail request=app-1 pass=1 fail=1 not_run=1 field_network=pass field_boot_cost=fail")
		helpers.assert_eq(last(world).action, "issue")
		helpers.assert_eq(last(world).ok, true)
	end)

	helpers.it("refuses an unknown action and answers a failing one", function()
		local progress, world = fixture({ copy = function() return false end,
			issue = function(_, _, done) done(false) end })
		progress.attach(RUN)
		progress.on_ready()
		local before = #world.pushed
		progress.on_action("delete_everything")
		helpers.assert_eq(#world.pushed, before, "an unknown action gets no answer")
		progress.on_action("issue")
		helpers.assert_eq(last(world).ok, false, "an issue before the end fails")
		progress.finished(SUMMARY, "the report")
		progress.on_action("copy")
		helpers.assert_eq(last(world).action, "copy")
		helpers.assert_eq(last(world).ok, false, "a refused clipboard is said")
		progress.on_action("issue")
		helpers.assert_eq(last(world).ok, false, "an issue form that did not open is said")
	end)
end)
