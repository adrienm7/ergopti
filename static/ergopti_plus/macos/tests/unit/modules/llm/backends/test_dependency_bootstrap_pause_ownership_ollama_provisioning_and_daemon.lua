--- tests/unit/modules/llm/backends/test_dependency_bootstrap_pause_ownership_ollama_provisioning_and_daemon.lua

--- Behavioral regression for HS-012 dependency bootstrap ownership. The real
--- ScriptControl, TimerScheduler, and TaskLifecycle run over faithful native
--- doubles; the class-wide inventory matrix separately drives both identities
--- through false/nil/throw rollback settlement.

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.llm.backends.dependency_bootstrap_pause_ownership_fixture"] = nil
local Fixture = require("tests.support.modules.llm.backends.dependency_bootstrap_pause_ownership_fixture")
local get_upvalue = Fixture.get_upvalue
local load_fixture = Fixture.load_fixture





helpers.describe("HS-119 Ollama provisioning and daemon verdicts", function()
	helpers.it("keeps dependencies ready when only daemon acquisition refuses", function()
		local fixture = load_fixture({
			backend = "ollama",
			daemon_start_result = false,
		})
		local completions = {}
		helpers.assert_true(fixture.checker.check_and_install_deps(function(ok)
			completions[#completions + 1] = ok
		end))

		fixture.tasks[1]:complete(0, "", "")

		helpers.assert_eq(fixture.daemon_calls, 1)
		helpers.assert_eq(fixture.checker.get_state(), "ready",
			"successful provisioning must not be poisoned by daemon acquisition")
		helpers.assert_true(fixture.checker.is_ready())
		helpers.assert_eq(fixture.checker.has_failed(), false)
		helpers.assert_eq(fixture.checker.get_failure_message(), nil)
		helpers.assert_eq(fixture.checker.get_daemon_state(), "failed")
		helpers.assert_eq(fixture.checker.is_daemon_ready(), false)
		helpers.assert_true(fixture.checker.has_daemon_failed())
		helpers.assert_true(type(fixture.checker.get_daemon_failure_message()) == "string"
			and fixture.checker.get_daemon_failure_message() ~= "")
		helpers.assert_eq(#completions, 1)
		helpers.assert_eq(completions[1], false,
			"the overall bootstrap callback still reports the unusable daemon")
	end)

	helpers.it("classifies a throwing daemon acquisition in the daemon domain", function()
		local fixture = load_fixture({
			backend = "ollama",
			daemon_start_throw = true,
		})
		local completions = {}
		helpers.assert_true(fixture.checker.check_and_install_deps(function(ok)
			completions[#completions + 1] = ok
		end))

		fixture.tasks[1]:complete(0, "", "")

		helpers.assert_eq(fixture.checker.get_state(), "ready")
		helpers.assert_eq(fixture.checker.has_failed(), false)
		helpers.assert_eq(fixture.checker.get_daemon_state(), "failed")
		helpers.assert_true(fixture.checker.has_daemon_failed())
		helpers.assert_eq(#completions, 1)
		helpers.assert_eq(completions[1], false)
	end)

	helpers.it("reports successful provisioning and daemon acquisition independently", function()
		local fixture = load_fixture({ backend = "ollama" })
		helpers.assert_true(fixture.checker.check_and_install_deps())

		fixture.tasks[1]:complete(0, "", "")

		helpers.assert_eq(fixture.checker.get_state(), "ready")
		helpers.assert_true(fixture.checker.is_ready())
		helpers.assert_eq(fixture.checker.get_failure_message(), nil)
		helpers.assert_eq(fixture.checker.get_daemon_state(), "ready")
		helpers.assert_true(fixture.checker.is_daemon_ready())
		helpers.assert_eq(fixture.checker.has_daemon_failed(), false)
		helpers.assert_eq(fixture.checker.get_daemon_failure_message(), nil)
	end)

	helpers.it("keeps daemon verdict pending when dependency provisioning fails", function()
		local fixture = load_fixture({ backend = "ollama" })
		helpers.assert_true(fixture.checker.check_and_install_deps())

		fixture.tasks[1]:complete(1, "", "dependency failure")

		helpers.assert_eq(fixture.checker.get_state(), "failed")
		helpers.assert_true(fixture.checker.has_failed())
		helpers.assert_true(type(fixture.checker.get_failure_message()) == "string")
		helpers.assert_eq(fixture.checker.get_daemon_state(), "pending")
		helpers.assert_eq(fixture.checker.is_daemon_ready(), false)
		helpers.assert_eq(fixture.checker.has_daemon_failed(), false)
		helpers.assert_eq(fixture.checker.get_daemon_failure_message(), nil)
	end)
end)

helpers.describe("HS-115 pre-commit callback obligations", function()
	for _, stage in ipairs({ "path", "pty" }) do
		helpers.it("settles the registered MLX callback when PAUSE supersedes " .. stage
			.. " preflight", function()
			local fixture = load_fixture({
				backend = "mlx",
				stale_preflight_stage = stage,
			})
			local completions = {}
			local accepted = fixture.checker.check_and_install_deps(function(ok)
				completions[#completions + 1] = ok
			end)

			helpers.assert_eq(accepted, false,
				"a superseded pre-commit intent never claims dispatch")
			helpers.assert_true(fixture.preflight_pause_result,
				"the injected PAUSE must settle before the stale check")
			helpers.assert_eq(#completions, 1,
				"an already registered waiter remains a terminal obligation")
			helpers.assert_eq(completions[1], false)
			helpers.assert_eq(#fixture.tasks, 0,
				"no native child may start after the preflight intent is superseded")
			helpers.assert_eq(fixture.checker.get_state(), "pending")
			if stage == "path" then
				helpers.assert_eq(fixture.pty_create_calls, 0)
			else
				helpers.assert_eq(fixture.pty_create_calls, 1)
				helpers.assert_eq(fixture.pty_remove_calls, 1,
					"the prepared wrapper must be removed before returning")
			end
		end)
	end
end)

helpers.describe("HS-113 dependency bootstrap deadline", function()
	for _, backend in ipairs({ "ollama", "mlx" }) do
		helpers.it(backend .. " fails a never-completing bootstrap at the owned deadline", function()
			local fixture = load_fixture({ backend = backend })
			local completions = {}
			local accepted = fixture.checker.check_and_install_deps(function(ok)
				completions[#completions + 1] = ok
			end)

			helpers.assert_true(accepted)
			helpers.assert_eq(#fixture.tasks, 1)
			helpers.assert_eq(#fixture.timers, 1,
				"every committed bootstrap task must own one deadline")
			helpers.assert_eq(fixture.timers[1].delay, 1800,
				"the deadline must use the shared 30-minute bootstrap ceiling")
			helpers.assert_eq(fixture.checker.get_state(), "pending")

			fixture.timers[1]:fire()

			helpers.assert_eq(fixture.tasks[1].terminate_calls, 1,
				"deadline expiry must terminate the exact task once")
			helpers.assert_eq(fixture.checker.get_state(), "failed")
			helpers.assert_true(type(fixture.checker.get_failure_message()) == "string"
				and fixture.checker.get_failure_message() ~= "",
				"deadline expiry must publish a visible failure reason")
			helpers.assert_eq(#completions, 1)
			helpers.assert_eq(completions[1], false)

			fixture.tasks[1]:complete(143, "", "late timeout settlement")
			helpers.assert_eq(fixture.checker.get_state(), "failed",
				"late native settlement cannot reverse the timeout outcome")
			helpers.assert_eq(#completions, 1)
		end)

		helpers.it(backend .. " cancels its deadline before publishing normal completion", function()
			local fixture = load_fixture({ backend = backend })
			helpers.assert_true(fixture.checker.check_and_install_deps())
			helpers.assert_eq(#fixture.timers, 1)
			local deadline = fixture.timers[1]

			fixture.tasks[1]:complete(0, "", "")

			helpers.assert_eq(deadline.running_state, false)
			helpers.assert_eq(deadline.stop_calls, 1,
				"normal completion must cancel the exact deadline once")
			helpers.assert_eq(fixture.checker.get_state(), "ready")
			deadline.callback()
			helpers.assert_eq(fixture.tasks[1].terminate_calls, 0)
			helpers.assert_eq(fixture.checker.get_state(), "ready",
				"a stale deadline callback must remain inert")
		end)

		helpers.it(backend .. " withholds success until deadline cancellation settles", function()
			local fixture = load_fixture({
				backend = backend,
				timer_stop_mode = "false",
			})
			helpers.assert_true(fixture.checker.check_and_install_deps())
			fixture.tasks[1]:complete(0, "", "")
			helpers.assert_eq(fixture.checker.get_state(), "pending",
				"a live deadline can still fire and must fence business success")
			helpers.assert_true(fixture.timers[1].running_state)

			fixture.timer_stop_mode = "true"
			helpers.assert_true(require("adapters.timer_scheduler").retryCleanup())
			helpers.assert_eq(fixture.checker.get_state(), "ready",
				"exact timer settlement must resume the retained terminal outcome")
			helpers.assert_eq(fixture.tasks[1].terminate_calls, 0)
		end)

		helpers.it(backend .. " never starts without a committed deadline", function()
			local fixture = load_fixture({
				backend = backend,
				timer_start_mode = "false",
			})
			helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
			helpers.assert_eq(#fixture.tasks, 1,
				"the task may be prepared before deadline acquisition")
			helpers.assert_eq(fixture.tasks[1].start_calls, 0,
				"the native subprocess boundary must remain untouched")
			helpers.assert_eq(fixture.checker.get_state(), "failed")
		end)
	end
end)

helpers.describe("HS-012 dependency-to-daemon pause handoff", function()
	helpers.it("quiesces ApiOllama when PAUSE re-enters its real checker handoff", function()
		local fixture = load_fixture({
			real_script_control = true,
			pause_on_daemon_start = true,
		})
		helpers.assert_true(fixture.checker.check_and_install_deps())
		fixture.tasks[1]:complete(0, "", "")
		helpers.assert_true(fixture.pause_on_daemon_start_result)
		helpers.assert_true(fixture.control.is_paused())
		helpers.assert_eq(fixture.daemon_calls, 1)
		helpers.assert_eq(fixture.daemon_live, false)
		helpers.assert_true(fixture.checker.is_ready(),
			"the completed provisioning verdict survives daemon PAUSE")
		helpers.assert_eq(fixture.checker.get_daemon_state(), "pending")
		helpers.assert_eq(fixture.checker.is_daemon_ready(), false)
		helpers.assert_true(fixture.control.stop())
	end)
end)

helpers.describe("HS-012 dependency bootstrap backend isolation", function()
	helpers.it("declares two distinct registered child owners", function()
		local mlx_source = helpers.read_driver_source(
			"owner_name = \"mlx_dependency_bootstrap\"")
		local ollama_source = helpers.read_driver_source(
			"owner_name = \"ollama_dependency_bootstrap\"")
		helpers.assert_not_nil(mlx_source)
		helpers.assert_not_nil(ollama_source)
		helpers.assert_true(mlx_source:find("ollama_dependency_bootstrap", 1, true) == nil)
		helpers.assert_true(ollama_source:find("mlx_dependency_bootstrap", 1, true) == nil)
	end)
end)

helpers.describe("Native official Ollama bootstrap receipt join", function()
	local function with_native_fixture(options, callback)
		helpers.with_stub_scope({ "adapters.native_bootstrap_pty", "adapters.python_interpreter" }, function()
			local fixture = load_fixture(options)
			local python = get_upvalue(fixture.check_impl, "PythonInterpreter")
			helpers.assert_not_nil(python)
			python.resolve = function() return nil, { reason = "none_native" } end
			python.native_arch = function() return "arm64" end
			python.native_candidates = function() return {} end
			fixture.native_ready = false
			fixture.native_settle_calls = 0
			fixture.native_marked = false
			package.loaded["adapters.native_bootstrap_pty"] = {
				prepare = function(path, environment, budget)
					fixture.native_source, fixture.native_environment, fixture.native_budget = path, environment, budget
					return {
						executable = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus",
						arguments = { "--managed-pty-worker", "1800000" },
						bind_input = function(task) fixture.native_bound = task; return true end,
						mark_start_attempted = function() fixture.native_marked = true; return true end,
						rollback = function() fixture.native_rolled_back = true; return true end,
						settle = function(code)
							fixture.native_settle_calls = fixture.native_settle_calls + 1
							fixture.native_code = code
							return fixture.native_ready
						end,
					}, true
				end,
			}
			callback(fixture)
		end)
	end

	helpers.it("emits the exact existing official source and private argv equivalents without Python", function()
		with_native_fixture({}, function(fixture)
			helpers.assert_true(fixture.checker.check_and_install_deps())
			helpers.assert_eq(fixture.native_source, "/repo/static/ergopti_plus/macos/modules/llm/ensure-ollama-deps.sh")
			local environment = {}
			for _, pair in ipairs(fixture.native_environment) do environment[pair[1]] = pair[2] end
			helpers.assert_eq(#fixture.native_environment, 6)
			helpers.assert_eq(environment.PROJECT_ROOT, "/repo/static/ergopti_plus/macos")
			helpers.assert_eq(environment.ERGOPTI_NATIVE_ARCH, "arm64")
			helpers.assert_eq(environment.ERGOPTI_BOOTSTRAP_OLLAMA_RESOLVED_BIN, "/fixture/ollama")
			helpers.assert_eq(environment.ERGOPTI_BOOTSTRAP_OLLAMA_INSTALL_DIR, "")
			helpers.assert_eq(environment.ERGOPTI_BOOTSTRAP_PYTHON, "")
			helpers.assert_eq(fixture.native_bound, fixture.tasks[1])
			helpers.assert_true(fixture.native_marked)
			helpers.assert_eq(fixture.tasks[1].args[1], "--managed-pty-worker")
			helpers.assert_eq(fixture.native_budget, 1800000)
			fixture.native_ready = true
			fixture.tasks[1]:complete(0)
			helpers.assert_eq(fixture.native_code, 0)
			helpers.assert_eq(fixture.daemon_calls, 1)
		end)
	end)

	helpers.it("retains callback-only success and retries its exact receipt during pause", function()
		with_native_fixture({}, function(fixture)
			helpers.assert_true(fixture.checker.check_and_install_deps())
			fixture.tasks[1]:complete(0)
			helpers.assert_eq(fixture.checker.provisioning_idle(), false)
			helpers.assert_eq(fixture.daemon_calls, 0)
			helpers.assert_eq(fixture.owner.pause(), false)
			helpers.assert_eq(#fixture.tasks, 1)
			fixture.native_ready = true
			helpers.assert_eq(fixture.owner.pause(), true)
			helpers.assert_eq(fixture.checker.provisioning_idle(), true)
			helpers.assert_eq(fixture.daemon_calls, 0, "a stale callback must not start a daemon after receipt recovery")
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains native receipt debt after original start " .. mode, function()
			with_native_fixture({ start_mode = mode }, function(fixture)
				helpers.assert_eq(fixture.checker.check_and_install_deps(), false)
				helpers.assert_true(fixture.native_marked)
				helpers.assert_eq(fixture.checker.provisioning_idle(), false)
				fixture.tasks[1]:complete(143)
				helpers.assert_eq(fixture.checker.provisioning_idle(), false)
				fixture.native_ready = true
				helpers.assert_eq(fixture.owner.pause(), true)
				helpers.assert_eq(fixture.checker.provisioning_idle(), true)
				helpers.assert_eq(fixture.daemon_calls, 0)
			end)
		end)
	end
end)

helpers.describe("Native migration caller context fences", function()
	local function receiving(stage, callback)
		helpers.with_stub_scope({ "adapters.managed_ollama_bootstrap" }, function()
			local fixture = load_fixture({})
			local binary = package.loaded["modules.llm.ollama_binary"]
			binary.resolve = function() return "/fixture/ollama", nil, "app" end
			binary.native_managed_install_dir = function() return "/fixture/native" end
			fixture.context_current, fixture.native_ready = true, false
			fixture.context_binds, fixture.input_binds, fixture.rollbacks = 0, 0, 0
			fixture.native_marked = false
			local function interrupt(at)
				if stage == at then fixture.context_current = false end
			end
			local owner = {
				executable = "/fixture/signed-helper", arguments = { "--managed-pty-worker", "1800000" },
				bind_input = function(task)
					fixture.input_binds = fixture.input_binds + 1
					fixture.native_task = task
					interrupt("input")
					return true
				end,
				mark_start_attempted = function()
					fixture.native_marked = true
					interrupt("marker")
					return true
				end,
				rollback = function()
					fixture.rollbacks = fixture.rollbacks + 1
					return not fixture.native_marked and (stage ~= "prepare_refusal" or fixture.cleanup_ready == true)
				end,
				settle = function() return fixture.native_ready end,
			}
			local context = {
				is_current = function() return fixture.context_current end,
				bind_environment = function(task)
					fixture.context_binds = fixture.context_binds + 1
					fixture.context_task = task
					interrupt("environment")
					return true
				end,
			}
			package.loaded["adapters.managed_ollama_bootstrap"] = {
				prepare = function()
					interrupt("prepare")
					return owner, stage ~= "prepare_refusal", context
				end,
			}
			local lifecycle = package.loaded["adapters.task_lifecycle"]
			local native, start = lifecycle.native, lifecycle.start
			lifecycle.native = function(...)
				local task = native(...)
				interrupt("construct")
				return task
			end
			lifecycle.start = function(...)
				local accepted = start(...)
				interrupt("start")
				return accepted
			end
			fixture.timer_start_hook = function() interrupt("timer") end
			local ok, failure = xpcall(callback, debug.traceback, fixture)
			lifecycle.native, lifecycle.start = native, start
			if not ok then error(failure, 0) end
		end)
	end

	local function install(fixture)
		return fixture.checker.install_native_for_selection({}, "/fixture/ollama", "app", "/fixture/native", nil)
	end

	for _, stage in ipairs({ "prepare", "construct", "environment", "input", "timer" }) do
		helpers.it("(native-caller-context) refuses stale " .. stage .. " before original native start", function()
			receiving(stage, function(fixture)
				helpers.assert_eq(install(fixture), false)
				for _, task in ipairs(fixture.tasks) do helpers.assert_eq(task.start_calls, 0) end
				helpers.assert_eq(fixture.native_marked, false)
				helpers.assert_true(fixture.rollbacks >= 1)
				helpers.assert_true(fixture.checker.provisioning_idle())
			end)
		end)
	end


	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("(native-caller-deadline-debt) retains exact committed timer after stop " .. mode, function()
			receiving("timer", function(fixture)
				fixture.timer_stop_mode = mode
				helpers.assert_eq(install(fixture), false)
				helpers.assert_eq(#fixture.tasks, 1)
				helpers.assert_eq(fixture.tasks[1].start_calls, 0)
				helpers.assert_eq(fixture.native_marked, false)
				helpers.assert_true(fixture.rollbacks >= 1)
				local original = fixture.timers[#fixture.timers]
				helpers.assert_eq(original.delay, 1800)
				helpers.assert_true(original.stop_calls >= 1,
					"currency withdrawal must attempt the exact already committed deadline")
				helpers.assert_true(original.running_state)
				helpers.assert_eq(fixture.checker.provisioning_idle(), false)
				local calls, timers = original.stop_calls, #fixture.timers
				helpers.assert_eq(fixture.checker.provisioning_idle(), false)
				helpers.assert_eq(original.stop_calls, calls, "read-only admission cannot retry timer cleanup")
				helpers.assert_eq(#fixture.timers, timers)
				helpers.assert_eq(fixture.owner.pause(), false)
				fixture.timer_stop_mode = "true"
				helpers.assert_eq(fixture.owner.pause(), true)
				helpers.assert_eq(original.running_state, false)
				helpers.assert_true(fixture.checker.provisioning_idle())
				helpers.assert_eq(#fixture.timers, timers, "original pause retires the same deadline")
			end)
		end)
	end

	helpers.it("(native-caller-marker-debt) cannot erase original owners after a failed post-marker fence", function()
		receiving("marker", function(fixture)
			helpers.assert_eq(install(fixture), false)
			helpers.assert_true(fixture.native_marked)
			helpers.assert_eq(fixture.tasks[1].start_calls, 0)
			helpers.assert_eq(fixture.checker.provisioning_idle(), false)
			helpers.assert_eq(fixture.checker.install_native_for_selection({}, "/fixture/ollama", "app", "/fixture/native", nil), false)
			fixture.native_ready = true
			fixture.tasks[1]:complete(78)
			helpers.assert_true(fixture.checker.provisioning_idle())
			helpers.assert_eq(fixture.daemon_calls, 0)
		end)
	end)

	helpers.it("(native-caller-start-debt) source replacement after start cannot commit or free exact child debt", function()
		receiving("start", function(fixture)
			helpers.assert_eq(install(fixture), false)
			helpers.assert_eq(fixture.tasks[1].start_calls, 1)
			helpers.assert_eq(fixture.tasks[1].terminate_calls, 1)
			helpers.assert_eq(fixture.checker.provisioning_idle(), false)
			fixture.native_ready = true
			fixture.tasks[1]:complete(143)
			helpers.assert_true(fixture.checker.provisioning_idle())
			helpers.assert_eq(fixture.daemon_calls, 0)
		end)
	end)
	helpers.it("(native-caller-preflight-debt) read-only admission refuses exact partial preparation cleanup debt", function()
		receiving("prepare_refusal", function(fixture)
			helpers.assert_eq(install(fixture), false)
			helpers.assert_eq(#fixture.tasks, 0)
			helpers.assert_eq(fixture.native_marked, false)
			helpers.assert_eq(fixture.checker.provisioning_idle(), false)
			local attempts = fixture.rollbacks
			helpers.assert_eq(install(fixture), false)
			helpers.assert_eq(fixture.rollbacks, attempts, "idle refusal never retries native owner cleanup")
			helpers.assert_eq(fixture.owner.pause(), false)
			fixture.cleanup_ready = true
			helpers.assert_true(fixture.owner.pause())
			helpers.assert_true(fixture.checker.provisioning_idle())
		end)
	end)

end)

helpers.describe("Official installation remains available without native daemon authority", function()
	helpers.it("(ollama-official-client-install) completes an explicitly chosen stock download as client provisioning", function()
		local fixture = load_fixture({})
		local binary = package.loaded["modules.llm.ollama_binary"]
		binary.resolve = function() return nil, "not installed", nil end
		binary.managed_install_dir = function() return "/fixture/official" end
		local completions = {}
		helpers.assert_true(fixture.checker.install_for_selection(function(value) completions[#completions + 1] = value end))
		helpers.assert_eq(#fixture.tasks, 1)
		helpers.assert_eq(fixture.tasks[1].start_calls, 1)
		fixture.tasks[1]:complete(0)
		helpers.assert_eq(fixture.daemon_calls, 0, "successful stock installation never acquires foreign daemon authority")
		helpers.assert_true(fixture.checker.is_ready())
		helpers.assert_eq(fixture.checker.get_daemon_state(), "pending")
		helpers.assert_eq(#completions, 1)
		helpers.assert_true(completions[1])
	end)
end)

helpers.describe("Ollama asynchronous provisioning window currency", function()
	for _, boundary in ipairs({ "unchanged", "inactive", "replacement", "active-query", "session-query", "epoch-query" }) do
		helpers.it("refences final provisioning UI at " .. boundary, function()
			local fixture = load_fixture({ defer_daemon_ready = true })
			local completions = {}
			helpers.assert_true(fixture.checker.check_and_install_deps(function(value)
				completions[#completions + 1] = value
			end))
			local marker = "OLLAMA_INSTALLING\n"
			fixture.tasks[1]:chunk(marker, "")
			helpers.assert_true(fixture.ui_active)
			fixture.tasks[1]:complete(0, marker, "")
			helpers.assert_eq(fixture.daemon_calls, 1)
			helpers.assert_eq(#completions, 0, "start acceptance is not the final daemon observation")
			helpers.assert_eq(type(fixture.daemon_transaction.on_settled), "function")
			local writes, hides, timers = fixture.ui_calls, fixture.ui_hide_calls, #fixture.timers
			local function revoke()
				fixture.active_query_hook, fixture.session_query_hook, fixture.epoch_query_hook = nil, nil, nil
				fixture.epoch = fixture.epoch + 1
				fixture.transition = true
				helpers.assert_true(fixture.owner.pause())
				fixture.transition = false
				fixture.paused = true
			end
			if boundary == "inactive" then fixture.ui_active = false
			elseif boundary == "replacement" then fixture.ui_session = fixture.ui_session + 1
			elseif boundary == "active-query" then fixture.active_query_hook = revoke
			elseif boundary == "session-query" then fixture.session_query_hook = revoke
			elseif boundary == "epoch-query" then fixture.epoch_query_hook = revoke end
			fixture.daemon_transaction.on_settled(true)
			if boundary == "unchanged" then
				helpers.assert_true(fixture.ui_calls > writes, "the exact original active window receives completion")
				helpers.assert_eq(#fixture.timers, timers + 1, "only the original auto-hide is acquired")
				helpers.assert_eq(#completions, 1)
				helpers.assert_true(completions[1])
				helpers.assert_true(fixture.checker.is_daemon_ready())
			else
				helpers.assert_eq(fixture.ui_calls, writes, "stale completion cannot write or hide a successor window")
				helpers.assert_eq(fixture.ui_hide_calls, hides)
				helpers.assert_eq(#fixture.timers, timers, "refusal cannot acquire a hide timer")
				if boundary == "inactive" or boundary == "replacement" then
					helpers.assert_eq(#completions, 1, "UI replacement does not revoke the current daemon verdict")
					helpers.assert_true(completions[1])
				else
					helpers.assert_eq(#completions, 0, "revoked task authority cannot deliver a successful completion")
				end
			end
			helpers.assert_eq(#fixture.tasks, 1, "completion cannot create a bootstrap successor")
		end)
	end
end)
