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
local NativePath = require("native_path")

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
	-- The in-memory tree has no links: two names are one entry only when equal.
	function ports.same_object(a, b) return a == b end
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
		helpers.it("moves what is free, backs up what clashes (legacy-folder-migration-moves)", function()
			helpers.assert_eq(#corpus.moves, 9, "complete move vectors")
			for _, row in ipairs(corpus.moves) do
				local ports, snapshot = M.memory_ports(row.tree)
				local report = Migration.apply(row.plan, ports)
				helpers.assert_eq(table.concat(snapshot(), " "), table.concat(row.after, " "), row.name)
				helpers.assert_eq(#report.moved, row.moved, row.name .. " moved")
				helpers.assert_eq(#report.backed_up, row.backed_up, row.name .. " backed up")
				helpers.assert_eq(#report.removed, row.removed, row.name .. " removed")
				local reasons = {}
				for _, kept in ipairs(report.kept) do reasons[#reasons + 1] = kept.reason end
				helpers.assert_eq(table.concat(reasons, ","), table.concat(row.kept_reasons, ","), row.name .. " kept")
			end
		end)

		helpers.it("rewrites only the old default folders of paths.toml (legacy-folder-migration-paths)", function()
			helpers.assert_eq(#corpus.paths_text, 4, "complete paths.toml vectors")
			-- A Windows row spells backslash separators, a filename byte on POSIX;
			-- the AutoHotkey replay holds it on Windows.
			local backslash_separates = NativePath.separators():find("\\", 1, true) ~= nil
			local replayed = 0
			for _, row in ipairs(corpus.paths_text) do
				if row.os ~= "windows" or backslash_separates then
					replayed = replayed + 1
					local rewritten = Migration.rewrite_paths_text(row.text, row.rewrites)
					local expected = type(row.expected) == "string" and row.expected or nil
					helpers.assert_eq(rewritten, expected, row.name)
				end
			end
			helpers.assert_true(replayed >= 3, "the POSIX paths.toml vectors replay")
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

		helpers.it("keeps a destination published after its check (legacy-folder-migration-race)", function()
			-- Another writer publishes the destination between the core's check and
			-- its rename: the no-replace rename refuses, and the old entry must go to
			-- the backup instead of being reported as kept beside a lost slot.
			local ports, snapshot = M.memory_ports({ "/h/old/storage.json", "/h/new/" })
			local rename = ports.rename
			local raced = false
			ports.rename = function(from, to)
				if to == "/h/new/storage.json" and not raced then
					raced = true
					assert(ports.make_dir("/h/new/storage.json/"))
				end
				return rename(from, to)
			end
			local report = Migration.apply({ { from_dir = "/h/old", to_dir = "/h/new", backup_dir = "/h/new/bak/old" } },
				ports)
			helpers.assert_true(raced, "the destination arrived after the check")
			helpers.assert_eq(#report.moved, 0, "nothing reported as moved over the new entry")
			helpers.assert_eq(#report.backed_up, 1, "the old entry went to its backup")
			helpers.assert_eq(#report.kept, 0, "nothing left behind")
			local after = table.concat(snapshot(), " ")
			helpers.assert_true(after:find("/h/new/bak/old/storage.json", 1, true) ~= nil, "the old entry is in the backup")
			helpers.assert_true(after:find("/h/new/storage.json/", 1, true) ~= nil, "the newer entry is untouched")
		end)

		helpers.it("reports a folder it cannot list or remove (legacy-folder-migration-list-refused)", function()
			local ports, snapshot = M.memory_ports({ "/h/old/storage.json", "/h/new/", "/h/gone/" })
			local list = ports.list
			ports.list = function(dir)
				if dir == "/h/old" then return nil, "Permission denied" end
				return list(dir)
			end
			ports.remove_empty_dir = function() return false end
			local report = Migration.apply({
				{ from_dir = "/h/old", to_dir = "/h/new", backup_dir = "/h/new/bak/old" },
				{ from_dir = "/h/gone", to_dir = "/h/new", backup_dir = "/h/new/bak/gone" },
			}, ports)
			helpers.assert_eq(#report.kept, 2, "both refusals are reported")
			helpers.assert_eq(report.kept[1].reason, "list_failed", "an unlistable folder is not an empty one")
			helpers.assert_eq(report.kept[1].detail, "Permission denied", "the refusal says why")
			helpers.assert_eq(report.kept[2].reason, "remove_failed", "an emptied folder left behind is reported")
			helpers.assert_true(table.concat(snapshot(), " "):find("/h/old/storage.json", 1, true) ~= nil,
				"the unlisted entry stays where it is")
			local lines = {}
			Migration.log_report({ info = function() end,
				warn = function(_, fmt, ...) lines[#lines + 1] = fmt:format(...) end }, "test", report)
			helpers.assert_true(lines[1]:find("could not be listed", 1, true) ~= nil, lines[1])
		end)

		helpers.it("leaves an old folder that is the new one under another name (legacy-folder-migration-alias)", function()
			local ports, snapshot = M.memory_ports({ "/h/new/config.toml", "/h/other/x" })
			-- /h/old is a link to /h/new, and /h/other/x a link to /h/new/x.
			local aliases = { ["/h/old"] = "/h/new", ["/h/other/x"] = "/h/new/x" }
			local exists = ports.exists
			ports.exists = function(path) return aliases[path] ~= nil or exists(path) end
			ports.same_object = function(a, b) return (aliases[a] or a) == (aliases[b] or b) end
			ports.make_dir("/h/new/x/")
			local report = Migration.apply({
				{ from_dir = "/h/old", to_dir = "/h/new", backup_dir = "/h/new/bak/old" },
				{ from = "/h/other/x", to = "/h/new/x", backup = "/h/new/bak/x" },
			}, ports)
			helpers.assert_true(table.concat(snapshot(), " "):find("/h/new/config.toml", 1, true) ~= nil,
				"the live entry stays where it is")
			helpers.assert_eq(#report.backed_up + #report.moved + #report.kept, 0, "nothing is archived or moved")
			helpers.assert_eq(#report.aliased, 2, "both aliases are recognised")
		end)

		helpers.it("refuses a plan without its ports or its backup", function()
			helpers.assert_true(not pcall(Migration.apply, {}, { exists = function() return false end }),
				"a missing port stops the migration")
			local ports = M.memory_ports({})
			helpers.assert_true(not pcall(Migration.apply, { { from = "/h/old", to = "/h/new" } }, ports),
				"a move without its backup path stops the migration")
			helpers.assert_true(not pcall(Migration.apply, { { from_dir = "/h/old", to_dir = "/h/new" } }, ports),
				"a merge without its backup folder stops the migration")
		end)

		helpers.it("logs every outcome once (legacy-folder-migration-log)", function()
			local lines = {}
			local logger = {
				info = function(_, fmt, ...) lines[#lines + 1] = "INFO " .. fmt:format(...) end,
				warn = function(_, fmt, ...) lines[#lines + 1] = "WARN " .. fmt:format(...) end,
			}
			Migration.log_report(logger, "test", {
				moved = { { from = "/a", to = "/b" } },
				backed_up = { { from = "/c", to = "/bak/c", taken = "/d" } },
				kept = { { from = "/e", to = "/bak/e", reason = "backup_exists" } },
				removed = { "/old" },
				aliased = {},
				paths_file = "rewritten",
			})
			helpers.assert_eq(#lines, 5, "one line per outcome")
			helpers.assert_true(lines[2]:find("WARN", 1, true) == 1 and lines[2]:find("/bak/c", 1, true) ~= nil,
				"a backed-up entry is a warning naming its backup")
			helpers.assert_true(lines[3]:find("a backup already exists", 1, true) ~= nil, "a kept entry says why")
		end)
	end)
end

return M
