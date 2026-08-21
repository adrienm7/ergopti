--- tests/unit/ui/menu/menu_llm/test_mlx_server_replacement_transaction.lua

--- =============================================================================
--- MODULE: MLX Server Replacement Transaction Regression
--- DESCRIPTION:
--- Drives the real MLX server lifecycle mixin with native-shaped task doubles.
--- Proves that termination accepts the task userdata as signal ownership while
--- retaining the predecessor until its exact completion callback, and that a
--- model or port successor cannot launch before that settlement.
---
--- FEATURES & RATIONALE:
--- 1. Faithful Native Shape: start() and terminate() return the task itself.
--- 2. Refusal Matrix: false, nil, and thrown termination keep the exact owner.
--- 3. Exact Completion: duplicate native callbacks cannot launch twice.
--- 4. Full Identity: backend, model, and port distinguish server capabilities.
--- 5. Global Intent: stop/backend/port/shutdown supersede every queued successor.
--- 6. Cleanup Proof: adopted and native owners survive OS cleanup refusal.
--- 7. Lsof Truth: Apple lsof 4.91 no-match succeeds without `-Q`, while an
---    operational error remains a strict cleanup refusal.
--- 8. Child Reaping: stopping the bash wrapper before readiness cannot leave
---    its Python child alive to bind the listener later.
--- =============================================================================

local helpers = require("tests.helpers")

local MODULE_NAMES = {
	"infra.notifications",
	"infra.logger",
	"infra.i18n",
	"modules.llm.api_common",
	"adapters.task_lifecycle",
	"modules.llm.api_mlx",
	"ui.menu.menu_llm.models_manager_mlx_server",
}





-- ====================================
-- ====================================
-- ======= 1/ Isolated Fixture ========
-- ====================================
-- ====================================

