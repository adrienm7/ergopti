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
--- 1. Never Overwrite: an entry moves only when nothing exists at its
---    destination. Otherwise both stay and the report names the kept entry, so a
---    folder written by a newer build is never replaced by an older one.
--- 2. Rename, Not Copy: a move is one rename inside the same home folder. It
---    loses nothing on failure and costs nothing for the multi-gigabyte managed
---    runtimes, so the folders themselves need no copy.
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

--- Moves one entry when its destination is free.
--- @param from string Old path.
--- @param to string New path.
--- @param ports table Native effects.
--- @param report table Report being filled.
local function move_entry(from, to, ports, report)
	if not ports.exists(from) then return end
	if ports.exists(to) then
		report.kept[#report.kept + 1] = { from = from, to = to, reason = "destination_exists" }
		return
	end
	local parent = to:match("^(.*)/[^/]+$")
	if parent and parent ~= "" and not ports.make_dir(parent) then
		report.kept[#report.kept + 1] = { from = from, to = to, reason = "parent_unavailable" }
		return
	end
	local moved, why = ports.rename(from, to)
	if moved then
		report.moved[#report.moved + 1] = { from = from, to = to }
	else
		report.kept[#report.kept + 1] = { from = from, to = to, reason = "rename_failed", detail = why }
	end
end

--- Applies a plan of folder moves.
---
--- Each step is either a single move (`from`, `to`) or a merge (`from_dir`,
--- `to_dir`, optional `entries`): every entry of `from_dir` (or only the named
--- ones) moves to the same name in `to_dir`, and `from_dir` is removed once it
--- is empty. A merge keeps entries it is not asked to move.
--- @param plan table Array of steps.
--- @param ports table exists, list, rename, make_dir, remove_empty_dir.
--- @return table report { moved = {{from,to}}, kept = {{from,to,reason}}, removed = {dir} }.
function M.apply(plan, ports)
	assert(type(plan) == "table", "legacy folder migration needs a plan")
	require_ports(ports)
	local report = { moved = {}, kept = {}, removed = {} }
	for _, step in ipairs(plan) do
		if step.from then
			move_entry(step.from, step.to, ports, report)
		elseif step.from_dir and ports.exists(step.from_dir) then
			local names = step.entries or ports.list(step.from_dir) or {}
			table.sort(names)
			for _, name in ipairs(names) do
				move_entry(join(step.from_dir, name), join(step.to_dir, name), ports, report)
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

--- Compares two folder spellings, ignoring trailing slashes.
--- @param a string
--- @param b string
--- @return boolean
local function same_folder(a, b)
	return (a:gsub("[/\\]+$", "")) == (b:gsub("[/\\]+$", ""))
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
						local trailing = value:match("[/\\]+$") or ""
						local new = (rule.new:gsub("[/\\]+$", "")) .. trailing
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
	for _, entry in ipairs(report.kept) do
		logger.warn(log, "Kept legacy folder entry %s: %s at %s (%s).", entry.from,
			entry.reason == "destination_exists" and "an entry already exists" or "it could not be moved",
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
