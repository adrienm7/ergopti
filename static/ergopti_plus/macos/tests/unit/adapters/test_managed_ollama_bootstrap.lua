--- tests/unit/adapters/test_managed_ollama_bootstrap.lua
--- Actual shared choices and the production adapter; native ports are modeled.

local helpers = require("tests.helpers")
local TARGET = "/owned/home/Library/Application Support/Ergopti/ollama-native-http"
local SOURCE = "/Applications/Ollama.app/Contents/Resources/ollama"
local BUDGET = 1800000

-- A controlled passive native-reader port, not a real Hammerspoon C receipt.
-- It reads only fixture-owned storage; task-facing hook methods remain foreign.
local native_task_environments = {}
local function passive_native_environment(task)
	local storage = native_task_environments[task]
	if type(storage) ~= "function" then error("unknown modeled native task") end
	local copied = {}
	for key, value in pairs(storage()) do copied[key] = value end
	return copied
end

local function receiving(body)
	local saved, getenv = {}, os.getenv
	local original_meta = hs.getObjectMetatable
	local original_info = debug.getinfo
	for name, value in pairs(package.loaded) do saved[name] = value end
	local state = { current = true, target = TARGET, home = "/owned/home", calls = {}, prepared = true, handle = {} }
	local ok, failure = xpcall(function()
		-- Only this exact fixture passive port models the admitted C identity.
		-- Every other function keeps its genuine debug classification.
		debug.getinfo = function(subject, options)
			if rawequal(subject, passive_native_environment) then return { what = "C" } end
			if type(subject) == "number" then subject = subject + 1 end
			local observed = original_info(subject, options)
			return observed
		end
		local native_meta = { environment = passive_native_environment }
		hs.getObjectMetatable = function(name)
			if name ~= "hs.task" then error("unexpected native metatable") end
			return native_meta
		end
		os.getenv = function(name)
			if name == "HOME" then return state.home end
			if name == "OLLAMA_MODELS" then return state.models end
			return getenv(name)
		end
		package.loaded["modules.llm.ollama_binary"] = {
			native_managed_install_dir = function() return state.target end,
		}
		package.loaded["adapters.python_interpreter"] = {
			native_arch = function() return state.architecture or "arm64" end,
			native_candidates = function()
				if state.resolve then state.resolve() end
				return { "/usr/bin/python3" }
			end,
		}
		package.loaded["adapters.native_bootstrap_pty"] = {
			prepare = function(script, environment, budget)
				state.calls[#state.calls + 1] = { script = script, environment = environment, budget = budget }
				if state.prepare then state.prepare() end
				return state.handle, state.prepared
			end,
		}
		package.loaded["infra.launcher_environment"] = nil
		package.loaded["core.llm.ollama_runtime_choice"] = nil
		package.loaded["adapters.managed_ollama_bootstrap"] = nil
		local choice = require("core.llm.ollama_runtime_choice")
		local adapter = require("adapters.managed_ollama_bootstrap")
		function state.issue(source, kind)
			local decision = choice.new_migration(source or SOURCE, kind or "app", TARGET, state.models, function()
				if state.current_hook then state.current_hook() end
				return state.current
			end)
			helpers.assert_true(type(decision) == "table", "Actual issuer accepts the independent captured tuple")
			return decision
		end
		function state.accept()
			local decision = state.issue()
			helpers.assert_eq(choice.choose(decision, "install_native"), true)
			return decision
		end
		body(adapter, choice, state)
	end, debug.traceback)
	os.getenv = getenv
	hs.getObjectMetatable = original_meta
	debug.getinfo = original_info
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(failure, 0) end
end

helpers.describe("consented native managed Ollama bootstrap port", function()
	helpers.it("consumes the actual choice and returns the exact original preparation owner", function()
		receiving(function(adapter, choice, state)
			local decision = state.accept()
			local owner, prepared = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
			helpers.assert_true(owner == state.handle)
			helpers.assert_eq(prepared, true)
			helpers.assert_eq(#state.calls, 1)
			local call = state.calls[1]
			helpers.assert_true(call.script:match("/modules/llm/ensure%-ollama%-native%-deps%.sh$") ~= nil)
			helpers.assert_eq(call.budget, BUDGET)
			local environment = {}
			for _, pair in ipairs(call.environment) do environment[pair[1]] = pair[2] end
			helpers.assert_eq(environment.ERGOPTI_NATIVE_ARCH, "arm64")
			helpers.assert_eq(environment.ERGOPTI_BOOTSTRAP_PYTHON, nil)
			helpers.assert_eq(environment.ERGOPTI_NATIVE_PYTHONS, "/usr/bin/python3")
			helpers.assert_eq(environment.OLLAMA_MODELS, nil)
			helpers.assert_eq(environment.ERGOPTI_BOOTSTRAP_OLLAMA_INSTALL_DIR, nil)
			helpers.assert_eq(choice.consume(decision, SOURCE, "app", TARGET, nil), false)
		end)
	end)
	helpers.it("rejects forged object methods and plain booleans without native preparation", function()
		receiving(function(adapter, _, state)
			for _, decision in ipairs({ true, { consume = function() return true end }, {} }) do
				local owner, prepared = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
				helpers.assert_eq(owner, nil)
				helpers.assert_eq(prepared, false)
			end
			helpers.assert_eq(#state.calls, 0)
		end)
	end)
	helpers.it("unselected and manual-stop choices never authorize the installer", function()
		receiving(function(adapter, choice, state)
			local decision = state.issue()
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), false)
			helpers.assert_eq(choice.choose(decision, "stop_manual"), false)
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), false)
			helpers.assert_eq(#state.calls, 0)
		end)
	end)
	helpers.it("binds exact original source path and classification before consuming", function()
		receiving(function(adapter, choice, state)
			local decision = state.accept()
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE .. "-foreign", "app", TARGET, nil, BUDGET)), false)
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "path", TARGET, nil, BUDGET)), false)
			helpers.assert_eq(#state.calls, 0)
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), true)
			helpers.assert_eq(#state.calls, 1)
		end)
	end)
	helpers.it("never accepts the legacy managed target or a caller-selected directory", function()
		receiving(function(adapter, choice, state)
			local decision = state.accept()
			for _, target in ipairs({ "/owned/home/Library/Application Support/Ergopti/ollama", "/foreign/runtime" }) do
				helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", target, nil, BUDGET)), false)
			end
			helpers.assert_eq(#state.calls, 0)
			helpers.assert_eq(choice.consume(decision, SOURCE, "app", TARGET, nil), true)
		end)
	end)
	helpers.it("preserves unset empty relative and custom model store without exporting a replacement", function()
		for _, models in ipairs({ false, "", "relative-models", "/custom/models" }) do
			receiving(function(adapter, _, state)
				if models == false then state.models = nil else state.models = models end
				local decision = state.accept()
				helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, state.models, BUDGET)), true)
				for _, pair in ipairs(state.calls[1].environment) do
					helpers.assert_true(pair[1] ~= "OLLAMA_MODELS", "No model migration or environment substitution")
				end
			end)
		end
	end)
	helpers.it("rejects invalid budgets before spending a selected choice", function()
		receiving(function(adapter, choice, state)
			local decision = state.accept()
			for _, budget in ipairs({ 0, -1, 0.5, math.huge, 2147483648, 9007199254740992, "1800000" }) do
				helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, budget)), false)
			end
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, 0 / 0)), false)
			helpers.assert_eq(#state.calls, 0)
			helpers.assert_eq(choice.consume(decision, SOURCE, "app", TARGET, nil), true)
		end)
	end)
	helpers.it("refuses issuer cancellation during native candidate capture before native allocation", function()
		receiving(function(adapter, choice, state)
			local decision = state.accept()
			state.resolve = function() helpers.assert_eq(choice.cancel(decision), true) end
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), false)
			helpers.assert_eq(#state.calls, 0)
		end)
	end)
	helpers.it("refuses raw model or native-target replacement during native candidate capture", function()
		for _, field in ipairs({ "models", "target" }) do
			receiving(function(adapter, _, state)
				local decision = state.accept()
				state.resolve = function() state[field] = "/foreign/replacement" end
				helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), false)
				helpers.assert_eq(#state.calls, 0)
			end)
		end
	end)
	helpers.it("refuses environment replacement from the actual issuer current callback", function()
		receiving(function(adapter, _, state)
			local decision = state.accept()
			state.current_hook = function() state.models = "/foreign/replacement" end
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), false)
			helpers.assert_eq(#state.calls, 0)
		end)
	end)
	helpers.it("returns a refused partial handle unchanged without retrying or claiming installation", function()
		receiving(function(adapter, choice, state)
			state.prepared = false
			local decision = state.accept()
			local owner, prepared = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
			helpers.assert_true(owner == state.handle)
			helpers.assert_eq(prepared, false)
			helpers.assert_eq(#state.calls, 1)
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), false)
			helpers.assert_eq(#state.calls, 1)
		end)
	end)
	helpers.it("preserves a native preparation exception and spends no second acquisition", function()
		receiving(function(adapter, _, state)
			local primary = {}
			state.prepare = function() error(primary) end
			local decision = state.accept()
			local ok, failure = pcall(adapter.prepare, decision, SOURCE, "app", TARGET, nil, BUDGET)
			helpers.assert_eq(ok, false)
			helpers.assert_true(failure == primary)
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), false)
			helpers.assert_eq(#state.calls, 1)
		end)
	end)
	helpers.it("admits an explicitly chosen absent source only into the fixed native install entry", function()
		receiving(function(adapter, choice, state)
			local decision = choice.new_migration("", nil, TARGET, nil, function() return true end)
			helpers.assert_true(type(decision) == "table")
			helpers.assert_eq(choice.choose(decision, "install_native"), true)
			helpers.assert_eq(select(2, adapter.prepare(decision, "", nil, TARGET, nil, BUDGET)), true)
			helpers.assert_eq(#state.calls, 1)
			helpers.assert_eq(#state.calls[1].environment, 3)
		end)
	end)
	helpers.it("refuses an unavailable native architecture before spending the actual choice", function()
		receiving(function(adapter, choice, state)
			local decision = state.accept()
			state.architecture = "foreign"
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), false)
			helpers.assert_eq(#state.calls, 0)
			helpers.assert_eq(choice.consume(decision, SOURCE, "app", TARGET, nil), true)
		end)
	end)
end)

