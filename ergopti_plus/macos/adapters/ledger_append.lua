--- adapters/ledger_append.lua

--- ==============================================================================
--- MODULE: Durable SQL Ledger Append Ownership
--- DESCRIPTION:
--- A bounded adjacent journal owns the exact append boundary before any byte is
--- written. Retrying completes only a verified prefix of that same batch, even
--- after the disposable SQLite cache disappears. Canonical bytes are never cut.
--- Restart recovery is not a claim of hardware fsync or power-loss ordering.
--- ==============================================================================

local M = {}
local FileSystem = require("adapters.file_system")
local json = require("hs.json")
local fs = require("hs.fs")
local LOG = "adapters.ledger_append"
local Logger = require("infra.logger")
local busy, lock_debt, publication_debt = false, nil, nil
local JOURNAL_SUFFIX = ".append-journal.json"

--- Retries only already-owned native release capabilities.
--- @return boolean settled
local function settle()
	if publication_debt then
		local ok, released = pcall(publication_debt)
		if not ok or released ~= true then return false end
		publication_debt = nil
	end
	if lock_debt then
		local ok, released = pcall(FileSystem.release_write_locks, lock_debt)
		if not ok or released ~= true then return false end
		lock_debt = nil
	end
	return true
end

local function integer(value)
	return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

local function attributes(path)
	local value, status = FileSystem.classify_no_follow(path)
	if status ~= "ok" or type(value) ~= "table" or value.mode ~= "file"
		or not integer(value.dev) or not integer(value.ino) or not integer(value.size) then return nil end
	return value
end

local function valid(receipt, path)
	if type(receipt) ~= "table" or getmetatable(receipt) ~= nil then return false end
	local fields = { version = true, path = true, resolved = true, dev = true, ino = true,
		offset = true, batch = true, phase = true }
	for key in pairs(receipt) do if not fields[key] then return false end end
	return receipt.version == 1 and receipt.path == path and type(receipt.resolved) == "string"
		and receipt.resolved:sub(1, 1) == "/" and integer(receipt.dev) and integer(receipt.ino)
		and integer(receipt.offset) and type(receipt.batch) == "string" and receipt.batch ~= ""
		and (receipt.phase == "pending" or receipt.phase == "settled")
end

local function load_journal(path)
	local content, status = FileSystem.read_with_status(path .. JOURNAL_SUFFIX)
	if status == "absent" then return nil, { status = "absent" }, true end
	if status ~= "ok" or type(content) ~= "string" then return nil, nil, false end
	local ok, receipt = pcall(json.decode, content)
	if not ok or not valid(receipt, path) then return nil, nil, false end
	return receipt, { status = "ok", content = content }, true
end

local function publish_journal(path, receipt, expected)
	local encoded = json.encode(receipt)
	if type(encoded) ~= "string" then return false end
	local written, _, cleanup = FileSystem.write_if_unchanged(path .. JOURNAL_SUFFIX, encoded, expected)
	if cleanup ~= nil then
		assert(type(cleanup) == "function", "ordinary ledger publication requires a cleanup capability")
		publication_debt = cleanup
	end
	if written ~= true then return false end
	return true, { status = "ok", content = encoded }
end

local function current(receipt, resolved)
	if resolved ~= receipt.resolved then return nil end
	local value = attributes(resolved)
	local route = fs.attributes(receipt.path)
	if type(route) ~= "table" or route.dev ~= receipt.dev or route.ino ~= receipt.ino then return nil end
	if not value or value.dev ~= receipt.dev or value.ino ~= receipt.ino
		or value.size < receipt.offset or value.size > receipt.offset + #receipt.batch then return nil end
	return value
end

