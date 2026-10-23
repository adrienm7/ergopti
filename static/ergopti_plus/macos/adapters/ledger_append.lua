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

local function date(value, empty)
	if empty and value == "" then return true end
	if type(value) ~= "string" then return false end
	local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	if not year or year < 1 or month < 1 or month > 12 or day < 1 then return false end
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then days[2] = 29 end
	return day <= days[month]
end

local function plain(value, fields)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	for key in pairs(value) do if not fields[key] then return false end end
	return true
end

local function absolute(value)
	return type(value) == "string" and value:sub(1, 1) == "/"
end

local function marker(previous_date, next_date)
	return string.format("\n-- === day rollover %s -> %s ===\n", previous_date, next_date)
end

local function valid_today(value, offset)
	if not plain(value, { path = true, resolved = true, present = true,
		dev = true, ino = true, size = true })
		or not absolute(value.path) or not absolute(value.resolved) then return false end
	if value.present == false then
		return offset == 0 and value.dev == nil and value.ino == nil and value.size == nil
	end
	return value.present == true and integer(value.dev) and integer(value.ino)
		and integer(value.size) and value.size == offset
end

local function valid(receipt, path)
	if not plain(receipt, { version = true, path = true, resolved = true, dev = true, ino = true,
		offset = true, batch = true, phase = true, kind = true, today = true,
		consumed_offset = true, previous_date = true, date = true }) then return false end
	if receipt.path ~= path or not absolute(receipt.resolved) or not integer(receipt.dev)
		or not integer(receipt.ino) or not integer(receipt.offset)
		or type(receipt.batch) ~= "string" or receipt.batch == "" then return false end
	if receipt.version == 1 then
		return receipt.kind == nil and receipt.today == nil and receipt.consumed_offset == nil
			and receipt.previous_date == nil and receipt.date == nil
			and (receipt.phase == "pending" or receipt.phase == "settled")
	end
	return receipt.version == 2 and receipt.kind == "rollover" and receipt.phase == "pending"
		and integer(receipt.consumed_offset) and valid_today(receipt.today, receipt.consumed_offset)
		and date(receipt.previous_date, true) and date(receipt.date)
		and receipt.batch == marker(receipt.previous_date, receipt.date)
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
local function owned(path, operation, adjacent_path)
	if busy then return false end
	busy = true
	local ok, accepted = xpcall(function()
		if not settle() then return false end
		local paths = adjacent_path and { path, adjacent_path } or { path }
		local group, acquired = FileSystem.acquire_write_locks(paths)
		lock_debt = group
		if acquired ~= true then return false end
		local resolved = group.resolved_paths[path]
		if type(resolved) ~= "string" then return false end
		return operation(resolved, group)
	end, debug.traceback)
	local released = settle()
	busy = false
	if not ok or accepted ~= true or not released then
		Logger.error(LOG, "Canonical ledger operation remains pending; durable intent and cleanup retained.")
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

--- Produces the original append schema only after its cache acknowledgement.
local function terminal(receipt)
	return { version = 1, path = receipt.path, resolved = receipt.resolved, dev = receipt.dev,
		ino = receipt.ino, offset = receipt.offset, batch = receipt.batch, phase = "settled" }
end

