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
---    existing backup is never replaced (one holding the same text, left by an
---    interrupted boot, is reused). The new text is staged and renamed over the
---    file, so a refused write never truncates it.
--- 4. Locator Follows Receipts: a key is rewritten only when its old folder
---    actually left (a refused move keeps the old folder, which the file still
---    names). When the new text cannot be published, the configuration folder
---    moves back to the folder the file still names, so boot never selects an
---    empty folder while the user's one sits elsewhere.
--- 5. Minimal by Decision: no build was ever published to users with the old
---    folders (project memory, 2026-09-23), so only the maintainer's machines
---    have them. The migration covers the folders those machines hold and is
---    meant to be deleted once they are moved; it is not a compatibility layer.
--- 6. Deferred Logging: the drivers run it before their logger opens its folder
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
	for _, name in ipairs({ "exists", "list", "rename", "make_dir", "remove_empty_dir", "same_object" }) do
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
	if ports.exists(to) and ports.same_object(from, to) then
		-- One physical entry reached by two names (a link): nothing to move, and
		-- archiving it as its own clash would take the live entry away.
		report.aliased[#report.aliased + 1] = { from = from, to = to }
		return
	end
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

--- Moves the entries of one merge step, then removes its emptied old folder.
---
--- A folder that cannot be listed is a refusal, not an empty folder: its
--- entries stay where they are and the report names it, so the boot log says
--- why the old settings were not found in the new folder.
--- @param step table Merge step (from_dir, to_dir, backup_dir, entries).
--- @param ports table Native effects.
--- @param report table Report being filled.
local function merge_entries(step, ports, report)
	local listed, list_error
	if step.entries then
		listed = step.entries
	else
		listed, list_error = ports.list(step.from_dir)
	end
	if type(listed) ~= "table" then
		report.kept[#report.kept + 1] = { from = step.from_dir, to = step.to_dir, reason = "list_failed",
			detail = list_error }
		return
	end
	-- A copy: the named entries come from the generated app_dirs table.
	local names = {}
	for _, name in ipairs(listed) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		move_entry(join(step.from_dir, name), join(step.to_dir, name), join(step.backup_dir, name), ports, report)
	end
	-- A folder already gone once its entries left has nothing to remove.
	if not ports.exists(step.from_dir) then return end
	local left, left_error = ports.list(step.from_dir)
	if type(left) ~= "table" then
		report.kept[#report.kept + 1] = { from = step.from_dir, to = step.to_dir, reason = "list_failed",
			detail = left_error }
	elseif #left == 0 then
		if ports.remove_empty_dir(step.from_dir) then
			report.removed[#report.removed + 1] = step.from_dir
		else
			report.kept[#report.kept + 1] = { from = step.from_dir, to = step.from_dir, reason = "remove_failed" }
		end
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
--- @param ports table exists, list (names, or nil and an error when the folder
---   cannot be listed), rename (never replacing), make_dir, remove_empty_dir,
---   same_object(a, b) (true when both names reach one physical entry).
--- @return table report { moved = {{from,to}}, backed_up = {{from,to,taken}},
---   kept = {{from,to,reason}}, removed = {dir}, aliased = {{from,to}} }.
function M.apply(plan, ports)
	assert(type(plan) == "table", "legacy folder migration needs a plan")
	require_ports(ports)
	local report = { moved = {}, backed_up = {}, kept = {}, removed = {}, aliased = {} }
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
			if ports.exists(step.to_dir) and ports.same_object(step.from_dir, step.to_dir) then
				-- The old folder is a link to the new one: its entries are the live
				-- ones, and its backup folder lies inside it.
				report.aliased[#report.aliased + 1] = { from = step.from_dir, to = step.to_dir }
			else
				merge_entries(step, ports, report)
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

--- The suffix of the private stage files the publication writes and renames.
local STAGE_SUFFIX = ".migration-stage"

--- Rewrites paths.toml, keeping its previous text as a backup first.
---
--- Both files are written to a stage beside them and renamed into place: the
--- backup with the no-replace rename, the file itself with an atomic replace,
--- so a refused or partial write leaves paths.toml exactly as it was. An
--- existing backup holding the current text (an earlier boot stopped after
--- writing it) is reused; one holding other text is never replaced.
--- @param path string paths.toml.
--- @param rewrites table See rewrite_paths_text.
--- @param backup_suffix string Suffix of the backup file.
--- @param ports table exists, read(path) -> text|nil, write(path, text) -> bool,
---   rename (never replacing), replace(from, to) -> bool (atomic), remove(path).
--- @return string outcome "absent", "unchanged", "rewritten", or the refusal
---   "read_failed", "backup_taken", "backup_refused" or "write_refused".
function M.rewrite_paths_file(path, rewrites, backup_suffix, ports)
	if not ports.exists(path) then return "absent" end
	local text = ports.read(path)
	if type(text) ~= "string" then return "read_failed" end
	local rewritten = M.rewrite_paths_text(text, rewrites)
	if not rewritten then return "unchanged" end
	local backup = path .. backup_suffix
	if ports.exists(backup) then
		if ports.read(backup) ~= text then return "backup_taken" end
	else
		-- The stage names are written by this migration alone.
		local stage = backup .. STAGE_SUFFIX
		ports.remove(stage)
		if not (ports.write(stage, text) and ports.rename(stage, backup)) then
			ports.remove(stage)
			return "backup_refused"
		end
	end
	local stage = path .. STAGE_SUFFIX
	ports.remove(stage)
	if not (ports.write(stage, rewritten) and ports.replace(stage, path)) then
		ports.remove(stage)
		return "write_refused"
	end
	return "rewritten"
end

--- The outcome a report records for one old folder.
--- @param report table Report from apply.
--- @param source string Absolute old folder.
--- @return string|nil kind "moved", "backed_up" or "kept".
--- @return table|nil entry The report row.
local function outcome_of(report, source)
	for _, kind in ipairs({ "moved", "backed_up", "kept" }) do
		for _, entry in ipairs(report[kind]) do
			if same_folder(entry.from, source) then return kind, entry end
		end
	end
	return nil
end

--- Keeps the rewrites whose old folder did not stay where it was.
---
--- A rule without a `source` is kept as it is. A rule whose source was kept
--- (its move was refused, or a backup slot was taken) is dropped: the old
--- folder still holds the data the file names.
--- @param rules table Array of { key, old, new, source }.
--- @param report table Report from apply.
--- @return table rewrites For rewrite_paths_text.
function M.settle_rewrites(rules, report)
	local settled = {}
	for _, rule in ipairs(rules) do
		if not (rule.source and outcome_of(report, rule.source) == "kept") then settled[#settled + 1] = rule end
	end
	return settled
end

--- Outcomes of rewrite_paths_file after which paths.toml still names old folders.
local REFUSED = { read_failed = true, backup_taken = true, backup_refused = true, write_refused = true }

--- Rewrites paths.toml from what moved, and when it cannot, moves each
--- `restorable` folder back to the old path the file still names.
--- @param path string paths.toml.
--- @param rules table Array of { key, old, new, source, restorable }.
--- @param backup_suffix string Suffix of the backup file.
--- @param report table Report from apply; receives paths_file and restored rows.
--- @param ports table The ports of apply and rewrite_paths_file.
function M.publish_paths_file(path, rules, backup_suffix, report, ports)
	report.restored = report.restored or {}
	report.paths_file = M.rewrite_paths_file(path, M.settle_rewrites(rules, report), backup_suffix, ports)
	if not REFUSED[report.paths_file] then return end
	for _, rule in ipairs(rules) do
		local kind, entry = nil, nil
		if rule.restorable and rule.source then kind, entry = outcome_of(report, rule.source) end
		if kind == "moved" or kind == "backed_up" then
			local back, why = ports.rename(entry.to, entry.from)
			if back then
				report.restored[#report.restored + 1] = { from = entry.to, to = entry.from }
			else
				report.kept[#report.kept + 1] = { from = entry.to, to = entry.from, reason = "restore_failed",
					detail = why }
			end
		end
	end
end




-- ================================
-- ================================
-- ======= 3/ Report ==============
-- ================================
-- ================================

--- What a kept row's reason means, for its warning.
local KEPT_REASONS = {
	backup_exists = "a backup already exists",
	list_failed = "its folder could not be listed",
	remove_failed = "its emptied folder could not be removed",
	restore_failed = "it could not be moved back to the folder paths.toml names",
}

--- Why paths.toml still names an old folder, for its warning.
local PATHS_FILE_REFUSALS = {
	read_failed = "it could not be read",
	backup_taken = "its backup name already holds other text",
	backup_refused = "its backup could not be written",
	write_refused = "its new text could not be written (the backup beside it holds the previous text)",
}

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
			KEPT_REASONS[entry.reason] or "it could not be moved", entry.to, tostring(entry.detail or entry.reason))
	end
	for _, dir in ipairs(report.removed) do
		logger.info(log, "Removed the emptied legacy folder %s.", dir)
	end
	for _, entry in ipairs(report.aliased or {}) do
		logger.info(log, "Left legacy folder entry %s: it is %s under another name.", entry.from, entry.to)
	end
	if report.paths_file == "rewritten" then
		logger.info(log, "paths.toml now names the new default folders; its previous text is kept beside it.")
	elseif PATHS_FILE_REFUSALS[report.paths_file] then
		logger.warn(log, "paths.toml still names an old default folder: %s.", PATHS_FILE_REFUSALS[report.paths_file])
	end
	for _, entry in ipairs(report.restored or {}) do
		logger.warn(log, "Moved %s back to %s, the folder paths.toml still names.", entry.from, entry.to)
	end
end

return M
