--- modules/keystats/ledger_replay.lua

--- ==============================================================================
--- MODULE: Bounded Local Ledger Replay
--- DESCRIPTION:
--- Rebuilds a fresh SQLite cache from this device's durable data.sql in steps
--- that each read one bounded block, apply only complete batches and stop once
--- a main-thread budget is spent. The resumable state (the byte offset applied
--- so far, always a batch boundary, and the ledger markers the today.log cursor
--- needs) is plain data the caller persists between steps, so an interrupted
--- replay resumes where it stopped instead of starting over.
---
--- FEATURES & RATIONALE:
--- 1. After a Mac reboot emptied TMPDIR, the whole 320 MB ledger was read into
---    one string, scanned byte by byte and executed in one call: the deferred
---    keystats start held the main thread 138 s (field ledger L64).
--- 2. The batch boundary rule is the one of Export._last_complete_batch_offset:
---    a "\nCOMMIT;\n" outside a string literal and outside a comment.
--- 3. The cursor is computed by the caller's existing cursor function over the
---    few markers it depends on, so a resumed replay yields the same cursor as
---    one pass over the whole ledger.
--- ==============================================================================

local M = {}

--- Bytes read per block. One block scans and applies in a few milliseconds,
--- well inside the recovery slice budget.
M.READ_BYTES = 32 * 1024

--- Version of the persisted state; another value is refused, never guessed.
M.STATE_VERSION = 1

local ROLLOVER_LINE = "^%-%- === day rollover .- %-%> %d%d%d%d%-%d%d%-%d%d ===$"
local BATCH_LINE = "^%-%- === ingest batch [^%(]- %(offset %d+ %-%> %d+,"

--- Creates the state of a replay that has applied nothing yet.
--- @return table state
function M.new_state()
	return { version = M.STATE_VERSION, offset = 0 }
end

--- Validates a persisted state before it is trusted.
--- @param state any Decoded state.
--- @return boolean valid
function M.is_state(state)
	if type(state) ~= "table" or state.version ~= M.STATE_VERSION then return false end
	if math.type(state.offset) ~= "integer" and not (type(state.offset) == "number" and state.offset % 1 == 0) then
		return false
	end
	if state.offset < 0 then return false end
	for _, key in ipairs({ "rollover", "first_batch", "last_batch" }) do
		if state[key] ~= nil and type(state[key]) ~= "string" then return false end
	end
	return true
end

--- Records one confirmed marker line in the state.
--- @param state table Replay state.
--- @param line string Marker line.
local function confirm_marker(state, line)
	if line:match(ROLLOVER_LINE) then
		state.rollover = line
		state.last_batch = nil
	elseif line:match(BATCH_LINE) then
		if state.rollover == nil and state.first_batch == nil then state.first_batch = line end
		state.last_batch = line
	end
end

