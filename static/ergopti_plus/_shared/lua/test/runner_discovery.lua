--- _shared/lua/test/runner_discovery.lua

--- ==============================================================================
--- MODULE: Native Lua Test Discovery
--- DESCRIPTION:
--- Uses the runners' required native provider for one complete inventory. Paths
--- stay native data, including POSIX backslashes and embedded newlines; neither
--- shell records nor an optional filesystem provider can change coverage.
--- ==============================================================================

local M = {}
local Native = require("luv")

--- Collects native files while refusing every incomplete enumeration.
--- @param root string Absolute native directory.
--- @param accept function Whether one basename belongs to the census.
--- @param skipped table Directory/link basenames excluded before target reads.
--- @return table|nil files Sorted complete native paths.
--- @return string|nil detail Original native failure.
function M.files(root, accept, skipped)
	local files = {}
	local function walk(path)
		local scan, scan_error = Native.fs_scandir(path)
		assert(scan, scan_error or "native test discovery refused")
		while true do
			local name, kind = Native.fs_scandir_next(scan)
			if name == nil then
				assert(kind == nil, kind)
				break
			end
			assert(type(name) == "string" and name ~= "", "native discovery returned an invalid name")
			local full = path .. "/" .. name
			local excluded = skipped[name]
			if excluded and kind == "unknown" then
				-- DT_UNKNOWN can name a regular file; classify without following a target.
				local attributes, attribute_error = Native.fs_lstat(full)
				assert(attributes, attribute_error or "native discovery lstat refused")
				kind = attributes.type
				assert(type(kind) == "string" and kind ~= "unknown", "native discovery lstat returned an invalid type")
			end
			-- Named directory/link exclusions must precede target metadata acquisition.
			if not (excluded and (kind == "directory" or kind == "link")) then
				if kind == "link" or kind == "unknown" then
					local attributes, attribute_error = Native.fs_stat(full)
					assert(attributes, attribute_error or "native discovery stat refused")
					kind = attributes.type
				end
				assert(type(kind) == "string", "native discovery returned an invalid type")
				if kind == "directory" then
					if not skipped[name] then walk(full) end
				elseif kind == "file" and accept(name) then
					files[#files + 1] = full
				end
			end
		end
	end
	local ok, detail = pcall(walk, root)
	if not ok then return nil, tostring(detail) end
	table.sort(files)
	return files
end

--- Collects dotted test-module names from the complete native census.
--- @param root string Absolute native driver root.
--- @param directory string Relative test directory.
--- @return table|nil modules Complete module inventory.
--- @return string|nil detail Original native failure.
function M.collect(root, directory)
	local files, detail = M.files(root .. "/" .. directory, function(name)
		return name:match("^test_.+%.lua$") ~= nil
	end, {})
	if not files then return nil, detail end
	local modules = {}
	for _, path in ipairs(files) do
		modules[#modules + 1] = path:sub(#root + 2):gsub("%.lua$", ""):gsub("/", ".")
	end
	return modules
end

return M
