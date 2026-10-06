--- _shared/lua/config_obsolete_parents.lua

--- Retains obsolete assignment containers until the explicit cleanup owns them.
local M = {}
local Codec = require("toml_codec")
local KeyPath = require("toml_codec.key_path")
local LeafRows = require("toml_codec.leaf_rows")

M.SHORTCUT_CONTAINERS = { "keyboard", "tap_keys" }

local function array_length(value, description)
	assert(type(value) == "table", description .. " must be a dense array")
	local count = 0
	for key in next, value do
		assert(type(key) == "number" and key >= 1 and key % 1 == 0,
			description .. " must be a dense array")
		count = count + 1
	end
	for index = 1, count do assert(rawget(value, index) ~= nil, description .. " must be a dense array") end
	return count
end

local function under(path, prefix)
	if #path < #prefix then return false end
	for index, segment in ipairs(prefix) do if path[index] ~= segment then return false end end
	return true
end

--- Builds the existing shortcut owners' semantic assignment-container paths.
--- @param containers table|nil Existing native container names, or both owners.
--- @return table namespaces Dense array of semantic paths.
function M.shortcut_namespaces(containers)
	containers = containers or M.SHORTCUT_CONTAINERS
	local paths = {}
	for index = 1, array_length(containers, "shortcut containers") do
		local key = containers[index]
		local known = false
		for _, name in ipairs(M.SHORTCUT_CONTAINERS) do if key == name then known = true end end
		assert(known, "shortcut container has no native assignment owner")
		paths[#paths + 1] = { "shortcuts", key }
	end
	return paths
end

--- Filters only neutral descendant deletions beneath proved obsolete parents.
--- Nondelete, whole-parent and ancestor operations refuse before publication;
--- retained row objects keep the actual writer's provenance and intent fields.
--- @param content string Exact classified source bytes, or empty when absent.
--- @param updates table Existing dense writer operations.
--- @param namespaces table Dense array of native-owned semantic parent paths.
--- @return table rows Original operations that can address the retained source.
function M.preserve(content, updates, namespaces)
	assert(type(content) == "string", "obsolete parent admission requires exact source bytes")
	local count = array_length(updates, "obsolete parent operations")
	local document, shapes = Codec.decode_with_shapes(content)
	assert(type(document) == "table" and type(shapes) == "table", "obsolete parent source is malformed")
	local obsolete = {}
	for index = 1, array_length(namespaces, "obsolete parent namespaces") do
		local path = namespaces[index]
		local length = array_length(path, "obsolete parent path")
		assert(length >= 2, "obsolete parent path needs a table and a key")
		for depth = 1, length do
			assert(type(path[depth]) == "string" and path[depth] ~= "", "obsolete parent path segments must be strings")
		end
		local value, prefix = document, {}
		for _, segment in ipairs(path) do
			value = value[segment]
			prefix[#prefix + 1] = segment
			if value == nil then break end
			if type(value) ~= "table" or shapes.arrays[value] == true then
				obsolete[#obsolete + 1] = prefix
				break
			end
		end
	end
	local rows, logical = {}, {}
	for index = 1, count do
		local row = updates[index]
		assert(type(row) == "table" and type(row.section) == "string" and row.section ~= ""
			and type(row.key) == "string" and row.key ~= "", "obsolete parent operation needs a section and key")
		assert(row.delete == nil or row.delete == true, "obsolete parent deletion must be Boolean true")
		assert(row.literal_key == nil or type(row.literal_key) == "boolean", "obsolete parent literal key must be Boolean")
		assert(row.delete ~= true or row.value == nil, "obsolete parent deletion cannot also set a value")
		assert(row.delete == true or row.value ~= nil, "obsolete parent operation must set or delete")
		LeafRows.publication_literal(row, content)
		local path = assert(KeyPath.parse(row.section, true), "obsolete parent operation section is malformed")
		-- Filtering must not erase a collision the existing writer rejects.
		-- Its logical row identities fold canonical sections and keys.
		local section, key = KeyPath.render(path):lower(), row.key:lower()
		logical[section] = logical[section] or {}
		assert(not logical[section][key], "obsolete parent operation logical key is duplicated")
		logical[section][key] = true
		path[#path + 1] = row.key
		local retained = false
		for _, parent in ipairs(obsolete) do
			if under(path, parent) or under(parent, path) then
				assert(#path > #parent and under(path, parent) and row.delete == true,
					"Configuration update collides with retained obsolete parent '" .. KeyPath.render(parent) .. "'")
				assert(row.intent == nil, "obsolete parent neutral deletion cannot carry nondelete assignment intent")
				retained = true
			end
		end
		if not retained then rows[#rows + 1] = row end
	end
	return rows
end

return M
