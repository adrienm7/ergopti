--- _shared/lua/network/failure.lua

--- ==============================================================================
--- MODULE: Managed Network Failure Contract
--- DESCRIPTION:
--- Interprets the canonical managed_network.json policy over structured native
--- receipts. It never infers a network cause from stderr, a URL or an origin's
--- refusal. Drivers own receipts, native settings and the live action owner.
--- ==============================================================================

local M = {}

local function contains(values, expected)
	for _, value in ipairs(values) do
		if type(value) == type(expected) and value == expected then return true end
	end
	return false
end

local function scalar(value, definition)
	if definition.type == "integer" then
		if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
			or value ~= math.floor(value) then return false end
	elseif definition.type == "string" then
		if type(value) ~= "string" then return false end
	else
		return false
	end
	return definition.values == nil or contains(definition.values, value)
end

local function nonempty_array(value)
	if type(value) ~= "table" or #value == 0 then return false end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key > #value or key ~= math.floor(key) then return false end
		count = count + 1
	end
	return count == #value
end

local function validate(policy)
	assert(type(policy) == "table" and policy.schema_version == 1, "unsupported managed network policy")
	assert(type(policy.fields) == "table" and type(policy.causes) == "table"
		and type(policy.actions) == "table" and nonempty_array(policy.rules)
		and nonempty_array(policy.capabilities), "incomplete managed network policy")
	assert(type(policy.default_cause) == "string" and policy.causes[policy.default_cause], "invalid default cause")
	local capabilities, rule_ids = {}, {}
	for _, name in ipairs(policy.capabilities) do
		assert(type(name) == "string" and name ~= "" and not capabilities[name], "invalid capability")
		capabilities[name] = true
	end
	for name, field in pairs(policy.fields) do
		assert(type(name) == "string" and type(field) == "table"
			and (field.type == "string" or field.type == "integer"), "invalid receipt field")
		if field.values ~= nil then
			assert(nonempty_array(field.values), "receipt enum must not be empty")
			for _, value in ipairs(field.values) do
				assert(scalar(value, { type = field.type }), "invalid receipt enum value")
			end
		end
	end
	for id, action in pairs(policy.actions) do
		assert(type(id) == "string" and type(action) == "table" and type(action.label_key) == "string"
			and action.label_key ~= "" and nonempty_array(action.requires), "invalid managed network action")
		for _, capability in ipairs(action.requires) do
			assert(capabilities[capability], "action needs an undeclared capability")
		end
	end
	for id, cause in pairs(policy.causes) do
		assert(type(id) == "string" and type(cause) == "table" and type(cause.message_key) == "string"
			and cause.message_key ~= "" and nonempty_array(cause.actions), "invalid managed network cause")
		for _, action in ipairs(cause.actions) do assert(policy.actions[action], "cause has an undeclared action") end
	end
	for _, rule in ipairs(policy.rules) do
		assert(type(rule) == "table" and type(rule.id) == "string" and rule.id ~= "" and not rule_ids[rule.id]
			and policy.causes[rule.cause] and type(rule.when) == "table" and next(rule.when), "invalid failure rule")
		rule_ids[rule.id] = true
		for field, values in pairs(rule.when) do
			assert(policy.fields[field] and nonempty_array(values), "rule has an undeclared receipt field")
			for _, value in ipairs(values) do assert(scalar(value, policy.fields[field]), "invalid rule receipt value") end
		end
	end
end

--- Builds a pure contract from the decoded canonical policy.
--- @param policy table Parsed _shared/modules/network/managed_network.json.
--- @return table contract The classify and actions functions. No I/O or logging.
function M.new(policy)
	validate(policy)
	local contract = {}

	--- Lists only the actions whose real host capabilities are available now.
	--- Recompute at dispatch; a row's retained capabilities do not admit a click.
	--- @param cause string Previously classified cause.
	--- @param capabilities table Fresh native owner and action capabilities.
	--- @return table actions Ordered id and label_key records, without paths.
	function contract.actions(cause, capabilities)
		assert(type(capabilities) == "table" and policy.causes[cause], "invalid failure action context")
		local actions = {}
		for _, id in ipairs(policy.causes[cause].actions) do
			local definition, available = policy.actions[id], true
			for _, capability in ipairs(definition.requires) do
				if capabilities[capability] ~= true then available = false end
			end
			if available then actions[#actions + 1] = { id = id, label_key = definition.label_key } end
		end
		return actions
	end

	--- Classifies typed native evidence without guessing from generic failures.
	--- Unknown metadata is discarded; malformed declared metadata fails closed.
	--- @param receipt table Native receipt. No stderr interpretation or secrets.
	--- @param capabilities table Fresh host capabilities, not UI input.
	--- @return table report Cause, message_key, evidence rule id and actions.
	function contract.classify(receipt, capabilities)
		assert(type(receipt) == "table", "managed network receipt must be a table")
		local cause, evidence, valid = policy.default_cause, "insufficient_evidence", true
		for field, definition in pairs(policy.fields) do
			if receipt[field] ~= nil and not scalar(receipt[field], definition) then valid = false end
		end
		if valid then
			for _, rule in ipairs(policy.rules) do
				local matches = true
				for field, values in pairs(rule.when) do
					if not contains(values, receipt[field]) then matches = false end
				end
				if matches then cause, evidence = rule.cause, rule.id; break end
			end
		else
			evidence = "invalid_receipt"
		end
		return { cause = cause, message_key = policy.causes[cause].message_key, evidence = evidence,
			actions = contract.actions(cause, capabilities) }
	end

	return contract
end

return M
