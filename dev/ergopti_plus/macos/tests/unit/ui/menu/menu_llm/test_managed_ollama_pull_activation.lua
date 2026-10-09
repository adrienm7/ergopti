--- tests/unit/ui/menu/menu_llm/test_managed_ollama_pull_activation.lua

--- ==============================================================================
--- MODULE: Managed Ollama Original Pull Activation Regression
--- DESCRIPTION:
--- Exercises the production manager's direct dispatch and retained preparation
--- ownership through controlled ports. This is not native source or SDK evidence.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.ollama_pull_fixture").with_fixture
local OWNED = "/fixture/owned-runtime"
local PYTHON = "/fixture/native-python"
local ARGUMENTS = { "-I", "/fixture/managed_ollama_pull.py", "--maximum-bytes", "4096" }

local function with_activation(options, callback)
	options = options or {}
	local names = { "adapters.managed_ollama_pull", "modules.llm.managed_native_python", "modules.llm.ollama_endpoint",
		"adapters.task_environment", "infra.launcher_environment" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local handle, bound, attempted, removed, fixture = nil, nil, false, false, nil
	local calls = { prepare = 0, bind = 0, mark = 0, rollback = 0, retire = {}, opaque = 0 }
	local rollback_ready = options.rollback_ready ~= false
	local rollback_hook
	local adapter = {
		handles = function(bin) return bin == (options.owned_path or OWNED) end,
		prepare_owned = function(model, port, python)
			calls.prepare = calls.prepare + 1
			helpers.assert_eq(model, options.repo or "registry/model:tiny")
			calls.model = model
			helpers.assert_eq(port, 12345)
			helpers.assert_eq(python, PYTHON)
			local lifecycle = package.loaded["adapters.task_lifecycle"]
			local native = lifecycle.native
			lifecycle.native = function(...)
				if options.construct_throw then error("controlled construction refusal") end
				local task = native(...)
				if task then
					local start = task.start
					function task:start()
						helpers.assert_eq(bound, self, "private input must precede dispatch")
						helpers.assert_true(attempted, "the original owner must mark dispatch")
						return start(self)
					end
				end
				return task
			end
			handle = { executable = PYTHON, arguments = ARGUMENTS }
			function handle.bind_input(task)
				calls.bind = calls.bind + 1
				helpers.assert_eq(fixture.active_tasks.ollama_pull, task, "pin task before private input")
				bound = task
				if options.bind_throw then error("controlled input refusal") end
				return options.bind_ready ~= false
			end
			function handle.rollback()
				calls.rollback = calls.rollback + 1
				if rollback_hook then local hook = rollback_hook; rollback_hook = nil; hook() end
				helpers.assert_eq(attempted, false, "attempted dispatch cannot use rollback")
				if not rollback_ready then return false end
				removed = true
				return true
			end
			return handle, options.prepared ~= false
		end,
		mark_start_attempted = function(task)
			calls.mark = calls.mark + 1
			if task == bound then attempted = true end
			return true
		end,
		rollback = function() return removed end,
		retire = function(task, code)
			calls.retire[#calls.retire + 1] = { task, code }
			return options.retired == true
		end,
	}
	package.loaded[names[1]] = adapter
	package.loaded[names[2]] = { resolve = function() if options.python_missing then return nil end; return PYTHON end }
	package.loaded[names[3]] = { get_port = function() return 12345 end }
	options.binary_path = options.stock and "/fixture/stock-runtime" or options.owned_path or OWNED
	options.network_env = { opaque_prelude = function() calls.opaque = calls.opaque + 1; return "fixture opaque; " end }
	local ok, error_value = xpcall(function()
		with_fixture(options, function(f)
			local binary = package.loaded["modules.llm.ollama_binary"]
			binary.SOURCE_NATIVE_MANAGED = "native_managed"
			binary.resolve = function()
				return options.binary_path, nil, options.binary_source
					or (options.stock and "path" or binary.SOURCE_NATIVE_MANAGED)
			end
			fixture = f
			f.calls = calls
			f.rollback_ready = function() rollback_ready = true end
			f.handle = function() return handle end
			f.rollback_hook = function(hook) rollback_hook = hook end
			f.start = function()
				return f.manager.pull_model(options.target_model or "owned/model:tiny",
					options.repo or "registry/model:tiny", function() return true end,
					function(reason) f.cancel_reason = reason; return true end,
					{ is_current = function() return true end, _requirement_lifecycle = options.requirement_lifecycle })
			end
			if options.native_port then
				local lifecycle = package.loaded["adapters.task_lifecycle"]
				f.native_calls = { construct = 0, start = 0, terminate = 0 }
				_G.hs.task = { new = function(executable, on_done, on_stream, arguments)
					f.native_calls.construct = f.native_calls.construct + 1
					if options.native_port == "construct_nil" then return nil end
					if options.native_port == "construct_throw" then error("native constructor raised") end
					local environment = { PATH = "/usr/bin:/bin", ERGOPTI_LOG_TOKEN = "fixture-only" }
					local task = { executable = executable, args = arguments,
						on_done = on_done, on_stream = on_stream, running = false }
					function task:environment() return environment end
					function task:setEnvironment(value) environment = value; return self end
					function task:start()
						f.native_calls.start = f.native_calls.start + 1
						helpers.assert_eq(f.active_tasks.ollama_pull, self)
						helpers.assert_nil(environment.ERGOPTI_LOG_TOKEN)
						self.running = true
						if options.native_port == "start_throw" then error("native dispatch raised after acquisition") end
						return false
					end
					function task:isRunning() return self.running end
					function task:terminate()
						f.native_calls.terminate = f.native_calls.terminate + 1
						return false
					end
					f.pulls[#f.pulls + 1] = task
					return task
				end }
				local actual = helpers.with_fresh_modules({ "adapters.task_lifecycle" }, function()
					return require("adapters.task_lifecycle")
				end)
				for _, name in ipairs({ "native", "start", "terminate" }) do lifecycle[name] = actual[name] end
				f.retirement_ready = function() options.retired = true end
			end
			callback(f)
		end)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(error_value, 0) end
end

helpers.describe("Managed Ollama original pull activation", function()
	helpers.it("uses direct native Python arguments and binds input before one original start mark", function()
		with_activation({}, function(f)
			helpers.assert_true(f.start())
			helpers.assert_eq(f.calls.prepare, 1)
			helpers.assert_eq(f.calls.bind, 1)
			helpers.assert_eq(f.calls.mark, 1)
			helpers.assert_eq(f.calls.opaque, 0)
			helpers.assert_eq(f.pulls[1].executable, PYTHON)
			helpers.assert_eq(f.pulls[1].args, ARGUMENTS)
		end)
	end)

	helpers.it("preserves the stock opaque shell pull without managed preparation", function()
		with_activation({ stock = true }, function(f)
			helpers.assert_true(f.start())
			helpers.assert_eq(f.calls.prepare, 0)
			helpers.assert_eq(f.calls.bind, 0)
			helpers.assert_eq(f.calls.opaque, 1)
			helpers.assert_eq(f.pulls[1].executable, "/bin/bash")
			helpers.assert_eq(f.pulls[1].args[1], "-c")
			helpers.assert_true(f.pulls[1].args[2]:find("fixture opaque; exec", 1, true) ~= nil)
			helpers.assert_true(f.pulls[1].args[2]:find("registry/model:tiny", 1, true) ~= nil)
		end)
	end)

	helpers.it("refuses unavailable native Python without constructing a task or falling back", function()
		with_activation({ python_missing = true }, function(f)
			helpers.assert_eq(f.start(), false)
			helpers.assert_eq(#f.pulls, 0)
			helpers.assert_eq(f.calls.prepare, 0)
			helpers.assert_eq(f.calls.opaque, 0)
			helpers.assert_eq(f.cancel_reason, "native_interpreter_unavailable")
		end)
	end)

	helpers.it("retains partial preparation debt in the original admission slot until exact rollback", function()
		with_activation({ prepared = false, rollback_ready = false }, function(f)
			helpers.assert_eq(f.start(), false)
			local owner = f.active_tasks.ollama_pull
			helpers.assert_type(owner, "table")
			helpers.assert_eq(#f.pulls, 0)
			helpers.assert_eq(f.start(), false)
			helpers.assert_eq(f.calls.prepare, 1)
			helpers.assert_eq(f.manager.cleanup_pending_pull(owner), false)
			f.rollback_ready()
			helpers.assert_true(f.manager.cleanup_pending_pull(owner))
			helpers.assert_nil(f.active_tasks.ollama_pull)
			helpers.assert_eq(f.calls.mark, 0)
		end)
	end)

	helpers.it("registers partial preparation debt with the original requirement pause owner", function()
		local adopted, settled = nil, 0
		local lifecycle = {
			adopt = function(owner, join) adopted = { owner = owner, join = join }; return true end,
			settle = function(owner) helpers.assert_true(owner == adopted.owner); settled = settled + 1 end,
		}
		with_activation({ prepared = false, rollback_ready = false, requirement_lifecycle = lifecycle }, function(f)
			helpers.assert_eq(f.start(), false)
			helpers.assert_true(adopted.owner == f.active_tasks.ollama_pull)
			helpers.assert_eq(adopted.join(), false)
			helpers.assert_eq(settled, 0)
			f.rollback_ready()
			helpers.assert_true(adopted.join())
			helpers.assert_eq(settled, 1)
			helpers.assert_nil(f.active_tasks.ollama_pull)
		end)
	end)

	helpers.it("fences reentrant preparation rollback without releasing a pending owner", function()
		with_activation({ prepared = false, rollback_ready = false }, function(f)
			helpers.assert_eq(f.start(), false)
			local owner = f.active_tasks.ollama_pull
			f.rollback_hook(function()
				helpers.assert_eq(f.manager.cleanup_pending_pull(owner), false)
				helpers.assert_true(f.active_tasks.ollama_pull == owner)
			end)
			f.rollback_ready()
			helpers.assert_true(f.manager.cleanup_pending_pull(owner))
			helpers.assert_nil(f.active_tasks.ollama_pull)
		end)
	end)

	helpers.it("retains preparation when native task construction raises", function()
		with_activation({ construct_throw = true, rollback_ready = false }, function(f)
			helpers.assert_eq(f.start(), false)
			local owner = f.active_tasks.ollama_pull
			helpers.assert_type(owner, "table")
			helpers.assert_eq(f.cancel_reason, "task_construction_failed")
			f.rollback_ready()
			helpers.assert_true(f.manager.cleanup_pending_pull(owner))
			helpers.assert_nil(f.active_tasks.ollama_pull)
		end)
	end)

	for _, failure in ipairs({ "bind_ready", "bind_throw" }) do
		helpers.it("retains exact undispatched task on input refusal: " .. failure, function()
			with_activation({ [failure] = failure == "bind_throw", rollback_ready = false }, function(f)
				helpers.assert_eq(f.start(), false)
				local task = f.pulls[1]
				helpers.assert_eq(f.active_tasks.ollama_pull, task)
				helpers.assert_eq(f.calls.mark, 0)
				helpers.assert_eq(task.running, false)
				helpers.assert_eq(f.manager.cleanup_pending_pull(task), false)
				f.rollback_ready()
				helpers.assert_true(f.manager.cleanup_pending_pull(task))
				helpers.assert_nil(f.active_tasks.ollama_pull)
			end)
		end)
	end

	helpers.it("passes the actual original callback status to retirement and retains missing ACK", function()
		with_activation({}, function(f)
			helpers.assert_true(f.start())
			local task = f.pulls[1]
			task.running = false
			task.on_done(78)
			helpers.assert_eq(f.calls.retire[1][1], task)
			helpers.assert_eq(f.calls.retire[1][2], 78)
			helpers.assert_eq(f.active_tasks.ollama_pull, task)
			helpers.assert_nil(f.http_callback())
			helpers.assert_eq(f.start(), false)
		end)
	end)
	helpers.it("downloads the catalogue registry tag while retaining the different presentation name", function()
		local file = assert(io.open(helpers.shared("modules/llm/models.json"), "rb"))
		local bytes = file:read("*a")
		helpers.assert_true(file:close())
		local catalogue = require("json").decode(bytes)
		local known = nil
		for _, provider in ipairs(catalogue) do
			for _, family in ipairs(provider.families) do
				for _, model in ipairs(family.models) do
					if model.name == "Qwen3-Coder-30B-A3B-Instruct" then known = model end
				end
			end
		end
		helpers.assert_type(known, "table", "independent current catalogue vector must exist")
		helpers.assert_eq(known.urls.ollama, "https://ollama.com/library/qwen3-coder:30b")
		with_activation({ target_model = "Qwen3-Coder-30B-A3B-Instruct", repo = "qwen3-coder:30b" }, function(f)
			helpers.assert_true(f.start())
			helpers.assert_eq(f.calls.model, "qwen3-coder:30b")
			helpers.assert_eq(f.calls.bind, 1)
			helpers.assert_eq(f.calls.mark, 1)
			helpers.assert_eq(f.calls.opaque, 0)
		end)
	end)

	helpers.it("keeps the canonical pathname on the stock route without its installed native hint kind", function()
		local canonical = os.getenv("HOME") .. "/Library/Application Support/Ergopti/ollama-native-http/ollama"
		with_activation({ owned_path = canonical, binary_source = "path" }, function(f)
			helpers.assert_true(f.start())
			helpers.assert_eq(f.calls.prepare, 0)
			helpers.assert_eq(f.calls.bind, 0)
			helpers.assert_eq(f.calls.opaque, 1)
			helpers.assert_eq(f.pulls[1].executable, "/bin/bash")
			helpers.assert_eq(f.pulls[1].args[1], "-c")
			helpers.assert_true(f.pulls[1].args[2]:find(canonical, 1, true) ~= nil)
		end)
	end)

	for _, refusal in ipairs({ "construct_nil", "construct_throw" }) do
		helpers.it("retains unattempted preparation through actual native constructor refusal: " .. refusal, function()
			with_activation({ native_port = refusal, rollback_ready = false }, function(f)
				helpers.assert_eq(f.start(), false)
				local owner = f.active_tasks.ollama_pull
				helpers.assert_type(owner, "table")
				helpers.assert_eq(f.native_calls.construct, 1)
				helpers.assert_eq(f.native_calls.start, 0)
				helpers.assert_eq(#f.pulls, 0)
				helpers.assert_eq(f.calls.bind, 0)
				helpers.assert_eq(f.calls.mark, 0)
				helpers.assert_eq(f.cancel_reason, "task_construction_failed")
				helpers.assert_eq(f.manager.cleanup_pending_pull(owner), false)
				f.rollback_ready()
				helpers.assert_true(f.manager.cleanup_pending_pull(owner))
				helpers.assert_nil(f.active_tasks.ollama_pull)
			end)
		end)
	end

	for _, refusal in ipairs({ "start_false", "start_throw" }) do
		helpers.it("retains the exact acquired native task until physical receipt after dispatch refusal: " .. refusal, function()
			with_activation({ native_port = refusal }, function(f)
				helpers.assert_eq(f.start(), false)
				local task = f.pulls[1]
				helpers.assert_eq(f.native_calls.construct, 1)
				helpers.assert_eq(f.native_calls.start, 1)
				helpers.assert_eq(f.calls.bind, 1)
				helpers.assert_eq(f.calls.mark, 1)
				helpers.assert_eq(f.active_tasks.ollama_pull, task)
				helpers.assert_true(task.running)
				helpers.assert_true(f.native_calls.terminate > 0)
				helpers.assert_eq(f.calls.rollback, 0)
				helpers.assert_eq(f.cancel_reason, "termination_refused", "the failed physical termination remains the primary cancellation reason")
				task.running = false
				task.on_done(78, "", "")
				helpers.assert_eq(f.active_tasks.ollama_pull, task, "native completion without receipt retains the exact root")
				helpers.assert_eq(f.calls.retire[1][1], task)
				helpers.assert_eq(f.calls.retire[1][2], 78)
				f.retirement_ready()
				task.on_done(78, "", "")
				helpers.assert_nil(f.active_tasks.ollama_pull, "physical receipt releases the original root")
				helpers.assert_nil(f.http_callback())
			end)
		end)
	end

end)

return true
