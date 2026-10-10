--- adapters/managed_ollama_bootstrap.lua

--- ==============================================================================
--- MODULE: Native Managed Ollama Bootstrap Admission
--- DESCRIPTION:
--- Consumes the shared, exact user choice at the original native PTY preparation
--- boundary. The caller retains the returned owner through task acquisition,
--- cancellation and its original physical retirement receipt. This port never
--- starts a daemon, relocates models or selects the stock installer.
--- ==============================================================================

local M = {}
local Choice = require("core.llm.ollama_runtime_choice")
local NativePty = require("adapters.native_bootstrap_pty")
local Binary = require("modules.llm.ollama_binary")
local Interpreter = require("adapters.python_interpreter")
local Environment = require("infra.launcher_environment")

local function absolute(value)
	return type(value) == "string" and value:sub(1, 1) == "/"
		and not value:find("[%z\1-\31\127]")
end

-- This continuation is currency only, never another installation grant. The
-- caller captures these exact methods and joins its original native owner on
-- refusal. Only the actual task environment supplies the helper's inherited
-- HOME/models; the native JSON header retains its original three allowed keys.
local function continuation(guard, native_meta, native_reader, home, models, target)
	local valid, busy = true, false
	local task, reader, writer, expected
	local bound = false
	local native_index = rawget(native_meta, "__index")
	local function inherited_current()
		return os.getenv("HOME") == home and os.getenv("OLLAMA_MODELS") == models
			and Binary.native_managed_install_dir() == target and valid
	end
	local function currency()
		if not valid or guard() ~= true or not valid then return false end
		return inherited_current()
	end
	local function methods_current()
		if not rawequal(rawget(native_meta, "environment"), native_reader)
			or not rawequal(rawget(native_meta, "__index"), native_index) then return false end
		-- The original C getter rejects a table on the real host. Plain tables
		-- below are the normal suite's explicitly modeled native task port.
		local methods = type(task) == "table" and task or native_meta
		return rawequal(rawget(methods, "environment"), reader)
			and rawequal(rawget(methods, "setEnvironment"), writer)
	end
	local function checked(action)
		if not valid or busy then valid = false; return false end
		busy = true
		local ok, result = pcall(action)
		busy = false
		if not ok or result ~= true or not valid then valid = false; return false end
		return true
	end
	local context = {}
	function context.is_current()
		return checked(function()
			if not currency() then return false end
			if bound then
				if not methods_current() then return false end
				local observed = reader(task)
				if not currency() or type(observed) ~= "table" or getmetatable(observed) ~= nil
					or Environment.verify_child_copy(expected, observed) ~= true then return false end
				-- Re-read the original native task dictionary after the external
				-- currency callback so its changes cannot bless a stale snapshot.
				observed = native_reader(task)
				return inherited_current() and methods_current() and type(observed) == "table"
					and getmetatable(observed) == nil and Environment.verify_child_copy(expected, observed) == true
			end
			return currency()
		end)
	end
	function context.bind_environment(original_task)
		return checked(function()
			if task ~= nil or original_task == nil or not currency() then return false end
			-- Reserve the exact task before any getter/setter callback. A failed
			-- attempt cannot bind a successor or retry an uncertain native write.
			task = original_task
			-- The original registered hs.task C getter validates the native
			-- object before any environment write; a caller method is not this
			-- authority. Its NSTask dictionary snapshot cannot invoke Lua.
			local native_environment = native_reader(task)
			if type(native_environment) ~= "table" or getmetatable(native_environment) ~= nil
				or not currency() then return false end
			reader, writer = task.environment, task.setEnvironment
			if type(reader) ~= "function" or type(writer) ~= "function" or not currency() then return false end
			local inherited = reader(task)
			if not currency() or type(inherited) ~= "table" or getmetatable(inherited) ~= nil then return false end
			local copied = Environment.child_copy(inherited)
			if copied == nil then return false end
			copied.HOME, copied.OLLAMA_MODELS = home, models
			-- Keep the expectation separate from the submitted mutable table.
			expected = Environment.child_copy(copied)
			if expected == nil or not methods_current() or not currency() then return false end
			if not rawequal(writer(task, copied), task) or not currency() or not methods_current() then return false end
			local observed = reader(task)
			if not currency() or type(observed) ~= "table" or getmetatable(observed) ~= nil
				or Environment.verify_child_copy(expected, observed) ~= true or not methods_current() then return false end
			observed = native_reader(task)
			if not inherited_current() or not methods_current() or type(observed) ~= "table"
				or getmetatable(observed) ~= nil or Environment.verify_child_copy(expected, observed) ~= true then return false end
			bound = true
			return valid
		end)
	end
	return context
