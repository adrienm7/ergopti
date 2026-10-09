--- adapters/apple_shortcuts.lua

--- ==============================================================================
--- MODULE: Chosen Apple Shortcut Owner
--- DESCRIPTION:
--- Keeps IDs private, revalidates choices asynchronously and retains exact query
--- and automation cleanup debt across consumers. Native qualification is an
--- explicit port; neither a CLI pathname nor a successful mock grants capability.
--- ==============================================================================

local Json = require("json")
local Unicode = require("compat.utf8")
local Parameter = require("program_parameter")
local M = { MAX_BYTES = 65536, MAX_CHOICES = 64, MAX_NAME_BYTES = 4096 }

local function fields(value, allowed, count)
	if type(value) ~= "table" or Json.is_null(value) or Json.is_array(value) then return false end
	local actual = 0
	for key in pairs(value) do if not allowed[key] then return false end; actual = actual + 1 end
	return actual == count
end

local function clean(value, maximum)
	return type(value) == "string" and #value <= maximum and not value:find("%z") and Unicode.len(value) ~= nil
end

local function identifier(value)
	return clean(value, 36) and #value == 36
		and value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

--- Checks the exact identifier syntax supported by the native chosen-ID role.
--- @param value any Private native identifier.
--- @return boolean valid
function M.valid_identifier(value) return identifier(value) end

--- Checks one bounded, closed native reply against its private request.
--- @param raw string Native JSON bytes after local retirement.
--- @param request table Captured operation, nonce and optional chosen ID.
--- @return table|nil packet Validated observed metadata.
--- @return string|nil reason Closed refusal category.
function M.validate_reply(raw, request)
	if type(raw) ~= "string" or #raw == 0 or #raw > M.MAX_BYTES then return nil, "invalid_reply" end
	local ok, data = pcall(Json.decode_lossless, raw)
	if not ok or type(data) ~= "table" or data.version ~= 1 or data.nonce ~= request.nonce
		or data.operation ~= request.operation then return nil, "invalid_reply" end
	if fields(data, { version = true, nonce = true, operation = true, status = true, reason = true }, 5)
		and data.status == "refused" then
		if data.reason == "automation_permission_refused" or data.reason == "native_refused"
			or data.reason == "catalogue_limit" or data.reason == "missing" then return nil, data.reason end
		return nil, "invalid_reply"
	end
	if not fields(data, { version = true, nonce = true, operation = true, status = true,
		rows = true, truncated = true }, 6) or data.status ~= "observed"
		or not Json.is_array(data.rows) or #data.rows > M.MAX_CHOICES
		or type(data.truncated) ~= "boolean" then return nil, "invalid_reply" end
	local ids = {}
	for _, row in ipairs(data.rows) do
		if not fields(row, { id = true, name = true, accepts_input = true }, 3)
			or not identifier(row.id) or not clean(row.name, M.MAX_NAME_BYTES)
			or type(row.accepts_input) ~= "boolean" or ids[row.id] then return nil, "invalid_reply" end
		ids[row.id] = true
	end
	if request.operation == "revalidate" and (#data.rows ~= 1 or data.truncated
		or data.rows[1].id ~= request.id) then return nil, "stale_discovery" end
	return data
end

local function handle_valid(handle, automation)
	if type(handle) ~= "table" then return false end
	for _, name in ipairs({ "start", "terminate", "isSettled", "onSettled" }) do
		if type(handle[name]) ~= "function" then return false end
	end
	return not automation or type(handle.automationSettled) == "function"
end

