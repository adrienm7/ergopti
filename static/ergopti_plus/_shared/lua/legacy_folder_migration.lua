--- _shared/lua/legacy_folder_migration.lua

--- ==============================================================================
--- MODULE: Legacy Folder Migration Core
--- DESCRIPTION:
--- The one-time move of the folders of the builds before the single folder name
--- (`Ergopti` on macOS and Windows, `ergopti` under XDG on Linux) into the new
--- root, shared by the macOS and Linux drivers. A driver builds the plan from the
--- generated app_dirs table and owns every native effect through the ports; this
--- module owns what is moved, what is refused and what the report says.
---
--- FEATURES & RATIONALE:
--- 1. Never Overwrite: an entry moves when nothing but an empty folder exists
---    at its destination. Otherwise the destination stays as it is and the old
---    entry is renamed into the backup folder of the new root, so a folder
---    written by a newer build is never replaced by an older one, every old
---    folder empties and is removed, and the migration has nothing left to do
---    at the next boot. Only a taken backup slot or a failed rename keeps an old
---    entry where it is, with a warning naming both paths.
--- 2. Rename, Not Copy: a move is one rename inside the same home folder. It
---    loses nothing on failure and costs nothing for the multi-gigabyte managed
---    runtimes, so the folders themselves need no copy. The rename port never
---    replaces what exists at its destination, so a newer file published there
---    after the check is kept and the old entry goes to the backup instead.
--- 3. Backup Before Rewrite: paths.toml is the one file whose TEXT changes (a
---    ConfigDirPath or LogsDirPath that named an old default folder). Its
---    previous text is written beside it under the backup suffix first, and an
---    existing backup is never replaced.
--- 4. Minimal by Decision: no build was ever published to users with the old
---    folders (project memory, 2026-09-23), so only the maintainer's machines
---    have them. The migration covers the folders those machines hold and is
---    meant to be deleted once they are moved; it is not a compatibility layer.
--- 5. Deferred Logging: the drivers run it before their logger opens its folder
---    (the logs folder is one of the moved entries), so the result is a report
---    the driver logs once its logger is ready.
---
--- WINDOWS: infra/legacy_folder_migration.ahk applies the same rules, replayed
--- from the same vectors (_shared/tests/corpus/paths/legacy_folder_migration_vectors.json).
--- ==============================================================================

local M = {}

local NativePath = require("native_path")



-- ================================
-- ================================
-- ======= 1/ Entry moves =========
-- ================================
-- ================================

--- Joins a directory and one entry name.
--- @param dir string Absolute directory, with or without a trailing slash.
--- @param name string Entry name.
--- @return string path
local function join(dir, name)
	return (dir:gsub("/+$", "")) .. "/" .. name
end

--- Checks that every port the plan needs is a function.
--- @param ports table Native effects.
local function require_ports(ports)
	assert(type(ports) == "table", "legacy folder migration needs its ports")
	for _, name in ipairs({ "exists", "list", "rename", "make_dir", "remove_empty_dir" }) do
		assert(type(ports[name]) == "function", "legacy folder migration port missing: " .. name)
	end
end

--- Renames one entry after creating the parent of its destination.
--- @param from string Old path.
--- @param to string New path, known to be free.
--- @param ports table Native effects.
--- @return boolean moved
--- @return string|nil reason Why it was not moved.
--- @return string|nil detail The rename error.
local function rename_into(from, to, ports)
	local parent = NativePath.dirname(to)
	if parent and parent ~= "" and not ports.make_dir(parent) then return false, "parent_unavailable" end
	local moved, why = ports.rename(from, to)
	if not moved then return false, "rename_failed", why end
	return true
end

