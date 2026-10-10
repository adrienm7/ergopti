--- adapters/managed_ollama_hint.lua

--- ==============================================================================
--- MODULE: Asynchronous Optional Runtime Metadata
--- DESCRIPTION:
--- One retained native task receives bounded public metadata off the UI thread.
--- Its cached result selects a candidate only; Python separately admits source,
--- signature, alias and image before any daemon secrets can be published.
--- ==============================================================================

local M = {}
local FileSystem = require("adapters.file_system")
local Interpreter = require("modules.llm.managed_native_python")
local Timer = require("adapters.timer_scheduler")
local Settings = require("modules.llm.bootstrap_retry_generated")
local ShellRunner = require("adapters.shell_runner")
local TaskLifecycle = require("adapters.task_lifecycle")
local Json = require("json")

-- The exact lifecycle handle stays strongly reachable until native settlement,
-- including a start refusal that may have followed native mutation.
M._active_tasks = {}
local pending, cached

local function awake_time()
	local observed, value = pcall(Timer.awake_time)
	if not observed or type(value) ~= "number" or value ~= value or value < 0 or value >= math.huge then return nil end
	return value
end

local function expired(operation)
	local current = awake_time()
	return current == nil or current >= operation.deadline
end

local function remaining(operation)
	local current = awake_time()
	if current == nil then
		operation.cancelled = true
		return nil
	end
	return operation.deadline - current
end

