--- _shared/lua/remap/owned_configuration_publication.lua

--- Publishes complete private documents through exact bound source and native receipts.
local Lifetime = require("keylogger.physical_subscription_lifetime")
local M = {}
local unpack_values = table.unpack or unpack
local function pack(...) return { n = select("#", ...), ... } end

--- Binds one exact publication source without granting runtime admission authority.
---@param owner table Original private subscriber.
---@param source table Exact identity, current, route, detach and retired ports.
---@param ports table Captured build, encode, filesystem and diagnostic ports.
---@return table|nil publisher Exact publication and retirement operations.
---@return string|nil reason Closed binding refusal.
function M.new(owner, source, ports)
	if type(owner) ~= "table" or type(source) ~= "table" or type(ports) ~= "table" then
		return nil, "owned_publication_binding_refused"
	end
	local methods, operations = {}, {}
	for _, name in ipairs({ "identity", "current", "route", "detach", "retired" }) do
		methods[name] = rawget(source, name)
		if type(methods[name]) ~= "function" then return nil, "owned_publication_binding_refused" end
	end
	for _, name in ipairs({ "build", "encode", "prepare", "read", "write", "receipt_view", "on_error" }) do
		operations[name] = rawget(ports, name)
		if type(operations[name]) ~= "function" then return nil, "owned_publication_binding_refused" end
	end
	local life = Lifetime.new(owner, {})
	local scope = life.capability()
	local private_token = scope.identity(owner)
	local token, path, stopped, busy, detaching = nil, nil, false, false, false
	local debts = {}
	local publisher = {}
	local function whole()
		for name, method in pairs(methods) do
			if not rawequal(rawget(source, name), method) then return false end
		end
		return true
	end
	local function exact(candidate_owner, candidate_token)
		return rawequal(candidate_owner, owner) and rawequal(candidate_token, token)
	end
	local function stale()
		stopped = true
		life.revoke()
		return false
	end
	local function current()
		if stopped or not whole() then return stale() end
		if not rawequal(methods.identity(owner), token) or stopped or not whole() then return stale() end
		if methods.current(owner, token) ~= true or stopped or not whole() then return stale() end
		if methods.route(owner, token) ~= path or stopped or not whole() then return stale() end
		return true
	end
	local acquired, accepted = pcall(life.run, function()
		token = methods.identity(owner)
		if type(token) ~= "table" or not whole() then return false end
		path = methods.route(owner, token)
		return type(path) == "string" and path ~= "" and current()
	end)
	if not acquired or accepted ~= true then return nil, "owned_publication_binding_refused" end

	local function settled(record)
		return record.authorized == true and type(record.settled) == "function" and record.settled() == true
	end
	local function forget_settled()
		for record in pairs(debts) do
			if settled(record) then
				debts[record] = nil
				assert(life.leave(record.frame), "Publication debt frame was already released")
			end
		end
		return next(debts) == nil
	end
	local function refusal(reason, original)
		return false, reason, original
	end

	--- Returns the original source token even after revocation; this is no authority.
	---@param candidate_owner table Exact original owner.
	---@return table|nil token Original private source identity.
	function publisher.identity(candidate_owner)
		if rawequal(candidate_owner, owner) then return token end
	end

	--- Publishes one complete document while retaining all actual native cleanup debt.
	---@param candidate_owner table Exact original owner.
	---@param candidate_token table Exact original source token.
	---@param input table Native generator arguments.
	---@return boolean accepted Literal publication and cleanup acknowledgement.
	---@return string|nil reason Closed refusal boundary.
	---@return any original Preserved provider refusal or raised object.
	function publisher.publish(candidate_owner, candidate_token, input)
		if not exact(candidate_owner, candidate_token) or stopped or busy or next(debts) ~= nil then
			return refusal("owned_publication_refused")
		end
		busy = true
		local outcome = pack(pcall(life.run, function()
			if not current() then return refusal("owned_publication_stale") end
			local document, detail = operations.build(input)
			if type(document) ~= "table" then return refusal("owned_publication_build_refused", detail) end
			if not current() then return refusal("owned_publication_stale") end
			local bytes, encode_detail = operations.encode(document)
			if type(bytes) ~= "string" then return refusal("owned_publication_encode_refused", encode_detail) end
			if not current() then return refusal("owned_publication_stale") end
			local prepared, prepare_detail = operations.prepare(path)
			if prepared ~= true then return refusal("owned_publication_prepare_refused", prepare_detail) end
			if not current() then return refusal("owned_publication_stale") end
			local observation = operations.read(path)
			if type(observation) ~= "table" or (observation.status ~= "ok" and observation.status ~= "absent")
				or (observation.status == "ok" and type(observation.content) ~= "string") then
				return refusal("owned_publication_read_refused")
			end
			local expected = { status = observation.status, content = observation.content }
			if not current() then return refusal("owned_publication_stale") end
			-- The debt exists before the writer can reenter stop or expose a receipt.
			local record = { frame = assert(life.enter()) }
			debts[record] = true
			local written, write_detail, receipt = operations.write(path, bytes, expected, operations.on_error)
			if type(receipt) ~= "table" then
				return refusal("owned_publication_receipt_missing", write_detail)
			end
			record.receipt = receipt
			local view = operations.receipt_view(receipt, path, expected, bytes, operations.on_error)
			local source_status = type(view) == "table" and view.published == true and "ok" or expected.status
			local source_content = type(view) == "table" and view.published == true and bytes or expected.content
			if type(view) == "table" and type(view.published) == "boolean" and type(view.source) == "table"
				and view.source.status == source_status and view.source.content == source_content then
				record.authorized = true
				record.settled, record.matches, record.retry = receipt.is_settled, receipt.matches_source, receipt.retry
			end
			local native_settled = settled(record)
			if native_settled then
				debts[record] = nil
				assert(life.leave(record.frame), "Publication debt frame was already released")
			end
			if written ~= true or type(view) ~= "table" or view.published ~= true
				or type(view.source) ~= "table" or view.source.status ~= "ok" or view.source.content ~= bytes
				or type(record.matches) ~= "function" or record.matches() ~= true or not native_settled then
				return refusal("owned_publication_native_refused", write_detail)
			end
			if not current() then return refusal("owned_publication_stale") end
			local final = operations.read(path)
			if type(final) ~= "table" or final.status ~= "ok" or final.content ~= bytes
				or not current() then return refusal("owned_publication_readback_refused") end
			return true
		end))
		busy = false
		if not outcome[1] then return refusal("owned_publication_raised", outcome[2]) end
		return unpack_values(outcome, 2, outcome.n)
	end

	--- Revokes immediately and explicitly retries retained native cleanup obligations.
	---@param candidate_owner table Exact original owner.
	---@param candidate_token table Exact original source token.
	---@return boolean detached Actual source detach and publication cleanup acknowledgement.
	function publisher.detach(candidate_owner, candidate_token)
		if not exact(candidate_owner, candidate_token) or detaching then return false end
		if scope.retired(owner, private_token) then return true end
		stopped, detaching = true, true
		life.revoke()
		local called, detached = pcall(life.run, function()
			for record in pairs(debts) do
				if not settled(record) and type(record.retry) == "function" then record.retry() end
			end
			local clean = forget_settled()
			if not whole() or methods.detach(owner, token) ~= true or not whole()
				or methods.retired(owner, token) ~= true or not whole() then return false end
			if clean then life.detach() end
			return clean
		end)
		detaching = false
		return called and detached == true
	end

	--- Observes retained frames only; never performs cleanup or foreign retries.
	---@param candidate_owner table Exact original owner.
	---@param candidate_token table Exact original source token.
	---@return boolean retired Actual source detach and complete original frame retirement.
	function publisher.retired(candidate_owner, candidate_token)
		return exact(candidate_owner, candidate_token) and scope.retired(owner, private_token)
	end
	return publisher
end

return M
