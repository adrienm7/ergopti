--- adapters/owned_program_runner.lua

--- ==============================================================================
--- MODULE: Owned Native Program Runner
--- DESCRIPTION:
--- Uses the bundled native tree supervisor, closed versioned receipts and exact
--- captured source proof. Helper exit alone never releases program ownership.
--- ==============================================================================

local M = {}
local Helper = require("platform.remap.lease_helper")
local Json = require("json")
local Logger = require("infra.logger")
local hs = hs
local LOG = "adapters.owned_program_runner"
M.MAX_PROTOCOL_BYTES = 512
local MAX_PROTOCOL_BYTES = M.MAX_PROTOCOL_BYTES
local MAX_PROTOCOL_RECORDS = 8
local MAX_PROTOCOL_LINE = 64
M._active_tasks = {}

local function refused()
	local handle = {}
	function handle.start() return false end
	function handle.terminate() return true, "settled" end
	function handle.isSettled() return true end
	function handle.hasCleanupDebt() return false end
	function handle.onSettled(observer)
		if type(observer) ~= "function" then return false end
		pcall(observer)
		return true
	end
	return handle
end

--- Reports bundle-bound supervisor readiness without starting a process.
--- @return boolean available
function M.available()
	local ok, path = pcall(Helper.resolve)
	return ok and type(path) == "string" and type(hs) == "table"
		and type(hs.task) == "table" and type(hs.task.new) == "function"
end

local function literal(value)
	return type(value) == "string" and not value:find("\0", 1, true)
end

