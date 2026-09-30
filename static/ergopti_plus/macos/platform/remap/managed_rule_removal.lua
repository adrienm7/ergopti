--- platform/remap/managed_rule_removal.lua

--- ==============================================================================
--- MODULE: Karabiner Managed-Rule Removal
--- DESCRIPTION:
--- Removes every rule carrying the exact ErgoptiPlus ownership marker from the
--- user's karabiner.json, in every profile, while every other byte of the file
--- stays as it was. Used when « Ergopti uses Karabiner » is off and by the
--- explicit « Remove Ergopti from Karabiner » command. Also removes, on the
--- user's confirmation, the untagged rules an older release left behind that
--- the merge refuses to replace (remove_legacy_rules).
---
--- FEATURES & RATIONALE:
--- 1. Byte-identical personal rules: the file is never decoded and re-encoded.
---    A position-aware scan finds each rule's exact byte span and only the
---    marked spans (with one adjacent separator) are cut out, so key order,
---    number spelling, escapes and indentation of personal rules are kept.
--- 2. One ownership parser: a rule is ErgoptiPlus's only when
---    LeaseContract.parse_managed_description accepts its description, the
---    same parser the generator uses. Unmarked rules are never removed.
--- 3. Fail closed: malformed JSON, duplicate structural keys, a non-object rule
---    or a result that does not decode to exactly the original minus the marked
---    rules refuses the removal and leaves the file untouched.
--- 4. Compare-before-write: publication goes through the atomic
---    FileSystem.write_if_unchanged with the exact bytes that were scanned, so a
---    concurrent Karabiner or editor write is never overwritten.
--- 5. No lease, no token, no Karabiner process: this module needs none of them.
--- 6. Ports resolved per call: the filesystem and JSON adapters are looked up
---    when a removal runs, so a caller always acts through the adapters that
---    are installed at that moment.
--- 7. One legacy verdict: the untagged rules removed on request are exactly
---    those the generator's merge reports as historical-signature conflicts
---    (Generator.find_legacy_signature_conflicts), after a verified backup of
---    the original bytes is written next to karabiner.json.
--- ==============================================================================

local M = {}

local Logger        = require("infra.logger")
local LeaseContract = require("platform.remap.lease_contract")

local LOG = "karabiner"

local JSON_WHITESPACE = { [" "] = true, ["\t"] = true, ["\n"] = true, ["\r"] = true }
local JSON_ESCAPES = {
	['"'] = '"', ["\\"] = "\\", ["/"] = "/",
	b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}
local HIGH_SURROGATE_FIRST = 0xD800
local LOW_SURROGATE_FIRST  = 0xDC00
local LOW_SURROGATE_LAST   = 0xDFFF
local SURROGATE_OFFSET     = 0x10000
local FIRST_PRINTABLE_BYTE = 0x20





-- ======================================
-- ======================================
-- ======= 1/ Position-Aware JSON =======
-- ======================================
-- ======================================

--- Raises a positioned scan failure caught by strip_managed_rules.
--- @param position integer Byte offset of the failure.
--- @param detail string What was expected.
local function fail_at(position, detail)
	error({ scan_error = string.format("invalid JSON at byte %d: %s", position, detail) }, 0)
end

--- Returns the first non-whitespace byte offset at or after position.
--- @param text string JSON source.
--- @param position integer Start offset.
--- @return integer position
local function skip_whitespace(text, position)
	while JSON_WHITESPACE[text:sub(position, position)] do position = position + 1 end
	return position
end