--- Reads at most one batch and an overrun byte; EOF is accepted only at exact size.
local function tail(receipt, resolved)
	local before = current(receipt, resolved)
	if not before then return nil end
	local file = io.open(resolved, "rb")
	if not file then return nil end
	local ok, content = pcall(function()
		if file:seek("set", receipt.offset) ~= receipt.offset then return nil end
		local bytes, read_error = file:read(#receipt.batch + 1)
		if bytes == nil and read_error == nil and before.size == receipt.offset then bytes = "" end
		return bytes
	end)
	local closed, ack = pcall(file.close, file)
	if not ok or not closed or ack ~= true or type(content) ~= "string" then return nil end
	local after = current(receipt, resolved)
	if not after or before.size ~= after.size or #content ~= after.size - receipt.offset
		or content ~= receipt.batch:sub(1, #content) then return nil end
	return content
end

local function resume(receipt, resolved)
	local prefix = tail(receipt, resolved)
	if prefix == nil then return false end
	if #prefix == #receipt.batch then return true end
	local file = io.open(resolved, "ab")
	if not file then return false end
	local written, ack = pcall(file.write, file, receipt.batch:sub(#prefix + 1))
	local closed, close_ack = pcall(file.close, file)
	if not written or ack ~= file or not closed or close_ack ~= true then return false end
	return tail(receipt, resolved) == receipt.batch
end

--- Runs one operation while retaining every refused lock/publication cleanup.
local function owned(path, operation)
	if busy then return false end
	busy = true
	local ok, accepted = xpcall(function()
		if not settle() then return false end
		local group, acquired = FileSystem.acquire_write_locks({ path })
		lock_debt = group
		if acquired ~= true then return false end
		local resolved = group.resolved_paths[path]
		if type(resolved) ~= "string" then return false end
		return operation(resolved)
	end, debug.traceback)
	local released = settle()
	busy = false
	if not ok or accepted ~= true or not released then
		Logger.error(LOG, "Canonical ledger append remains pending; exact journal and outbox preserved.")
		return false
	end
	return true
end

--- Releases retained native capabilities without reopening SQLite or appending SQL.
--- @return boolean complete False preserves the caller's lifecycle cleanup retry.
function M.cleanup()
	if busy then return false end
	busy = true
	local ok, released = pcall(settle)
	busy = false
	return ok and released == true
end

--- Completes a pending durable batch before a fresh-cache replay can read it.
--- @param path string Canonical local ledger path.
--- @param batch string Existing SQLite outbox; empty is legitimate after cache loss.
--- @return boolean recovered No new intent is created and no journal is settled here.
function M.recover(path, batch)
	return owned(path, function(resolved)
		local receipt, _, loaded = load_journal(path)
		if not loaded then return false end
		if not receipt or receipt.phase == "settled" then return true end
		if batch ~= "" and batch ~= receipt.batch then return false end
		return resume(receipt, resolved)
	end)
end

--- Publishes or resumes a batch, then clears its SQLite outbox before settling.
--- @param path string Canonical local ledger path.
--- @param batch string Exact pending SQLite outbox, possibly empty after an uncertain clear.
--- @param clear function Transactional outbox clear; must acknowledge literal true.
--- @param origin function Validates an unjournaled legacy ledger once, never per batch.
--- @return boolean committed The durable journal and SQLite agree on publication.
function M.flush(path, batch, clear, origin)
	assert(type(batch) == "string" and type(clear) == "function" and type(origin) == "function",
		"invalid ledger append ownership")
	return owned(path, function(resolved)
		local receipt, expected, loaded = load_journal(path)
		if not loaded then return false end
		if receipt and receipt.phase == "pending" then
			if batch ~= "" and batch ~= receipt.batch then return false end
		elseif batch == "" then return true
		else
			local source = attributes(resolved)
			if not source then return false end
			local changed_origin = receipt and (receipt.resolved ~= resolved or source.dev ~= receipt.dev
				or source.ino ~= receipt.ino or source.size < receipt.offset + #receipt.batch)
			local offset = source.size
			-- Legacy files and the shipped compactor's atomic replacement require
			-- rare full admission; ordinary settled batches never reread history.
			if receipt == nil or changed_origin then
				local content, status = FileSystem.read_with_status(path)
				if status ~= "ok" or type(content) ~= "string" or #content ~= offset then return false end
				if #content >= #batch and content:sub(-#batch) == batch
					and origin(content:sub(1, #content - #batch)) == true then
					offset = #content - #batch
				elseif origin(content) ~= true then return false end
			end
			receipt = { version = 1, path = path, resolved = resolved, dev = source.dev, ino = source.ino,
				offset = offset, batch = batch, phase = "pending" }
			local published, next_expected = publish_journal(path, receipt, expected)
			if not published then return false end
			expected = next_expected
		end
		if not resume(receipt, resolved) then return false end
		if clear() ~= true then return false end
		local terminal = {}
		for key, value in pairs(receipt) do terminal[key] = value end
		terminal.phase = "settled"
		return publish_journal(path, terminal, expected)
	end)
end

return M