--- Moves one old entry into its backup slot, the destination being taken.
--- @param from string Old path.
--- @param to string The taken destination.
--- @param backup string Path the old entry takes.
--- @param ports table Native effects.
--- @param report table Report being filled.
local function back_up_entry(from, to, backup, ports, report)
	if ports.exists(backup) then
		report.kept[#report.kept + 1] = { from = from, to = backup, reason = "backup_exists" }
		return
	end
	local saved, reason, detail = rename_into(from, backup, ports)
	if saved then
		report.backed_up[#report.backed_up + 1] = { from = from, to = backup, taken = to }
	elseif reason == "rename_failed" and ports.exists(backup) then
		-- The backup slot was taken between the check and the rename: the
		-- no-replace rename kept what arrived there.
		report.kept[#report.kept + 1] = { from = from, to = backup, reason = "backup_exists" }
	else
		report.kept[#report.kept + 1] = { from = from, to = backup, reason = reason, detail = detail }
	end
end

--- Moves one entry to its destination, or into the backup folder when the
--- destination holds something.
---
--- The rename port never replaces an existing destination (renameat2
--- RENAME_NOREPLACE, a hard link, an exclusive mkdir reservation or a Win32
--- move without MOVEFILE_REPLACE_EXISTING). The existence checks only choose
--- the slot: a destination that appears between the check and the rename makes
--- the rename fail, and the entry then goes to its backup like any taken name.
--- @param from string Old path.
--- @param to string New path.
--- @param backup string Path the old entry takes when `to` is taken.
--- @param ports table Native effects.
--- @param report table Report being filled.
local function move_entry(from, to, backup, ports, report)
	if not ports.exists(from) then return end
	if ports.exists(to) then
		-- An empty folder a newer build created ahead of the migration holds no
		-- data: it gives way to the old entry.
		local left = ports.list(to)
		if not (left and #left == 0 and ports.remove_empty_dir(to)) then
			back_up_entry(from, to, backup, ports, report)
			return
		end
	end
	local moved, reason, detail = rename_into(from, to, ports)
	if moved then
		report.moved[#report.moved + 1] = { from = from, to = to }
	elseif reason == "rename_failed" and ports.exists(to) then
		back_up_entry(from, to, backup, ports, report)
	else
		report.kept[#report.kept + 1] = { from = from, to = to, reason = reason, detail = detail }
	end
end

--- Applies a plan of folder moves.
---
--- Each step is either a single move (`from`, `to`, `backup`) or a merge
--- (`from_dir`, `to_dir`, `backup_dir`, optional `entries`): every entry of
--- `from_dir` (or only the named ones) moves to the same name in `to_dir`, or
--- to the same name in `backup_dir` when that name is taken, and `from_dir` is
--- removed once it is empty. A merge keeps entries it is not asked to move.
--- @param plan table Array of steps.
--- @param ports table exists, list, rename, make_dir, remove_empty_dir.
--- @return table report { moved = {{from,to}}, backed_up = {{from,to,taken}},
---   kept = {{from,to,reason}}, removed = {dir} }.
function M.apply(plan, ports)
	assert(type(plan) == "table", "legacy folder migration needs a plan")
	require_ports(ports)
	local report = { moved = {}, backed_up = {}, kept = {}, removed = {} }
	for index, step in ipairs(plan) do
		if step.from then
			assert(type(step.to) == "string" and type(step.backup) == "string",
				"legacy folder migration step " .. index .. " needs to and backup")
			move_entry(step.from, step.to, step.backup, ports, report)
		else
			assert(type(step.from_dir) == "string" and type(step.to_dir) == "string"
				and type(step.backup_dir) == "string",
				"legacy folder migration step " .. index .. " needs from_dir, to_dir and backup_dir")
		end
		if step.from_dir and ports.exists(step.from_dir) then
			-- A copy: the named entries come from the generated app_dirs table.
			local names = {}
			for _, name in ipairs(step.entries or ports.list(step.from_dir) or {}) do names[#names + 1] = name end
			table.sort(names)
			for _, name in ipairs(names) do
				move_entry(join(step.from_dir, name), join(step.to_dir, name), join(step.backup_dir, name), ports,
					report)
			end
			local left = ports.list(step.from_dir)
			if left and #left == 0 and ports.remove_empty_dir(step.from_dir) then
				report.removed[#report.removed + 1] = step.from_dir
			end
		end
	end
	return report
end





-- =====================================
-- =====================================
-- ======= 2/ paths.toml rewrite =======
-- =====================================
-- =====================================

--- Compares two folder spellings, ignoring trailing separators (a backslash is one only on Windows).
--- @param a string
--- @param b string
--- @return boolean
local function same_folder(a, b)
	return NativePath.without_trailing_separators(a) == NativePath.without_trailing_separators(b)
end

--- Rewrites the paths.toml keys that name an old default folder.
---
--- Only a `Key = "value"` line whose value is one of the key's old spellings is
--- changed, to the new value with the same trailing separator. Every other line
--- is kept byte for byte, comments included.
--- @param text string paths.toml content.
--- @param rewrites table Array of { key, old = {spellings}, new }.
--- @return string|nil rewritten New text, or nil when nothing changed.
function M.rewrite_paths_text(text, rewrites)
	assert(type(text) == "string", "paths.toml text must be a string")
	local changed = false
	local out = text:gsub("([^\n]*)", function(line)
		local indent, key, spacing, value, rest = line:match('^(%s*)([%w_]+)(%s*=%s*)"([^"]*)"(.*)$')
		if not key then return line end
		for _, rule in ipairs(rewrites) do
			if rule.key == key then
				for _, old in ipairs(rule.old) do
					if value ~= "" and same_folder(value, old) then
						local trailing = value:sub(#NativePath.without_trailing_separators(value) + 1)
						local new = NativePath.without_trailing_separators(rule.new) .. trailing
						if new ~= value then
							changed = true
							return indent .. key .. spacing .. '"' .. new .. '"' .. rest
						end
					end
				end
			end
		end
		return line
	end)
	return changed and out or nil
end

--- Rewrites paths.toml in place, keeping its previous text as a backup first.
--- @param path string paths.toml.
--- @param rewrites table See rewrite_paths_text.
--- @param backup_suffix string Suffix of the backup file.
--- @param ports table read(path) -> text|nil, exists(path), write(path, text) -> bool.
--- @return string outcome "absent", "unchanged", "rewritten" or "backup_refused".
function M.rewrite_paths_file(path, rewrites, backup_suffix, ports)
	if not ports.exists(path) then return "absent" end
	local text = ports.read(path)
	if type(text) ~= "string" then return "backup_refused" end
	local rewritten = M.rewrite_paths_text(text, rewrites)
	if not rewritten then return "unchanged" end
	local backup = path .. backup_suffix
	if ports.exists(backup) or not ports.write(backup, text) then return "backup_refused" end
	if not ports.write(path, rewritten) then return "backup_refused" end
	return "rewritten"
end




-- ================================
-- ================================
-- ======= 3/ Report ==============
-- ================================
-- ================================

--- Logs a migration report through the driver's logger.
--- @param logger table Logger with info and warn.
--- @param log string Logger module name.
--- @param report table Report from apply, with an optional paths_file outcome.
function M.log_report(logger, log, report)
	for _, entry in ipairs(report.moved) do
		logger.info(log, "Moved legacy folder entry %s to %s.", entry.from, entry.to)
	end
	for _, entry in ipairs(report.backed_up) do
		logger.warn(log, "Moved legacy folder entry %s to the backup %s: %s is already taken.", entry.from,
			entry.to, entry.taken)
	end
	for _, entry in ipairs(report.kept) do
		logger.warn(log, "Kept legacy folder entry %s: %s at %s (%s).", entry.from,
			entry.reason == "backup_exists" and "a backup already exists" or "it could not be moved",
			entry.to, tostring(entry.detail or entry.reason))
	end
	for _, dir in ipairs(report.removed) do
		logger.info(log, "Removed the emptied legacy folder %s.", dir)
	end
	if report.paths_file == "rewritten" then
		logger.info(log, "paths.toml now names the new default folders; its previous text is kept beside it.")
	elseif report.paths_file == "backup_refused" then
		logger.warn(log, "paths.toml still names an old default folder: its backup could not be written.")
	end
end

return M
