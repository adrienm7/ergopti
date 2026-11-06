--- adapters/apple_shortcuts_cli.lua

--- ==============================================================================
--- MODULE: Apple Shortcuts Command-Line Transport
--- DESCRIPTION:
--- The query and invocation ports of the chosen Apple Shortcut owner
--- (adapters/apple_shortcuts.lua) over the system tool /usr/bin/shortcuts:
--- `shortcuts list --show-identifiers` answers discovery and revalidation in
--- the owner's own reply format, and `shortcuts run <identifier>` invokes the
--- chosen shortcut for the run_apple_shortcut action.
---
--- FEATURES & RATIONALE:
--- 1. The owner keeps its rules: the reply is validated by validate_reply, a
---    revalidation of an identifier the library no longer holds is refused as
---    `missing`, and a name that changed since discovery as `stale_discovery`.
--- 2. Every process is bounded by the request's byte limit and deadline, and
---    stopped when it passes either; the tool's identity (path and file
---    fingerprint) is checked before each query and run.
--- 3. Cancellation stops the command-line tool. Shortcuts runs a shortcut in
---    its own service, which may finish the actions already handed to it: the
---    owner's automation receipt here is the tool's exit, and the README says
---    so (security notes of _shared/modules/actions).
--- 4. Payload-free native logging: shortcut names, identifiers and the text a
---    run receives or returns never reach the log.
--- ==============================================================================

local M = {}

local Shell = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")
local Owner = require("adapters.apple_shortcuts")
local Native = require("adapters.apple_shortcuts_native")
local Parameter = require("program_parameter")
local Json = require("json")

--- The system tool every transport of the owner names.
M.SHORTCUTS_BIN = "/usr/bin/shortcuts"

--- The uniform type a run's text output is written as.
M.TEXT_OUTPUT_TYPE = "public.plain-text"

-- Rows of the most recent successful listing, in the owner's choice order.
-- Declared above every reader.
local _observed_rows = {}





-- ================================
-- ================================
-- ======= 1/ Listing Reply =======
-- ================================
-- ================================