--- Creates an isolated owner; transports must register physical custody before return.
--- Query transport enforces request.limit and request.timeout before buffering bytes.
--- Invocation transport uses the existing v1 literal model and must separately prove
--- remote automation retirement. Process exit alone never supplies that receipt.
--- @param ports table qualified, identity, query and invoke functions.
--- @return table|nil owner Shared picker/consumer lifecycle.
--- @return string|nil reason Closed refusal category.
function M.new(ports)
	for _, name in ipairs({ "qualified", "identity", "query", "invoke" }) do
		if type(ports) ~= "table" or type(ports[name]) ~= "function" then return nil, "ports_unavailable" end
	end
	local owner, generation, sequence, choices, active, observing = {}, 0, 0, {}, nil, false
	local function observe(callback, ...)
		local prior = observing
		observing = true
		local ok, value = pcall(callback, ...)
		observing = prior
		return ok, value
	end
	local function qualified(role)
		local ok, ready = observe(ports.qualified, role)
		return ok and ready == true
	end
	local function identity()
		local ok, value = observe(ports.identity)
		if not ok or not fields(value, { executable = true, token = true }, 2)
			or value.executable ~= "/usr/bin/shortcuts" or not clean(value.token, M.MAX_BYTES)
			or value.token == "" then return nil end
		return { executable = value.executable, token = value.token }
	end
	local function same(left)
		local right = identity()
		return right and left and right.token == left.token and right.executable == left.executable
	end
	local function settled(entry)
		if not entry.handle then return false end
		local ok, value = pcall(entry.handle.isSettled)
		if not ok or value ~= true then return false end
		if entry.automation then
			local observed, retired = pcall(entry.handle.automationSettled)
			if not observed or retired ~= true then return false end
		end
		return true
	end
	local function cancel(entry)
		entry.cancelled = true
		if not entry.handle then return false end
		pcall(entry.handle.terminate)
		if settled(entry) and active == entry then active = nil end
		return active ~= entry
	end
	local packet = M.validate_reply
	local function query(operation, selected, finish)
		if active then return false, "cleanup_pending" end
		local epoch = generation
		if not qualified("discovery") then return false, "discovery_unqualified" end
		local cli = identity()
		if not cli or selected and not same(selected.cli) then return false, "identity_refused" end
		if generation ~= epoch then return false, "stale_discovery" end
		sequence = sequence + 1
		local request = { version = 1, nonce = sequence, operation = operation, id = selected and selected.id,
			limit = M.MAX_BYTES, timeout = 20 }
		local entry = { epoch = epoch, cli = cli, constructing = true }
		active = entry
		local function complete()
			if entry.constructing or active ~= entry or not entry.completed or not settled(entry) then return end
			active = nil
			if entry.cancelled or generation ~= entry.epoch then return end
			if not entry.reply or entry.code ~= 0 or entry.errors ~= "" or not same(cli)
				or not qualified("discovery") then finish(nil, "query_refused"); return end
			local value, reason = packet(entry.reply, request)
			finish(value, reason, cli)
		end
		local transport_request = {}
		for key, value in pairs(request) do transport_request[key] = value end
		local ok, handle = pcall(ports.query, transport_request, function(code, raw, errors)
			if entry.completed then entry.invalid = true; entry.reply = nil; cancel(entry); return end
			entry.completed, entry.code, entry.errors = true, code, errors
			entry.reply = type(raw) == "string" and #raw <= M.MAX_BYTES and raw or nil
			complete()
		end)
		if not ok or not handle_valid(handle, false) then
			-- An invalid constructor cannot prove it allocated nothing. Retain its
			-- reservation instead of allowing a successor over unknown custody.
			entry.constructing, entry.cancelled = false, true
			return false, "transport_refused"
		end
		entry.handle = handle
		local watching, observed = pcall(handle.onSettled, complete)
		entry.constructing = false
		if not watching or observed ~= true or entry.cancelled then cancel(entry); return false, "transport_refused" end
		local started, receipt = pcall(handle.start)
		if not started or receipt ~= true then cancel(entry); return false, "start_refused" end
		complete()
		return true
	end
	--- Invalidates every picker key and retries only the retained native owner.
	--- @return boolean retired All local and remote owners acknowledged retirement.
	function owner.invalidate()
		generation, choices = generation + 1, {}
		return not active or cancel(active)
	end
	--- Reports any retained operation, including refused cancellation.
	--- @return boolean pending
	function owner.pending() return active ~= nil end
	--- Requests private structured inventory after native capability admission.
	--- @param finish function Receives choices or a closed failure reason.
	--- @return boolean accepted
	function owner.discover(finish)
		if observing then return false, "busy" end
		if type(finish) ~= "function" then return false, "invalid_callback" end
		if active then return false, "cleanup_pending" end
		generation, choices = generation + 1, {}
		return query("discover", nil, function(data, reason, cli)
			if not data then finish(nil, reason); return end
			local result = { choices = {}, truncated = data.truncated }
			for index, row in ipairs(data.rows) do
				local key = tostring(generation) .. ":" .. tostring(index)
				choices[key] = { id = row.id, name = row.name, accepts_input = row.accepts_input, cli = cli }
				result.choices[index] = { key = key, label = row.name, provider = "apple_shortcuts" }
			end
			finish(result)
		end)
	end
	--- Rechecks the chosen ID and lowers without names or arbitrary workflow argv.
	--- @param key string Opaque picker key.
	--- @param arguments table Must be empty; CLI input options need their own model.
	--- @param finish function Receives the existing v1 scalar or closed reason.
	--- @return boolean accepted
	function owner.resolve(key, arguments, finish)
		if observing then return false, "busy" end
		if type(finish) ~= "function" then return false, "invalid_callback" end
		local selected = type(key) == "string" and choices[key]
		if not selected then return false, "stale_discovery" end
		if type(arguments) ~= "table" or next(arguments) ~= nil then return false, "unsupported_input" end
		return query("revalidate", selected, function(data, reason)
			if not data then finish(nil, reason); return end
			if choices[key] ~= selected or data.rows[1].name ~= selected.name
				or data.rows[1].accepts_input ~= selected.accepts_input then finish(nil, "stale_discovery"); return end
			local scalar = Json.encode({ version = 1, executable = selected.cli.executable,
				arguments = Json.array({ "run", selected.id }) })
			if not Parameter.parse(scalar, "hs") then finish(nil, "invalid_program"); return end
			finish(scalar)
		end)
	end
	--- Invokes identically for every consumer while retaining service retirement debt.
	--- @param key string Opaque picker key.
	--- @param consumer string Caller-owned gesture, keyboard or other consumer identity.
	--- @param admitted function Rechecked before native activation and completion.
	--- @param finish function Receives success and a closed terminal category.
	--- @return boolean accepted
	function owner.invoke(key, consumer, admitted, finish)
		if observing then return false, "busy" end
		if not clean(consumer, 256) or consumer == "" or type(admitted) ~= "function"
			or type(finish) ~= "function" then return false, "invalid_consumer" end
		if not qualified("invocation") then return false, "invocation_unqualified" end
		if not qualified("cancellation") then return false, "cancellation_unqualified" end
		local selected, epoch = choices[key], generation
		local function allowed()
			local ok, ready = observe(admitted, consumer)
			return ok and ready == true and generation == epoch and choices[key] == selected
				and same(selected and selected.cli) and qualified("invocation") and qualified("cancellation")
		end
		if not allowed() then return false, "admission_refused" end
		return owner.resolve(key, {}, function(scalar, reason)
			if not scalar then finish(false, reason); return end
			if active or not allowed() then finish(false, "admission_refused"); return end
			local entry = { epoch = epoch, automation = true, constructing = true }
			active = entry
			local function complete()
				if entry.constructing or active ~= entry or not entry.completed or not settled(entry) then return end
				active = nil
				if entry.cancelled or generation ~= epoch then return end
				local admitted_now = allowed()
				finish(entry.success == true and admitted_now, not admitted_now and "admission_refused"
					or entry.success == true and "completed" or "execution_refused")
			end
			local ok, handle = pcall(ports.invoke, scalar, allowed, function(success)
				if entry.completed then entry.success = false; cancel(entry); return end
				entry.completed, entry.success = true, success == true
				complete()
			end)
			if not ok or not handle_valid(handle, true) then
				entry.constructing, entry.cancelled = false, true
				finish(false, "transport_refused"); return
			end
			entry.handle = handle
			local watching, observed = pcall(handle.onSettled, complete)
			entry.constructing = false
			if not watching or observed ~= true or not allowed() then cancel(entry); return end
			local started, receipt = pcall(handle.start)
			if not started or receipt ~= true then cancel(entry); return end
			complete()
		end)
	end
	return owner
end

return M