local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local bytes = assert(file:read("*a"))
	assert(file:close())
	return bytes
end

local function write(path, bytes)
	local file = assert(io.open(path, "wb"))
	assert(file:write(bytes))
	assert(file:close())
end

local function command(text)
	local pipe = assert(io.popen("( " .. text .. " ) 2>&1; printf '\\n__STATUS__:%s' \"$?\"", "r"))
	local bytes = assert(pipe:read("*a"))
	assert(pipe:close())
	local status = assert(tonumber(bytes:match("__STATUS__:(%d+)%s*$")))
	return bytes:gsub("\n?__STATUS__:%d+%s*$", ""), status
end

local function shell_receiving(body, refused)
	local output, created = command("mktemp -d " .. quote(helpers.temp_dir() .. "/ergopti-native-choice.XXXXXX"))
	helpers.assert_eq(created, 0)
	local root = assert(output:match("^(/[^\r\n]+)\n?$"))
	local ok, failure = xpcall(function()
		local _, made = command("mkdir " .. quote(root .. "/source") .. " " .. quote(root .. "/home"))
		helpers.assert_eq(made, 0)
		local driver = helpers.driver_root()
		write(root .. "/source/ensure-ollama-native-deps.sh", read(driver .. "modules/llm/ensure-ollama-native-deps.sh"))
		write(root .. "/source/network-retry.sh", read(driver .. "modules/llm/network-retry.sh"))
		write(root .. "/foreign-python", "#!/bin/bash\nprintf inherited > \"$FIXTURE_ROOT/foreign-called\"\nexit 0\n")
		write(root .. "/recording-python", [[#!/bin/bash
set -eu
[ "$1" = "$FIXTURE_ROOT/source/managed_ollama_runtime.py" ]
[ "$2" = install ]
[ "$3" = --timeout ] && [ "$4" = 1 ]
[ "$5" = --idle-timeout ] && [ "$6" = 60 ]
[ "$7" = --connect-timeout ] && [ "$8" = 30 ]
[ "$9" = --minimum-bytes-per-second ] && [ "${10}" = 1024 ]
[ "${OLLAMA_MODELS+x}" = x ] && [ "$OLLAMA_MODELS" = relative-models ]
printf selected > "$FIXTURE_ROOT/recorded-called"
exit 78
]])
		write(root .. "/home/models-sentinel", "existing models remain at their original location")
		write(root .. "/home/service-sentinel", "existing foreign service remains untouched")
		local delegate = [[native_bootstrap_python() {
[ -z "${ERGOPTI_BOOTSTRAP_PYTHON+x}" ] || return 96
[ "$1" = "$HOME/Library/Application Support/Ergopti/native-bootstrap" ] || return 97
printf bootstrap > "$FIXTURE_ROOT/bootstrap-called"
]]
		if refused then
			delegate = delegate .. "return 78\n}\n"
		else
			delegate = delegate .. 'export ERGOPTI_BOOTSTRAP_PYTHON="$FIXTURE_ROOT/recording-python"\n}\n'
		end
		write(root .. "/source/native_python_bootstrap.sh", delegate)
		local _, executable = command("chmod 755 " .. quote(root .. "/foreign-python") .. " " .. quote(root .. "/recording-python"))
		helpers.assert_eq(executable, 0)
		local bytes, status = command("env -u BASH_ENV -u ENV FIXTURE_ROOT=" .. quote(root)
			.. " HOME=" .. quote(root .. "/home") .. " ERGOPTI_BOOTSTRAP_PYTHON=" .. quote(root .. "/foreign-python")
			.. " ERGOPTI_BOOTSTRAP_TIMEOUT_MS=1000 OLLAMA_MODELS=relative-models /bin/bash "
			.. quote(root .. "/source/ensure-ollama-native-deps.sh"))
		body(root, bytes, status)
	end, debug.traceback)
	local _, removed = command("rm -rf " .. quote(root))
	helpers.assert_eq(removed, 0)
	if not ok then error(failure, 0) end
end

helpers.describe("native installer source and fixed environment receiving", function()
	helpers.it("sends only fields admitted by the unchanged actual nonofficial native parser", function()
		local worker = read(helpers.driver_root() .. "launcher/Sources/ErgoptiPlus/ManagedPTYWorker.swift")
		local branch = assert(worker:match(':%s*%[("PROJECT_ROOT".-"ERGOPTI_MLX_REPAIR")%]'))
		local admitted, count = {}, 0
		for name in branch:gmatch('"([A-Z_]+)"') do admitted[name] = true; count = count + 1 end
		helpers.assert_eq(count, 4)
		helpers.assert_eq(admitted.ERGOPTI_BOOTSTRAP_PYTHON, nil)
		helpers.assert_true(worker:find("timeout <= Int64(Int32.max)", 1, true) ~= nil)
		receiving(function(adapter, _, state)
			local decision = state.accept()
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), true)
			helpers.assert_eq(#state.calls[1].environment, 3)
			for _, pair in ipairs(state.calls[1].environment) do
				helpers.assert_eq(admitted[pair[1]], true)
			end
		end)
	end)
	helpers.it("clears executable inherited Python and delegates only to the original fixed bootstrap", function()
		shell_receiving(function(root, output, status)
			helpers.assert_eq(status, 78)
			helpers.assert_eq(read(root .. "/bootstrap-called"), "bootstrap")
			helpers.assert_eq(read(root .. "/recorded-called"), "selected")
			local foreign = io.open(root .. "/foreign-called", "rb")
			if foreign then foreign:close() end
			helpers.assert_eq(foreign, nil)
			helpers.assert_true(output:find("OLLAMA_INSTALLING", 1, true) ~= nil)
			helpers.assert_eq(output:find("OLLAMA_VERIFIED", 1, true), nil)
			helpers.assert_eq(read(root .. "/home/models-sentinel"), "existing models remain at their original location")
			helpers.assert_eq(read(root .. "/home/service-sentinel"), "existing foreign service remains untouched")
		end, false)
	end)
	helpers.it("preserves bootstrap refusal without executing inherited or successor interpreters", function()
		shell_receiving(function(root, output, status)
			helpers.assert_eq(status, 78)
			helpers.assert_eq(read(root .. "/bootstrap-called"), "bootstrap")
			for _, name in ipairs({ "foreign-called", "recorded-called" }) do
				local file = io.open(root .. "/" .. name, "rb")
				if file then file:close() end
				helpers.assert_eq(file, nil)
			end
			helpers.assert_eq(output:find("OLLAMA_VERIFIED", 1, true), nil)
			helpers.assert_eq(output:find("OLLAMA_INSTALLED", 1, true), nil)
			helpers.assert_eq(read(root .. "/home/models-sentinel"), "existing models remain at their original location")
			helpers.assert_eq(read(root .. "/home/service-sentinel"), "existing foreign service remains untouched")
		end, true)
	end)
end)