end

--- Prepare the existing native installer after one explicit issued choice.
--- Source/caller currency is rechecked by the shared issuer during consumption.
--- A partial preparation owner is returned unchanged; it must be rolled back or
--- retained by the caller, never discarded because prepared is false. Preparation
--- is not task acquisition, installation, daemon activation or server readiness.
--- @param decision table Opaque shared migration choice selected by the user.
--- @param source_path string Exact currently selected source, or empty if absent.
--- @param source_kind string|nil Exact original source classification.
--- @param native_target string Existing native managed installation directory.
--- @param model_store string|nil Exact raw inherited OLLAMA_MODELS value.
--- @param timeout_ms number Remaining original caller bootstrap budget.
--- @return table|nil owner Original native PTY input and retirement owner.
--- @return boolean prepared Original preparation result.
--- @return table|nil context Once-bound original task currency continuation.
function M.prepare(decision, source_path, source_kind, native_target, model_store, timeout_ms)
	local home = os.getenv("HOME")
	if not absolute(home) then return nil, false end
	-- Capture the registered native method independently of a task-facing
	-- wrapper. Hammerspoon registers this C getter when hs.task is loaded.
	local native_ok, native_meta, native_reader = pcall(function()
		local library = hs.task
		if library == nil or type(hs.getObjectMetatable) ~= "function" then return nil end
		local metatable = hs.getObjectMetatable("hs.task")
		if type(metatable) ~= "table" then return nil end
		return metatable, rawget(metatable, "environment")
	end)
	if not native_ok or type(native_reader) ~= "function" then return nil, false end
	local proof_ok, proof = pcall(debug.getinfo, native_reader, "S")
	if not proof_ok or type(proof) ~= "table" or proof.what ~= "C" then return nil, false end
	-- The unchanged Swift header admits only a positive signed Int32 duration.
	if type(timeout_ms) ~= "number" or timeout_ms <= 0 or timeout_ms >= math.huge
		or timeout_ms % 1 ~= 0 or timeout_ms > 2147483647
		or not absolute(native_target) or native_target ~= Binary.native_managed_install_dir()
		or model_store ~= os.getenv("OLLAMA_MODELS") then return nil, false end
	local origin = debug.getinfo(1, "S").source
	local driver = type(origin) == "string" and origin:match("^@(.*)/adapters/managed_ollama_bootstrap%.lua$")
	if not absolute(driver) then return nil, false end
	local architecture = Interpreter.native_arch()
	if architecture ~= "arm64" and architecture ~= "x86_64" then return nil, false end
	local candidates = Interpreter.native_candidates()
	if type(candidates) ~= "table" then return nil, false end
	for _, path in ipairs(candidates) do
		if not absolute(path) then return nil, false end
	end
	local environment = {
		{ "PROJECT_ROOT", driver },
		{ "ERGOPTI_NATIVE_ARCH", architecture },
		{ "ERGOPTI_NATIVE_PYTHONS", table.concat(candidates, ":") },
	}
	-- Native source/receipt allocation may invoke external callbacks. The caller
	-- must refence its original intent before binding or starting the returned
	-- exact task, and commit only the original acknowledged acquisition.
	if native_target ~= Binary.native_managed_install_dir()
		or model_store ~= os.getenv("OLLAMA_MODELS") or home ~= os.getenv("HOME") then return nil, false end
	local consumed, guard = Choice.consume(decision, source_path, source_kind, native_target, model_store)
	if consumed ~= true or type(guard) ~= "function" then
		return nil, false
	end
	if native_target ~= Binary.native_managed_install_dir()
		or model_store ~= os.getenv("OLLAMA_MODELS") or home ~= os.getenv("HOME") then return nil, false end
	local context = continuation(guard, native_meta, native_reader, home, model_store, native_target)
	if context.is_current() ~= true then return nil, false end
	local owner, prepared = NativePty.prepare(driver .. "/modules/llm/ensure-ollama-native-deps.sh", environment, timeout_ms)
	-- Preserve every partial owner and its original result. The caller must
	-- check context again before task acquisition, binding, start and commit.
	return owner, prepared, context
end

return M
