--- _shared/lua/hotstrings/personal_adoption.lua

--- ==============================================================================
--- MODULE: Personal Source Adoption Projection (Shared)
--- DESCRIPTION:
--- Combines exact native source observations with canonical ownership decisions.
--- Filesystem access and publication remain with their existing native owners.
--- ==============================================================================

local M = {}
local Files = require("hotstrings.personal_files")
local Policy = require("hotstrings.personal_scope")
local Scanner = require("toml_codec.record_scanner")
local Reader = require("toml_codec.reader")
local KeyPath = require("toml_codec.key_path")

local function primary_identity(path, ports)
	return (ports.primary_physical or ports.physical)(path)
end

--- Represents explicit true over a still-recognized historical neutral false.
--- The native caller holds and rechecks the admitted legacy source cohort.
function M.preference_row(record, section, value)
	assert(type(record) == "table" and record.admitted == true and type(record.legacy_name) == "string"
		and Files.is_descriptor(record.source) and record.source.id == record.owner
		and (section == nil or type(section) == "string" and section ~= "") and type(value) == "boolean",
		"personal legacy preference needs its captured admitted owner")
	return { section = KeyPath.render(section and { "hotstrings", "modules", record.owner } or { "hotstrings", "groups" }),
		key = section or record.owner, value = value,
		personal_choice = value == true and true or nil,
		literal_key = section and section:find(".", 1, true) and true or nil }
end

