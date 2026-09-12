--- ui/download_window/pending_queue.lua

--- ==============================================================================
--- MODULE: Download Window Pending Presentation Queue
--- DESCRIPTION:
--- Retains structural presentation updates independently of a bounded log tail.
--- State setters coalesce in last-update order; log append uses a fixed ring so
--- noisy subprocess output cannot evict initialization or shift a large array.
--- ==============================================================================

local M = {}

local LOG_CAPACITY = 200
local QUEUE_METATABLE = {}
local STATE_KEYS = {
	resetUI = true,
	setKind = true,
	setModel = true,
	update = true,
	showLog = true,
	done = true,
	setStep = true,
	setDetail = true,
	setProgress = true,
	setError = true,
}

--- Rejects objects that were not allocated by this queue owner.
--- @param queue table Pending queue.
local function require_queue(queue)
	assert(type(queue) == "table" and getmetatable(queue) == QUEUE_METATABLE,
		"pending presentation queue must be created by new()")
end

--- Creates one independent presentation queue for a window session.
--- @return table queue Empty queue.
function M.new()
	return setmetatable({
		state = {},
		sequence = 0,
		logs = {},
		log_head = 1,
		log_count = 0,
		dropped = 0,
	}, QUEUE_METATABLE)
end

--- Retains one command without letting log overflow discard structural state.
--- @param queue table Queue created by new().
--- @param key string Explicit presentation method, or addLog for disposable text.
--- @param code string JavaScript command prepared by the window owner.
--- @return boolean accepted True once the command is retained.
function M.push(queue, key, code)
	require_queue(queue)
	assert(type(key) == "string" and (key == "addLog" or STATE_KEYS[key] == true),
		"unknown pending presentation key")
	assert(type(code) == "string" and code ~= "", "presentation command must be a non-empty string")
	if key ~= "addLog" then
		queue.sequence = queue.sequence + 1
		queue.state[key] = { order = queue.sequence, code = code }
		return true
	end

	if queue.log_count < LOG_CAPACITY then
		local slot = (queue.log_head + queue.log_count - 1) % LOG_CAPACITY + 1
		queue.logs[slot] = code
		queue.log_count = queue.log_count + 1
	else
		queue.logs[queue.log_head] = code
		queue.log_head = queue.log_head % LOG_CAPACITY + 1
		queue.dropped = queue.dropped + 1
	end
	return true
end

--- Detaches ordered state followed by the retained log tail and resets the queue.
--- @param queue table Queue created by new().
--- @return table codes Latest state commands followed by the newest log commands.
--- @return integer dropped Number of old log commands discarded since the last drain.
function M.drain(queue)
	require_queue(queue)
	local state = {}
	for _, entry in pairs(queue.state) do state[#state + 1] = entry end
	table.sort(state, function(left, right) return left.order < right.order end)
	local codes = {}
	for _, entry in ipairs(state) do codes[#codes + 1] = entry.code end
	for offset = 0, queue.log_count - 1 do
		local slot = (queue.log_head + offset - 1) % LOG_CAPACITY + 1
		codes[#codes + 1] = queue.logs[slot]
	end
	local dropped = queue.dropped
	queue.state = {}
	queue.sequence = 0
	queue.logs = {}
	queue.log_head = 1
	queue.log_count = 0
	queue.dropped = 0
	return codes, dropped
end

return M
