--- _shared/lua/toml_codec/leaf_rows.lua

--- ==============================================================================
--- MODULE: TOML Leaf Rows (shared)
--- DESCRIPTION:
--- Turns set/delete operations on decoded key paths into rows the batch writer
--- can apply to an existing file without losing a neighbour or producing a key
--- TOML cannot parse.
---
--- WHY THE BATCH WRITER ALONE IS NOT ENOUGH:
--- The writer addresses a `key = value` line under a table header and writes
--- the key bare. Two shapes defeat that. A leaf inside an inline table
--- (`groups = { rolls = true }`) has no line of its own, and a runtime identity
--- such as an extension pack's `ext:demo:rolls` is not a bare key. The first is
--- rewritten as one replacement of the whole inline value, cloned from the
--- decoded file so unknown entries survive; the second is created inside a new
--- inline table, whose keys the encoder quotes. A non-bare key under an
--- existing table header cannot be addressed by line and is refused rather than
--- written in a form a later read would misparse.
--- ==============================================================================

local M = {}
local Codec = require("toml_codec.codec")
local KeyPath = require("toml_codec.key_path")
local RecordScanner = require("toml_codec.record_scanner")

--- Whether a segment can be written as a bare TOML key.
--- @param segment string
--- @return boolean
local function is_bare(segment)
	return segment:match("^[A-Za-z0-9_%-]+$") ~= nil
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = clone(child) end
	return copy
end

--- A collision-free identity for a key path.
--- @param segments table
--- @param count number|nil Leading segments to include.
--- @return string
local function identity(segments, count)
	local parts = {}
	for index = 1, count or #segments do parts[index] = segments[index] end
	return table.concat(parts, "\0")
end

local function prefix(segments, count)
	local out = {}
	for index = 1, count do out[index] = segments[index] end
	return out
end

local function lookup(document, segments, count)
	local value = document
	for index = 1, count or #segments do
		if type(value) ~= "table" then return nil end
		value = value[segments[index]]
	end
	return value
end

--- Applies one leaf change inside a detached table, pruning emptied parents.
--- @param root table Detached candidate.
--- @param rest table Remaining segments below the candidate.
--- @param operation table Set or delete operation.
local function apply_inside(root, rest, operation)
	local target, ancestry = root, {}
	for index = 1, #rest - 1 do
		local child = target[rest[index]]
		assert(child == nil or type(child) == "table", "TOML leaf path crosses a scalar: " .. rest[index])
		if child == nil then
			if operation.delete then return end
			child = {}
			target[rest[index]] = child
		end
		ancestry[#ancestry + 1] = { parent = target, key = rest[index] }
		target = child
	end
	if operation.delete then target[rest[#rest]] = nil else target[rest[#rest]] = clone(operation.value) end
	for index = #ancestry, 1, -1 do
		local node = ancestry[index]
		if next(node.parent[node.key]) ~= nil then break end
		node.parent[node.key] = nil
	end
end

--- Plans writer rows for leaf operations against exact source bytes.
--- @param content string Exact source bytes, "" for an absent file.
--- @param operations table Dense array of `{ path = segments, value = any }`
---   or `{ path = segments, delete = true }`; paths have a table and a key.
--- @return table rows Batch writer rows.
function M.prepare(content, operations)
	assert(type(content) == "string", "leaf rows need the exact source bytes")
	assert(type(operations) == "table", "leaf rows need an operation array")
	local scanned, detail = RecordScanner.scan_records(content, { quoted_headers = true })
	assert(scanned, "TOML source cannot be scanned: " .. tostring(detail))
	local decoded = Codec.decode(content)
	assert(type(decoded) == "table", "TOML source is malformed")
	local inline = {}
	for _, record in ipairs(scanned.records) do
		if record.addressable and type(lookup(decoded, record.path)) == "table" then
			inline[identity(record.path)] = true
		end
	end
	for index, operation in ipairs(operations) do
		local path = type(operation) == "table" and operation.path or nil
		assert(type(path) == "table" and #path >= 2, "leaf operation needs a table and a key at " .. index)
		for _, segment in ipairs(path) do
			assert(type(segment) == "string" and segment ~= "", "leaf path segments must be non-empty strings")
		end
		assert((operation.delete == true) ~= (operation.value ~= nil), "leaf operation sets or deletes at " .. index)
	end

	-- A new inline container is chosen once per absent ancestor, so a bare
	-- sibling cannot create a table header that duplicates it.
	local created = {}
	for _, operation in ipairs(operations) do
		local path = operation.path
		if not operation.delete and not is_bare(path[#path]) then
			local anchor = nil
			for depth = 2, #path - 1 do
				if lookup(decoded, path, depth) == nil then anchor = depth; break end
			end
			assert(anchor and is_bare(path[anchor]), "TOML key cannot be written under a table header: "
				.. KeyPath.render(path))
			created[identity(path, anchor)] = anchor
		end
	end

	local candidates, order, rows = {}, {}, {}
	local function fold(anchor_path, operation)
		local key = identity(anchor_path)
		if not candidates[key] then
			local existing = lookup(decoded, anchor_path)
			candidates[key] = { path = anchor_path, value = clone(existing) or {} }
			order[#order + 1] = key
		end
		local rest = {}
		for index = #anchor_path + 1, #operation.path do rest[#rest + 1] = operation.path[index] end
		apply_inside(candidates[key].value, rest, operation)
	end
	--- Plans one operation as a folded inline change or a writer row.
	--- @param operation table Validated leaf operation.
	local function plan(operation)
		local path, anchor = operation.path, nil
		-- A leaf the source does not hold has nothing to remove, including one
		-- whose parent is a scalar another reader keeps at that name. No row is
		-- planned, so the file keeps those bytes exactly as they are.
		if operation.delete and lookup(decoded, path) == nil then return end
		for depth = 1, #path - 1 do
			if inline[identity(path, depth)] or created[identity(path, depth)] then anchor = depth; break end
		end
		if anchor then
			fold(prefix(path, anchor), operation)
		elseif is_bare(path[#path]) then
			rows[#rows + 1] = { section = KeyPath.render(prefix(path, #path - 1)), key = path[#path],
				value = clone(operation.value), delete = operation.delete }
		else
			-- Only a deletion of a present quoted key reaches here, and under a
			-- table header it cannot be addressed by line without misparsing it.
			error("TOML key cannot be removed under a table header: " .. KeyPath.render(path))
		end
	end
	for _, operation in ipairs(operations) do plan(operation) end
	for _, key in ipairs(order) do
		local candidate = candidates[key]
		local parent, name = prefix(candidate.path, #candidate.path - 1), candidate.path[#candidate.path]
		if next(candidate.value) == nil then
			if lookup(decoded, candidate.path) ~= nil then
				rows[#rows + 1] = { section = KeyPath.render(parent), key = name, delete = true }
			end
		else
			rows[#rows + 1] = { section = KeyPath.render(parent), key = name, value = candidate.value }
		end
	end
	return rows
end

return M