local function original_task(environment, hooks)
	local stored, writes = {}, 0
	for key, value in pairs(environment) do stored[key] = value end
	local task = {}
	native_task_environments[task] = function() return stored end
	function task:environment()
		if hooks and hooks.read then hooks.read() end
		local copy = {}
		for key, value in pairs(stored) do copy[key] = value end
		return copy
	end
	function task:setEnvironment(values)
		writes = writes + 1
		if hooks and hooks.write then
			local answer = hooks.write(values, self)
			if answer ~= nil then return answer end
		end
		stored = {}
		for key, value in pairs(values) do stored[key] = value end
		return self
	end
	return task, function() return stored, writes end
end

helpers.describe("retained native bootstrap task context", function()
	helpers.it("retains the exact preparation owner when source HOME models or target withdraw during preparation", function()
		for _, field in ipairs({ "current", "home", "models", "target" }) do
			receiving(function(adapter, _, state)
				local decision = state.accept()
				state.prepare = function()
					if field == "current" then state.current = false else state[field] = "/foreign/context" end
				end
				local owner, prepared, context = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
				helpers.assert_true(owner == state.handle)
				helpers.assert_eq(prepared, true)
				helpers.assert_eq(context.is_current(), false)
				helpers.assert_eq(context.bind_environment({}), false)
				helpers.assert_eq(#state.calls, 1)
			end)
		end
	end)
	helpers.it("pins captured raw HOME and every original model-store form on only the exact task", function()
		for _, models in ipairs({ false, "", "relative-models", "/custom/models" }) do
			receiving(function(adapter, choice, state)
				if models ~= false then state.models = models end
				local decision = state.accept()
				local owner, prepared, context = adapter.prepare(decision, SOURCE, "app", TARGET, state.models, BUDGET)
				helpers.assert_true(owner == state.handle)
				helpers.assert_eq(prepared, true)
				local original = { HOME = "/foreign/home", OLLAMA_MODELS = "/foreign/models", HTTPS_PROXY = "https://relay.invalid", SSL_CERT_FILE = "/owned/cert", ERGOPTI_LOG_TOKEN = "fixture-private" }
				local task, observed = original_task(original)
				helpers.assert_eq(context.bind_environment(task), true)
				local child, writes = observed()
				helpers.assert_eq(writes, 1)
				helpers.assert_eq(child.HOME, "/owned/home")
				helpers.assert_eq(child.OLLAMA_MODELS, state.models)
				helpers.assert_eq(child.HTTPS_PROXY, "https://relay.invalid")
				helpers.assert_eq(child.SSL_CERT_FILE, "/owned/cert")
				helpers.assert_eq(child.ERGOPTI_LOG_TOKEN, nil)
				helpers.assert_eq(original.HOME, "/foreign/home")
				helpers.assert_eq(context.is_current(), true)
				helpers.assert_eq(choice.consume(decision, SOURCE, "app", TARGET, state.models), false)
				helpers.assert_eq(context.bind_environment({}), false)
				helpers.assert_eq(context.is_current(), false)
				helpers.assert_eq(#state.calls, 1)
			end)
		end
	end)
	helpers.it("rejects later exact child environment substitution without repairing or granting a successor", function()
		for _, field in ipairs({ "HOME", "OLLAMA_MODELS", "SSL_CERT_FILE" }) do
			receiving(function(adapter, _, state)
				local decision = state.accept()
				local owner, _, context = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
				local task, observed = original_task({ HOME = state.home, SSL_CERT_FILE = "/owned/cert" })
				helpers.assert_eq(context.bind_environment(task), true)
				local child = observed()
				child[field] = "/foreign/substitution"
				helpers.assert_eq(context.is_current(), false)
				helpers.assert_eq(select(2, observed()), 1)
				helpers.assert_true(owner == state.handle)
				helpers.assert_eq(#state.calls, 1)
			end)
		end
	end)
	helpers.it("refuses getter or setter replacement on the bound original task", function()
		for _, field in ipairs({ "environment", "setEnvironment" }) do
			receiving(function(adapter, _, state)
				local decision = state.accept()
				local _, _, context = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
				local task = original_task({ HOME = state.home })
				helpers.assert_eq(context.bind_environment(task), true)
				task[field] = function() error("replacement must not be called") end
				helpers.assert_eq(context.is_current(), false)
			end)
		end
	end)
	helpers.it("requires exact native setter identity and never retries an uncertain write", function()
		for _, answer in ipairs({ false, {}, "raise" }) do
			receiving(function(adapter, _, state)
				local decision = state.accept()
				local owner, _, context = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
				local task, observed = original_task({ HOME = state.home }, { write = function()
					if answer == "raise" then error("known fixture write failure") end
					return answer
				end })
				helpers.assert_eq(context.bind_environment(task), false)
				helpers.assert_eq(context.bind_environment(task), false)
				helpers.assert_eq(select(2, observed()), 1)
				helpers.assert_true(owner == state.handle)
				helpers.assert_eq(context.is_current(), false)
			end)
		end
	end)
	helpers.it("keeps detached expectations when the original setter mutates its submitted environment", function()
		receiving(function(adapter, _, state)
			local decision = state.accept()
			local _, _, context = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
			local task, observed = original_task({ HOME = state.home, SSL_CERT_FILE = "/owned/cert" }, { write = function(values)
				values.SSL_CERT_FILE = "/foreign/cert"
			end })
			helpers.assert_eq(context.bind_environment(task), false)
			helpers.assert_eq(select(2, observed()), 1)
			helpers.assert_eq(context.is_current(), false)
		end)
	end)
	helpers.it("refuses synchronous getter setter and issuer reentry without a second binding", function()
		for _, boundary in ipairs({ "read", "write", "guard" }) do
			receiving(function(adapter, _, state)
				local decision = state.accept()
				local _, _, context = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
				local nested = 0
				local function reenter()
					nested = nested + 1
					helpers.assert_eq(context.is_current(), false)
				end
				local hooks = {}
				if boundary == "guard" then state.current_hook = reenter else hooks[boundary] = reenter end
				local task, observed = original_task({ HOME = state.home }, hooks)
				helpers.assert_eq(context.bind_environment(task), false)
				helpers.assert_eq(nested, 1)
				helpers.assert_true(select(2, observed()) <= 1)
				helpers.assert_eq(context.bind_environment({}), false)
				helpers.assert_eq(context.is_current(), false)
			end)
		end
	end)
	helpers.it("refuses source HOME or model changes through original environment callbacks", function()
		for _, boundary in ipairs({ "read", "write" }) do
			for _, field in ipairs({ "current", "home", "models" }) do
				receiving(function(adapter, _, state)
					local decision = state.accept()
					local owner, _, context = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
					local hooks = { [boundary] = function()
						if field == "current" then state.current = false else state[field] = "/foreign/context" end
					end }
					local task, observed = original_task({ HOME = state.home }, hooks)
					helpers.assert_eq(context.bind_environment(task), false)
					helpers.assert_eq(context.is_current(), false)
					helpers.assert_true(select(2, observed()) <= 1)
					helpers.assert_true(owner == state.handle)
				end)
			end
		end
	end)
	helpers.it("retains a refused preparation owner with currency but no renewed installation choice", function()
		receiving(function(adapter, choice, state)
			state.prepared = false
			local decision = state.accept()
			local owner, prepared, context = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
			helpers.assert_true(owner == state.handle)
			helpers.assert_eq(prepared, false)
			helpers.assert_eq(context.is_current(), true)
			helpers.assert_eq(choice.consume(decision, SOURCE, "app", TARGET, nil), false)
			helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), false)
			helpers.assert_eq(#state.calls, 1)
			state.current = false
			helpers.assert_eq(context.is_current(), false)
			state.current = true
			helpers.assert_eq(context.is_current(), false)
		end)
	end)
	helpers.it("refuses unusable inherited HOME before consuming the exact choice", function()
		for _, home in ipairs({ false, "", "relative-home", "/owned/home\nforeign" }) do
			receiving(function(adapter, choice, state)
				local decision = state.accept()
				if home == false then state.home = nil else state.home = home end
				helpers.assert_eq(select(2, adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)), false)
				helpers.assert_eq(#state.calls, 0)
				helpers.assert_eq(choice.consume(decision, SOURCE, "app", TARGET, nil), true)
			end)
		end
	end)
end)

helpers.describe("native bootstrap continuation readback", function()
	helpers.it("refuses task environment mutation in the final shared currency callback", function()
		receiving(function(adapter, _, state)
			local decision = state.accept()
			local _, _, context = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
			local task, observed = original_task({ HOME = state.home })
			helpers.assert_eq(context.bind_environment(task), true)
			local child = observed()
			local visits = 0
			state.current_hook = function()
				visits = visits + 1
				if visits == 2 then child.HOME = "/foreign/after-snapshot" end
			end
			helpers.assert_eq(context.is_current(), false)
			helpers.assert_eq(visits, 2)
			helpers.assert_eq(select(2, observed()), 1)
		end)
	end)
end)

helpers.describe("source-bound passive native bootstrap readback", function()
	helpers.it("never delegates the final bind read to a source-withdrawing task wrapper", function()
		receiving(function(adapter, _, state)
			local decision = state.accept()
			local owner, prepared, context = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
			local reads = 0
			local hooks = { read = function()
				reads = reads + 1
				if reads == 3 then state.current = false end
			end }
			local task, observed = original_task({ HOME = state.home }, hooks)
			helpers.assert_eq(context.bind_environment(task), true)
			helpers.assert_eq(reads, 2)
			helpers.assert_eq(state.current, true)
			helpers.assert_true(owner == state.handle)
			helpers.assert_eq(prepared, true)
			helpers.assert_eq(select(2, observed()), 1)
			hooks.read = nil
			helpers.assert_eq(context.is_current(), true)
		end)
	end)
	helpers.it("never delegates final currency readback to a source-withdrawing task wrapper", function()
		receiving(function(adapter, _, state)
			local decision = state.accept()
			local _, _, context = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
			local hooks = {}
			local task, observed = original_task({ HOME = state.home }, hooks)
			helpers.assert_eq(context.bind_environment(task), true)
			local reads = 0
			hooks.read = function()
				reads = reads + 1
				if reads == 2 then state.current = false end
			end
			helpers.assert_eq(context.is_current(), true)
			helpers.assert_eq(reads, 1)
			helpers.assert_eq(state.current, true)
			helpers.assert_eq(select(2, observed()), 1)
		end)
	end)
end)

helpers.describe("original native bootstrap C getter admission", function()
	helpers.it("refuses an already installed Lua native-getter wrapper before consumption", function()
		receiving(function(adapter, choice, state)
			local decision = state.accept()
			local native_meta = hs.getObjectMetatable("hs.task")
			local original = native_meta.environment
			local calls = 0
			native_meta.environment = function(task)
				calls = calls + 1
				return original(task)
			end
			local owner, prepared = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
			helpers.assert_eq(owner, nil)
			helpers.assert_eq(prepared, false)
			helpers.assert_eq(#state.calls, 0)
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(choice.consume(decision, SOURCE, "app", TARGET, nil), true)
		end)
	end)
	helpers.it("refuses missing or throwing C identity proof before consuming the selected choice", function()
		for _, mode in ipairs({ "missing", "throw" }) do
			receiving(function(adapter, choice, state)
				local decision = state.accept()
				local original = debug.getinfo
				debug.getinfo = function(subject, options)
					if rawequal(subject, passive_native_environment) then
						if mode == "throw" then error("fixture native proof unavailable") end
						return {}
					end
					if type(subject) == "number" then subject = subject + 1 end
					local observed = original(subject, options)
					return observed
				end
				local owner, prepared = adapter.prepare(decision, SOURCE, "app", TARGET, nil, BUDGET)
				helpers.assert_eq(owner, nil)
				helpers.assert_eq(prepared, false)
				helpers.assert_eq(#state.calls, 0)
				helpers.assert_eq(choice.consume(decision, SOURCE, "app", TARGET, nil), true)
			end)
		end
	end)
end)
