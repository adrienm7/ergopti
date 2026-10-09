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
--- inline table, whose keys the encoder quotes, when an ancestor is absent. Under
--- an existing table header it is an ordinary row: the writer quotes it and
--- addresses its quoted line, so a bare sibling written first never locks it out.
--- ==============================================================================

local M = {}
local Codec = require("toml_codec.codec")
local KeyPath = require("toml_codec.key_path")
local RecordScanner = require("toml_codec.record_scanner")
local provenance = setmetatable({}, { __mode = "k" })
local publications = setmetatable({}, { __mode = "k" })

--- Whether a segment can be written as a bare TOML key.
--- @param segment string
--- @return boolean
local function is_bare(segment)
	return segment:match("^[A-Za-z0-9_%-]+$") ~= nil
end

local function clone(value, seen)
	if type(value) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local copy = {}
	seen[value] = copy
	for key, child in pairs(value) do copy[clone(key, seen)] = clone(child, seen) end
	provenance[copy] = provenance[value]
	return copy
end

--- Decodes one exact source, retaining value-kind evidence under this owner.
--- Ordinary model tables cannot create array receipts by resembling empty arrays.
function M.decode_source(content)
	local document, shapes = Codec.decode_with_shapes(content)
	if not document then return nil, nil end
	local function retain(value, path)
		if type(value) ~= "table" then return end
		provenance[value] = { source = content, path = path, array = shapes.arrays[value] == true,
			numbers = clone(shapes.numbers[value]), strings = clone(shapes.strings[value]) }
		for key, child in pairs(value) do
			local child_path = {}
			for index, segment in ipairs(path) do child_path[index] = segment end
			child_path[#child_path + 1] = key
			retain(child, child_path)
		end
	end
	retain(document, {})
	return document, shapes
end

--- Returns detached descriptive provenance; it grants no publication authority.
function M.source_origin(value)
	local origin = provenance[value]
	if not origin then return nil end
	return { source = origin.source, path = clone(origin.path), array = origin.array }
end

local function shape_receipt(value)
	local shapes = { arrays = {}, numbers = {}, strings = {} }
	local visiting = {}
	local function retain(node)
		if type(node) ~= "table" then return end
		assert(not visiting[node], "TOML source-shape value contains a cycle")
		visiting[node] = true
		local origin = provenance[node]
		if origin then
			if origin.array then shapes.arrays[node] = true end
			shapes.numbers[node], shapes.strings[node] = origin.numbers, origin.strings
		end
		for _, child in pairs(node) do retain(child) end
		visiting[node] = nil
	end
	retain(value)
	return shapes
end

--- Serializes a model using only kind evidence retained from actual decodes.
function M.value_literal(value)
	return Codec.encode_value_with_shapes(value, shape_receipt(value))
end

--- Validates this owner's exact row, source and still-unchanged desired value.
--- Copying the exposed opaque token never authenticates a replacement row.
function M.publication_literal(row, content)
	local publication = publications[row]
	if not publication and row.source_shape == nil then return nil end
	assert(publication and row.source_shape == publication.token, "unowned TOML source-shape capability")
	assert(content == publication.source, "TOML source-shape capability belongs to another source")
	assert(row.section == publication.section and row.key == publication.key and row.delete == publication.delete
		and rawequal(row.value, publication.value), "TOML source-shape row ownership changed")
	local literal = not row.delete and M.value_literal(row.value) or nil
	assert(literal == publication.literal, "TOML source-shape desired value changed after preparation")
	return literal
end

--- Exposes an opaque receipt only for causal ownership controls and forwarding.
--- A consumer must retain the actual prepared row as well as this token.
function M.publication_capability(row)
	local publication = publications[row]
	return publication and publication.token or nil
end

--- Detaches supported decoded TOML values, including nested arrays and maps.
--- The codec represents these values as plain tables without metatables.
--- @param value any
--- @return any
function M.clone_value(value)
	return clone(value)
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
	local decoded = M.decode_source(content)
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
			local anchor, folded = nil, false
			for depth = 1, #path - 1 do
				if inline[identity(path, depth)] then folded = true; break end
			end
			for depth = 2, #path - 1 do
				if folded then break end
				if lookup(decoded, path, depth) == nil then anchor = depth; break end
			end
			if anchor then created[identity(path, anchor)] = anchor end
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
		else
			rows[#rows + 1] = { section = KeyPath.render(prefix(path, #path - 1)), key = path[#path],
				value = clone(operation.value), delete = operation.delete }
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
	for _, row in ipairs(rows) do
		local token = {}
		row.source_shape = token
		publications[row] = { token = token, source = content, section = row.section, key = row.key,
			delete = row.delete, value = row.value, literal = not row.delete and M.value_literal(row.value) or nil }
	end
	return rows
end

return M