--- Recognizes representation intent only; native admission remains independent.
function M.is_preference_intent(row)
	if row.personal_choice == nil then return false end
	local parts = type(row.section) == "string" and KeyPath.parse(row.section, true)
	if parts and type(row.key) == "string" then parts[#parts + 1] = row.key end
	assert(row.personal_choice == true and row.value == true and row.delete == nil
		and parts and Files.preference_default(KeyPath.render(parts)) == true,
		"personal choice intent needs an exact nondelete canonical Boolean true leaf")
	return true
end

local function supported_rule_identity(content)
	local scanned = Scanner.scan_records(content, { quoted_headers = true })
	local parsed, committed = Reader.parse_text(content)
	if not scanned or committed ~= true then return false end
	for _, header in ipairs(scanned.headers) do
		-- Keep the established bare-array dialect. A single quoted semantic
		-- identity that this reader cannot recover has no safe literal gate owner.
		if header.array and header.segments and #header.segments == 1
			and not (parsed.sections or {})[header.segments[1]] then return false end
	end
	return true
end

local function dense(values)
	if type(values) ~= "table" then return false end
	local count = 0
	for key in pairs(values) do
		if type(key) ~= "number" or key < 1 or key > #values or key % 1 ~= 0 then return false end
		count = count + 1
	end
	return count == #values
end

--- Plans literal declared sections for canonical descriptor owners only.
--- Native receipts authorize publication; this policy grants no capability.
function M.plan_gates(inventory, targets, enabled)
	if type(inventory) ~= "table" or not dense(targets) or type(enabled) ~= "boolean" then return nil, "invalid-request" end
	if #targets == 0 then return nil, "empty-scope" end
	local selected, changes = {}, {}
	for _, id in ipairs(targets) do
		if not Files.components(id) or selected[id] then return nil, "invalid-category" end
		if not dense(inventory[id]) then return nil, "unknown-category" end
		selected[id] = true
		changes[#changes + 1] = { group = id, enabled = enabled }
		local sections = {}
		for _, name in ipairs(inventory[id]) do
			if type(name) ~= "string" or name == "" or name == "-" or sections[name] then return nil, "invalid-section" end
			sections[name] = true
			changes[#changes + 1] = { group = id, section = name, enabled = enabled }
		end
	end
	return changes
end

--- Composes a menu scope containing primary/common and canonical personal files.
--- Generic owners retain the unchanged generic planner and refusal rules.
function M.plan_selection(inventory, targets, enabled)
	if not dense(targets) then return nil, "invalid-request" end
	if #targets == 0 then return nil, "empty-scope" end
	local seen, changes = {}, {}
	for _, id in ipairs(targets) do
		if seen[id] then return nil, "invalid-category" end
		local planner = Files.components(id) and M.plan_gates or require("hotstrings.bulk_scope").plan
		local part, reason = planner(inventory, { id }, enabled)
		if not part then return nil, reason end
		seen[id] = true
		for _, choice in ipairs(part) do changes[#changes + 1] = choice end
	end
	return changes
end

--- Builds one source cohort without modifying files, preferences or the registry.
--- Existing legacy preferences are considered only when an actual stored owner
--- exists; new files with colliding historical labels still have distinct owners.
--- @param records table Dense discovered source records with source/path/legacy_name.
--- @param choices table Normalized canonical group and section choices.
--- @param primary_path string The independently owned primary personal source.
--- @param ports table Exact native capture and physical-identity functions.
--- @return table|nil records Detached admitted/unavailable records in source order.
--- @return string|nil reason
function M.stage(records, choices, primary_path, ports)
	if type(choices) ~= "table" then return nil, "invalid-preferences" end
	if type(ports) ~= "table" or type(ports.capture) ~= "function" or type(ports.physical) ~= "function" then
		return nil, "invalid-native-owner"
	end
	if type(records) ~= "table" or type(primary_path) ~= "string" or primary_path == "" then
		return nil, "invalid-request"
	end
	local count = 0
	for key in pairs(records) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #records then return nil, "invalid-inventory" end
		count = count + 1
	end
	if count ~= #records then return nil, "invalid-inventory" end
	local candidates, snapshots = {}, {}
	local primary, primary_status = primary_identity(primary_path, ports)
	for index, record in ipairs(records) do
		if type(record) ~= "table" or type(record.path) ~= "string" then return nil, "invalid-inventory" end
		local snapshot = ports.capture(record.path)
		snapshots[index] = snapshot
		local legacy = record.legacy_name
		local has_legacy = type(legacy) == "string"
			and (record.legacy_stored == true
				or (type(choices.groups) == "table" and choices.groups[legacy] ~= nil)
				or (type(choices.modules) == "table" and choices.modules[legacy] ~= nil))
		candidates[index] = { source = record.source, path = record.path,
			physical = snapshot and snapshot.physical or nil,
			legacy_owner = has_legacy and legacy or nil }
	end
	local inventory, reason = Policy.plan_adoption(candidates)
	if not inventory then return nil, reason end
	for index, entry in ipairs(inventory) do
		entry.legacy_name = candidates[index].legacy_owner
		entry.primary_path = primary_path
		local snapshot = snapshots[index]
		if not snapshot then
			entry.admitted, entry.exclusive, entry.reason = false, false, "unreadable-source"
		elseif not supported_rule_identity(snapshot.content) then
			entry.admitted, entry.exclusive, entry.reason = false, false, "unsupported-rule-identity"
		elseif primary and snapshot.physical == primary then
			entry.admitted, entry.exclusive, entry.reason = false, false, "primary-source-alias"
		elseif primary_status == "unavailable" then
			entry.admitted, entry.exclusive, entry.reason = false, false, "unavailable-primary-identity"
		end
		entry.physical = snapshot and snapshot.physical or nil
		entry.content = snapshot and snapshot.content or nil
	end
	return inventory
end

--- Rechecks exact route, physical identity and source bytes for a held cohort.
--- @param inventory table The detached cohort captured before native registration.
--- @param selected table The captured source/owner/path binding.
--- @param ports table Exact native source functions.
--- @return boolean
function M.current(inventory, selected, ports)
	local admitted = Policy.admit(inventory, selected)
	if not admitted then return false end
	for _, record in ipairs(inventory) do
		local snapshot = ports.capture(record.path)
		if record.physical then
			if not snapshot or snapshot.physical ~= record.physical or snapshot.content ~= record.content then
				return false
			end
			local primary, status = primary_identity(record.primary_path, ports)
			if record.admitted and (status == "unavailable" or primary == snapshot.physical) then return false end
		elseif snapshot then return false end
	end
	return true
end

--- Checks a published candidate without advancing the boot-owned catalogue.
--- Native consumers must first verify their invocation-scoped publication proof.
--- This detached probe supplies cleanup evidence, never mutation authority.
--- @param inventory table Original closed source cohort.
--- @param selected table Original admitted source binding.
--- @param content string Exact native-owned candidate bytes.
--- @param ports table Exact native capture functions.
--- @return boolean current
function M.published_current(inventory, selected, content, ports)
	if type(content) ~= "string" or not Policy.admit(inventory, selected) then return false end
	local candidate, replaced = {}, false
	for index, record in ipairs(inventory) do
		local copy = {}
		for key, value in pairs(record) do copy[key] = value end
		if record.owner == selected.owner and record.path == selected.path then
			if record.physical ~= selected.physical or record.content ~= selected.content then return false end
			local observed = ports.capture(record.path)
			if not observed or observed.content ~= content then return false end
			for _, sibling in ipairs(inventory) do
				if sibling ~= record and sibling.physical == observed.physical then return false end
			end
			copy.physical, copy.content, replaced = observed.physical, observed.content, true
		end
		candidate[index] = copy
	end
	return replaced and M.current(candidate, selected, ports) == true
end

--- Advances only one acknowledged publication within its previously admitted
--- cohort. An unexpected replacement or alias leaves future authority closed.
function M.advance(inventory, selected, content, ports)
	if not Policy.admit(inventory, selected) or type(content) ~= "string" then return false end
	local target
	for _, record in ipairs(inventory) do
		local observed = ports.capture(record.path)
		if record.owner == selected.owner and record.path == selected.path then
			local primary, status = primary_identity(record.primary_path, ports)
			if not observed or observed.content ~= content
				or status == "unavailable" or primary == observed.physical then return false end
			target = { record = record, observed = observed }
		elseif record.physical and (not observed or observed.physical ~= record.physical
			or observed.content ~= record.content) or not record.physical and observed then return false end
	end
	if not target then return false end
	for _, record in ipairs(inventory) do
		if record ~= target.record and record.physical == target.observed.physical then return false end
	end
	target.record.physical, target.record.content = target.observed.physical, target.observed.content
	return true
end

--- Projects only the selected unambiguous legacy preferences into the new owner.
--- Unknown legacy records remain in their existing disk namespace.
--- @param record table Current adoption record.
--- @param choices table Normalized canonical group and section choices.
--- @return boolean enabled
--- @return table sections Detached explicit section choices.
function M.preferences(record, choices)
	local groups, modules = choices.groups or {}, choices.modules or {}
	local enabled = groups[record.owner]
	local supplied = modules[record.owner]
	if record.admitted ~= true then return false, {} end
	if enabled == nil and record.legacy_name then enabled = groups[record.legacy_name] end
	if enabled == nil then enabled = record.legacy_name == nil and Files.additional_default_enabled or false end
	if supplied == nil and record.legacy_name then supplied = modules[record.legacy_name] end
	local sections = {}
	for name, value in pairs(supplied or {}) do sections[name] = value end
	return enabled, sections
end

return M