local function snapshot(directory, driver)
	-- An optional installation may not exist. A positive native directory
	-- observation avoids asking the strict pathname classifier to enumerate
	-- children of a missing parent; it grants no source or absence authority.
	if not hs or not hs.fs or type(hs.fs.symlinkAttributes) ~= "function" then return nil end
	local observed, directory_attributes = pcall(hs.fs.symlinkAttributes, directory)
	if not observed or type(directory_attributes) ~= "table" or directory_attributes.mode ~= "directory" then return nil end
	local paths = {
		directory .. "/.ergopti-managed-runtime.json",
		directory .. "/ollama",
		driver .. "/../_shared/modules/llm/managed_ollama_runtime.json",
		driver .. "/../_shared/modules/llm/managed_ollama_release.json",
		driver .. "/../_shared/modules/llm/managed_ollama_bootstrap.json",
		driver .. "/modules/llm/network-retry.sh",
		driver .. "/modules/llm/managed_ollama_hint.py",
		driver .. "/../_shared/modules/network/bootstrap_retry.json",
	}
	local fields = { directory, driver }
	for _, path in ipairs(paths) do
		local ok, attributes, status = pcall(FileSystem.classify_no_follow, path)
		if not ok or status ~= "ok" or type(attributes) ~= "table" or attributes.mode ~= "file" then return nil end
		-- These cheap attributes invalidate a provisional cache; they never
		-- authorize a source inode, and large native identities are not rounded
		-- into a claim of source or socket authority.
		for _, name in ipairs({ "mode", "size", "modification", "change", "ino", "dev", "permissions" }) do
			fields[#fields + 1] = tostring(attributes[name])
		end
	end
	return table.concat(fields, "\0")
end

local function decoded_result(bytes, directory)
	local ok, value = pcall(Json.decode, bytes)
	if not ok or type(value) ~= "table" or value.version ~= 1 or value.candidate ~= directory .. "/ollama"
		or type(value.budgets) ~= "table" then return nil end
	local count = 0
	for name in pairs(value) do
		if name ~= "version" and name ~= "candidate" and name ~= "budgets" then return nil end
		count = count + 1
	end
	if count ~= 3 then return nil end
	count = 0
	for name, budget in pairs(value.budgets) do
		if name ~= "admission" and name ~= "idle" and name ~= "retirement" then return nil end
		if type(budget) ~= "number" or budget <= 0 or budget % 1 ~= 0 or budget > 9007199254740991 then return nil end
		count = count + 1
	end
	return count == 3 and value or nil
end

--- Get a physically settled provisional result, or advance one exact owner.
--- @param directory string Exact canonical optional install directory.
--- @param driver string Actual loaded driver root.
--- @return table|nil hint Public metadata only.
--- @return string|nil state `pending` while a native capability remains.
function M.get(directory, driver)
	local started = awake_time()
	if started == nil then
		cached = nil
		if pending ~= nil then pending.cancelled = true; pending.advance() end
		return nil, pending ~= nil and "pending" or nil
	end
	local current = snapshot(directory, driver)
	if pending ~= nil then
		pending.advance()
		if pending ~= nil then return nil, "pending" end
	end
	if not current then cached = nil; return nil end
	if cached and cached.key == current then
		local value = cached.value
		if cached.transient then cached = nil end
		return value
	end
	cached = nil
	local operation = { key = current, committed = false, deadline = started + Settings.admission_seconds }
	pending = operation
	M._active_tasks[operation] = true
	local function stop_child()
		if operation.handle and not operation.termination_accepted then
			operation.termination_accepted = TaskLifecycle.terminate(operation.handle, "managed Ollama metadata rollback") == true
		end
	end
	local function advance()
		if pending ~= operation or operation.dispatching or operation.advancing then return end
		operation.advancing = true
		if expired(operation) or snapshot(directory, driver) ~= operation.key then operation.cancelled = true end
		if operation.cancelled and operation.preflight then
			local ok, retired = pcall(Interpreter.cancel)
			if not ok or retired ~= true then operation.advancing = false; return end
			operation.preflight = false
		end
		if not operation.cancelled and not operation.handle and not operation.failed then
			local budget = remaining(operation)
			local python, state
			if budget ~= nil and budget > 0 then python, state = Interpreter.resolve(budget)
			else operation.cancelled = true end
			operation.preflight = state == "pending"
			if operation.preflight then
				if not operation.preflight_observer then
					operation.preflight_observer = true
					local ok, registered = pcall(Interpreter.onSettled, function()
						operation.preflight_settled = true
						advance()
					end)
					if not ok or registered ~= true then operation.cancelled = true end
				end
				operation.advancing = false
				-- Settlement may arrive synchronously during registration. Continue
				-- only after leaving that frame; resolve still owns byte admission.
				local continued = operation.preflight_settled or operation.cancelled
				operation.preflight_settled = false
				if continued then advance() end
				return
			end
			if type(python) ~= "string" or python:sub(1, 1) ~= "/" then
				operation.failed = true
			else
				local budget = remaining(operation)
				local arch = hs and hs.processInfo and hs.processInfo.arch
				if budget == nil or budget <= 0 or (arch ~= "arm64" and arch ~= "x86_64") then
					operation.cancelled = true
				else
					operation.dispatching = true
					-- Isolated Python ignores inherited bytecode settings; disable
					-- cache writes explicitly without changing script argument positions.
					local ok, handle = pcall(ShellRunner.spawn, python, {
						"-IB", driver .. "/modules/llm/managed_ollama_hint.py",
						"--timeout-seconds", tostring(budget), "--policy-sha256", Settings.source_sha256,
						"--architecture", arch,
					}, function(status, stdout, stderr)
						operation.status, operation.stdout, operation.stderr = status, stdout, stderr
						advance()
					end, nil, nil, true)
					operation.dispatching = false
					if not ok or type(handle) ~= "table" then
						operation.failed = true
					else
						operation.handle = handle
						M._active_tasks[handle] = true
						local registered, accepted = pcall(function() return handle.onSettled(advance) end)
						local observed, retired = pcall(handle.isSettled)
						if not registered or accepted ~= true or not observed or retired == true
							or expired(operation) or operation.cancelled then
							operation.cancelled = true
						else
							operation.dispatching = true
							if TaskLifecycle.start(handle, "managed Ollama metadata") then operation.committed = true
							else operation.cancelled = true end
							operation.dispatching = false
						end
					end
				end
			end
		end
		if expired(operation) then operation.cancelled = true end
		if operation.cancelled then stop_child() end
		if operation.handle then
			local observed, retired = pcall(operation.handle.isSettled)
			if not observed or retired ~= true then operation.advancing = false; return end
		end
		if operation.timer then
			local ok, retired = pcall(Timer.cancel, operation.timer)
			if not ok or retired ~= true then operation.advancing = false; return end
			operation.timer = nil
		end
		local value
		if operation.committed and not operation.cancelled and operation.status == 0
			and operation.stderr == "" and type(operation.stdout) == "string"
			and not expired(operation) and snapshot(directory, driver) == operation.key then
			value = decoded_result(operation.stdout, directory)
		end
		cached = { key = operation.key, value = value, transient = operation.cancelled or operation.failed }
		if operation.handle then M._active_tasks[operation.handle] = nil end
		M._active_tasks[operation] = nil
		pending = nil
		operation.advancing = false
	end
	operation.advance = advance
	operation.dispatching = true
	local budget = remaining(operation)
	local armed, timer, committed
	if budget ~= nil then armed, timer, committed = pcall(Timer.after, math.max(0, budget), function()
		operation.cancelled = true
		advance()
	end) end
	operation.dispatching = false
	operation.timer = armed and timer or nil
	if not armed or committed ~= true then operation.cancelled = true end
	advance()
	if pending ~= nil then return nil, "pending" end
	return cached and cached.value or nil
end

--- Cancel only the retained transaction and retry exact native cleanup debt.
--- @return boolean retired True after both preflight, task and timer retire.
function M.cancel()
	if pending == nil then return true end
	pending.cancelled = true
	pending.advance()
	return pending == nil
end

return M