--- Scans one JSON string and decodes it (keys must be compared decoded).
--- @param text string JSON source.
--- @param position integer Offset of the opening quote.
--- @return integer last Offset of the closing quote.
--- @return string value Decoded string.
local function scan_string(text, position)
	local parts = {}
	local cursor = position + 1
	while true do
		local byte = text:byte(cursor)
		if byte == nil then fail_at(cursor, "unterminated string") end
		if byte == 34 then return cursor, table.concat(parts) end
		if byte < FIRST_PRINTABLE_BYTE then fail_at(cursor, "control character in string") end
		if byte == 92 then
			local escape = text:sub(cursor + 1, cursor + 1)
			if escape == "u" then
				local hex = text:sub(cursor + 2, cursor + 5)
				if not hex:match("^%x%x%x%x$") then fail_at(cursor, "invalid \\u escape") end
				local code_point = tonumber(hex, 16)
				cursor = cursor + 6
				if code_point >= HIGH_SURROGATE_FIRST and code_point < LOW_SURROGATE_FIRST then
					local low_hex = text:match("^\\u(%x%x%x%x)", cursor)
					local low = low_hex and tonumber(low_hex, 16) or nil
					if not low or low < LOW_SURROGATE_FIRST or low > LOW_SURROGATE_LAST then
						fail_at(cursor, "unpaired surrogate")
					end
					code_point = SURROGATE_OFFSET
						+ (code_point - HIGH_SURROGATE_FIRST) * 0x400 + (low - LOW_SURROGATE_FIRST)
					cursor = cursor + 6
				elseif code_point >= LOW_SURROGATE_FIRST and code_point <= LOW_SURROGATE_LAST then
					fail_at(cursor, "unpaired surrogate")
				end
				parts[#parts + 1] = utf8.char(code_point)
			else
				local decoded = JSON_ESCAPES[escape]
				if not decoded then fail_at(cursor, "invalid escape") end
				parts[#parts + 1] = decoded
				cursor = cursor + 2
			end
		else
			local run_end = cursor
			while true do
				local next_byte = text:byte(run_end + 1)
				if next_byte == nil or next_byte == 34 or next_byte == 92
					or next_byte < FIRST_PRINTABLE_BYTE then break end
				run_end = run_end + 1
			end
			parts[#parts + 1] = text:sub(cursor, run_end)
			cursor = run_end + 1
		end
	end
end

local scan_value

--- Scans one JSON array, recording each element's exact span.
--- @param text string JSON source.
--- @param position integer Offset of `[`.
--- @return table node { kind, first, last, elements }
local function scan_array(text, position)
	local node = { kind = "array", first = position, elements = {} }
	local cursor = skip_whitespace(text, position + 1)
	if text:sub(cursor, cursor) == "]" then
		node.last = cursor
		return node
	end
	while true do
		local element = scan_value(text, cursor)
		node.elements[#node.elements + 1] = element
		cursor = skip_whitespace(text, element.last + 1)
		local separator = text:sub(cursor, cursor)
		if separator == "]" then
			node.last = cursor
			return node
		end
		if separator ~= "," then fail_at(cursor, "expected ',' or ']'") end
		cursor = skip_whitespace(text, cursor + 1)
	end
end

--- Scans one JSON object; a duplicated key is recorded, not merged.
--- @param text string JSON source.
--- @param position integer Offset of `{`.
--- @return table node { kind, first, last, members = { [key] = { values } } }
local function scan_object(text, position)
	local node = { kind = "object", first = position, members = {} }
	local cursor = skip_whitespace(text, position + 1)
	if text:sub(cursor, cursor) == "}" then
		node.last = cursor
		return node
	end
	while true do
		if text:sub(cursor, cursor) ~= '"' then fail_at(cursor, "expected a member name") end
		local key_last, key = scan_string(text, cursor)
		cursor = skip_whitespace(text, key_last + 1)
		if text:sub(cursor, cursor) ~= ":" then fail_at(cursor, "expected ':'") end
		local value = scan_value(text, skip_whitespace(text, cursor + 1))
		local values = node.members[key] or {}
		values[#values + 1] = value
		node.members[key] = values
		cursor = skip_whitespace(text, value.last + 1)
		local separator = text:sub(cursor, cursor)
		if separator == "}" then
			node.last = cursor
			return node
		end
		if separator ~= "," then fail_at(cursor, "expected ',' or '}'") end
		cursor = skip_whitespace(text, cursor + 1)
	end
end

--- Scans any JSON value starting exactly at position.
--- @param text string JSON source.
--- @param position integer Offset of the value's first byte.
--- @return table node { kind, first, last, ... }
scan_value = function(text, position)
	local first = text:sub(position, position)
	if first == "{" then return scan_object(text, position) end
	if first == "[" then return scan_array(text, position) end
	if first == '"' then
		local last = scan_string(text, position)
		return { kind = "string", first = position, last = last }
	end
	for _, literal in ipairs({ "true", "false", "null" }) do
		if text:sub(position, position + #literal - 1) == literal then
			return { kind = literal, first = position, last = position + #literal - 1 }
		end
	end
	if first == "-" or first:match("^%d$") then
		local cursor = first == "-" and position + 1 or position
		local integer = text:match("^0", cursor) or text:match("^[1-9]%d*", cursor)
		if not integer then fail_at(position, "invalid number") end
		cursor = cursor + #integer
		local fraction = text:match("^%.%d+", cursor)
		if fraction then cursor = cursor + #fraction end
		local exponent = text:match("^[eE][%+%-]?%d+", cursor)
		if exponent then cursor = cursor + #exponent end
		return { kind = "number", first = position, last = cursor - 1 }
	end
	fail_at(position, "unexpected character")
end

--- Returns the single value of a structural member, or nil when absent.
--- @param object table Object node.
--- @param key string Member name.
--- @param path string Diagnostic path.
--- @return table|nil node
local function unique_member(object, key, path)
	local values = object.members[key]
	if values == nil then return nil end
	if #values ~= 1 then
		error({ scan_error = string.format("duplicate '%s' member in %s", key, path) }, 0)
	end
	return values[1]
end





-- ==========================================
-- ==========================================
-- ======= 2/ Byte-Preserving Removal =======
-- ==========================================
-- ==========================================

--- Rebuilds one rules array without the removed elements. Kept elements are
--- copied byte for byte; each is followed by the separator that followed it.
--- @param text string JSON source.
--- @param array table Array node.
--- @param removed table Set of removed element indices.
--- @return string replacement Exact text for array.first..array.last.
local function rebuild_array(text, array, removed)
	local elements = array.elements
	local kept = {}
	for index = 1, #elements do
		if not removed[index] then kept[#kept + 1] = index end
	end
	local last_element = elements[#elements]
	local closing = text:sub(last_element.last + 1, array.last)
	if #kept == 0 then return "[" .. closing end
	local parts = { text:sub(array.first, elements[1].first - 1) }
	for position, index in ipairs(kept) do
		local element = elements[index]
		parts[#parts + 1] = text:sub(element.first, element.last)
		if position < #kept then
			parts[#parts + 1] = text:sub(element.last + 1, elements[index + 1].first - 1)
		end
	end
	parts[#parts + 1] = closing
	return table.concat(parts)
end

--- Compares two decoded JSON values structurally.
--- @param left any First value.
--- @param right any Second value.
--- @return boolean equal
local function deep_equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do
		if not deep_equal(value, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

--- Decodes one JSON text through the codec adapter.
--- @param text string JSON source.
--- @param label string Diagnostic label.
--- @return any value
local function decode_or_fail(text, label)
	local value, decode_err = require("adapters.json_codec").decode(text)
	if decode_err ~= nil then
		error({ scan_error = label .. " does not decode: " .. tostring(decode_err) }, 0)
	end
	return value
end

--- Removes the rules a selector picks from a karabiner.json text, in every
--- profile. Pure: no filesystem access, so the byte guarantee is testable.
--- @param text string Complete karabiner.json content.
--- @param is_selected function fn(rule, profile_index, rule_index) -> boolean, given
---        each rule decoded on its own; it may raise { scan_error = detail }.
--- @return string|nil stripped New content (the input itself when nothing is selected).
--- @return integer|string removed_or_error Count of removed rules, or the refusal.
local function strip_selected_rules(text, is_selected)
	if type(text) ~= "string" then return nil, "karabiner.json content must be a string" end
	local ok, result, removed_count = pcall(function()
		local root_first = skip_whitespace(text, 1)
		local root = scan_value(text, root_first)
		if skip_whitespace(text, root.last + 1) <= #text then
			fail_at(root.last + 1, "trailing content")
		end
		if root.kind ~= "object" then
			error({ scan_error = "karabiner.json must be a JSON object" }, 0)
		end
		local profiles = unique_member(root, "profiles", "the root object")
		if profiles == nil then return text, 0 end
		if profiles.kind ~= "array" then
			error({ scan_error = "profiles must be an array" }, 0)
		end

		local edits = {}
		local removed_by_profile = {}
		local total = 0
		for profile_index, profile in ipairs(profiles.elements) do
			if profile.kind ~= "object" then
				error({ scan_error = string.format("profile %d must be an object", profile_index) }, 0)
			end
			local path = string.format("profile %d", profile_index)
			local complex = unique_member(profile, "complex_modifications", path)
			if complex ~= nil then
				if complex.kind ~= "object" then
					error({ scan_error = path .. " complex_modifications must be an object" }, 0)
				end
				local rules = unique_member(complex, "rules", path .. " complex_modifications")
				if rules ~= nil then
					if rules.kind ~= "array" then
						error({ scan_error = path .. " complex_modifications.rules must be an array" }, 0)
					end
					local removed = {}
					local removed_here = 0
					for rule_index, rule_node in ipairs(rules.elements) do
						if rule_node.kind ~= "object" then
							error({ scan_error = string.format("%s rule %d must be an object",
								path, rule_index) }, 0)
						end
						local rule = decode_or_fail(text:sub(rule_node.first, rule_node.last),
							string.format("%s rule %d", path, rule_index))
						if type(rule) == "table" and is_selected(rule, profile_index, rule_index) then
							removed[rule_index] = true
							removed_here = removed_here + 1
						end
					end
					if removed_here > 0 then
						edits[#edits + 1] = { node = rules, removed = removed }
						removed_by_profile[profile_index] = removed
						total = total + removed_here
					end
				end
			end
		end
		if total == 0 then return text, 0 end

		table.sort(edits, function(a, b) return a.node.first > b.node.first end)
		local stripped = text
		for _, edit in ipairs(edits) do
			stripped = stripped:sub(1, edit.node.first - 1)
				.. rebuild_array(stripped, edit.node, edit.removed)
				.. stripped:sub(edit.node.last + 1)
		end

		-- The scan is only trusted when the result decodes to exactly the
		-- original document minus the selected rules
		local expected = decode_or_fail(text, "the original karabiner.json")
		for profile_index, removed in pairs(removed_by_profile) do
			local rules = expected.profiles[profile_index].complex_modifications.rules
			for rule_index = #rules, 1, -1 do
				if removed[rule_index] then table.remove(rules, rule_index) end
			end
		end
		local actual = decode_or_fail(stripped, "the stripped karabiner.json")
		if not deep_equal(expected, actual) then
			error({ scan_error = "the stripped document differs beyond the selected rules" }, 0)
		end
		return stripped, total
	end)
	if not ok then
		if type(result) == "table" and result.scan_error then return nil, result.scan_error end
		return nil, "managed-rule scan raised: " .. tostring(result)
	end
	return result, removed_count
end

--- Removes every exactly marked ErgoptiPlus rule from a karabiner.json text.
--- Pure: no filesystem access, so the byte guarantee is testable directly.
--- @param text string Complete karabiner.json content.
--- @return string|nil stripped New content (the input itself when nothing is marked).
--- @return integer|string removed_or_error Count of removed rules, or the refusal.
function M.strip_managed_rules(text)
	return strip_selected_rules(text, function(rule)
		return LeaseContract.parse_managed_description(rule.description) ~= nil
	end)
end





-- ===============================
-- ===============================
-- ======= 3/ File Removal =======
-- ===============================
-- ===============================

--- Removes every ErgoptiPlus-marked rule from the live karabiner.json.
--- @param karabiner_out string Absolute path to karabiner.json.
--- @return boolean ok True when no marked rule remains in the published file.
--- @return string detail `absent`, `unchanged`, `removed`, or the refusal.
--- @return integer removed_count Number of rules removed.
function M.remove_managed_rules(karabiner_out)
	Logger.start(LOG, "Removing ErgoptiPlus rules from karabiner.json…")
	if type(karabiner_out) ~= "string" or karabiner_out == "" then
		Logger.error(LOG, "Managed-rule removal refused: the karabiner.json path is not resolved.")
		return false, "karabiner.json path is not resolved", 0
	end
	local FileSystem = require("adapters.file_system")
	local raw, status, read_detail = FileSystem.read_with_status(karabiner_out)
	if status == "absent" then
		Logger.success(LOG, "No karabiner.json at '%s' — no ErgoptiPlus rule to remove.", karabiner_out)
		return true, "absent", 0
	end
	if status ~= "ok" or type(raw) ~= "string" then
		local detail = "karabiner.json could not be read: " .. tostring(read_detail or status)
		Logger.error(LOG, "Managed-rule removal refused — %s.", detail)
		return false, detail, 0
	end

	local stripped, removed_or_error = M.strip_managed_rules(raw)
	if stripped == nil then
		Logger.error(LOG, "Managed-rule removal refused — %s. karabiner.json was left untouched.",
			tostring(removed_or_error))
		return false, tostring(removed_or_error), 0
	end
	if removed_or_error == 0 then
		Logger.success(LOG, "karabiner.json holds no ErgoptiPlus rule — nothing to remove.")
		return true, "unchanged", 0
	end

	local write_ok, written, write_detail = pcall(FileSystem.write_if_unchanged, karabiner_out, stripped,
		{ status = "ok", content = raw })
	if not write_ok or written ~= true then
		local detail = "karabiner.json publication refused: "
			.. tostring(write_ok and (write_detail or "write failed") or written)
		Logger.error(LOG, "Managed-rule removal failed — %s.", detail)
		return false, detail, 0
	end
	Logger.success(LOG, "Removed %d ErgoptiPlus rule(s) from karabiner.json; personal rules are byte-identical.",
		removed_or_error)
	return true, "removed", removed_or_error
end

-- Distinguishes two backups written within the same second of one launch.
local _legacy_backup_serial = 0

--- Writes the exact original bytes to a new file next to karabiner.json and
--- reads them back. An existing file of that name is never replaced.
--- @param FileSystem table File-system adapter.
--- @param karabiner_out string Absolute path to karabiner.json.
--- @param raw string Original content.
--- @return string|nil backup_path Path of the verified backup.
--- @return string|nil error_message Why no verified backup exists.
local function write_legacy_backup(FileSystem, karabiner_out, raw)
	_legacy_backup_serial = _legacy_backup_serial + 1
	local backup_path = string.format("%s.ergoptiplus-legacy-%s-%d.bak",
		karabiner_out, os.date("%Y%m%d-%H%M%S"), _legacy_backup_serial)
	local create_ok, created, create_status, create_detail = pcall(FileSystem.create_if_absent,
		backup_path, raw)
	if not create_ok then
		return nil, "backup creation raised: " .. tostring(created)
	end
	if created ~= true then
		return nil, string.format("backup '%s' was not created (%s): %s", backup_path,
			tostring(create_status), tostring(create_detail))
	end
	local observed, observed_status = FileSystem.read_with_status(backup_path)
	if observed_status ~= "ok" or observed ~= raw then
		return nil, string.format("backup '%s' does not read back as the original bytes (%s)",
			backup_path, tostring(observed_status))
	end
	return backup_path
end

--- Removes, from every profile, the untagged rules an older ErgoptiPlus left
--- in karabiner.json that the merge refuses to replace: exactly those
--- Generator.find_legacy_signature_conflicts reports. Personal rules and
--- managed-tagged rules keep their bytes. A verified backup of the original
--- file is written first; the new content is published only over the exact
--- bytes that were read and classified.
--- @param karabiner_out string Absolute path to karabiner.json.
--- @param legacy_context table Fourth return value of Generator.build_karabiner_json.
--- @return boolean ok True when no such rule remains in the published file.
--- @return string detail `absent`, `unchanged`, `removed`, or the refusal.
--- @return integer removed_count Number of rules removed.
--- @return string|nil backup_path The verified backup, when one was written.
function M.remove_legacy_rules(karabiner_out, legacy_context)
	Logger.start(LOG, "Removing legacy ErgoptiPlus rules from karabiner.json…")
	local function refuse(detail, backup_path)
		Logger.error(LOG, "Legacy-rule removal refused — %s. karabiner.json was left untouched.", detail)
		return false, detail, 0, backup_path
	end
	if type(karabiner_out) ~= "string" or karabiner_out == "" then
		return refuse("the karabiner.json path is not resolved")
	end
	if type(legacy_context) ~= "table" then
		return refuse("the legacy migration context is missing")
	end
	local FileSystem = require("adapters.file_system")
	local raw, status, read_detail = FileSystem.read_with_status(karabiner_out)
	if status == "absent" then
		Logger.success(LOG, "No karabiner.json at '%s' — no legacy ErgoptiPlus rule to remove.", karabiner_out)
		return true, "absent", 0
	end
	if status ~= "ok" or type(raw) ~= "string" then
		return refuse("karabiner.json could not be read: " .. tostring(read_detail or status))
	end

	-- A tree, like the merge's: classification must see the file the merge sees.
	local tree, decode_err = require("adapters.json_codec").decode(raw)
	if decode_err ~= nil or type(tree) ~= "table" then
		return refuse("karabiner.json is not valid JSON: " .. tostring(decode_err or "not an object"))
	end
	local conflicts, classify_err = require("platform.remap.generator")
		.find_legacy_signature_conflicts(tree, legacy_context)
	if not conflicts then
		return refuse("karabiner.json cannot be classified: " .. tostring(classify_err))
	end
	if #conflicts == 0 then
		Logger.success(LOG, "karabiner.json holds no legacy ErgoptiPlus rule — nothing to remove.")
		return true, "unchanged", 0
	end

	local expected = {}
	for _, conflict in ipairs(conflicts) do
		expected[conflict.profile_index] = expected[conflict.profile_index] or {}
		expected[conflict.profile_index][conflict.rule_index] = conflict.description
	end
	local stripped, removed_or_error = strip_selected_rules(raw, function(rule, profile_index, rule_index)
		local description = expected[profile_index] and expected[profile_index][rule_index]
		if description == nil then return false end
		-- The byte scan and the decoded tree must agree on which rule this is.
		if LeaseContract.parse_managed_description(rule.description)
			or tostring(rule.description) ~= description then
			error({ scan_error = string.format(
				"profile %d rule %d is not the classified legacy rule", profile_index, rule_index) }, 0)
		end
		return true
	end)
	if stripped == nil then return refuse(tostring(removed_or_error)) end
	if removed_or_error ~= #conflicts then
		return refuse(string.format("the byte scan found %d of the %d legacy rules",
			removed_or_error, #conflicts))
	end

	local backup_path, backup_err = write_legacy_backup(FileSystem, karabiner_out, raw)
	if not backup_path then return refuse(backup_err) end

	local write_ok, written, write_detail = pcall(FileSystem.write_if_unchanged, karabiner_out, stripped,
		{ status = "ok", content = raw })
	if not write_ok or written ~= true then
		return refuse("karabiner.json publication refused: "
			.. tostring(write_ok and (write_detail or "write failed") or written), backup_path)
	end
	Logger.success(LOG,
		"Removed %d legacy ErgoptiPlus rule(s) from karabiner.json; the original is kept at '%s'.",
		#conflicts, backup_path)
	return true, "removed", #conflicts, backup_path
end

return M
