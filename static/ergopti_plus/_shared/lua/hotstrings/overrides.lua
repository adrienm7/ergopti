--- _shared/lua/hotstrings/overrides.lua

--- ==============================================================================
--- MODULE: Hotstring Override Parser (Shared)
--- DESCRIPTION:
--- Reads the bytes of the user's override file (hotstrings_overrides.toml) into
--- the tree every driver's delay, colour, preview and priority cascade consumes:
--- { [category] = { delay_offset, delay_unlimited, legacy_delay, color,
--- show_tooltip, priority, sections = { [section] = { ... } } } }.
---
--- FEATURES & RATIONALE:
--- 1. One reader: macOS hand-rolled a line scanner of about 190 lines while Linux
---    decoded the document in about 25, and the two disagreed on extension
---    tables and on which values count as valid. Both now decode with the
---    canonical TOML codec and read the tree through this module.
--- 2. Reserved table: `[__global__]` is not an override category. Its keys are
---    owned by the base configuration and a writer retains them byte-for-byte,
---    so a parser that listed it would have the writer refuse its own file (the
---    rule Windows follows in _ParseOverrides).
--- 3. Typed leaves: a value of the wrong type is dropped, never coerced, so a
---    quoted number cannot become a delay on one driver and be ignored on
---    another.
--- 4. Key policy: the one thing that differs per driver is how a table name
---    becomes a category or section key (macOS lowercases bare identifiers and
---    reads `[ext.<id>]` as the category `ext.<id>`; Linux keeps keys as
---    written, its extension categories being `ext:<pack>:<name>`). The policy
---    is an explicit argument, never a default.
--- 5. Strict document: invalid TOML raises, and the caller decides how a whole
---    unreadable file is reported.
--- ==============================================================================

local M = {}

local TomlCodec = require("toml_codec")

--- The reserved table no category may be named after.
M.RESERVED_TABLE = "__global__"

--- The table prefix of extension categories.
local EXTENSION_PREFIX = "ext"

--- Whether a value is one bare TOML key segment.
--- @param value any
--- @return boolean
local function is_bare_segment(value)
	return type(value) == "string" and value ~= "" and value:match("^[%w_%-]+$") ~= nil
end

--- Canonicalizes a bare category or an ext.<id> category to its shared key.
--- @param value any Candidate category.
--- @return string|nil canonical Lowercase key, nil when invalid.
function M.normalize_category(value)
	if type(value) ~= "string" then return nil end
	local extension_id = value:match("^[eE][xX][tT]%.([%w_%-]+)$")
	if is_bare_segment(extension_id) then return "ext." .. extension_id:lower() end
	if is_bare_segment(value) then return value:lower() end
	return nil
end

--- Canonicalizes one section identifier to the shared lowercase key contract.
--- @param value any Candidate section.
--- @return string|nil canonical Lowercase key, nil when absent or invalid.
function M.normalize_section(value)
	if not is_bare_segment(value) then return nil end
	return value:lower()
end

--- Whether a value is a finite, non-negative activation delay in seconds. Zero
--- is intentional: the hotstring stays always active.
--- @param value any
--- @return boolean
function M.is_delay(value)
	return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

--- Whether a value is the stored offset of a delay override: the signed seconds
--- it adds to the base expansion delay.
--- @param value any
--- @return boolean
function M.is_delay_offset(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

--- Reads the owned leaves of one override table.
--- @param values table Decoded table of a category or a section.
--- @return table entry Owned fields only.
local function override_fields(values)
	local entry = {}
	if M.is_delay_offset(values.delay_offset) then entry.delay_offset = values.delay_offset end
	if values.delay_unlimited == true then entry.delay_unlimited = true end
	-- The absolute delay of earlier builds, held only until the boot migration turns it into an offset.
	if M.is_delay(values.delay) then entry.legacy_delay = values.delay end
	if type(values.color) == "string" then entry.color = values.color end
	if type(values.show_tooltip) == "boolean" then entry.show_tooltip = values.show_tooltip end
	local priority = values.priority
	if type(priority) == "number" and priority >= 0 and priority == math.floor(priority) and priority < math.huge then
		entry.priority = priority
	end
	return entry
end

--- Adds one category table, with its one-level section tables, to the tree.
--- @param tree table Tree under construction.
--- @param key string Canonical category.
--- @param values table Decoded category table.
--- @param policy table Key policy.
local function add_category(tree, key, values, policy)
	local entry = tree[key] or { sections = {} }
	for field, value in pairs(override_fields(values)) do entry[field] = value end
	for name, section_values in pairs(values) do
		local section = type(section_values) == "table" and policy.section(name) or nil
		if section then
			local section_entry = entry.sections[section] or {}
			for field, value in pairs(override_fields(section_values)) do section_entry[field] = value end
			entry.sections[section] = section_entry
		end
	end
	tree[key] = entry
end

--- How a driver names the categories and sections of its override file.
--- `category(name)` and `section(name)` answer the key to store or nil to skip a
--- table; `extension_tables` says whether a top-level `ext` table holds one
--- category per child (`[ext.<id>]`, `[ext.<id>.<section>]`).
M.POLICIES = {
	--- macOS: bare lowercase identifiers, extensions under the `ext.` namespace.
	lowercase_bare = {
		category = function(name) return M.normalize_category(name) end,
		section = function(name) return M.normalize_section(name) end,
		extension_tables = true,
	},
	--- Linux: any key, as written, since an extension category is spelled
	--- `"ext:<pack>:<name>"` and a section may be a quoted dotted key.
	verbatim = {
		category = function(name) return name end,
		section = function(name) return name end,
		extension_tables = false,
	},
}

--- Interprets override file bytes, raising when they are not valid TOML.
--- @param content string Exact file bytes.
--- @param policy table One of M.POLICIES.
--- @return table overrides The override tree.
function M.parse(content, policy)
	assert(type(policy) == "table" and type(policy.category) == "function" and type(policy.section) == "function",
		"the override parser needs a key policy")
	local document = TomlCodec.decode(content)
	assert(type(document) == "table", "the override file is not valid TOML")
	local tree = {}
	for name, values in pairs(document) do
		if type(values) == "table" and name ~= M.RESERVED_TABLE then
			if policy.extension_tables and name:lower() == EXTENSION_PREFIX then
				for extension_id, extension_values in pairs(values) do
					local key = type(extension_values) == "table"
						and policy.category(EXTENSION_PREFIX .. "." .. tostring(extension_id)) or nil
					if key then add_category(tree, key, extension_values, policy) end
				end
			else
				local key = policy.category(name)
				if key then add_category(tree, key, values, policy) end
			end
		end
	end
	return tree
end

return M
