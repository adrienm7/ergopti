--- _shared/lua/shortcuts/physical_slots.lua

--- ==============================================================================
--- MODULE: User Physical Shortcut Slots
--- DESCRIPTION:
--- Names user-owned physical keys and exact modifier sets in the existing
--- shortcuts.keyboard namespace. Native adapters prove event provenance and
--- translate platform modifier names; this owner never resolves logical text.
--- ==============================================================================

local M = {}

local PREFIX = "physical_"
local MODIFIER_ORDER = { "ctrl", "alt", "shift", "super" }
local MODIFIERS = { ctrl = true, alt = true, shift = true, super = true }
local MODIFIER_KEYS = {
	ShiftLeft = true, ShiftRight = true, ControlLeft = true, ControlRight = true,
	AltLeft = true, AltRight = true, MetaLeft = true, MetaRight = true, CapsLock = true,
}
local NATIVE_FIELDS = { hs = true, evdev = true, ahk = true }

--- Recognizes this namespace even when its contents are malformed.
--- @param slot any Candidate configuration key.
--- @return boolean owned_namespace
function M.is_namespace(slot)
	return type(slot) == "string" and slot:sub(1, #PREFIX) == PREFIX
end

--- Returns detached canonical modifier ordering for shared editors.
--- @return table modifiers Dense array of canonical modifier names.
function M.modifiers()
	local result = {}
	for index, name in ipairs(MODIFIER_ORDER) do result[index] = name end
	return result
end

--- Normalizes only a dense modifier array or a closed boolean modifier set.
--- @param value table|nil Modifiers; nil is an empty set for encoding only.
--- @return table|nil set Detached exact modifier set.
local function modifier_set(value)
	if value == nil then return {} end
	if type(value) ~= "table" or getmetatable(value) ~= nil then return nil end
	local result, count, array = {}, 0, false
	for key in pairs(value) do if type(key) == "number" then array = true end end
	for key, item in pairs(value) do
		if array then
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value
				or type(item) ~= "string" or MODIFIERS[item] ~= true or result[item] then return nil end
			result[item], count = true, count + 1
		else
			if MODIFIERS[key] ~= true or type(item) ~= "boolean" then return nil end
			if item then result[key] = true end
		end
	end
	if array and count ~= #value then return nil end
	return result
end

--- Encodes one exact modifier set, including plain physical keys.
--- @param set table Validated canonical modifier set.
--- @return string token Canonical ordered modifiers or none.
local function modifier_token(set)
	local tokens = {}
	for _, name in ipairs(MODIFIER_ORDER) do
		if set[name] then tokens[#tokens + 1] = name end
	end
	return #tokens == 0 and "none" or table.concat(tokens, "_")
end

--- Checks a native identity without inferring support from another platform.
--- @param value any Registry identity.
--- @param field string Registry platform field.
--- @return boolean valid
local function valid_native(value, field)
	if value == nil then return true end
	if field == "ahk" then return type(value) == "string" and value ~= "" and value:find("[%c]") == nil end
	return type(value) == "number" and value % 1 == 0 and value >= (field == "evdev" and 1 or 0)
end

--- Binds one immutable registry snapshot without creating any assignments.
--- @param registry table Decoded canonical physical_keys.json.
--- @return table owner Stateless slot and native-identity policy.
function M.new(registry)
	assert(type(registry) == "table" and registry.schema_version == 1
		and type(registry.keys) == "table" and type(registry.forms) == "table",
		"physical slots require the canonical physical-key registry")
	local forms, keys, order, form_count = {}, {}, {}, 0
	for index, form in pairs(registry.forms) do
		assert(type(index) == "number" and index % 1 == 0 and index >= 1 and index <= #registry.forms
			and type(form) == "string" and form:match("^[a-z]+$") and not forms[form],
			"physical-key registry form is invalid")
		forms[form] = true
		form_count = form_count + 1
	end
	assert(form_count > 0 and form_count == #registry.forms, "physical-key registry forms must be a dense array")
	for code, record in pairs(registry.keys) do
		assert(type(code) == "string" and code:match("^[A-Za-z][A-Za-z0-9]*$")
			and type(record) == "table" and (record.kind == "key" or record.kind == "mouse_button" or record.kind == "wheel"),
			"physical-key registry record is invalid")
		if record.kind == "key" and MODIFIER_KEYS[code] ~= true then
			assert(record.geometry == nil or type(record.geometry) == "table", "physical-key geometry is invalid")
			assert(type(record.group) == "string" and record.group ~= "", "physical-key group is invalid")
			local copy = { native = {}, overrides = {}, forms = {}, group = record.group }
			for field in pairs(NATIVE_FIELDS) do
				assert(valid_native(record[field], field), "physical-key native identity is invalid")
				copy.native[field] = record[field]
			end
			for form in pairs(forms) do
				copy.forms[form] = record.geometry == nil or type(record.geometry[form]) == "table"
				local override = record["macos_" .. form]
				if override ~= nil then
					assert(type(override) == "table" and valid_native(override.hs, "hs"),
						"physical-key macOS identity override is invalid")
					copy.overrides[form] = override.hs
				end
			end
			keys[code], order[#order + 1] = copy, code
		end
	end
	assert(#order > 0, "physical-key registry has no shortcut keys")
	table.sort(order)
	local owner = { is_namespace = M.is_namespace }

	--- Reads registry-owned classification without exposing its mutable record.
	--- @param slot any Canonical physical slot.
	--- @return string|nil group Registry key group.
	function owner.key_group(slot)
		local descriptor = owner.parse(slot)
		return descriptor and keys[descriptor.code].group or nil
	end

	--- Builds a canonical slot from a registry code and exact modifiers.
	--- @param code any W3C physical-key code.
	--- @param modifiers table|nil Canonical boolean set or dense modifier array.
	--- @return string|nil slot Canonical configuration key.
	--- @return string|nil reason Closed refusal reason.
	function owner.encode(code, modifiers)
		if type(code) ~= "string" or keys[code] == nil then return nil, "invalid_physical_key" end
		local set = modifier_set(modifiers)
		if not set then return nil, "invalid_modifiers" end
		return PREFIX .. modifier_token(set) .. "_" .. code
	end

	--- Parses only the canonical spelling of a user physical slot.
	--- @param slot any Stored configuration key.
	--- @return table|nil descriptor Detached { slot, code, mods }.
	--- @return string|nil reason Closed refusal reason.
	function owner.parse(slot)
		if not M.is_namespace(slot) then return nil, "outside_namespace" end
		local modifiers, code = slot:sub(#PREFIX + 1):match("^(.-)_([A-Za-z][A-Za-z0-9]*)$")
		if not modifiers or keys[code] == nil then return nil, "invalid_physical_key" end
		local set = {}
		if modifiers ~= "none" then
			for name in modifiers:gmatch("[^_]+") do
				if MODIFIERS[name] ~= true or set[name] then return nil, "invalid_modifiers" end
				set[name] = true
			end
		end
		if owner.encode(code, set) ~= slot then return nil, "noncanonical_slot" end
		return { slot = slot, code = code, mods = set }
	end

	--- Recognizes only valid owned slots, independently of their stored action.
	--- @param slot any Configuration key.
	--- @return boolean owned
	function owner.owns(slot) return owner.parse(slot) ~= nil end

	--- Names an event only after its host proves a physical registry identity.
	--- @param detail table { physical = true, code = W3C code, mods = exact set }.
	--- @return string|nil slot Canonical matched slot.
	--- @return string|nil reason Closed refusal reason.
	function owner.match(detail)
		if type(detail) ~= "table" or detail.physical ~= true or type(detail.mods) ~= "table" then
			return nil, "physical_evidence_required"
		end
		for name, held in pairs(detail.mods) do
			if MODIFIERS[name] ~= true or type(held) ~= "boolean" then return nil, "invalid_modifiers" end
		end
		return owner.encode(detail.code, detail.mods)
	end

	--- Resolves native identity on the requested platform and keyboard form.
	--- @param slot any Canonical physical slot.
	--- @param field string hs, evdev or ahk; translation belongs to native ports.
	--- @param form string|nil Explicit registry form, or the registry base identity.
	--- @return number|string|nil identity Registry native identity, never a logical key.
	--- @return string|nil reason Closed refusal reason.
	function owner.native_code(slot, field, form)
		local descriptor, reason = owner.parse(slot)
		if not descriptor then return nil, reason end
		if NATIVE_FIELDS[field] ~= true then return nil, "invalid_native_field" end
		if form ~= nil and forms[form] ~= true then return nil, "invalid_keyboard_form" end
		local key = keys[descriptor.code]
		if form ~= nil and key.forms[form] ~= true then return nil, "key_absent_on_form" end
		local value = key.native[field]
		if field == "hs" and form ~= nil and key.overrides[form] ~= nil then value = key.overrides[form] end
		if value == nil then return nil, "native_key_unavailable" end
		return value
	end

	--- Requires one native identity shared by every supported keyboard form.
	--- Native taps lacking per-event form proof must not claim a swapped twin.
	--- @param slot any Canonical physical slot.
	--- @param field string Native registry field.
	--- @return number|string|nil identity Exact form-independent native identity.
	--- @return string|nil reason Closed refusal reason.
	function owner.stable_native_code(slot, field)
		local descriptor, reason = owner.parse(slot)
		if not descriptor then return nil, reason end
		if NATIVE_FIELDS[field] ~= true then return nil, "invalid_native_field" end
		local identity
		for form in pairs(forms) do
			local native = owner.native_code(slot, field, form)
			if native == nil or (identity ~= nil and native ~= identity) then return nil, "keyboard_form_required" end
			identity = native
		end
		return identity
	end

	--- Lists registry positions whose requested native identity exists.
	--- @param field string Native registry field.
	--- @param form string|nil Registry keyboard form.
	--- @return table|nil codes Sorted detached physical-key code array.
	--- @return string|nil reason Closed refusal reason.
	function owner.candidates(field, form)
		if NATIVE_FIELDS[field] ~= true then return nil, "invalid_native_field" end
		if form ~= nil and forms[form] ~= true then return nil, "invalid_keyboard_form" end
		local result = {}
		for _, code in ipairs(order) do
			if owner.native_code(owner.encode(code), field, form) ~= nil then result[#result + 1] = code end
		end
		return result
	end

	--- Resolves a captured native identity only when the registry is unambiguous.
	--- @param identity number|string Native identity proved by the adapter.
	--- @param field string Native registry field.
	--- @param form string|nil Registry keyboard form.
	--- @return string|nil code Unique W3C physical-key code.
	--- @return string|nil reason Closed refusal reason.
	function owner.code_for(identity, field, form)
		if identity == nil then return nil, "native_key_unavailable" end
		local candidates, reason = owner.candidates(field, form)
		if not candidates then return nil, reason end
		local matched
		for _, code in ipairs(candidates) do
			if owner.native_code(owner.encode(code), field, form) == identity then
				if matched then return nil, "ambiguous_native_key" end
				matched = code
			end
		end
		return matched, matched == nil and "native_key_unavailable" or nil
	end

	return owner
end

return M