--- Builds one exact append intent, retaining the existing legacy-origin admission.
local function prepare_append(path, resolved, batch, previous, origin)
	local source = attributes(resolved)
	if not source then return nil end
	local changed_origin = previous and (previous.resolved ~= resolved or source.dev ~= previous.dev
		or source.ino ~= previous.ino or source.size < previous.offset + #previous.batch)
	local offset = source.size
	if previous == nil or changed_origin then
		local content, status = FileSystem.read_with_status(path)
		if status ~= "ok" or type(content) ~= "string" or #content ~= offset then return nil end
		if #content >= #batch and content:sub(-#batch) == batch
			and origin(content:sub(1, #content - #batch)) == true then
			offset = #content - #batch
		elseif origin(content) ~= true then return nil end
	end
	return { version = 1, path = path, resolved = resolved, dev = source.dev, ino = source.ino,
		offset = offset, batch = batch, phase = "pending" }
end

--- Captures only a consumed regular journal or a proven empty absent journal.
local function snapshot_today(path, resolved, offset)
	local route, status = FileSystem.classify_no_follow(path)
	local source, source_status = FileSystem.classify_no_follow(resolved)
	if status == "absent" and source_status == "absent" and offset == 0 then
		return { path = path, resolved = resolved, present = false }
	end
	if status ~= "ok" or source_status ~= "ok" or type(route) ~= "table" or route.mode ~= "file"
		or type(source) ~= "table" or source.mode ~= "file" or not integer(source.dev)
		or not integer(source.ino) or source.size ~= offset
		or route.dev ~= source.dev or route.ino ~= source.ino or route.size ~= source.size then return nil end
	return { path = path, resolved = resolved, present = true,
		dev = source.dev, ino = source.ino, size = source.size }
end

--- Retirement never escapes the journal owner as an independently reusable capability.
local function retire_today(receipt, path, resolved)
	local expected = receipt.today
	if expected.path ~= path or expected.resolved ~= resolved then return false end
	local route, status = FileSystem.classify_no_follow(path)
	local source, source_status = FileSystem.classify_no_follow(resolved)
	if status == "absent" and source_status == "absent" then return true end
	if not expected.present or status ~= "ok" or source_status ~= "ok"
		or type(route) ~= "table" or route.mode ~= "file"
		or type(source) ~= "table" or source.mode ~= "file"
		or route.dev ~= expected.dev or route.ino ~= expected.ino or route.size ~= expected.size
		or source.dev ~= expected.dev or source.ino ~= expected.ino or source.size ~= expected.size then return false end
	if FileSystem.remove_exact(resolved) ~= true then return false end
	local _, after = FileSystem.classify_no_follow(path)
	local _, resolved_after = FileSystem.classify_no_follow(resolved)
	return after == "absent" and resolved_after == "absent"
end

local function same_terminal(receipt, expected)
	if not valid(expected, receipt.path) or expected.version ~= 1 or expected.phase ~= "settled" then return false end
	for key, value in pairs(terminal(receipt)) do if expected[key] ~= value then return false end end
	return true
end

local function resume_rollover(path, receipt, expected, resolved, today_path, group, reset)
	if type(today_path) ~= "string" or type(reset) ~= "function"
		or receipt.today.path ~= today_path then return false end
	local today_resolved = group.resolved_paths[today_path]
	if type(today_resolved) ~= "string"
		or tail(receipt, resolved) == nil or not retire_today(receipt, today_path, today_resolved)
		or not resume(receipt, resolved) or reset(receipt.date, terminal(receipt)) ~= true then return false end
	return publish_journal(path, terminal(receipt), expected)
end

--- Repairs owned intent before replay and before a fresh journal writer is admitted.
--- @param path string Canonical local ledger path.
--- @param batch string Existing SQLite outbox; empty is legitimate after cache loss.
--- @param today_path string|nil Caller-bound journal path required for rollover recovery.
--- @param reset function|nil Checked idempotent cache reset required for rollover recovery.
--- @param completion table|nil Exact terminal identity retained by an acknowledged rollover reset.
--- @return boolean recovered No new intent is created.
function M.recover(path, batch, today_path, reset, completion)
	return owned(path, function(resolved, group)
		local receipt, expected, loaded = load_journal(path)
		if not loaded then return false end
		if completion ~= nil and (not receipt or not same_terminal(receipt, completion)) then return false end
		if not receipt or receipt.phase == "settled" then
			return completion == nil or tail(receipt, resolved) == receipt.batch
		end
		if receipt.version == 2 then
			if batch ~= "" then return false end
			return resume_rollover(path, receipt, expected, resolved, today_path, group, reset)
		end
		if completion ~= nil or (batch ~= "" and batch ~= receipt.batch) then return false end
		return resume(receipt, resolved)
	end, today_path)
end

--- Owns consumed-journal retirement, exact marker publication and cache reset.
--- The existing instance admission fences the live producer. These cooperative
--- path locks coordinate canonical mutation; they do not exclude unrelated writers.
--- @param path string Canonical local ledger path.
--- @param today_path string Expected local journal path, supplied by the caller.
--- @param offset integer Committed consumed offset backed by the settled outbox.
--- @param previous_date string Old canonical date, possibly empty at initialization.
--- @param next_date string New canonical date.
--- @param reset function Idempotent cache reset acknowledging literal true after COMMIT.
--- @param origin function Existing complete-ledger admission predicate.
--- @return boolean committed False retains exact intent or leaves retirement unstarted.
function M.rollover(path, today_path, offset, previous_date, next_date, reset, origin)
	assert(absolute(today_path) and integer(offset) and date(previous_date, true) and date(next_date)
		and type(reset) == "function" and type(origin) == "function", "invalid rollover ownership")
	return owned(path, function(resolved, group)
		local receipt, expected, loaded = load_journal(path)
		if not loaded then return false end
		if receipt and receipt.version == 2 then
			if receipt.today.path ~= today_path or receipt.consumed_offset ~= offset
				or receipt.previous_date ~= previous_date or receipt.date ~= next_date then return false end
		elseif receipt and receipt.phase == "pending" then return false
		else
			local today_resolved = group.resolved_paths[today_path]
			if type(today_resolved) ~= "string" then return false end
			local today = snapshot_today(today_path, today_resolved, offset)
			if not today then return false end
			receipt = prepare_append(path, resolved, marker(previous_date, next_date), receipt, origin)
			if not receipt then return false end
			receipt.version, receipt.kind = 2, "rollover"
			receipt.today, receipt.consumed_offset = today, offset
			receipt.previous_date, receipt.date = previous_date, next_date
			local published, next_expected = publish_journal(path, receipt, expected)
			if not published then return false end
			expected = next_expected
		end
		return resume_rollover(path, receipt, expected, resolved, today_path, group, reset)
	end, today_path)
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
		if not loaded or (receipt and receipt.version ~= 1) then return false end
		if receipt and receipt.phase == "pending" then
			if batch ~= "" and batch ~= receipt.batch then return false end
		elseif batch == "" then return true
		else
			receipt = prepare_append(path, resolved, batch, receipt, origin)
			if not receipt then return false end
			local published, next_expected = publish_journal(path, receipt, expected)
			if not published then return false end
			expected = next_expected
		end
		if not resume(receipt, resolved) then return false end
		if clear() ~= true then return false end
		return publish_journal(path, terminal(receipt), expected)
	end)
end

return M
