--- _shared/lua/toml_codec/cleanup_roots.lua
--- Explicit whole-root cleanup; ordinary batch and leaf addressing stay unchanged.
local Codec = require("toml_codec")
local Scanner = require("toml_codec.record_scanner")
local KeyPath = require("toml_codec.key_path")
local M = {}
local math_type = math.type
local BOM = string.char(0xEF, 0xBB, 0xBF)

--- Acquires physical semantic root identities from the existing strict owners.
--- Ambiguous root assignments refuse instead of borrowing a textual prefix.
function M.scan(source)
	local ok, document, shapes = pcall(Codec.decode_with_shapes, source)
	if not ok or type(document) ~= "table" then return nil, "the source is not valid TOML" end
	local scan, detail = Scanner.scan_records(source, { quoted_headers = true })
	if not scan then return nil, detail end
	local record_roots, header_roots, projections, order = {}, {}, {}, {}
	local function project(root)
		if not projections[root] then projections[root] = true; order[#order + 1] = root end
	end
	for _, header in ipairs(scan.headers) do
		if not header.segments or #header.segments == 0 then return nil, "the source has an unproven table identity" end
		header_roots[header] = header.segments[1]
		if header.array then project(header.segments[1]) end
	end
	for _, record in ipairs(scan.records) do
		local root
		if record.header then root = header_roots[record.header]
		else
			local parts = record.key_text and KeyPath.parse(record.key_text)
			if not parts or #parts == 0 then return nil, "the source has an unproven root assignment" end
			root = parts[1]
			project(root)
		end
		record_roots[record] = root
	end
	return { document = document, shapes = shapes, scan = scan,
		record_roots = record_roots, header_roots = header_roots, projections = projections, order = order }
end

local function same(a, b, left, right)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then
		if type(a) == "number" and math_type and math_type(a) ~= math_type(b) then return false end
		return a == b or (type(a) == "number" and a ~= a and b ~= b)
	end
	if (left.arrays[a] == true) ~= (right.arrays[b] == true) then return false end
	for key, value in pairs(a) do if not same(value, b[key], left, right) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end

--- Removes only complete exact semantic roots and proves every other typed value.
--- No serializer regenerates surviving records, comments, numeric or temporal tokens.
function M.render(source, roots)
	local receipt, detail = M.scan(source)
	if not receipt then return nil, detail end
	local selected, count = {}, 0
	for _, root in ipairs(roots) do
		if type(root) ~= "string" or root == "" or selected[root] or receipt.document[root] == nil then
			return nil, "the complete root selection is invalid"
		end
		selected[root] = true; count = count + 1
	end
	local dropped = {}
	for header, root in pairs(receipt.header_roots) do if selected[root] then dropped[header.index] = true end end
	for record, root in pairs(receipt.record_roots) do
		if selected[root] then for index = record.first, record.last do dropped[index] = true end end
	end
	local lines = {}
	for index, line in ipairs(receipt.scan.lines) do if not dropped[index] then lines[#lines + 1] = line.text .. line.eol end end
	local candidate = table.concat(lines)
	if source:sub(1, #BOM) == BOM and candidate:sub(1, #BOM) ~= BOM then candidate = BOM .. candidate end
	local ok, after, shapes = pcall(Codec.decode_with_shapes, candidate)
	if not ok or type(after) ~= "table" then return nil, "the cleanup candidate is not valid TOML" end
	for root, value in pairs(receipt.document) do
		if selected[root] then
			if after[root] ~= nil then return nil, "the cleanup candidate retains a selected root" end
		elseif not same(value, after[root], receipt.shapes, shapes) then
			return nil, "the cleanup candidate changes an unselected typed root"
		end
	end
	for root in pairs(after) do if receipt.document[root] == nil then return nil, "the cleanup candidate invents a root" end end
	return candidate, count
end
return M