--- Parses `shortcuts list --show-identifiers`: one "Name (IDENTIFIER)" line
--- per shortcut. A line that does not read so refuses the whole listing, as a
--- partial library would let a stored identifier look deleted.
--- @param text any The tool's stdout.
--- @return table|nil rows Array of { id, name }.
function M.parse_list(text)
	if type(text) ~= "string" then return nil end
	local rows, seen = {}, {}
	for line in text:gmatch("[^\n]+") do
		local name, id = line:match("^(.-) %(([%x%-]+)%)$")
		if not name or name == "" or not Owner.valid_identifier(id) or seen[id] then return nil end
		seen[id] = true
		rows[#rows + 1] = { id = id, name = name }
	end
	return rows
end

--- The reply packet adapters/apple_shortcuts.lua validates, for one request.
--- The command line does not say whether a shortcut takes input: every
--- shortcut accepts --input-path, and one that takes none ignores it.
--- @param request table { nonce, operation, id }
--- @param rows table Parsed listing.
--- @return string raw JSON reply.
function M.reply(request, rows)
	local selected = rows
	if request.operation == "revalidate" then
		selected = {}
		for _, row in ipairs(rows) do
			if row.id == request.id then selected[1] = row end
		end
		if #selected == 0 then
			return Json.encode({ version = 1, nonce = request.nonce, operation = request.operation,
				status = "refused", reason = "missing" })
		end
	end
	local listed = {}
	for index = 1, math.min(#selected, Owner.MAX_CHOICES) do
		listed[index] = { id = selected[index].id, name = selected[index].name, accepts_input = true }
	end
	return Json.encode({ version = 1, nonce = request.nonce, operation = request.operation,
		status = "observed", rows = Json.array(listed), truncated = #selected > Owner.MAX_CHOICES })
end

--- The shell line of the editor's listing: the tool runs in the background
--- and a watcher stops it after `seconds`, so a stalled Shortcuts service cannot
--- hold the editor's modal forever. The watcher's own output is discarded, so
--- only the tool keeps the captured pipe open.
--- @param seconds number The bound.
--- @return string command
function M.bounded_list_command(seconds)
	return string.format("%s list --show-identifiers & pid=$!; "
		.. "( sleep %d; kill $pid ) >/dev/null 2>&1 & watcher=$!; "
		.. "wait $pid; status=$?; kill $watcher 2>/dev/null; exit $status", M.SHORTCUTS_BIN, seconds)
end

--- Lists the library for a binding editor, inside its modal: the editor is a
--- synchronous dialog chain, opened from a menu, never from the keyboard tap.
--- Bounded by the owner's query deadline and byte limit, and refused when the
--- tool is absent or replaced.
--- @return table|nil rows Array of { id, name } in library order.
--- @return string|nil reason Closed refusal category.
function M.list_blocking()
	if not Native.cli_identity() then return nil, "identity_refused" end
	local output = Shell.exec_checked(M.bounded_list_command(Owner.QUERY_TIMEOUT_SEC))
	if not output then return nil, "query_refused" end
	if #output > Owner.MAX_BYTES then return nil, "catalogue_limit" end
	local rows = M.parse_list(output)
	if not rows then return nil, "invalid_reply" end
	return rows
end

--- The rows of the most recent discovery listing, in the order of the owner's
--- choices: the action and its editor read a choice's identifier here, since
--- the owner keeps identifiers out of its public choices.
--- @return table rows Copied array of { id, name }.
function M.observed_rows()
	local copy = {}
	for index, row in ipairs(_observed_rows) do copy[index] = { id = row.id, name = row.name } end
	return copy
end





-- ====================================
-- ====================================
-- ======= 2/ Bounded Processes =======
-- ====================================
-- ====================================

--- Spawns one bounded, payload-free run of the tool.
--- @param args table Argument vector.
--- @param limit number Output bytes before the tool is stopped.
--- @param timeout_sec number Seconds before the tool is stopped.
--- @param done function fn(code, stdout, stderr, overflow, timed_out).
--- @return table|nil handle { start, terminate, isSettled, onSettled }
local function spawn_bounded(args, limit, timeout_sec, done)
	if type(limit) ~= "number" or limit <= 0 or type(timeout_sec) ~= "number" or timeout_sec <= 0 then return nil end
	local stdout, stderr, bytes, overflow, timed_out = {}, {}, 0, false, false
	local raw, timer
	local function take(into, chunk)
		if overflow or type(chunk) ~= "string" or chunk == "" then return end
		bytes = bytes + #chunk
		if bytes > limit then overflow = true; return end
		into[#into + 1] = chunk
	end
	raw = Shell.spawn(M.SHORTCUTS_BIN, args, function(code, out, err)
		if timer then TimerScheduler.cancel(timer); timer = nil end
		take(stdout, out)
		take(stderr, err)
		done(code, table.concat(stdout), table.concat(stderr), overflow, timed_out)
	end, function(_, out, err)
		take(stdout, out)
		take(stderr, err)
		if not overflow then return true end
		if raw then pcall(raw.terminate) end
		return false
	end, nil, true)
	if type(raw) ~= "table" then return nil end
	local handle = { terminate = raw.terminate, isSettled = raw.isSettled, onSettled = raw.onSettled }
	function handle.start()
		local started = raw.start() == true
		if started and not raw.isSettled() then
			local scheduled, candidate, committed = pcall(TimerScheduler.after, timeout_sec, function()
				timer = nil
				timed_out = true
				pcall(raw.terminate)
			end)
			if not scheduled or committed ~= true then
				-- A running tool without its deadline is not an accepted bounded run.
				-- The owner keeps this exact process until termination is acknowledged.
				pcall(raw.terminate)
				return false
			end
			if raw.isSettled() then
				TimerScheduler.cancel(candidate)
			else
				timer = candidate
			end
		end
		return started
	end
	return handle
end





-- ========================
-- ========================
-- ======= 3/ Ports =======
-- ========================
-- ========================

--- Whether the tool is the one the owner admits, unchanged.
--- @return boolean
local function qualified()
	return Native.cli_identity() ~= nil
end

--- The ports of adapters/apple_shortcuts.lua over the command-line tool.
--- @param current_run function Returns the run being invoked:
---   { input_path, output_path, timeout_sec, max_bytes }, filled with
---   { code, stderr, timed_out, overflow } once the tool exits.
--- @return table ports qualified, identity, query, invoke.
function M.ports(current_run)
	if type(current_run) ~= "function" then error("apple_shortcuts_cli.ports: current_run must be a function", 2) end
	local ports = {}
	ports.qualified = qualified
	ports.identity = function() return Native.cli_identity() end
	function ports.query(request, finish)
		return spawn_bounded({ "list", "--show-identifiers" }, request.limit, request.timeout,
			function(code, out, _, overflow, timed_out)
				local rows = code == 0 and not overflow and not timed_out and M.parse_list(out) or nil
				if not rows then finish(code ~= 0 and code or 1, nil, ""); return end
				if request.operation == "discover" then _observed_rows = rows end
				finish(0, M.reply(request, rows), "")
			end)
	end
	function ports.invoke(scalar, _, finish)
		local program = Parameter.parse(scalar, "posix")
		local run = current_run()
		if not program or program.executable ~= M.SHORTCUTS_BIN or #program.arguments ~= 2
			or program.arguments[1] ~= "run" or not Owner.valid_identifier(program.arguments[2])
			or type(run) ~= "table" then return nil end
		local args = { "run", program.arguments[2] }
		if run.input_path then
			args[#args + 1] = "--input-path"
			args[#args + 1] = run.input_path
		end
		if run.output_path then
			args[#args + 1] = "--output-path"
			args[#args + 1] = run.output_path
			args[#args + 1] = "--output-type"
			args[#args + 1] = M.TEXT_OUTPUT_TYPE
		end
		local handle = spawn_bounded(args, run.max_bytes, run.timeout_sec,
			function(code, _, err, overflow, timed_out)
				run.code, run.stderr, run.overflow, run.timed_out = code, err, overflow, timed_out
				finish(code == 0 and not overflow and not timed_out)
			end)
		if not handle then return nil end
		-- The tool's exit is the only receipt the command line gives (header, 3)
		handle.automationSettled = handle.isSettled
		return handle
	end
	return ports
end

return M
