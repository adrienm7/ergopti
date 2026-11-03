--- _shared/lua/test/legacy_folder_migration_contract.lua

--- ==============================================================================
--- MODULE: Legacy Folder Migration Contract
--- DESCRIPTION:
--- Replays the shared legacy folder migration vectors against the shared Lua
--- core over an in-memory file tree, so the macOS and Linux suites hold the same
--- move, refusal and paths.toml rules as the AutoHotkey port. No test touches a
--- real user folder: the tree exists only in this table.
--- ==============================================================================

local M = {}
local Migration = require("legacy_folder_migration")
local Json = require("json")

local function read(path)
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a"))
	assert(file:close())
	return content
end

--- Builds in-memory ports over a tree of paths (directories end with "/").
--- @param tree table Array of paths.
--- @return table ports
--- @return function snapshot Sorted array of every path left.
function M.memory_ports(tree)
	local entries = {}
	for _, path in ipairs(tree) do entries[path] = true end
	-- A directory exists by its own marker or by any entry below it.
	local function is_dir(path)
		if entries[path .. "/"] then return true end
		local prefix = path .. "/"
		for entry in pairs(entries) do
			if entry:sub(1, #prefix) == prefix then return true end
		end
		return false
	end
	local function exists(path) return entries[path] == true or is_dir(path) end
	local ports = {}
	ports.exists = exists
	function ports.list(dir)
		if not is_dir(dir) then return nil end
		local names, seen = {}, {}
		local prefix = dir .. "/"
		for path in pairs(entries) do
			if path ~= prefix and path:sub(1, #prefix) == prefix then
				local name = path:sub(#prefix + 1):match("^([^/]+)")
				if name and not seen[name] then seen[name] = true; names[#names + 1] = name end
			end
		end
		table.sort(names)
		return names
	end
	function ports.rename(from, to)
		if exists(to) then return nil, "exists" end
		local moved = {}
		for path in pairs(entries) do
			if path == from or path == from .. "/" or path:sub(1, #from + 1) == from .. "/" then
				moved[#moved + 1] = path
			end
		end
		for _, path in ipairs(moved) do
			entries[path] = nil
			entries[to .. path:sub(#from + 1)] = true
		end
		return true
	end
	function ports.make_dir(path)
		local current = ""
		for part in path:gmatch("[^/]+") do
			current = current .. "/" .. part
			if entries[current] then return false end
			if not is_dir(current) then entries[current .. "/"] = true end
		end
		return true
	end
	function ports.remove_empty_dir(path)
		local names = ports.list(path)
		if not names or #names > 0 then return false end
		entries[path .. "/"] = nil
		return true
	end
	local function snapshot()
		local paths = {}
		for path in pairs(entries) do paths[#paths + 1] = path end
		table.sort(paths)
		return paths
	end
	return ports, snapshot
end

--- Registers the vector replay.
--- @param helpers table Driver assertions and case registration.
--- @param shared_root string Path of static/ergopti_plus/_shared.
function M.run(helpers, shared_root)
	local corpus = Json.decode(read(shared_root .. "/tests/corpus/paths/legacy_folder_migration_vectors.json"))

	helpers.describe("Shared legacy folder migration", function()
		helpers.it("moves what is free, keeps what clashes (legacy-folder-migration-moves)", function()
			helpers.assert_eq(#corpus.moves, 7, "complete move vectors")
			for _, row in ipairs(corpus.moves) do
				local ports, snapshot = M.memory_ports(row.tree)
				local report = Migration.apply(row.plan, ports)
				helpers.assert_eq(table.concat(snapshot(), " "), table.concat(row.after, " "), row.name)
				helpers.assert_eq(#report.moved, row.moved, row.name .. " moved")
				local reasons = {}
				for _, kept in ipairs(report.kept) do reasons[#reasons + 1] = kept.reason end
				helpers.assert_eq(table.concat(reasons, ","), table.concat(row.kept_reasons, ","), row.name .. " kept")
			end
		end)

		helpers.it("rewrites only the old default folders of paths.toml (legacy-folder-migration-paths)", function()
			helpers.assert_eq(#corpus.paths_text, 4, "complete paths.toml vectors")
			for _, row in ipairs(corpus.paths_text) do
				local rewritten = Migration.rewrite_paths_text(row.text, row.rewrites)
				local expected = type(row.expected) == "string" and row.expected or nil
				helpers.assert_eq(rewritten, expected, row.name)
			end
		end)

		helpers.it("keeps the previous paths.toml text before rewriting it (legacy-folder-migration-backup)", function()
			local files = { ["/r/paths.toml"] = 'ConfigDirPath = "/h/old/"\n' }
			local ports = {
				exists = function(path) return files[path] ~= nil end,
				read = function(path) return files[path] end,
				write = function(path, text) files[path] = text; return true end,
			}
			local rewrites = { { key = "ConfigDirPath", old = { "/h/old" }, new = "/r/config" } }
			helpers.assert_eq(Migration.rewrite_paths_file("/r/paths.toml", rewrites, ".bak", ports), "rewritten")
			helpers.assert_eq(files["/r/paths.toml.bak"], 'ConfigDirPath = "/h/old/"\n', "backup holds the old text")
			helpers.assert_eq(files["/r/paths.toml"], 'ConfigDirPath = "/r/config/"\n', "file names the new folder")
			files["/r/paths.toml"] = 'ConfigDirPath = "/h/old/"\n'
			helpers.assert_eq(Migration.rewrite_paths_file("/r/paths.toml", rewrites, ".bak", ports), "backup_refused",
				"an existing backup is never replaced")
			helpers.assert_eq(files["/r/paths.toml"], 'ConfigDirPath = "/h/old/"\n', "nothing rewritten without a backup")
			helpers.assert_eq(Migration.rewrite_paths_file("/r/none.toml", rewrites, ".bak", ports), "absent")
		end)

		helpers.it("refuses a plan without its ports", function()
			helpers.assert_true(not pcall(Migration.apply, {}, { exists = function() return false end }),
				"a missing port stops the migration")
		end)
	end)
end

return M