--- Constructs an exact native protocol owner using the existing pinned transport.
--- @param transport function Private native task constructor.
--- @param executable string Literal executable path.
--- @param arguments table Dense literal argument array.
--- @param terminal function Completion receiving only success and native status.
--- @param admitted function Exact captured admission predicate.
--- @param source table Captured source path and raw-byte SHA-256.
--- @return table handle Retained protocol and physical lifecycle owner.
function M.spawn(transport, executable, arguments, terminal, admitted, source)
	if type(transport) ~= "function" or type(admitted) ~= "function" or not literal(executable)
		or executable:sub(1, 1) ~= "/" or type(arguments) ~= "table" or type(source) ~= "table"
		or not literal(source.source_path) or source.source_path:sub(1, 1) ~= "/"
		or type(source.source_sha256) ~= "string" or #source.source_sha256 ~= 64
		or not source.source_sha256:match("^[0-9a-f]+$") then return refused() end
	local count = 0
	for key, value in pairs(arguments) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #arguments or not literal(value) then return refused() end
		count = count + 1
	end
	if count ~= #arguments then return refused() end
	local resolved, helper = pcall(Helper.resolve)
	if not resolved or type(helper) ~= "string" then return refused() end
	local encoded, request = pcall(Json.encode, { version = 1, executable = executable,
		arguments = Json.array(arguments), source_path = source.source_path, source_sha256 = source.source_sha256 })
	if not encoded or type(request) ~= "string" then return refused() end
	local handle, raw, observers = {}, nil, {}
	local phase, buffer, bytes, records = "prepared", "", 0, 0
	local start_dispatching, queued, cancelled, invalid, start_attempted = false, {}, false, false, false
	local physical, receipt, status, terminal_sent, pending_seen, finalized = false, false, nil, false, false, false
	local helper_success, never_started, request_sent, held_seen, activation_sent, active_seen = false, false, false, false, false, false
	local function settled()
		return finalized or (physical and receipt and (helper_success or never_started)
			and not invalid and buffer == "" and not start_dispatching)
	end
	local function notify()
		if finalized or not settled() then return end
		finalized = true
		M._active_tasks[handle] = nil
		local ready = observers
		observers = {}
		-- Business completion runs while its action entry remains owned; observers
		-- may release that entry only after its admitted terminal callback returns.
		if not terminal_sent then
			terminal_sent = true
			if type(terminal) == "function" then pcall(terminal, active_seen and not cancelled and status == 0, status) end
		end
		for _, observer in ipairs(ready) do pcall(observer) end
	end
	local function cancel()
		cancelled = true
		if not raw then return false end
		if not start_attempted then
			local accepted = raw.terminate()
			physical, receipt, never_started = raw.isSettled() == true, true, true
			notify()
			return accepted == true
		end
		if physical then notify(); return settled() end
		-- EOF remains a cancellation authority even when a queued write refuses.
		local closed = raw.close_input() == true
		return closed
	end
	local function fail()
		if not invalid then Logger.error(LOG, "Private native supervisor protocol refused.") end
		invalid = true
		buffer = ""
		cancel()
	end
	local function line(value)
		if invalid or receipt then fail(); return end
		records = records + 1
		if records > MAX_PROTOCOL_RECORDS then fail(); return end
		if value == "V1 HELD" and request_sent and not held_seen and (phase == "waiting" or cancelled) then
			held_seen, phase = true, "held"
			if cancelled then cancel(); return end
			local ok, allowed = pcall(admitted)
			if not ok or allowed ~= true or cancelled then cancel(); return end
			phase, activation_sent = "activating", true
			if raw.set_input("ACTIVATE\n") ~= true then cancel() end
		elseif value == "V1 ACTIVE" and activation_sent and not active_seen then
			active_seen, phase = true, "active"
		elseif value:match("^V1 PENDING %d+$") and phase ~= "prepared" then
			local text = value:match("^V1 PENDING (%d+)$")
			local numeric = tonumber(text)
			if pending_seen or not numeric or numeric > 2147483647 or tostring(numeric) ~= text then fail(); return end
			pending_seen, phase = true, "cancelling"
			cancel()
		else
			local retired, refusal = value:match("^V1 RETIRED (%d+)$"), value:match("^V1 REFUSED (%d+)$")
			local numeric = tonumber(retired or refusal)
			if retired and numeric and tostring(numeric) == retired and numeric <= 255 and (request_sent or cancelled) and phase ~= "prepared" then
				receipt, status, phase = true, numeric, "retired"
			elseif refusal and numeric and tostring(numeric) == refusal and numeric <= 2147483647 and not held_seen and not pending_seen and phase ~= "prepared" then
				receipt, status, phase = true, nil, "refused"
			else fail(); return end
		end
	end
	local function consume(stdout, stderr)
		if finalized then return end
		if type(stderr) == "string" and stderr ~= "" then fail(); return end
		if stdout == nil or stdout == "" then return end
		if type(stdout) ~= "string" then fail(); return end
		bytes = bytes + #stdout
		if bytes > MAX_PROTOCOL_BYTES then fail(); return end
		if start_dispatching then queued[#queued + 1] = stdout; return end
		buffer = buffer .. stdout
		while true do
			local ending = buffer:find("\n", 1, true)
			if not ending then break end
			local value = buffer:sub(1, ending - 1)
			buffer = buffer:sub(ending + 1)
			if #value > MAX_PROTOCOL_LINE then fail(); return end
			line(value)
		end
		if #buffer > MAX_PROTOCOL_LINE then fail() end
		notify()
	end
	raw = transport(helper, { "--owned-program-worker" }, function(code, stdout, stderr)
		consume(stdout, stderr)
		physical, helper_success = true, code == 0
		if code ~= 0 then invalid = true end
		notify()
	end, function(_, stdout, stderr) consume(stdout, stderr); return true end, nil, true, true)
	if type(raw) ~= "table" or raw.isSettled() == true then return refused() end
	M._active_tasks[handle] = true
	raw.onSettled(function() physical = true; notify() end)
	function handle.start()
		if phase ~= "prepared" then return false end
		phase = "admitting"
		local ok, allowed = pcall(admitted)
		if not ok or allowed ~= true or cancelled then cancel(); return false end
		phase, start_dispatching, start_attempted = "waiting", true, true
		local started = raw.start() == true
		start_dispatching = false
		if not started then cancelled = true end
		local pending = queued
		queued = {}
		for _, value in ipairs(pending) do bytes = bytes - #value; consume(value, "") end
		if not started then cancel(); return false end
		if not cancelled and not invalid then
			request_sent = true
			if raw.set_input(request .. "\n") ~= true then cancel(); return false end
		end
		notify()
		return not cancelled and not invalid
	end
	function handle.terminate()
		if settled() then return true, "settled" end
		local accepted = cancel()
		return accepted, settled() and "settled" or accepted and "pending" or "refused"
	end
	function handle.isSettled() return settled() end
	--- Reports unresolved native cleanup without conflating healthy execution.
	--- @return boolean pending
	function handle.hasCleanupDebt()
		return not settled() and (invalid or cancelled or physical)
	end
	function handle.onSettled(observer)
		if type(observer) ~= "function" then return false end
		if settled() then pcall(observer) else observers[#observers + 1] = observer end
		return true
	end
	return handle
end

return M
