--- _shared/lua/core/llm/managed_ollama_daemon_receipt.lua

--- ==============================================================================
--- MODULE: Shared managed Ollama daemon lifecycle receipt
--- DESCRIPTION:
--- Receives complete fixed frames from one original foreground task. READY is
--- only an observation; native qualification and current source authority remain
--- with their owners. Child exit without RETIRED never releases native custody.
--- ==============================================================================

local M = {}
local issued_tasks = setmetatable({}, { __mode = "k" })
-- A lost caller reference cannot release a nonce with unsettled native custody.
local nonce_owners = {}

--- Prepares a receiver without launching, signalling or acquiring native resources.
--- @param task table Original transport handle, retained by its caller.
--- @param nonce string Exact lowercase hexadecimal caller nonce.
--- @param ports table Existing transport budget and exact-task physical predicate.
--- @return table|nil receiver Fixed observations, never a mutable native receipt.
--- @return string|nil reason Fixed protocol refusal.
function M.new(task, nonce, ports)
	if type(task) ~= "table" or type(nonce) ~= "string" or #nonce ~= 32
		or not nonce:match("^[0-9a-f]+$") or issued_tasks[task] or nonce_owners[nonce] then
		return nil, "protocol"
	end
	if type(ports) ~= "table" then return nil, "state" end
	for key in next, ports do
		if key ~= "max_protocol_bytes" and key ~= "is_settled"
			and key ~= "was_start_attempted" then return nil, "state" end
	end
	local max_protocol_bytes = rawget(ports, "max_protocol_bytes")
	local is_settled = rawget(ports, "is_settled")
	local was_start_attempted = rawget(ports, "was_start_attempted")
	if was_start_attempted ~= nil and type(was_start_attempted) ~= "function" then return nil, "state" end
	if type(max_protocol_bytes) ~= "number" or max_protocol_bytes ~= max_protocol_bytes
		or max_protocol_bytes <= 0 or max_protocol_bytes >= math.huge or max_protocol_bytes % 1 ~= 0
		or type(is_settled) ~= "function" then return nil, "state" end
	local checked, settled = pcall(is_settled, task)
	if not checked or settled ~= false then return nil, "state" end
	-- An external predicate may reenter before this receiver publishes custody.
	if issued_tasks[task] or nonce_owners[nonce] then return nil, "protocol" end

	local receiver = {}
	local buffer, received = "", 0
	local active, ready, retired = false, false, nil
	local invalid, joined = false, false
	issued_tasks[task] = true
	nonce_owners[nonce] = receiver

	local function refuse()
		invalid = true
		return false, "protocol"
	end

	local function receive_line(line)
		local actual, role = line:match("^ERGOPTI_MANAGED_DAEMON_V1 ([0-9a-f]+) (.+)$")
		if actual ~= nonce or retired ~= nil then return refuse() end
		if role == "ACTIVE" and not active then
			active = true
			return true
		end
		if role == "READY" and active and not ready then
			ready = true
			return true
		end
		local status = role and role:match("^RETIRED ([0-9]+)$") or nil
		if not status or #status > 3 or (status ~= "0" and status:sub(1, 1) == "0") then return refuse() end
		status = tonumber(status)
		if not status or status > 255 or (not ready and status ~= 78) then return refuse() end
		retired = status
		return true
	end

	--- Receives only stdout attributed by the caller to this original task.
	--- @param original table Exact task handle, not a PID or successor.
	--- @param chunk string Bounded fragment of the fixed lifecycle protocol.
	--- @return boolean accepted
	function receiver.feed(original, chunk)
		if not rawequal(original, task) then return false, "identity" end
		if invalid or joined then return false, "state" end
		if type(chunk) ~= "string" then return refuse() end
		received = received + #chunk
		if received > max_protocol_bytes or chunk:find("[^\n\032-\126]") then return refuse() end
		buffer = buffer .. chunk
		while true do
			local boundary = buffer:find("\n", 1, true)
			if not boundary then return true end
			local line = buffer:sub(1, boundary - 1)
			buffer = buffer:sub(boundary + 1)
			if receive_line(line) ~= true then return false, "protocol" end
		end
	end

	--- Reports READY observation only while the original task is still live.
	--- @param original table Exact original task.
	--- @return boolean observed
	function receiver.ready_observed(original)
		if not rawequal(original, task) or invalid or joined or retired ~= nil or not ready then return false end
		local ok, physical = pcall(is_settled, task)
		return ok == true and physical == false
	end

	--- Joins the native RETIRED frame to actual settlement and callback status.
	--- @param original table Exact original task.
	--- @param exit_status integer Original completion status.
	--- @return boolean retired
	--- @return string state Fixed retirement state.
	function receiver.finish(original, exit_status)
		if not rawequal(original, task) then return false, "identity" end
		if invalid then return false, "protocol" end
		local ok, physical = pcall(is_settled, task)
		if not ok or physical ~= true then return false, "pending" end
		if type(exit_status) ~= "number" or exit_status % 1 ~= 0 or exit_status < 0 or exit_status > 255
			or buffer ~= "" or retired == nil or exit_status ~= retired then return refuse() end
		joined = true
		if nonce_owners[nonce] == receiver then nonce_owners[nonce] = nil end
		return true, "retired"
	end

	--- Retires only an exact prepared task that never attempted native start.
	--- Missing or ambiguous provenance keeps the original nonce pinned.
	--- @param original table Exact original transport handle.
	--- @return boolean released
	--- @return string state Fixed preactivation state.
	function receiver.rollback_prepared(original)
		if not rawequal(original, task) then return false, "identity" end
		if invalid or joined or received ~= 0 or type(was_start_attempted) ~= "function" then
			return false, "pending"
		end
		local before_ok, before = pcall(was_start_attempted, task)
		if not before_ok or before ~= false then return false, "pending" end
		local settled_ok, physical = pcall(is_settled, task)
		local after_ok, after = pcall(was_start_attempted, task)
		if not settled_ok or physical ~= true or not after_ok or after ~= false
			or invalid or joined or received ~= 0 or nonce_owners[nonce] ~= receiver then
			return false, "pending"
		end
		joined = true
		nonce_owners[nonce] = nil
		return true, "prepared"
	end

	return receiver, nil
end

return M