--- Runs one isolated real server-mixin fixture.
--- @param options string|table Native task and listener-cleanup behavior.
--- @param assertions function Fixture assertion callback.
local function with_server_fixture(options, assertions)
	if type(options) ~= "table" then options = { terminate_mode = options } end
	local terminate_mode = options.terminate_mode or "self"
	local start_mode = options.start_mode or "self"
	local cleanup_mode = options.cleanup_mode or "true"
	local probe_body = options.probe_body or ""
	local saved_modules = {}
	for _, name in ipairs(MODULE_NAMES) do saved_modules[name] = package.loaded[name] end
	local saved_hs = rawget(_G, "hs")
	local saved_os_execute = os.execute
	local ok, err = xpcall(function()
		local noop = function() end
		local current_port = 3460
		local server_tasks = {}
		local logged_errors = {}
		local cleanup_commands = {}
		local events = {}
		local timer_count = 0
		local function lsof_command_contract(command)
			local query = "/usr/sbin/lsof -nP -tiTCP:" .. tostring(math.floor(current_port))
				.. " -sTCP:LISTEN"
			return command:find("/usr/sbin/lsof -Q", 1, true) == nil
				and command:find("output=$(" .. query .. " 2>\"$err_file\")", 1, true) ~= nil
				and command:find("if [ -s \"$err_file\" ]; then return 2; fi", 1, true) ~= nil
				and command:find("if [ \"$status\" -eq 1 ] && [ -z \"$output\" ]; then return 0; fi", 1, true) ~= nil
				and command:find("pids=$(probe_listener) || exit 1", 1, true) ~= nil
				and command:find("remaining=$(probe_listener) || exit 1", 1, true) ~= nil
		end
		local function supervises_python_child(arguments)
			local command = type(arguments) == "table" and arguments[2] or nil
			if type(command) ~= "string" then return false end
			local cleanup_at = command:find("cleanup_mlx_child()", 1, true)
			local cleanup_wait_at = cleanup_at
				and command:find("wait \"$MLX_PID\"", cleanup_at, true) or nil
			local latch_at = command:find("trap 'MLX_STOP_PENDING=1' TERM INT HUP", 1, true)
			local launch_at = command:find("-m mlx_lm server", 1, true)
			local pid_at = command:find("MLX_PID=$!", 1, true)
			local exit_handler_at = command:find("trap 'cleanup_mlx_child' EXIT", 1, true)
			local handler_at = command:find("trap 'cleanup_mlx_child; exit 15' TERM INT HUP", 1, true)
			local pending_at = command:find("if [ \"$MLX_STOP_PENDING\" -eq 1 ]", 1, true)
			local terminal_wait_at = pending_at
				and command:find("wait \"$MLX_PID\"", pending_at, true) or nil
			return cleanup_at ~= nil and cleanup_wait_at ~= nil and latch_at ~= nil
				and launch_at ~= nil and pid_at ~= nil and exit_handler_at ~= nil and handler_at ~= nil
				and pending_at ~= nil and terminal_wait_at ~= nil
				and cleanup_at < cleanup_wait_at and cleanup_wait_at < latch_at
				and latch_at < launch_at and launch_at < pid_at and pid_at < exit_handler_at
				and exit_handler_at < handler_at
				and handler_at < pending_at and pending_at < terminal_wait_at
				and command:find("kill -TERM -- \"$KILL_TARGET\"", 1, true) ~= nil
				and command:find("kill -KILL -- \"$KILL_TARGET\"", 1, true) ~= nil
		end

		os.execute = function(command)
			cleanup_commands[#cleanup_commands + 1] = command
			events[#events + 1] = "cleanup"
			local apple_491_safe = lsof_command_contract(command)
			if cleanup_mode == "empty_lsof_error" then
				-- The production shell must distinguish a diagnostic-bearing failure
				-- from Apple lsof's empty status-1 no-match result.
				if apple_491_safe then return false, "exit", 1 end
				return true, "exit", 0
			end
			if cleanup_mode == "apple_491_absence" then
				-- Stock macOS lsof has no -Q and reports no matches as status 1.
				if apple_491_safe then return true, "exit", 0 end
				return false, "exit", 1
			end
			if cleanup_mode == "throw" then error("fixture cleanup failure") end
			if cleanup_mode == "false" then return false, "exit", 1 end
			if cleanup_mode == "nil" then return nil, "exit", 1 end
			return true, "exit", 0
		end

		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["infra.logger"] = {
			UNIFIED_LOG_FILE = "/tmp/ergopti-test.log",
			debug = noop,
			info = noop,
			warn = noop,
			error = function(...) server_tasks.logged_error = { ... }; logged_errors[#logged_errors + 1] = { ... } end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["modules.llm.api_common"] = {
			protected_call = function(callback, _, ...)
				if type(callback) ~= "function" then return true, nil end
				return xpcall(callback, debug.traceback, ...)
			end,
		}
		package.loaded["modules.llm.api_mlx"] = {
			get_port = function() return current_port end,
			reset_endpoints = noop,
			set_model_hf_path = noop,
			set_active_server_pgid = noop,
			mark_load_failed = noop,
		}
		package.loaded["adapters.task_lifecycle"] = {
			native = function(label, _, on_done, on_chunk, arguments)
				local task = {
					label = label,
					running = false,
					terminate_calls = 0,
					arguments = arguments,
					child_alive = false,
					listener_bound = false,
					child_supervised = label == "MLX server launch"
						and supervises_python_child(arguments),
				}
				function task:start()
					self.running = true
					if self.label == "MLX server launch" then
						events[#events + 1] = "start"
						if options.simulate_starting_child then self.child_alive = true end
						if start_mode:find("sync_", 1, true) == 1 then
							self:complete(options.start_code or 0)
						end
					end
					if start_mode == "false" or start_mode == "sync_false" then return false end
					if start_mode == "nil" or start_mode == "sync_nil" then return nil end
					if start_mode == "throw" or start_mode == "sync_throw" then
						error("fixture start failure")
					end
					return self
				end
				function task:isRunning() return self.running end
				function task:terminate()
					self.terminate_calls = self.terminate_calls + 1
					if options.simulate_starting_child and self.child_supervised and self.child_alive then
						self.child_alive = false
						events[#events + 1] = "child-exit"
					end
					if terminate_mode:find("sync_", 1, true) == 1 then self:complete(15) end
					if terminate_mode == "throw" or terminate_mode == "sync_throw" then
						error("fixture termination failure")
					end
					if terminate_mode == "false" or terminate_mode == "sync_false" then return false end
					if terminate_mode == "nil" or terminate_mode == "sync_nil" then return nil end
					return self
				end
				function task:complete(code)
					self.running = false
					on_done(code or 15, "", "")
				end
				function task:stream(stdout, stderr)
					if type(on_chunk) ~= "function" then return nil end
					return on_chunk(self, stdout or "", stderr or "")
				end
				function task:attempt_late_bind()
					if self.child_alive then self.listener_bound = true end
					return self.listener_bound
				end
				if label == "MLX server launch" then server_tasks[#server_tasks + 1] = task end
				return task
			end,
			start = function(task)
				local started_ok, started = xpcall(function() return task:start() end, debug.traceback)
				return started_ok and started ~= false and started ~= nil
			end,
		}
		_G.hs = {
			execute = function() return probe_body end,
			json = { decode = function()
				local data = {}
				if options.probe_model then data[1] = { id = options.probe_model } end
				return { data = data }
			end },
			timer = {
				doAfter = function(_, callback)
					timer_count = timer_count + 1
					return { callback = callback, stop = noop }
				end,
			},
		}
		package.loaded["ui.menu.menu_llm.models_manager_mlx_server"] = nil

		local obj = {
			get_mlx_repo = function(model) return "fixture/" .. tostring(model) end,
		}
		local deps = { active_tasks = {} }
		require("ui.menu.menu_llm.models_manager_mlx_server").install({
			obj = obj,
			deps = deps,
			project_venv_python_escaped = "/fixture/python",
			active_tasks_gc_root = {},
		})

		assertions({
			obj = obj,
			deps = deps,
			server_tasks = server_tasks,
			logged_errors = logged_errors,
			cleanup_commands = cleanup_commands,
			events = events,
			timer_count = function() return timer_count end,
			set_port = function(port) current_port = port end,
			set_start_mode = function(mode) start_mode = mode end,
			set_cleanup_mode = function(mode) cleanup_mode = mode end,
		})
	end, debug.traceback)

	os.execute = saved_os_execute
	_G.hs = saved_hs
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved_modules[name] end
	if not ok then error(err, 0) end
end

--- Marks one launched server ready through its real streaming callback.
--- @param task table Native task double.
local function mark_ready(task)
	task:stream("Application startup complete\n", "")
end





-- ===========================================
-- ===========================================
-- ======= 2/ Replacement Transactions =======
-- ===========================================
-- ===========================================

helpers.describe("HS-008: exact MLX server replacement ownership", function()
	helpers.it("(HS-008-termination-refusal) keeps A and its joined callers retryable", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_server_fixture(mode, function(fixture)
				local primary_successes = 0
				local joined_successes = 0
				local joined_cancellations = 0
				local candidate_cancellations = 0

				helpers.assert_true(fixture.obj.start_server("A",
					function() primary_successes = primary_successes + 1 end,
					function() end) == true)
				local predecessor = fixture.server_tasks[1]
				helpers.assert_not_nil(predecessor)
				helpers.assert_true(fixture.obj.start_server("A",
					function() joined_successes = joined_successes + 1 end,
					function() joined_cancellations = joined_cancellations + 1 end) == true)

				local accepted = fixture.obj.start_server("B", function() end,
					function() candidate_cancellations = candidate_cancellations + 1 end)
				helpers.assert_eq(accepted, false, mode)
				helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], predecessor,
					"a refused signal cannot drop the only retryable predecessor owner")
				helpers.assert_eq(#fixture.server_tasks, 1,
					"a successor cannot launch after termination refusal")
				helpers.assert_eq(candidate_cancellations, 1,
					"the rejected successor must receive one terminal")
				helpers.assert_eq(joined_cancellations, 0,
					"predecessor waiters remain valid when termination never committed")

				mark_ready(predecessor)
				helpers.assert_eq(primary_successes, 1)
				helpers.assert_eq(joined_successes, 1,
					"a failed replacement cannot consume a predecessor waiter")
			end)
		end
	end)

	helpers.it("(HS-008-native-self-settlement) launches B only after A's exact callback", function()
		with_server_fixture("self", function(fixture)
			local candidate_successes = 0
			local candidate_cancellations = 0
			fixture.obj.start_server("A", function() end, function() end)
			local predecessor = fixture.server_tasks[1]
			mark_ready(predecessor)

			local accepted = fixture.obj.start_server("B",
				function() candidate_successes = candidate_successes + 1 end,
				function() candidate_cancellations = candidate_cancellations + 1 end)
			helpers.assert_eq(accepted, true,
				"the native task userdata means SIGTERM was accepted")
			helpers.assert_eq(predecessor.terminate_calls, 1)
			helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], predecessor,
				"signal acceptance is not process settlement")
			helpers.assert_eq(#fixture.server_tasks, 1,
				"B must wait for A's exact completion callback")
			helpers.assert_eq(candidate_successes, 0)
			helpers.assert_eq(candidate_cancellations, 0)

			predecessor:complete(15)
			helpers.assert_eq(#fixture.server_tasks, 2,
				"A's callback transfers ownership to exactly one successor")
			local successor = fixture.server_tasks[2]
			helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], successor)
			predecessor:complete(15)
			helpers.assert_eq(#fixture.server_tasks, 2,
				"a duplicate predecessor callback cannot launch B twice")

			mark_ready(successor)
			helpers.assert_eq(candidate_successes, 1)
			helpers.assert_eq(candidate_cancellations, 0)
		end)
	end)

	helpers.it("(HS-008-sync-terminate) publishes a synchronous completion before returning", function()
		with_server_fixture({ terminate_mode = "sync_complete" }, function(fixture)
			local candidate_successes = 0
			fixture.obj.start_server("A", function() end, function() end)
			local predecessor = fixture.server_tasks[1]
			mark_ready(predecessor)

			helpers.assert_eq(fixture.obj.start_server("B", function()
				candidate_successes = candidate_successes + 1
			end, function() end), true)
			helpers.assert_eq(predecessor.terminate_calls, 1)
			helpers.assert_eq(#fixture.cleanup_commands, 1)
			helpers.assert_eq(#fixture.server_tasks, 2,
				"a synchronous predecessor callback must install exactly one successor")
			helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], fixture.server_tasks[2])
			helpers.assert_eq(fixture.events[2], "cleanup",
				"the exact listener cleanup must precede successor task publication")
			helpers.assert_eq(fixture.events[3], "start")
			mark_ready(fixture.server_tasks[2])
			helpers.assert_eq(candidate_successes, 1)
		end)
	end)

	helpers.it("(HS-008-sync-terminate-result) lets exact completion outrank a late refusal", function()
		for _, mode in ipairs({ "sync_false", "sync_nil", "sync_throw" }) do
			with_server_fixture({ terminate_mode = mode }, function(fixture)
				local settlements = 0
				fixture.obj.start_server("A", function() end, function() end)
				local predecessor = fixture.server_tasks[1]
				mark_ready(predecessor)
				helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
					settlements = settlements + 1
					return true
				end, { kind = "stop" }), true, mode)
				helpers.assert_eq(settlements, 1)
				helpers.assert_eq(fixture.obj._server_lifecycle_owner, nil)
				helpers.assert_eq(#fixture.cleanup_commands, 1)
			end)
		end
	end)

	helpers.it("(HS-008-sync-start) leaves no owner or probe after synchronous completion", function()
		with_server_fixture({ start_mode = "sync_complete", start_code = 0 }, function(fixture)
			local cancellations = 0
			helpers.assert_eq(fixture.obj.start_server("A", function() end, function()
				cancellations = cancellations + 1
			end), false)
			helpers.assert_eq(#fixture.server_tasks, 1)
			helpers.assert_eq(#fixture.cleanup_commands, 1)
			helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], nil)
			helpers.assert_eq(fixture.obj._server_lifecycle_owner, nil)
			helpers.assert_eq(fixture.obj._server_identity, nil)
			helpers.assert_eq(fixture.timer_count(), 0,
				"a synchronously completed start cannot publish a readiness timer")
			helpers.assert_eq(cancellations, 1)
		end)
	end)

	helpers.it("(HS-008-sync-start-result) ignores every return after exact completion", function()
		for _, mode in ipairs({ "sync_false", "sync_nil", "sync_throw" }) do
			with_server_fixture({ start_mode = mode, start_code = 0 }, function(fixture)
				local cancellations = 0
				helpers.assert_eq(fixture.obj.start_server("A", function() end, function()
					cancellations = cancellations + 1
				end), false, mode)
				helpers.assert_eq(cancellations, 1)
				helpers.assert_eq(fixture.obj._server_lifecycle_owner, nil)
				helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], nil)
				helpers.assert_eq(fixture.timer_count(), 0)
			end)
		end
	end)

	helpers.it("(HS-008-successor-start-refusal) sends one terminal for false, nil, and throw", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_server_fixture("self", function(fixture)
				local candidate_successes = 0
				local candidate_cancellations = 0
				fixture.obj.start_server("A", function() end, function() end)
				local predecessor = fixture.server_tasks[1]
				mark_ready(predecessor)
				fixture.set_start_mode(mode)

				helpers.assert_eq(fixture.obj.start_server("B", function()
					candidate_successes = candidate_successes + 1
				end, function()
					candidate_cancellations = candidate_cancellations + 1
				end), true, mode)
				predecessor:complete(15)

				helpers.assert_eq(candidate_successes, 0, mode)
				helpers.assert_eq(candidate_cancellations, 1,
					"the recursive successor and its owner must share one terminal gate")
				helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], nil)
				helpers.assert_eq(fixture.obj._server_lifecycle_owner, nil)
			end)
		end
	end)

	helpers.it("(HS-008-sync-cleanup-refusal) keeps the cleanup owner retryable", function()
		with_server_fixture({
			terminate_mode = "sync_complete",
			cleanup_mode = "false",
		}, function(fixture)
			local candidate_cancellations = 0
			fixture.obj.start_server("A", function() end, function() end)
			local predecessor = fixture.server_tasks[1]
			mark_ready(predecessor)

			helpers.assert_eq(fixture.obj.start_server("B", function() end, function()
				candidate_cancellations = candidate_cancellations + 1
			end), false)
			helpers.assert_eq(candidate_cancellations, 1)
			helpers.assert_eq(#fixture.server_tasks, 1)
			helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], nil)
			helpers.assert_eq(fixture.obj._server_lifecycle_owner.phase, "cleanup")
			helpers.assert_eq(fixture.obj._server_lifecycle_owner.intent, nil,
				"the rejected waiter must release intent authority without releasing cleanup debt")
			helpers.assert_eq(fixture.obj._server_transition_intent, nil)
			helpers.assert_eq(fixture.obj._server_ready, true)

			fixture.set_cleanup_mode("true")
			helpers.assert_eq(fixture.obj.stop_server_if_needed(nil, { kind = "stop" }), true)
			helpers.assert_eq(fixture.obj._server_lifecycle_owner, nil)
		end)
	end)

	helpers.it("(HS-008-port-identity) replaces the same model when its port changes", function()
		with_server_fixture("self", function(fixture)
			local successor_successes = 0
			fixture.obj.start_server("A", function() end, function() end)
			local predecessor = fixture.server_tasks[1]
			mark_ready(predecessor)
			fixture.set_port(4567)

			local accepted = fixture.obj.start_server("A",
				function() successor_successes = successor_successes + 1 end,
				function() end)
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(successor_successes, 0,
				"the old-port process cannot satisfy the new-port identity")
			helpers.assert_eq(#fixture.server_tasks, 1)
			predecessor:complete(15)
			helpers.assert_eq(#fixture.server_tasks, 2)
			local successor = fixture.server_tasks[2]
			helpers.assert_true(type(successor.arguments) == "table"
				and tostring(successor.arguments[2]):find("%-%-port 4567") ~= nil,
				"the successor launch must carry the port captured by its exact identity")
			mark_ready(successor)
			helpers.assert_eq(successor_successes, 1)
		end)
	end)

	helpers.it("(HS-008-public-stop) reports refusal and settles only from the exact callback", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_server_fixture(mode, function(fixture)
				local settlements = 0
				fixture.obj.start_server("A", function() end, function() end)
				local predecessor = fixture.server_tasks[1]
				mark_ready(predecessor)

				helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
					settlements = settlements + 1
				end), false, mode)
				helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], predecessor)
				helpers.assert_eq(fixture.obj._server_ready, true)
				helpers.assert_eq(settlements, 0)
			end)
		end

		with_server_fixture("self", function(fixture)
			local settlements = 0
			fixture.obj.start_server("A", function() end, function() end)
			local predecessor = fixture.server_tasks[1]
			mark_ready(predecessor)

			helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
				settlements = settlements + 1
			end), true)
			helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], predecessor,
				"native-self is signal acceptance, not stop settlement")
			helpers.assert_eq(settlements, 0)
			predecessor:complete(15)
			helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], nil)
			helpers.assert_eq(fixture.obj._server_target, nil)
			helpers.assert_eq(fixture.obj._server_ready, false)
			helpers.assert_eq(settlements, 1)
			predecessor:complete(15)
			helpers.assert_eq(settlements, 1, "duplicate callbacks are terminally inert")
		end)
	end)

	helpers.it("(HS-008-latest-successor) launches only the newest model/port request", function()
		with_server_fixture("self", function(fixture)
			local b_cancellations = 0
			local c_successes = 0
			fixture.obj.start_server("A", function() end, function() end)
			local predecessor = fixture.server_tasks[1]
			mark_ready(predecessor)

			helpers.assert_eq(fixture.obj.start_server("B", function() end, function()
				b_cancellations = b_cancellations + 1
			end), true)
			fixture.set_port(4567)
			helpers.assert_eq(fixture.obj.start_server("C", function()
				c_successes = c_successes + 1
			end, function() end), true)
			helpers.assert_eq(predecessor.terminate_calls, 1,
				"successor updates join the one exact predecessor signal")
			helpers.assert_eq(b_cancellations, 1)
			helpers.assert_eq(#fixture.server_tasks, 1)

			predecessor:complete(15)
			helpers.assert_eq(#fixture.server_tasks, 2)
			local successor = fixture.server_tasks[2]
			helpers.assert_true(tostring(successor.arguments[2]):find("fixture/C", 1, true) ~= nil)
			helpers.assert_true(tostring(successor.arguments[2]):find("%-%-port 4567") ~= nil)
			mark_ready(successor)
			helpers.assert_eq(c_successes, 1)
		end)
	end)

	helpers.it("(HS-008-stop-supersedes-replacement) cancels B for every stop intent", function()
		for _, kind in ipairs({ "stop", "backend", "port", "shutdown" }) do
			with_server_fixture("self", function(fixture)
				local b_cancellations = 0
				local winning_settlements = 0
				fixture.obj.start_server("A", function() end, function() end)
				local predecessor = fixture.server_tasks[1]
				mark_ready(predecessor)

				helpers.assert_eq(fixture.obj.start_server("B", function() end, function()
					b_cancellations = b_cancellations + 1
				end), true)
				helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
					winning_settlements = winning_settlements + 1
					fixture.events[#fixture.events + 1] = kind
					return true
				end, { kind = kind }), true)
				helpers.assert_eq(b_cancellations, 1, kind)
				helpers.assert_eq(predecessor.terminate_calls, 1,
					"all intents must join one predecessor signal")

				predecessor:complete(15)
				helpers.assert_eq(#fixture.server_tasks, 1,
					"a later " .. kind .. " intent must prevent B from launching")
				helpers.assert_eq(winning_settlements, 1)
				helpers.assert_eq(fixture.events[#fixture.events - 1], "cleanup")
				helpers.assert_eq(fixture.events[#fixture.events], kind)
				predecessor:complete(15)
				helpers.assert_eq(winning_settlements, 1)
			end)
		end
	end)

	helpers.it("(HS-008-global-latest-intent) resolves port and backend races globally", function()
		for _, order in ipairs({
			{ first = "port", last = "backend" },
			{ first = "backend", last = "port" },
		}) do
			with_server_fixture("self", function(fixture)
				local settlements = { port = 0, backend = 0 }
				fixture.obj.start_server("A", function() end, function() end)
				local predecessor = fixture.server_tasks[1]
				mark_ready(predecessor)
				local function request(kind)
					return fixture.obj.stop_server_if_needed(function()
						settlements[kind] = settlements[kind] + 1
						return true
					end, { kind = kind })
				end

				helpers.assert_eq(request(order.first), true)
				helpers.assert_eq(request(order.last), true)
				helpers.assert_eq(predecessor.terminate_calls, 1)
				predecessor:complete(15)
				helpers.assert_eq(settlements[order.first], 0,
					"the earlier cross-surface intent cannot publish")
				helpers.assert_eq(settlements[order.last], 1,
					"the globally latest intent must publish exactly once")
			end)
		end
	end)

	helpers.it("(HS-008-adopted-cleanup) proves exact-port absence and retries every refusal", function()
		for _, cleanup_mode in ipairs({ "false", "nil", "throw" }) do
			with_server_fixture({
				cleanup_mode = cleanup_mode,
				probe_body = "adopted",
				probe_model = "fixture/A",
			}, function(fixture)
				fixture.set_port(4567)
				local settlements = 0
				helpers.assert_eq(fixture.obj.start_server("A", function() end, function() end), true)
				helpers.assert_eq(#fixture.server_tasks, 0)
				helpers.assert_eq(fixture.obj._server_lifecycle_owner.phase, "adopted")
				helpers.assert_eq(fixture.obj._server_ready, true)

				helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
					settlements = settlements + 1
					return true
				end, { kind = "shutdown" }), false, cleanup_mode)
				helpers.assert_eq(settlements, 0)
				helpers.assert_eq(fixture.obj._server_lifecycle_owner.phase, "cleanup")
				helpers.assert_not_nil(fixture.obj._server_identity)
				helpers.assert_eq(fixture.obj._server_ready, true,
					"cleanup refusal must retain the adopted readiness identity")
				helpers.assert_true(fixture.cleanup_commands[1]:find("TCP:4567", 1, true) ~= nil)
				helpers.assert_true(fixture.cleanup_commands[1]:find("$remaining", 1, true) ~= nil,
					"the hard kill must be followed by an absence proof")

				fixture.set_cleanup_mode("true")
				helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
					settlements = settlements + 1
					return true
				end, { kind = "shutdown" }), true)
				helpers.assert_eq(settlements, 1)
				helpers.assert_eq(fixture.obj._server_lifecycle_owner, nil)
				helpers.assert_eq(fixture.obj._server_identity, nil)
				helpers.assert_eq(fixture.obj._server_ready, false)
			end)
		end
	end)

	helpers.it("(HS-008-legacy-cleanup) proves absence before a no-task stop callback", function()
		with_server_fixture("self", function(fixture)
			fixture.set_port(5678)
			local settlements = 0
			helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
				helpers.assert_eq(#fixture.cleanup_commands, 1,
					"legacy cleanup must complete before publication")
				settlements = settlements + 1
				return true
			end, { kind = "shutdown" }), true)
			helpers.assert_eq(settlements, 1)
			helpers.assert_true(fixture.cleanup_commands[1]:find("TCP:5678", 1, true) ~= nil)
			helpers.assert_eq(fixture.obj._server_lifecycle_owner, nil)
		end)
	end)

	helpers.it("(HS-008-lsof-status) separates exact absence from an empty lsof error", function()
		with_server_fixture({ cleanup_mode = "empty_lsof_error" }, function(fixture)
			fixture.set_port(6789)
			local settlements = 0
			helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
				settlements = settlements + 1
				return true
			end, { kind = "shutdown" }), false,
				"empty stdout from an operational lsof error is not absence proof")
			helpers.assert_eq(settlements, 0)
			helpers.assert_not_nil(fixture.obj._server_lifecycle_owner,
				"an unproved listener must retain its retryable cleanup owner")
			helpers.assert_true(fixture.cleanup_commands[1]:find("/usr/sbin/lsof -Q", 1, true) == nil,
				"Apple's bundled lsof 4.91 does not support -Q")
			helpers.assert_true(fixture.cleanup_commands[1]:find(
				"if [ -s \"$err_file\" ]; then return 2; fi", 1, true) ~= nil,
				"a diagnostic-bearing lsof failure must be refused")
		end)

		with_server_fixture({ cleanup_mode = "apple_491_absence" }, function(fixture)
			fixture.set_port(6789)
			local settlements = 0
			helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
				settlements = settlements + 1
				return true
			end, { kind = "shutdown" }), true,
				"Apple lsof status 1 with empty stdout/stderr must prove listener absence")
			helpers.assert_eq(settlements, 1)
			helpers.assert_eq(fixture.obj._server_lifecycle_owner, nil)
		end)
	end)

	helpers.it("(HS-008-native-cleanup-debt) rejects the exact waiter and keeps cleanup retryable", function()
		with_server_fixture({ cleanup_mode = "false" }, function(fixture)
			local first_settlements = 0
			local first_refusals = 0
			local refusal_reason = nil
			local retry_settlements = 0
			fixture.obj.start_server("A", function() end, function() end)
			local predecessor = fixture.server_tasks[1]
			mark_ready(predecessor)
			helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
				first_settlements = first_settlements + 1
				return true
			end, {
				kind = "shutdown",
				on_cancel = function(reason)
					first_refusals = first_refusals + 1
					refusal_reason = reason
					return false
				end,
			}), true)

			predecessor:complete(15)
			helpers.assert_eq(first_settlements, 0)
			helpers.assert_eq(first_refusals, 1,
				"the waiter that owns async shutdown must receive one negative terminal")
			helpers.assert_eq(refusal_reason, "cleanup_refused")
			helpers.assert_eq(fixture.deps.active_tasks["mlx_server"], nil)
			helpers.assert_eq(fixture.obj._server_lifecycle_owner.phase, "cleanup")
			helpers.assert_eq(fixture.obj._server_ready, true)

			fixture.set_cleanup_mode("true")
			helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
				retry_settlements = retry_settlements + 1
				return true
			end, { kind = "backend" }), true)
			helpers.assert_eq(first_settlements, 0,
				"a refused cleanup continuation must lose authority on retry")
			helpers.assert_eq(first_refusals, 1,
				"retry settlement cannot redeliver the prior negative terminal")
			helpers.assert_eq(retry_settlements, 1)
			helpers.assert_eq(fixture.obj._server_lifecycle_owner, nil)
		end)
	end)

	helpers.it("(HS-008-stop-before-bind) reaps Python before publishing wrapper settlement", function()
		with_server_fixture({
			terminate_mode = "sync_self",
			simulate_starting_child = true,
		}, function(fixture)
			local settlements = 0
			fixture.obj.start_server("A", function() end, function() end)
			local predecessor = fixture.server_tasks[1]
			helpers.assert_true(predecessor.child_alive,
				"the fixture must stop during the child-starting window")

			helpers.assert_eq(fixture.obj.stop_server_if_needed(function()
				fixture.events[#fixture.events + 1] = "settled"
				settlements = settlements + 1
				return true
			end, { kind = "shutdown" }), true)
			helpers.assert_eq(settlements, 1)
			helpers.assert_eq(predecessor.child_alive, false,
				"accepted wrapper stop must reap its exact Python child")
			helpers.assert_eq(predecessor:attempt_late_bind(), false,
				"a stopped child cannot bind the MLX port after cleanup proof")
			helpers.assert_eq(fixture.events[#fixture.events - 2], "child-exit",
				"the child must exit before listener cleanup begins")
			helpers.assert_eq(fixture.events[#fixture.events - 1], "cleanup",
				"listener cleanup must run after the child exit")
			helpers.assert_eq(fixture.events[#fixture.events], "settled",
				"settlement must remain the final published event")
			helpers.assert_eq(fixture.obj._server_lifecycle_owner, nil)
		end)
	end)
end)

return true
