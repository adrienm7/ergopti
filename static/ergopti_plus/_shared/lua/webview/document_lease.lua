--- _shared/lua/webview/document_lease.lua
--- ==============================================================================
--- MODULE: Native Document Initialization Lease
--- DESCRIPTION:
--- Binds private native load ownership to an actual page nonce, opaque native
--- challenge and bounded real bridge roundtrip. Native callbacks are ports.
--- ==============================================================================

local M = {}
local next_generation = 0
local MAX_GENERATION = 9007199254740991 -- JSON/JavaScript exact integer boundary.

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

--- Creates one native window's lease owner. No page supplies these ports.
--- @param ports table Native clock/current/read_document/nonce/deadline/read_nonce/challenge/confirm.
--- @return table
function M.new(ports)
	assert(type(ports) == "table", "document lease requires native ports")
	for _, name in ipairs({ "clock", "current", "read_document", "nonce", "deadline", "read_nonce", "challenge", "confirm" }) do
		assert(type(ports[name]) == "function", "document lease requires " .. name)
	end
	assert(finite(ports.timeout_ms) and ports.timeout_ms % 1 == 0 and ports.timeout_ms > 0
		and ports.timeout_ms <= 2147483647, "document initialization deadline must be a bounded integer")
	assert(type(ports.uri) == "string" and ports.uri ~= "", "document lease requires the actual native base URI")
	local owner = {}
	local active, last_load, closed = nil, nil, false
	local debts, settled_listeners = {}, {}
	local used_tokens = {}

	local function private_current(record)
		return not closed and active == record and not record.retired
	end

	local function now()
		local ok, value = pcall(ports.clock)
		return ok and finite(value) and value or nil
	end

	local function within_budget(record)
		local value = now()
		return finite(record.started) and finite(record.deadline)
			and value ~= nil and value >= record.started and value < record.deadline
	end

	local function observed_current(record)
		if not private_current(record) then return false end
		local ok, current = pcall(ports.current)
		if not ok or current ~= true or not private_current(record) then return false end
		local read, uri, loading = pcall(ports.read_document)
		if not read or uri ~= ports.uri or loading ~= false or not private_current(record) then return false end
		ok, current = pcall(ports.current)
		return ok and current == true and private_current(record)
	end

	local function notify_settled()
		if not closed or next(debts) ~= nil then return end
		local callbacks = settled_listeners
		settled_listeners = {}
		for _, callback in ipairs(callbacks) do pcall(callback) end
	end

	local function release_debt(work)
		local ok, settled = pcall(work.is_settled, work)
		if ok and settled == true then debts[work] = nil; notify_settled(); return true end
		return false
	end

	local function cancel_work(record)
		local work = record.work
		if not work then return true end
		-- Detach consent first; cancellation may reenter a new load/window.
		record.work = nil
		local ok, accepted = pcall(work.cancel, work)
		if not ok or accepted ~= true then debts[work] = record; return false end
		return release_debt(work)
	end

	local function refusal_current(record)
		return not closed and active == nil and last_load == record and record.retired
			and record.failure_reason ~= nil
	end

	local function retire(record, reason)
		if record.retired then return end
		record.retired, record.state, record.failure_reason = true, "retired", reason
		if active == record then active = nil end
		cancel_work(record)
		-- Native cleanup can synchronously create a successor; it owns no old notice.
		if reason and refusal_current(record) and type(ports.on_refused) == "function" then
			pcall(ports.on_refused, record, reason)
		end
	end

	local function current_initialization(record)
		if not private_current(record) or not within_budget(record) then
			if private_current(record) then retire(record, "deadline") end
			return false
		end
		return observed_current(record) and within_budget(record) and private_current(record)
	end

	local function confirm(record)
		if record.state ~= "ack_pending" or not current_initialization(record) then return end
		record.state = "confirming"
		local ok, accepted = pcall(ports.confirm, record.generation, record.token, record.page_nonce)
		if not ok or accepted ~= true then
			if private_current(record) then retire(record, "confirmation") end
		end
	end

	--- Revokes the previous document before any native cleanup or entropy read.
	function owner.start_load()
		if closed or next_generation >= MAX_GENERATION then return false end
		local previous = active
		if previous then retire(previous) end
		if closed or active ~= nil then return false end
		next_generation = next_generation + 1
		local record = { generation = next_generation, state = "allocating", retired = false }
		active, last_load = record, record
		local started = now()
		if not private_current(record) then return false end
		if not started then retire(record, "clock"); return false end
		record.started, record.deadline, record.state = started, started + ports.timeout_ms, "loading"
		local ok, token = pcall(ports.nonce)
		if not private_current(record) then return false end
		if not ok or type(token) ~= "string" or #token ~= 24 or token:find("[^A-Za-z0-9+/]")
			or used_tokens[token] then retire(record, "entropy"); return false end
		record.token, used_tokens[token] = token, true
		local allocated, work = pcall(ports.deadline, record.deadline, function()
			if private_current(record) and record.state ~= "admitted" then retire(record, "deadline") end
		end)
		if not allocated or type(work) ~= "table" or type(work.cancel) ~= "function"
			or type(work.is_settled) ~= "function" or type(work.on_settled) ~= "function" then
			if private_current(record) then retire(record, "timer") end
			return false
		end
		debts[work] = record
		-- A synchronous allocation callback may already have retired this record.
		if private_current(record) then record.work = work else pcall(work.cancel, work) end
		local listened, listening = pcall(work.on_settled, work, function()
			if release_debt(work) and private_current(record) and record.state == "ack_pending" then confirm(record) end
		end)
		if work.started ~= true or not listened or listening ~= true or not private_current(record) then
			if private_current(record) then retire(record, "timer") end
			return false
		end
		return true
	end

	--- Reads the real current page's intrinsic nonce through an owned result callback.
	function owner.finished_load()
		local record = active
		if not record or record.state ~= "loading" or not current_initialization(record) then return false end
		record.state = "reading_nonce"
		local called, accepted = pcall(ports.read_nonce, function(page_nonce)
			if record.state ~= "reading_nonce" or not current_initialization(record) then return end
			if type(page_nonce) ~= "string" or #page_nonce ~= 36 or page_nonce:find("[^0-9a-f]") then retire(record, "page_nonce"); return end
			record.page_nonce, record.state = page_nonce, "challenged"
			local ok, handed = pcall(ports.challenge, record.generation, record.token, page_nonce)
			if not ok or handed ~= true then if private_current(record) then retire(record, "challenge") end end
		end)
		if not called or accepted ~= true then if private_current(record) then retire(record, "nonce_read") end; return false end
		return private_current(record)
	end

	local function matches(record, metadata)
		return type(metadata) == "table" and metadata.generation == record.generation
			and metadata.token == record.token and metadata.page_nonce == record.page_nonce
	end

	--- Admits only an exact actual challenge ACK; physical timer retirement precedes confirmation.
	function owner.ack(metadata)
		local record = active
		if not record or record.state ~= "challenged" or not matches(record, metadata)
			or not current_initialization(record) then return false end
		record.state = "ack_pending"
		local work = record.work
		if not work then retire(record, "timer"); return false end
		if cancel_work(record) and private_current(record) then confirm(record) end
		return private_current(record)
	end

	--- Returns only a private admitted lease, never a page-provided owner object.
	function owner.admit(metadata, payload)
		local record = active
		if not record or not matches(record, metadata) then return nil end
		if record.state == "confirming" then
			if payload ~= "ready" or not current_initialization(record) then return nil end
			record.state = "admitted"
		end
		if record.state ~= "admitted" or not observed_current(record) then return nil end
		return record
	end

	function owner.capture()
		local record = active
		return record and record.state == "admitted" and observed_current(record) and record or nil
	end

	--- Exact failed load lineage for a native notice; no document gains action consent.
	function owner.refusal_current(record)
		return type(record) == "table" and refusal_current(record)
	end

	--- Final private fence after reentrant native observations; performs no native I/O.
	function owner.retains(record)
		return type(record) == "table" and record.state == "admitted" and private_current(record)
	end

	function owner.current(record)
		return type(record) == "table" and record.state == "admitted" and observed_current(record)
	end

	--- GTK's existing bounded event-loop pump also expires a pending confirmation.
	function owner.poll()
		local record = active
		if record and record.state ~= "admitted" and not within_budget(record) then retire(record, "deadline") end
	end

	--- Logical retirement always precedes physical cleanup; retain every unsettled timer.
	function owner.close()
		closed = true
		local record = active
		active = nil
		if record then retire(record) end
		local settled = true
		local captured = {}
		for work in pairs(debts) do captured[#captured + 1] = work end
		for _, work in ipairs(captured) do
			pcall(work.cancel, work)
			if not release_debt(work) then settled = false end
		end
		return settled
	end

	function owner.on_settled(callback)
		if type(callback) ~= "function" then return false end
		if closed and owner.is_settled() then pcall(callback) else settled_listeners[#settled_listeners + 1] = callback end
		return true
	end

	function owner.is_settled()
		for work in pairs(debts) do if not release_debt(work) then return false end end
		return true
	end

	return owner
end

return M
