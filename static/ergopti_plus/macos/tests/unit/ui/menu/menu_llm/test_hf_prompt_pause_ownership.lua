--- tests/unit/ui/menu/menu_llm/test_hf_prompt_pause_ownership.lua

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"infra.paths",
	"ui.ui_builder",
	"ui.menu.menu_llm.models_manager_mlx_hf",
}

local function with_fixture(options, callback)
	options = options or {}
	helpers.with_fresh_modules(MODULES, function()
		local fixture = {
			start_mode = "success",
			stop_mode = "success",
			delete_mode = "success",
			terminate_mode = "success",
			timers = {},
			tasks = {},
			authorized = true,
			settles = 0,
			terminals = {},
			notifications = 0,
			direct_finishes = 0,
			nested_pause_results = {},
			ui_timer_business = 0,
		}

		local timer_stub = { secondsSinceEpoch = function() return 1 end }
		function timer_stub.doAfter(_, fn)
			fn()
			return { stop = function() return true end }
		end
		function timer_stub.new(delay, fn)
			local timer = { delay = delay, fn = fn, live = false, stops = 0 }
			function timer:start()
				self.live = true
				if fixture.start_mode == "timer_sync" then self.fn() end
				if fixture.start_mode == "timer_throw" then error("HF timer start mutation") end
				if fixture.start_mode == "timer_false" then return false end
				if fixture.start_mode == "timer_nil" then return nil end
				return self
			end
			function timer:stop()
				self.stops = self.stops + 1
				if fixture.stop_mode == "throw" then error("HF timer stop refusal") end
				if fixture.stop_mode == "false" then return false end
				if fixture.stop_mode == "nil" then return nil end
				self.live = false
				return self
			end
			function timer:running() return self.live end
			function timer:deliver() self.fn() end
			fixture.timers[#fixture.timers + 1] = timer
			return timer
		end

		local task_stub = {}
		function task_stub.new(_, done, stream, _args)
			if fixture.start_mode == "construction_nil" then return nil end
			local task = { done = done, stream = stream, live = false, terminates = 0 }
			function task:start()
				if fixture.start_mode == "task_reentrant_pause_before_activation" then
					fixture.nested_pause_results[#fixture.nested_pause_results + 1]
						= fixture.pause()
				end
				self.live = true
				if fixture.start_mode == "task_reentrant_pause" then
					fixture.nested_pause_results[#fixture.nested_pause_results + 1]
						= fixture.pause()
				end
				if fixture.start_mode == "task_sync_success"
					or fixture.start_mode == "task_sync_false"
					or fixture.start_mode == "task_sync_nil"
					or fixture.start_mode == "task_sync_throw" then
					self.live = false
					self.done(0)
				end
				if fixture.start_mode == "task_sync_throw" then
					error("HF task start mutation")
				end
				if fixture.start_mode == "task_throw" then
					error("HF task start mutation")
				end
				if fixture.start_mode == "task_false" then return false end
				if fixture.start_mode == "task_nil" then return nil end
				if fixture.start_mode == "task_sync_false" then return false end
				if fixture.start_mode == "task_sync_nil" then return nil end
				if fixture.start_mode == "task_stopped_false" then
					self.live = false
					return false
				end
				if fixture.start_mode == "task_stopped_success" then
					self.live = false
					return self
				end
				return self
			end
			function task:terminate()
				self.terminates = self.terminates + 1
				if fixture.terminate_mode == "stop_false"
					or fixture.terminate_mode == "stop_nil"
					or fixture.terminate_mode == "stop_throw" then
					self.live = false
				end
				if fixture.terminate_mode == "stop_throw" then
					error("HF terminate stopped then raised")
				end
				if fixture.terminate_mode == "stop_false" then return false end
				if fixture.terminate_mode == "stop_nil" then return nil end
				if fixture.terminate_mode == "mutate_false" then
					self.live = false
					self.done(0)
					return false
				end
				if fixture.terminate_mode == "accepted_stopped" then
					self.live = false
					return self
				end
				if fixture.terminate_mode == "throw" then error("HF terminate refusal") end
				if fixture.terminate_mode == "false" then return false end
				if fixture.terminate_mode == "nil" then return nil end
				return self
			end
			function task:isRunning() return self.live end
			function task:complete(code)
				self.live = false
				self.done(code)
			end
			fixture.tasks[#fixture.tasks + 1] = task
			return task
		end

		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.notifications"] = {
			notify = function()
				fixture.notifications = fixture.notifications + 1
				if fixture.pause_on_notify == true then
					fixture.pause_on_notify = false
					fixture.nested_pause_results[#fixture.nested_pause_results + 1]
						= fixture.pause()
				end
				return true
			end,
		}
		package.loaded["infra.paths"] = {
			shared = function(path)
				if options.boundary_throw == "paths" then
					error("HF paths boundary failure")
				end
				return "/fixture/" .. tostring(path)
			end,
		}
		package.loaded["ui.ui_builder"] = {
			show_webview = function(opts)
				fixture.webview_options = opts
				local webview = { live = true, deletes = 0 }
				function webview:delete()
					self.deletes = self.deletes + 1
					if fixture.delete_mode == "throw" then error("HF webview delete refusal") end
					if fixture.delete_mode == "false" then return false end
					if fixture.delete_mode == "nil" then return nil end
					self.live = false
					opts.on_close()
					if fixture.delete_mode == "mutate_false" then return false end
					return self
				end
				fixture.webview = webview
				local acquired = type(opts.on_webview_created) ~= "function"
					or opts.on_webview_created(webview)
				if acquired ~= true then return nil end
				if options.schedule_ui_timer == true then
					local scheduled = opts.schedule_after(0.05, function()
						fixture.ui_timer_business = fixture.ui_timer_business + 1
					end, "fixture focus retry")
					if scheduled ~= true then return nil end
				end
				if options.show_mode == "mutate_throw" then
					error("HF webview factory mutate-then-throw")
				end
				if options.show_mode == "mutate_false" then return false end
				if options.show_mode == "mutate_nil" then return nil end
				if fixture.delete_mode == "sync_close_on_show" then
					webview.live = false
					opts.on_close()
				end
				return webview
			end,
		}

		local ucc = {}
		function ucc:setCallback(fn)
			fixture.bridge_callback = fn
			return self
		end
		local hs_overrides = {
			timer = timer_stub,
			task = task_stub,
			application = {
				get = function()
					if options.boundary_throw == "application" then
						error("HF application boundary failure")
					end
					return nil
				end,
				find = function() return nil end,
			},
			pasteboard = { getContents = function()
				if options.boundary_throw == "pasteboard" then
					error("HF pasteboard boundary failure")
				end
				return ""
			end },
			urlevent = { openURL = function()
				if fixture.pause_on_open_url == true then
					fixture.pause_on_open_url = false
					fixture.nested_pause_results[#fixture.nested_pause_results + 1]
						= fixture.pause()
				end
				return true
			end },
			webview = { usercontent = { new = function() return ucc end } },
			screen = {
				mainScreen = function()
					if options.boundary_throw == "screen" then
						error("HF screen boundary failure")
					end
					return { frame = function() return { x = 0, y = 0, w = 1920, h = 1080 } end }
				end,
			},
			drawing = { windowLevels = { floating = 1 } },
		}

		local Mixin = helpers.load_with_stubs(
			"ui.menu.menu_llm.models_manager_mlx_hf", hs_overrides)
		-- load_with_stubs installs its shared-path table after fixture stubs. Mutate
		-- that same captured table here so the live prompt crosses the hostile path
		-- boundary instead of a pre-load stand-in that production never observes.
		if options.boundary_throw == "paths" then
			package.loaded["infra.paths"].shared = function()
				error("HF paths boundary failure")
			end
		end
		fixture.obj = {}
		fixture.deps = { active_tasks = {} }
		fixture.lifecycle = {
			adopt = function(flow, pause_join)
				fixture.flow = flow
				fixture.pause_join = pause_join
				fixture.registered = true
				return true
			end,
			settle = function(flow)
				if fixture.registered ~= true or fixture.flow ~= flow then return false end
				fixture.registered = false
				fixture.settles = fixture.settles + 1
				return true
			end,
		}
		fixture.provenance = {
			owner = {},
			lifecycle = fixture.lifecycle,
			is_authorized = function() return fixture.authorized end,
		}
		local install_ctx = {
			obj = fixture.obj,
			deps = fixture.deps,
			presets = {},
		}
		if options.direct == true then
			install_ctx.begin_direct_operation = function()
				local operation = {
					lifecycle = fixture.lifecycle,
					is_authorized = function() return fixture.authorized end,
				}
				function operation.finish(done, _, result)
					fixture.direct_finishes = fixture.direct_finishes + 1
					if type(done) == "function" then done(result) end
					return true
				end
				return operation
			end
		end
		Mixin.install(install_ctx)
		function fixture.on_done(result)
			fixture.terminals[#fixture.terminals + 1] = result
			if fixture.pause_on_done == true then
				fixture.pause_on_done = false
				fixture.nested_pause_results[#fixture.nested_pause_results + 1]
					= fixture.pause()
			end
			return true
		end
		function fixture.prompt(use_direct)
			local provenance = fixture.provenance
			if use_direct then provenance = nil end
			return fixture.obj.prompt_hf_login(fixture.on_done, provenance)
		end
		function fixture.fire_prompt_timer()
			fixture.timers[1]:deliver()
		end
		function fixture.validate(token)
			fixture.bridge_callback({ body = { type = "validate", token = token or "hf_fixture" } })
		end
		function fixture.pause()
			fixture.authorized = false
			if type(fixture.pause_join) ~= "function" then return true end
			return fixture.pause_join(fixture.flow)
		end
		function fixture.open_model_source()
			return fixture.obj.open_model_source_page("fixture/repository")
		end
		function fixture.open_missing_model_source()
			return fixture.obj.open_model_source_page("missing model")
		end
		callback(fixture)
	end)
end

helpers.describe("HuggingFace prompt/webview/task exact requirement ownership", function()
	helpers.it("owns the missing-source notification across reentrant PAUSE", function()
		with_fixture({ direct = true }, function(fixture)
			fixture.pause_on_notify = true
			helpers.assert_eq(fixture.open_missing_model_source(), false)
			helpers.assert_eq(fixture.notifications, 1)
			helpers.assert_eq(fixture.nested_pause_results[1], false,
				"PAUSE cannot settle while the native notification boundary is on stack")
			helpers.assert_eq(fixture.settles, 1,
				"the notification boundary must settle its exact provenance child")
			helpers.assert_eq(fixture.direct_finishes, 1)
			helpers.assert_eq(fixture.registered, false)
		end)
	end)

	helpers.it("keeps one provenance child through prompt, webview, and task terminal", function()
		with_fixture({}, function(fixture)
			helpers.assert_true(fixture.prompt())
			helpers.assert_true(fixture.registered)
			fixture.fire_prompt_timer()
			helpers.assert_not_nil(fixture.webview)
			helpers.assert_eq(#fixture.tasks, 0)
			fixture.validate()
			helpers.assert_eq(#fixture.tasks, 1)
			helpers.assert_true(fixture.deps.active_tasks.hf_login == fixture.tasks[1])
			helpers.assert_eq(#fixture.terminals, 0)
			fixture.tasks[1]:complete(0)
			helpers.assert_eq(fixture.settles, 1)
			helpers.assert_eq(#fixture.terminals, 1)
			helpers.assert_eq(fixture.terminals[1], true)
			fixture.tasks[1]:complete(0)
			helpers.assert_eq(#fixture.terminals, 1)
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins the prompt timer on PAUSE after " .. mode .. " stop", function()
			with_fixture({}, function(fixture)
				helpers.assert_true(fixture.prompt())
				fixture.stop_mode = mode
				helpers.assert_eq(fixture.pause(), false)
				fixture.timers[1]:deliver()
				helpers.assert_nil(fixture.webview)
				helpers.assert_eq(#fixture.tasks, 0)
				helpers.assert_eq(#fixture.terminals, 0)
				fixture.stop_mode = "success"
				helpers.assert_true(fixture.pause())
				fixture.timers[1]:deliver()
				helpers.assert_nil(fixture.webview)
				helpers.assert_eq(#fixture.terminals, 0)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("withholds the prompt while one-shot self-stop returns " .. mode, function()
			with_fixture({}, function(fixture)
				helpers.assert_true(fixture.prompt())
				fixture.stop_mode = mode
				fixture.fire_prompt_timer()
				helpers.assert_nil(fixture.webview)
				helpers.assert_eq(#fixture.tasks, 0)
				fixture.stop_mode = "success"
				fixture.fire_prompt_timer()
				helpers.assert_not_nil(fixture.webview)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the exact webview after " .. mode .. " delete", function()
			with_fixture({}, function(fixture)
				helpers.assert_true(fixture.prompt())
				fixture.fire_prompt_timer()
				fixture.delete_mode = mode
				helpers.assert_eq(fixture.pause(), false)
				helpers.assert_true(fixture.webview.live)
				helpers.assert_eq(#fixture.tasks, 0)
				helpers.assert_eq(#fixture.terminals, 0)
				fixture.delete_mode = "success"
				helpers.assert_true(fixture.pause())
				helpers.assert_eq(fixture.webview.live, false)
				helpers.assert_eq(#fixture.tasks, 0)
				helpers.assert_eq(#fixture.terminals, 0)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("suppresses task terminal after " .. mode .. " PAUSE termination", function()
			with_fixture({}, function(fixture)
				helpers.assert_true(fixture.prompt())
				fixture.fire_prompt_timer()
				fixture.validate()
				fixture.terminate_mode = mode
				helpers.assert_eq(fixture.pause(), false)
				helpers.assert_eq(#fixture.terminals, 0)
				fixture.tasks[1]:complete(0)
				helpers.assert_eq(#fixture.terminals, 0,
					"a native task completion after PAUSE cannot reach business callback")
				fixture.tasks[1]:complete(0)
				helpers.assert_eq(#fixture.terminals, 0)
			end)
		end)
	end

	helpers.it("accepts synchronous task completion over a false terminate return", function()
		with_fixture({}, function(fixture)
			helpers.assert_true(fixture.prompt())
			fixture.fire_prompt_timer()
			fixture.validate()
			fixture.terminate_mode = "mutate_false"
			helpers.assert_true(fixture.pause())
			helpers.assert_eq(#fixture.terminals, 0)
			helpers.assert_nil(fixture.deps.active_tasks.hf_login)
		end)
	end)

	helpers.it("accepts webview close settlement over a false delete return", function()
		with_fixture({}, function(fixture)
			helpers.assert_true(fixture.prompt())
			fixture.fire_prompt_timer()
			fixture.delete_mode = "mutate_false"
			helpers.assert_true(fixture.pause())
			helpers.assert_eq(#fixture.tasks, 0)
			helpers.assert_eq(#fixture.terminals, 0)
		end)
	end)

	for _, mode in ipairs({ "task_sync_false", "task_sync_nil", "task_sync_throw" }) do
		helpers.it("buffers a synchronous completion across " .. mode, function()
			with_fixture({}, function(fixture)
				fixture.start_mode = mode
				helpers.assert_true(fixture.prompt())
				fixture.fire_prompt_timer()
				fixture.validate()
				helpers.assert_eq(#fixture.terminals, 1)
				helpers.assert_eq(fixture.terminals[1], false,
					"a completion observed before start refusal cannot publish success")
				helpers.assert_nil(fixture.deps.active_tasks.hf_login)
			end)
		end)
	end

	helpers.it("commits one synchronous successful task terminal after start", function()
		with_fixture({}, function(fixture)
			fixture.start_mode = "task_sync_success"
			helpers.assert_true(fixture.prompt())
			fixture.fire_prompt_timer()
			fixture.validate()
			helpers.assert_eq(fixture.settles, 1)
			helpers.assert_eq(#fixture.terminals, 1)
			helpers.assert_eq(fixture.terminals[1], true)
			helpers.assert_nil(fixture.deps.active_tasks.hf_login)
		end)
	end)

	helpers.it("commits one asynchronous failed task terminal", function()
		with_fixture({}, function(fixture)
			helpers.assert_true(fixture.prompt())
			fixture.fire_prompt_timer()
			fixture.validate()
			fixture.tasks[1]:complete(17)
			helpers.assert_eq(fixture.settles, 1)
			helpers.assert_eq(#fixture.terminals, 1)
			helpers.assert_eq(fixture.terminals[1], false)
			fixture.tasks[1]:complete(0)
			helpers.assert_eq(#fixture.terminals, 1)
		end)
	end)

	for _, mode in ipairs({ "task_false", "task_nil", "task_throw" }) do
		helpers.it("retains a mutating task after " .. mode .. " start refusal", function()
			with_fixture({}, function(fixture)
				fixture.start_mode = mode
				helpers.assert_true(fixture.prompt())
				fixture.fire_prompt_timer()
				fixture.validate()
				helpers.assert_eq(#fixture.tasks, 1)
				helpers.assert_true(fixture.deps.active_tasks.hf_login == fixture.tasks[1])
				helpers.assert_eq(#fixture.terminals, 0,
					"a start refusal cannot settle while its exact task remains live")
				fixture.tasks[1]:complete(0)
				helpers.assert_eq(fixture.settles, 1)
				helpers.assert_nil(fixture.deps.active_tasks.hf_login)
				helpers.assert_eq(#fixture.terminals, 1)
				helpers.assert_eq(fixture.terminals[1], false,
					"late completion cannot upgrade a start-refused task to success")
			end)
		end)
	end

	for _, case in ipairs({
		{ start = "task_false", terminate = "stop_false" },
		{ start = "task_nil", terminate = "stop_nil" },
		{ start = "task_throw", terminate = "stop_throw" },
	}) do
		helpers.it("settles a start-refused task when terminate "
			.. case.terminate .. " proves it stopped", function()
			with_fixture({}, function(fixture)
				fixture.start_mode = case.start
				fixture.terminate_mode = case.terminate
				helpers.assert_true(fixture.prompt())
				fixture.fire_prompt_timer()
				fixture.validate()
				helpers.assert_eq(#fixture.tasks, 1)
				helpers.assert_eq(fixture.tasks[1].terminates, 1)
				helpers.assert_eq(fixture.tasks[1].live, false)
				helpers.assert_nil(fixture.deps.active_tasks.hf_login)
				helpers.assert_eq(fixture.settles, 1)
				helpers.assert_eq(fixture.terminals, { false })
			end)
		end)
	end

	for _, boundary in ipairs({ "application", "pasteboard", "screen", "paths" }) do
		helpers.it("settles prompt ownership when the " .. boundary
			.. " boundary raises", function()
			with_fixture({ boundary_throw = boundary }, function(fixture)
				helpers.assert_true(fixture.prompt())
				fixture.fire_prompt_timer()
				helpers.assert_nil(fixture.webview)
				helpers.assert_eq(#fixture.tasks, 0)
				helpers.assert_eq(fixture.settles, 1)
				helpers.assert_eq(fixture.terminals, { false })
				helpers.assert_eq(fixture.registered, false,
					"a prompt construction exception must not strand active_flow")
			end)
		end)
	end

	for _, mode in ipairs({ "mutate_false", "mutate_nil", "mutate_throw" }) do
		helpers.it("settles the exact webview after a " .. mode
			.. " factory refusal", function()
			with_fixture({ show_mode = mode }, function(fixture)
				helpers.assert_true(fixture.prompt())
				fixture.fire_prompt_timer()
				helpers.assert_not_nil(fixture.webview,
					"the factory must publish the candidate before its refusal")
				helpers.assert_eq(fixture.webview.live, false,
					"the exact acquired candidate must be deleted")
				helpers.assert_eq(fixture.webview.deletes, 1)
				helpers.assert_eq(fixture.settles, 1)
				helpers.assert_eq(fixture.terminals, { false })
			end)
		end)
	end

	helpers.it("settles a task construction refusal exactly once", function()
		with_fixture({}, function(fixture)
			fixture.start_mode = "construction_nil"
			helpers.assert_true(fixture.prompt())
			fixture.fire_prompt_timer()
			fixture.validate()
			helpers.assert_eq(#fixture.tasks, 0)
			helpers.assert_nil(fixture.deps.active_tasks.hf_login)
			helpers.assert_eq(fixture.settles, 1)
			helpers.assert_eq(#fixture.terminals, 1)
			helpers.assert_eq(fixture.terminals[1], false)
		end)
	end)

	helpers.it("suppresses a task created across reentrant PAUSE before start returns", function()
		with_fixture({}, function(fixture)
			fixture.start_mode = "task_reentrant_pause"
			helpers.assert_true(fixture.prompt())
			fixture.fire_prompt_timer()
			fixture.validate()
			helpers.assert_eq(#fixture.tasks, 1)
			helpers.assert_eq(fixture.nested_pause_results, { false })
			helpers.assert_eq(fixture.tasks[1].terminates, 2,
				"a signal accepted before start commits must be repeated afterwards")
			helpers.assert_eq(#fixture.terminals, 0)
			fixture.tasks[1]:complete(0)
			helpers.assert_eq(#fixture.terminals, 0)
			helpers.assert_nil(fixture.deps.active_tasks.hf_login)
		end)
	end)

	helpers.it("keeps a pre-activation start candidate owned across reentrant PAUSE", function()
		with_fixture({}, function(fixture)
			fixture.start_mode = "task_reentrant_pause_before_activation"
			fixture.terminate_mode = "false"
			helpers.assert_true(fixture.prompt())
			fixture.fire_prompt_timer()
			fixture.validate()
			helpers.assert_eq(fixture.nested_pause_results, { false },
				"PAUSE cannot settle while start() is still on-stack")
			helpers.assert_eq(#fixture.tasks, 1)
			helpers.assert_eq(fixture.tasks[1].terminates, 2,
				"the newly-live exact task must be signalled again after start")
			helpers.assert_true(fixture.deps.active_tasks.hf_login == fixture.tasks[1])
			helpers.assert_eq(#fixture.terminals, 0)
			fixture.tasks[1]:complete(0)
			helpers.assert_nil(fixture.deps.active_tasks.hf_login)
			helpers.assert_eq(#fixture.terminals, 0,
				"the revoked task terminal must stay business-inert")
		end)
	end)

	helpers.it("settles a truthy start that is already stopped without a terminal", function()
		with_fixture({}, function(fixture)
			fixture.start_mode = "task_stopped_success"
			helpers.assert_true(fixture.prompt())
			fixture.fire_prompt_timer()
			fixture.validate()
			helpers.assert_nil(fixture.deps.active_tasks.hf_login)
			helpers.assert_eq(fixture.settles, 1)
			helpers.assert_eq(fixture.terminals, { false })
		end)
	end)

	helpers.it("accepts a truthy terminate that proves the task stopped", function()
		with_fixture({}, function(fixture)
			helpers.assert_true(fixture.prompt())
			fixture.fire_prompt_timer()
			fixture.validate()
			fixture.terminate_mode = "accepted_stopped"
			helpers.assert_true(fixture.pause())
			helpers.assert_nil(fixture.deps.active_tasks.hf_login)
			helpers.assert_eq(fixture.tasks[1].terminates, 1)
			helpers.assert_eq(#fixture.terminals, 0)
		end)
	end)

	helpers.it("holds task-terminal notification callbacks across nested PAUSE", function()
		with_fixture({}, function(fixture)
			helpers.assert_true(fixture.prompt())
			fixture.fire_prompt_timer()
			fixture.validate()
			fixture.pause_on_notify = true
			fixture.tasks[1]:complete(0)
			helpers.assert_eq(fixture.nested_pause_results, { false })
			helpers.assert_eq(#fixture.terminals, 0,
				"revocation inside the notification must suppress on_done")
			helpers.assert_eq(fixture.settles, 1)
		end)
	end)

	helpers.it("holds the final on_done callback across nested PAUSE", function()
		with_fixture({}, function(fixture)
			helpers.assert_true(fixture.prompt())
			fixture.fire_prompt_timer()
			fixture.validate()
			fixture.pause_on_done = true
			fixture.tasks[1]:complete(0)
			helpers.assert_eq(fixture.nested_pause_results, { false })
			helpers.assert_eq(fixture.terminals, { true })
			helpers.assert_eq(fixture.settles, 1)
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins an owned webview timer after " .. mode .. " stop", function()
			with_fixture({ schedule_ui_timer = true }, function(fixture)
				helpers.assert_true(fixture.prompt())
				fixture.fire_prompt_timer()
				helpers.assert_eq(#fixture.timers, 2)
				local ui_timer = fixture.timers[2]
				fixture.stop_mode = mode
				helpers.assert_eq(fixture.pause(), false)
				helpers.assert_eq(ui_timer.stops, 1)
				ui_timer:deliver()
				helpers.assert_eq(fixture.ui_timer_business, 0)
				helpers.assert_eq(ui_timer.stops, 2,
					"late native delivery retries settlement on the same handle")
				fixture.stop_mode = "success"
				helpers.assert_true(fixture.pause())
				helpers.assert_eq(ui_timer.stops, 3)
				ui_timer:deliver()
				helpers.assert_eq(fixture.ui_timer_business, 0)
			end)
		end)
	end

	helpers.it("keeps direct source navigation on-stack visible to PAUSE", function()
		with_fixture({ direct = true }, function(fixture)
			fixture.pause_on_open_url = true
			helpers.assert_eq(fixture.open_model_source(), false)
			helpers.assert_eq(fixture.nested_pause_results, { false })
			helpers.assert_eq(fixture.notifications, 0,
				"a revoked URL boundary cannot publish its success notification")
			helpers.assert_eq(fixture.direct_finishes, 1)
		end)
	end)

	helpers.it("rejects a direct selector prompt without maintenance provenance", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.prompt(true), false)
			helpers.assert_eq(#fixture.timers, 0)
			helpers.assert_eq(#fixture.terminals, 0)
		end)
	end)

	helpers.it("rejects passed provenance that is already paused", function()
		with_fixture({}, function(fixture)
			fixture.authorized = false
			helpers.assert_eq(fixture.prompt(), false)
			helpers.assert_eq(#fixture.timers, 0)
			helpers.assert_nil(fixture.webview)
			helpers.assert_eq(#fixture.tasks, 0)
			helpers.assert_eq(#fixture.terminals, 0)
			helpers.assert_eq(fixture.settles, 1)
		end)
	end)

	helpers.it("uses the existing maintenance capability for a direct selector", function()
		with_fixture({ direct = true }, function(fixture)
			helpers.assert_true(fixture.prompt(true))
			fixture.fire_prompt_timer()
			fixture.validate()
			fixture.tasks[1]:complete(0)
			helpers.assert_eq(fixture.direct_finishes, 1)
			helpers.assert_eq(#fixture.terminals, 1)
		end)
	end)

	helpers.it("rejects synchronous prompt-timer delivery before commit", function()
		with_fixture({}, function(fixture)
			fixture.start_mode = "timer_sync"
			helpers.assert_eq(fixture.prompt(), false)
			helpers.assert_nil(fixture.webview)
			helpers.assert_eq(#fixture.tasks, 0)
			helpers.assert_eq(#fixture.terminals, 1)
			helpers.assert_eq(fixture.terminals[1], false)
		end)
	end)

	for _, mode in ipairs({ "timer_false", "timer_nil", "timer_throw" }) do
		helpers.it("settles a prompt-timer " .. mode .. " start refusal", function()
			with_fixture({}, function(fixture)
				fixture.start_mode = mode
				helpers.assert_eq(fixture.prompt(), false)
				helpers.assert_nil(fixture.webview)
				helpers.assert_eq(#fixture.tasks, 0)
				helpers.assert_eq(fixture.settles, 1)
				helpers.assert_eq(#fixture.terminals, 1)
				helpers.assert_eq(fixture.terminals[1], false)
			end)
		end)
	end
end)
