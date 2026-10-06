--- _shared/lua/remap/virtual_hid_dependency_policy.lua

--- Observes bound dependency facts; native verification and installation remain native-owned.
local M = {}
local Lifetime = require("keylogger.physical_subscription_lifetime")
local SOURCES = { "installed", "broker", "client", "intent" }
local MAX_EXACT_DOUBLE = 9007199254740991
local number_type = math.type
local SUPPORTED_PACKAGE, SUPPORTED_DRIVER, SUPPORTED_PROTOCOL = "8.5.0", "1.8.0", 7
local SCHEMA = {
	installed = { reference = "identity", package_version = "text", driver_version = "text", client_protocol = "integer",
		signature_valid = "boolean", ordinary_root_owned = "boolean", bundle_identity_valid = "boolean",
		reference_qualified = "boolean", extension_approved = "boolean" },
	broker = { reference = "identity", connection = "identity", connected = "boolean",
		socket_peer_verified = "boolean", dynamic_reference_valid = "boolean" },
	client = { connection = "identity", stage = "stage", initializer_issued = "boolean", driver_activated = "boolean",
		driver_connected = "boolean", driver_version_mismatched = "boolean", keyboard_ready = "boolean" },
	intent = { mode = "mode", tap_hold = "boolean", close_other_instances = "boolean", runtime_pin_enabled = "boolean",
		signed_exact_runtime = "boolean", root_owned_install = "boolean", owned_runtime_installable = "boolean",
		owned_peer_bootstrap_complete = "boolean", owned_peer_stream_qualified = "boolean", foreign_grabber_active = "boolean",
		stock_quit_requested = "boolean", stock_quit_native_settled = "boolean", cleanup_pending = "boolean",
		second_vhid_job_planned = "boolean" },
}
local function plain(value) return type(value) == "table" and getmetatable(value) == nil end
local function integer(value)
	if type(value) ~= "number" or value <= 0 then return false end
	if type(number_type) == "function" then return number_type(value) == "integer" end
	return value <= MAX_EXACT_DOUBLE and value % 1 == 0
end
local function valid(value, kind)
	if kind == "boolean" then return type(value) == "boolean" end
	if kind == "identity" then return plain(value) end
	if kind == "integer" then return integer(value) end
	if kind == "text" then return type(value) == "string" and #value > 0 and #value <= 64 and not value:find("[%z\r\n]") end
	if kind == "stage" then return value == "connection" or value == "initialize" or value == "status" end
	if kind == "mode" then return value == "shared" or value == "owned" end
	return false
end
local function copied(record, previous)
	assert(plain(record) and SCHEMA[rawget(record, "kind")], "Invalid dependency receipt kind")
	local kind, result = rawget(record, "kind"), {}
	assert(integer(rawget(record, "revision")) and rawget(record, "revision") == (previous and previous.revision or 0) + 1,
		"Dependency revision gap or replay")
	assert(integer(rawget(record, "generation")) and (previous == nil or rawget(record, "generation") >= previous.generation),
		"Dependency source generation regressed")
	for name, value in next, record do
		if name == "kind" or name == "revision" or name == "generation" then result[name] = value
		else
			assert(SCHEMA[kind][name] and valid(value, SCHEMA[kind][name]), "Invalid known dependency fact")
			-- Opaque identities are compared only by reference; their mutable contents are never read.
			result[name] = value
		end
	end
	if kind == "client" then
		assert(valid(result.stage, "stage"), "Missing dependency client event")
		if result.stage ~= "status" then
			for _, name in ipairs({ "driver_activated", "driver_connected", "driver_version_mismatched", "keyboard_ready" }) do
				assert(result[name] == nil, "Client status has no actual status event")
			end
		end
		assert(result.stage == "initialize" or result.initializer_issued == nil, "Initializer has no actual initialize event")
	end
	return result
end
local function result(state, detail, reason)
	return { state = state, reason = reason or state, detail = detail, admit = state == "ready" }
end