--- Builds the marker-only ledger the cursor function reads.
--- @param state table Replay state.
--- @return string compact
local function compact_markers(state)
	local lines = {}
	if state.rollover then
		lines[#lines + 1] = state.rollover
		if state.last_batch then lines[#lines + 1] = state.last_batch end
	elseif state.first_batch then
		lines[#lines + 1] = state.first_batch
		if state.last_batch and state.last_batch ~= state.first_batch then lines[#lines + 1] = state.last_batch end
	end
	if #lines == 0 then return "" end
	return table.concat(lines, "\n") .. "\n"
end

--- Scans `buf` from `pos` for batch boundaries and marker lines.
--- @param scan table Scanner state { pos, in_string, last_commit, markers }.
--- @param buf string Bytes from the state offset.
--- @param eof boolean True when no byte follows `buf`.
local function scan_buffer(scan, buf, eof)
	local n = #buf
	local p = scan.pos
	while p <= n do
		if scan.in_string then
			local q = buf:find("'", p, true)
			if not q then p = n + 1; break end
			if q == n and not eof then p = q; break end
			if buf:sub(q + 1, q + 1) == "'" then p = q + 2
			else scan.in_string = false; p = q + 1 end
		else
			local q = buf:find("[%-'\n]", p)
			if not q then p = n + 1; break end
			local c = buf:sub(q, q)
			if c == "'" then
				scan.in_string = true
				p = q + 1
			elseif c == "-" then
				if q == n and not eof then p = q; break end
				if buf:sub(q + 1, q + 1) == "-" then
					local e = buf:find("\n", q + 2, true)
					if not e then
						if not eof then p = q; break end
						e = n + 1
					end
					if q == 1 or buf:sub(q - 1, q - 1) == "\n" then
						scan.markers[#scan.markers + 1] = { at = q, line = buf:sub(q, e - 1) }
					end
					-- The newline that ends a comment is consumed with it, as in the
					-- byte scanner: it never opens a COMMIT boundary.
					p = e + 1
				else
					p = q + 1
				end
			else
				if n - q < 8 and not eof then p = q; break end
				if buf:sub(q + 1, q + 8) == "COMMIT;\n" then
					scan.last_commit = q + 8
					p = q + 9
				else
					p = q + 1
				end
			end
		end
	end
	scan.pos = p
end

--- Runs one bounded replay step.
--- @param options table {
---   path string      Ledger path.
---   size integer     Ledger size captured for this replay (bytes past it are ignored).
---   state table      Replay state, updated in place only after each applied batch run.
---   exec function    Applies SQL text; returns true or false, detail.
---   clock function   Monotonic nanoseconds.
---   deadline integer Clock value after which the step returns.
---   cursor function  (ledger, complete_offset) -> cursor table.
---   open function|nil io.open replacement (tests). }
--- @return string status "more", "done" or "failed".
--- @return table|string|nil detail Cursor when done, reason when failed.
function M.step(options)
	local state, size = options.state, options.size
	if not M.is_state(state) then return "failed", "invalid replay state" end
	-- A JSON round trip may hand the offset back as an integral float.
	state.offset = math.tointeger(state.offset)
	if math.type(size) ~= "integer" or size < 0 then return "failed", "invalid ledger size" end
	if state.offset > size then return "failed", "the ledger is shorter than the replayed offset" end
	if state.offset == size then
		return "done", options.cursor(compact_markers(state), #compact_markers(state))
	end
	local file = (options.open or io.open)(options.path, "rb")
	if not file then return "failed", "the ledger cannot be opened" end
	local ok, status, detail = pcall(function()
		if file:seek("set", state.offset) ~= state.offset then return "failed", "the ledger cannot be positioned" end
		local buf, read_to = "", state.offset
		local scan = { pos = 1, in_string = false, last_commit = 0, markers = {} }
		while true do
			local want = math.min(M.READ_BYTES, size - read_to)
			if want > 0 then
				local block = file:read(want)
				if type(block) ~= "string" or #block ~= want then
					return "failed", "the ledger ended before its captured size"
				end
				buf = buf .. block
				read_to = read_to + want
			end
			local eof = read_to >= size
			scan_buffer(scan, buf, eof)
			local applied = scan.last_commit
			if applied > 0 then
				local exec_ok, exec_detail = options.exec(buf:sub(1, applied))
				if exec_ok ~= true then return "failed", exec_detail or "the cache refused a ledger batch" end
				local kept = {}
				for _, marker in ipairs(scan.markers) do
					if marker.at <= applied then confirm_marker(state, marker.line)
					else kept[#kept + 1] = { at = marker.at - applied, line = marker.line } end
				end
				state.offset = state.offset + applied
				buf = buf:sub(applied + 1)
				scan.pos = scan.pos - applied
				scan.last_commit = 0
				scan.markers = kept
			end
			if eof then
				-- Only markers inside complete batches are confirmed; the trailing
				-- bytes go to the cursor function, which admits a rollover-only tail.
				local compact = compact_markers(state)
				return "done", options.cursor(compact .. buf, #compact)
			end
			-- A batch larger than one block keeps reading: no step may end
			-- without progress, or a large batch would never be applied.
			if applied > 0 and options.clock() >= options.deadline then return "more" end
		end
	end)
	file:close()
	if not ok then return "failed", tostring(status) end
	return status, detail
end

return M
