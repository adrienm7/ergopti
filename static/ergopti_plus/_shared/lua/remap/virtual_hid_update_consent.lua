--- _shared/lua/remap/virtual_hid_update_consent.lua

--- Owns one explicit offer over the real dependency policy; native update ports remain native-owned.
local M = {}
local Dependency = require("remap.virtual_hid_dependency_policy")
local Lifetime = require("keylogger.physical_subscription_lifetime")
local SOURCES = { "installed", "broker", "client", "intent" }
local function plain(value) return type(value) == "table" and getmetatable(value) == nil end
local function binding(value, methods)
	assert(plain(value) and plain(rawget(value, "owner")) and plain(rawget(value, "token"))
		and plain(rawget(value, "scope")), "Missing exact update capability")
	local result = { owner = rawget(value, "owner"), token = rawget(value, "token") }
	for _, name in ipairs(methods) do
		result[name] = rawget(value.scope, name)
		assert(type(result[name]) == "function", "Missing update capability port")
	end
	return result
end

--- Creates an observational owner without querying, downloading, installing or granting native authority.
--- The target must retain verified fixed package custody; the effect owns native retirement and replacement.
---@param owner table Exact consent owner.
---@param sources table Existing installed/broker/client/intent subscriptions owned by the dependency policy.
---@param target table Exact verified target owner/token/scope with identity/current ports.
---@param effect table Exact fixed native identity/current/retire/replace ports; async ports return "pending",nonce.
--- Both native ports receive the eight fixed cohort arguments then private nonce/completion.
--- Completion(owner,token,nonce,physicalTerminalACK,outcome) requires literal true ACK and Boolean outcome.
--- Pending request acceptance is not native retirement; native adapters must never block the main loop.
---@return table consent One-use offer, receipt routing and actual dependency retirement ports.
function M.new(owner, sources, target, effect)
	assert(plain(owner) and plain(sources), "Missing update consent owner")
	local observed = {}
	for _, name in ipairs(SOURCES) do observed[name] = binding(rawget(sources, name), { "identity", "current", "retired" }) end
	local selected = binding(target, { "identity", "current" })
	local operation = binding(effect, { "identity", "current", "retire", "replace" })
	local life = Lifetime.new(owner, {})
	local capability = life.capability()
	local own_token = capability.identity(owner)
	local own_current, own_retired = capability.current, capability.retired
	life.bind_detach(function() life.detach(); return true end)
	local active, busy, issued, consumed, epoch = true, false, false, false, 0
	local state, offer_token, offered_epoch, offered_intent = "observing", nil, nil, nil
	local cohorts, consent, dependency_stop = {}, {}, nil
	local phase, pending, invoke, complete, drain
	local function revoke(reason)
		active, state = false, reason
		life.revoke()
		if dependency_stop then dependency_stop() end
		return false, reason
	end
	local dependency = Dependency.new(owner, sources, function() revoke("consent-source-refused") end)
	local dependency_receive, dependency_decision, dependency_retired = dependency.receive, dependency.decision, dependency.retired
	dependency_stop = dependency.stop
	local function owned() return active and own_current(owner, own_token) == true end
	local function foreign(port, ...)
		if not owned() then return false, nil end
		local ok, value = pcall(port, ...)
		return ok and owned(), value
	end
	local function current(source)
		for _ = 1, 2 do
			local ok, identity = foreign(source.identity, source.owner)
			if not ok or not rawequal(identity, source.token) then return false end
			local accepted, value = foreign(source.current, source.owner, source.token)
			if not accepted or value ~= true then return false end
		end
		return owned()
	end
	local function fence()
		if not owned() then return false end
		for _, name in ipairs(SOURCES) do if not current(observed[name]) then return false end end
		return current(selected) and current(operation) and owned()
	end
	local function stable(installed)
		if not owned() or epoch ~= offered_epoch then return false end
		if installed and not current(observed.installed) then return false end
		return current(observed.intent) and current(selected) and current(operation) and owned()
	end
	local function connection_scope(source, require_retired)
		local ok, identity = foreign(source.identity, source.owner)
		if not ok or not rawequal(identity, source.token) then return false end
		if current(source) then return true end
		if not require_retired then return owned() end
		local accepted, retired = foreign(source.retired, source.owner, source.token)
		local cut, last_identity = foreign(source.identity, source.owner)
		return accepted and retired == true and cut and rawequal(last_identity, source.token) and owned()
	end
	local function phase_fence(require_retired)
		if phase == nil then return fence() end
		if not stable(phase == "retirement") then return false end
		if phase == "retirement" then
			return connection_scope(observed.broker, require_retired) and connection_scope(observed.client, require_retired)
		end
		return owned()
	end
	local function operate(port)
		if not owned() then return false, state end
		if busy then return revoke("consent-reentered") end
		busy = true
		local ok, value, reason = pcall(life.run, function()
			if not phase_fence(false) then return revoke("consent-source-refused") end
			local accepted, detail = port()
			if not owned() then return false, state end
			if not phase_fence(false) then return revoke("consent-source-refused") end
			return accepted, detail
		end)
		busy = false
		if drain then drain() end
		if not ok then return revoke("consent-input-refused") end
		if not owned() then return false, state end
		return value, reason
	end
	local function unchanged()
		if epoch ~= offered_epoch or not fence() then return false end
		local decision = dependency_decision()
		return owned() and epoch == offered_epoch and decision.state == "incompatible-vhid" and fence()
	end

	-- A logical ticket retains debt; only an exact native terminal ACK can release it.
	complete = function(context, outcome)
		context.closed = true
		if pending == context then pending = nil end
		local ok, accepted, reason = pcall(function()
			if not owned() then return false, state end
			if outcome ~= true then return revoke(context.kind == "retirement" and "cleanup-pending" or "consent-effect-refused") end
			if not phase_fence(context.kind == "retirement") then return revoke("consent-stale") end
			if context.kind == "retirement" then return invoke("replacement") end
			state = "requalification-pending"
			return true, state
		end)
		assert(life.leave(context.frame), "Update completion frame already released")
		if not ok then return revoke("consent-source-refused") end
		return accepted, reason
	end
	drain = function()
		local context = pending
		if context and context.returned and context.authorized and context.buffered then
			local outcome = context.buffered.outcome
			context.buffered = nil
			busy = true
			complete(context, outcome)
			busy = false
		end
	end
	invoke = function(kind)
		phase = kind
		local context = { kind = kind, nonce = {}, frame = life.enter(), returned = false, authorized = false }
		assert(context.frame ~= nil, "Missing update operation frame")
		pending = context
		local function completion(candidate_owner, candidate_token, nonce, physically_closed, outcome)
			if not rawequal(candidate_owner, operation.owner) or not rawequal(candidate_token, operation.token)
				or not rawequal(nonce, context.nonce) or context.closed
				or physically_closed ~= true or type(outcome) ~= "boolean" then return false end
			if context.receiving then return revoke("consent-reentered") end
			return life.run(function()
				if context.closed then return false end
				-- Identity survives stop; current authority is not required to settle old physical debt.
				context.receiving = true
				local ok, identity = pcall(operation.identity, operation.owner)
				context.receiving = false
				if not ok or not rawequal(identity, operation.token) then return false end
				if not context.returned or busy then
					if context.buffered then return false end
					context.buffered = { outcome = outcome }
					return true
				end
				if not context.authorized then return false end
				busy = true
				complete(context, outcome)
				busy = false
				return true -- Receipt of physical completion, never effect success or readiness.
			end)
		end
		local port = kind == "retirement" and operation.retire or operation.replace
		local ok, response, ticket = pcall(port, operation.owner, operation.token, selected.owner, selected.token,
			offer_token, observed.intent.owner, observed.intent.token, offered_intent, context.nonce, completion)
		context.returned = true
		if ok and response == "pending" and rawequal(ticket, context.nonce) then
			context.authorized = true
			if owned() then state = kind .. "-pending" end
			if context.buffered then
				local outcome = context.buffered.outcome
				context.buffered = nil
				return complete(context, outcome)
			end
			return false, state
		end
		if ok and response == true and context.buffered == nil then return complete(context, true) end
		context.closed = true
		if pending == context then pending = nil end
		assert(life.leave(context.frame), "Refused update frame already released")
		return revoke(kind == "retirement" and "cleanup-pending" or "consent-effect-refused")
	end

	--- Routes an immutable shallow receipt through the unchanged real dependency validator.
	--- Only its accepted revisions/generations are retained; opaque identities are never interpreted.
	---@param record table Actual bound observation receipt; no native fact is manufactured.
	---@param token table Exact original source subscription identity.
	---@return boolean accepted Receipt retention, never update/readiness authority.
	function consent.receive(record, token)
		if busy then return revoke("consent-reentered") end
		if not owned() then return false, state end
		if not plain(record) then return revoke("consent-input-refused") end
		local copy = {}
		for key, value in next, record do copy[key] = value end
		return operate(function()
			if dependency_receive(copy, token) ~= true then return revoke("consent-input-refused") end
			if not owned() then return false, state end
			local previous = cohorts[copy.kind]
			local planned_close = consumed and phase == "retirement" and pending and pending.authorized
				and (copy.kind == "broker" or copy.kind == "client") and previous
				and copy.generation == previous.generation and rawequal(copy.connection, previous.connection)
				and rawequal(copy.reference, previous.reference)
			cohorts[copy.kind] = { revision = copy.revision, generation = copy.generation,
				reference = copy.reference, connection = copy.connection }
			epoch = epoch + 1
			if planned_close then offered_epoch = epoch
			elseif issued and consumed then return revoke("consent-stale")
			elseif issued then state = "consent-stale" end
			return true
		end)
	end

	--- Mints at most one opaque offer from a current qualified incompatibility decision.
	---@param candidate_owner table Exact original consent owner.
	---@return table|nil offer Identity only; mutable contents grant nothing.
	function consent.offer(candidate_owner)
		if not rawequal(candidate_owner, owner) then return nil, "consent-identity-refused" end
		if busy then revoke("consent-reentered"); return nil, state end
		if issued then return nil, "consent-offer-consumed" end
		local value, reason = operate(function()
			local decision = dependency_decision()
			if not owned() or decision.state ~= "incompatible-vhid" then return nil, "consent-not-incompatible" end
			if not fence() then return revoke("consent-source-refused") end
			issued, state, offer_token, offered_epoch = true, "offered", {}, epoch
			offered_intent = cohorts.intent.generation
			return offer_token
		end)
		if type(value) == "table" then return value end
		return nil, reason
	end

	--- Consumes literal user confirmation before retirement/effects and revalidates between both ports.
	--- Pending handoffs await exact physical completion. Success is requalification pending, never admission.
	---@param candidate_owner table Exact original consent owner.
	---@param offer table Exact identity returned by offer.
	---@param confirmed boolean Only literal true permits the one fixed native effect.
	---@return boolean accepted Whether the one current effect returned literal true.
	---@return string reason Stable policy state; never raw native payloads.
	function consent.confirm(candidate_owner, offer, confirmed)
		if not rawequal(candidate_owner, owner) or offer_token == nil or not rawequal(offer, offer_token) then
			return false, "consent-identity-refused"
		end
		if busy then return revoke("consent-reentered") end
		if consumed then return false, "consent-offer-consumed" end
		consumed = true
		if not owned() then return false, state end
		if confirmed ~= true then state = "consent-declined"; return false, state end
		return operate(function()
			if not unchanged() then return revoke("consent-stale") end
			return invoke("retirement")
		end)
	end

	--- Closing the offer is a consumed refusal, with no native effect.
	function consent.close(candidate_owner, offer) return consent.confirm(candidate_owner, offer, false) end
	--- Returns detached status only; installation never grants readiness.
	function consent.status() return { state = state, admit = false } end
	--- Revokes consent before actual dependency observer retirement.
	function consent.stop() revoke("consent-stopped"); return true end
	--- Waits for all four real subscription detach/retirement ACKs and this owner's callback frames.
	function consent.retired()
		if active or busy or pending ~= nil then return false end
		busy = true
		local ok, completed = pcall(life.run, function()
			if dependency_retired() ~= true then return false end
			life.detach(); return true
		end)
		busy = false
		if drain then drain() end
		return pending == nil and ok and completed == true and own_retired(owner, own_token) == true
	end
	return consent
end

return M