--- Captures four exact subscriptions without querying, launching or granting native authority.
---@param owner table Exact policy owner.
---@param sources table Independent installed, broker, client and intent source capabilities.
---@param on_refused function Once-only framed terminal diagnostic with a fixed reason code.
---@return table policy Observational decision and exact retirement ports.
function M.new(owner, sources, on_refused)
	assert(plain(owner) and plain(sources) and type(on_refused) == "function", "Missing dependency policy ownership")
	local bindings = {}
	for _, name in ipairs(SOURCES) do
		local source = rawget(sources, name)
		assert(plain(source) and plain(rawget(source, "owner")) and plain(rawget(source, "token"))
			and plain(rawget(source, "scope")), "Missing exact dependency source")
		local binding = { owner = rawget(source, "owner"), token = rawget(source, "token") }
		for _, method in ipairs({ "identity", "current", "detach", "retired" }) do
			local operation = rawget(source.scope, method)
			assert(type(operation) == "function", "Missing dependency source port")
			binding[method] = operation
		end
		bindings[name] = binding
	end
	for name in next, sources do assert(bindings[name], "Unknown dependency source") end
	local life = Lifetime.new(owner, {})
	local own = life.capability()
	local own_token, own_current, own_retired = own.identity(owner), own.current, own.retired
	local facts, initializer = {}, nil
	local active, busy, finished, refused, reason, retirement_reentered = true, false, false, false, nil, false
	local policy = {}
	life.bind_detach(function() life.detach(); return true end)
	local function revoke(message)
		active = false
		life.revoke()
		if reason == nil then reason = message end
		if message and not refused then
			refused = true
			life.run(function() pcall(on_refused, message) end)
		end
		return false
	end
	local function owned() return active and own_current(owner, own_token) == true end
	local function foreign(operation, ...)
		if not owned() then return false end
		local ok, value = pcall(operation, ...)
		if not owned() then return false end
		if not ok then return revoke("dependency_source_refused") end
		return value
	end
	local function fence()
		if not owned() then return false end
		for _, name in ipairs(SOURCES) do
			local source = bindings[name]
			if not rawequal(foreign(source.identity, source.owner), source.token)
				or foreign(source.current, source.owner, source.token) ~= true
				or not rawequal(foreign(source.identity, source.owner), source.token)
				or foreign(source.current, source.owner, source.token) ~= true then
				return revoke("dependency_source_refused")
			end
		end
		return owned()
	end
	local function operate(operation)
		if not active then return false, reason or "dependency_stopped" end
		if busy then return revoke("dependency_reentered"), "dependency_reentered" end
		busy = true
		local ok, value = pcall(life.run, function()
			if not fence() then return false end
			return operation()
		end)
		busy = false
		if not ok then revoke("dependency_input_refused"); return false, "dependency_input_refused" end
		if not active then return false, reason or "dependency_stopped" end
		return value
	end

	--- Copies a dense source observation; acceptance is not readiness or native verification.
	---@param record table Plain closed receipt from the bound native observation owner.
	---@param token table Exact actual source-minted subscription identity.
	---@return boolean accepted Whether this current receipt was retained once.
	---@return string|nil reason Fixed terminal refusal, never a raw foreign exception.
	function policy.receive(record, token)
		return operate(function()
			assert(plain(record), "Missing dependency receipt")
			local kind = rawget(record, "kind")
			assert(bindings[kind] and rawequal(bindings[kind].token, token), "Dependency source identity changed")
			local previous, next_initializer = facts[kind], initializer
			local next_record = copied(record, previous)
			if kind == "client" then
				if previous == nil or next_record.stage == "connection" or next_record.generation ~= previous.generation
					or not rawequal(next_record.connection, previous.connection) then next_initializer = nil end
				if next_record.stage == "initialize" then
					next_initializer = next_record.initializer_issued == true and next_record.connection ~= nil
						and { generation = next_record.generation, connection = next_record.connection, revision = next_record.revision } or nil
				end
			end
			if not fence() then return false end
			facts[kind], initializer = next_record, next_initializer
			return true
		end)
	end
	local function classify()
		local intent, installed, broker, client = facts.intent, facts.installed, facts.broker, facts.client
		if intent and (intent.mode == "shared" or intent.mode == "owned" and intent.tap_hold == false) then
			return result("inactive", "owned-taphold-not-selected")
		end
		if not intent or intent.mode ~= "owned" or intent.tap_hold ~= true then return result("unverified-vhid-state", "unknown-owned-intent") end
		if intent.cleanup_pending == true or intent.stock_quit_requested == true and intent.stock_quit_native_settled ~= true then
			return result("cleanup-pending", "owned-closure-unsettled")
		end
		if intent.foreign_grabber_active == true then return result("other-karabiner-active", "foreign-grabber-still-active") end
		if intent.second_vhid_job_planned == true then
			return result("unverified-vhid-state", "shared-vhid-has-no-second-owner", "vhid-broker-ownership-unresolved")
		end
		if intent.second_vhid_job_planned ~= false then return result("unverified-vhid-state", "shared-vhid-ownership-unknown") end
		if not installed or installed.reference == nil or installed.reference_qualified ~= true
			or installed.signature_valid ~= true or installed.ordinary_root_owned ~= true or installed.bundle_identity_valid ~= true then
			return result("unverified-vhid-state", "installed-reference-unqualified")
		end
		if installed.package_version ~= SUPPORTED_PACKAGE or installed.driver_version ~= SUPPORTED_DRIVER
			or installed.client_protocol ~= SUPPORTED_PROTOCOL then return result("unverified-vhid-state", "unsupported-installed-reference") end
		if installed.extension_approved == false then return result("awaiting-extension-approval", "official-extension-not-approved") end
		if installed.extension_approved ~= true then return result("unverified-vhid-state", "extension-approval-unknown") end
		if not broker or broker.connected ~= true or broker.connection == nil or broker.socket_peer_verified ~= true
			or broker.dynamic_reference_valid ~= true or not rawequal(broker.reference, installed.reference) then
			return result("unverified-vhid-state", "live-broker-reference-unqualified")
		end
		if not client or not rawequal(client.connection, broker.connection) or client.stage ~= "status" then
			return result("unverified-vhid-state", "current-client-status-missing")
		end
		if client.driver_connected ~= true then return result("unverified-vhid-state", "driver-connection-unverified") end
		if client.driver_version_mismatched == true then return result("incompatible-vhid", "qualified-driver-abi-mismatch") end
		if client.driver_version_mismatched ~= false or client.driver_activated ~= true then
			return result("unverified-vhid-state", "driver-operating-facts-unknown")
		end
		if not initializer or initializer.generation ~= client.generation or not rawequal(initializer.connection, client.connection)
			or initializer.revision >= client.revision or client.keyboard_ready ~= true then
			return result("unverified-vhid-state", "fresh-post-initializer-readiness-missing")
		end
		if intent.cleanup_pending ~= false or intent.foreign_grabber_active ~= false
			or not (intent.stock_quit_requested == false or intent.stock_quit_requested == true and intent.stock_quit_native_settled == true) then
			return result("unverified-vhid-state", "stock-closure-state-unknown")
		end
		for _, name in ipairs({ "runtime_pin_enabled", "signed_exact_runtime", "root_owned_install", "owned_runtime_installable",
			"owned_peer_bootstrap_complete", "owned_peer_stream_qualified" }) do
			if intent[name] ~= true then return result("unverified-vhid-state", name .. "-unqualified") end
		end
		return result("ready", "bound-operational-dependency-qualified")
	end

	--- Returns an explained observed decision after exact before/after source fences.
	---@return table decision Detached classification; grants no installer or history authority.
	function policy.decision()
		local decision = operate(function()
			local value = classify()
			if not fence() then return false end
			return value
		end)
		if type(decision) == "table" then return decision end
		return result("unverified-vhid-state", reason or "dependency-stopped")
	end

	--- Revokes first; actual observer detachment stays bound to the original native owners.
	function policy.stop() active = false; life.revoke(); return true end

	--- Retains facts until all four actual detach/retirement acknowledgements and frames settle.
	---@return boolean retired Whether every exact original obligation completed.
	function policy.retired()
		if busy then retirement_reentered = true; return false end
		if finished then return true end
		if active then return false end
		busy, retirement_reentered = true, false
		local all = true
		for _, name in ipairs(SOURCES) do
			local source = bindings[name]
			if not source.detached then
				local ok, accepted = pcall(source.detach, source.owner, source.token)
				source.detached = ok and accepted == true
			end
			if source.detached and not source.complete then
				local ok, accepted = pcall(source.retired, source.owner, source.token)
				source.complete = ok and accepted == true
			end
			all = source.complete == true and all
		end
		if all and not retirement_reentered then own.detach(owner, own_token) end
		all = all and not retirement_reentered and own_retired(owner, own_token) == true
		busy = false
		if not all then return false end
		facts, initializer, finished = {}, nil, true
		return true
	end
	return policy
end

return M
