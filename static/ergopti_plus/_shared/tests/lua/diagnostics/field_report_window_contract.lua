--- _shared/tests/lua/diagnostics/field_report_window_contract.lua

--- Exercises the controller of the field report progress window
--- (_shared/diagnostics/engine/field_check/field_report_window.lua) under a
--- driver's suite: events before the page loads are replayed at ready in
--- order; each step change and the end reach the page; cancel and close stop a
--- run still going on, a close box too; the folder, the copy and the issue use
--- the run's own folder and report, the issue through the bug-report link
--- builder with the evidence line as its diagnostics and the report copied
--- first; an unknown action is refused and a failing one answered.
return function(helpers)
	local Window = require("diagnostics.engine.field_check.field_report_window")
	local Json = require("core.text.engine.json")

	local function read_json(path)
		local handle = assert(io.open(path, "rb"))
		local text = handle:read("*a")
		handle:close()
		return Json.decode(text)
	end

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

	--- A controller over recording effects, with its window bound.
	local function fixture(overrides)
		local world = { pushed = {}, cancelled = 0, copies = {}, opened = {}, urls = {}, closed = 0, logs = {} }
		local effects = {
			open_folder = function(dir, done) table.insert(world.opened, dir); done(true) end,
			copy = function(text) table.insert(world.copies, text); return true end,
			issue_form = function()
				return { templates = read_json(helpers.shared("diagnostics/data/issue_templates.json")),
					repository = { owner = "owner", repo = "repo" },
					fields = { version = "1.2.3", driver = "macOS", os = "macOS 15" },
					notes = { diagnostics = "The complete report is on your clipboard." } }
			end,
			open_url = function(url, done) table.insert(world.urls, url); done(true) end,
		}
		for name, fn in pairs(overrides or {}) do effects[name] = fn end
		local logger = {}
		for _, level in ipairs({ "info", "warn", "error", "success" }) do
			logger[level] = function(_, template, ...) table.insert(world.logs, level .. ":" .. string.format(template, ...)) end
		end
		local controller = Window.new({
			open_key = "field_report.open_finder",
			title_of = function(step) return step.check == "network" and "Network" or nil end,
			cancel = function() world.cancelled = world.cancelled + 1; return true end,
			effects = effects, logger = logger, log = "test",
		})
		controller.bind({
			push = function(message) table.insert(world.pushed, message); return true end,
			close = function() world.closed = world.closed + 1 end,
		})
		return controller, world
	end

	local function last(world) return world.pushed[#world.pushed] end

	helpers.describe("field report window: the page messages", function()
		helpers.it("replays the events before ready in order, then pushes each change", function()
			local controller, world = fixture()
			controller.started(RUN.steps[1])
			controller.attach(RUN)
			helpers.assert_eq(#world.pushed, 0, "nothing reaches a page that has not loaded")
			controller.on_ready()
			helpers.assert_eq(#world.pushed, 2)
			local init = world.pushed[1]
			helpers.assert_eq(init.type, "init")
			helpers.assert_eq(init.open_key, "field_report.open_finder")
			helpers.assert_eq(init.steps[1].id, "field_network")
			helpers.assert_eq(init.steps[1].title, "Network")
			helpers.assert_eq(init.steps[2].title, "field_boot_cost", "a step without a Tests row reads as its id")
			helpers.assert_eq(init.not_run[1].id, "driver_reload")
			helpers.assert_eq(init.not_run[1].reason, "needs_collector")
			helpers.assert_eq(world.pushed[2].type, "step")
			helpers.assert_eq(world.pushed[2].state, "running")
			controller.recorded("field_network", "pass")
			helpers.assert_eq(last(world).id, "field_network")
			helpers.assert_eq(last(world).state, "pass")
			controller.finished(SUMMARY, "the report")
			local done = last(world)
			helpers.assert_eq(done.type, "done")
			helpers.assert_eq(done.passed, false)
			helpers.assert_eq(done.interrupted, false)
			helpers.assert_eq(done.counts.fail, 1)
			helpers.assert_eq(done.folder, "/tmp/fr/app-1")
		end)

		helpers.it("brings a page that loads after the end fully up to date", function()
			local controller, world = fixture()
			controller.attach(RUN)
			controller.started(RUN.steps[1])
			controller.recorded("field_network", "pass")
			controller.finished(SUMMARY, "the report")
			controller.on_ready()
			local types = {}
			for _, message in ipairs(world.pushed) do types[#types + 1] = message.type .. ":" .. tostring(message.state) end
			helpers.assert_eq(table.concat(types, " "), "init:nil step:pass done:nil")
		end)

		helpers.it("leaves an empty list out of init", function()
			local message = Window.init_message({ steps = {}, not_run = {} }, function() return nil end, "k")
			helpers.assert_nil(message.steps)
			helpers.assert_nil(message.not_run)
		end)
	end)

	helpers.describe("field report window: the actions", function()
		helpers.it("cancels a run still going on, by its button, its close button or its close box", function()
			local controller, world = fixture()
			controller.attach(RUN)
			controller.on_action("cancel")
			helpers.assert_eq(world.cancelled, 1)
			controller.on_action("close")
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
			local controller, world = fixture()
			controller.attach(RUN)
			controller.finished(SUMMARY, "the report")
			controller.on_action("close")
			helpers.assert_eq(world.cancelled, 0)
			helpers.assert_eq(world.closed, 1)
		end)

		helpers.it("opens the run's folder and copies its report", function()
			local controller, world = fixture()
			controller.attach(RUN)
			controller.on_ready()
			controller.finished(SUMMARY, "the report")
			controller.on_action("open_folder")
			helpers.assert_eq(world.opened[1], "/tmp/fr/app-1")
			helpers.assert_eq(last(world).action, "open_folder")
			helpers.assert_eq(last(world).ok, true)
			controller.on_action("copy")
			helpers.assert_eq(world.copies[1], "the report")
			helpers.assert_eq(last(world).action, "copy")
			helpers.assert_eq(last(world).ok, true)
		end)

		helpers.it("opens the bug form with the evidence line, the report on the clipboard first", function()
			local order, url = {}, nil
			local controller, world = fixture({
				copy = function(text) table.insert(order, "copy:" .. text); return true end,
				open_url = function(target, done) table.insert(order, "url"); url = target; done(true) end,
			})
			controller.attach(RUN)
			controller.on_ready()
			controller.finished(SUMMARY, "the report")
			controller.on_action("issue")
			helpers.assert_eq(table.concat(order, " "), "copy:the report url")
			helpers.assert_contains(url, "https://github.com/owner/repo/issues/new?template=bug_report.yml")
			helpers.assert_contains(url, "version=1.2.3")
			helpers.assert_contains(url, "check%3Dfield_report%20verdict%3Dfail%20request%3Dapp-1")
			helpers.assert_true(not url:find("tmp", 1, true), "the folder path never enters the form")
			helpers.assert_eq(last(world).action, "issue")
			helpers.assert_eq(last(world).ok, true)
		end)

		helpers.it("refuses an unknown action and answers a failing one", function()
			local controller, world = fixture({ copy = function() return false end })
			controller.attach(RUN)
			controller.on_ready()
			local before = #world.pushed
			controller.on_action("delete_everything")
			helpers.assert_eq(#world.pushed, before, "an unknown action gets no answer")
			controller.on_action("copy")
			helpers.assert_eq(last(world).action, "copy")
			helpers.assert_eq(last(world).ok, false, "copying before the end fails")
			controller.finished(SUMMARY, "the report")
			controller.on_action("issue")
			helpers.assert_eq(last(world).ok, false, "a refused clipboard stops the issue")
		end)
	end)
end
