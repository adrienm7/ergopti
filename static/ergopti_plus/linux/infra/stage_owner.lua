--- infra/stage_owner.lua

--- ==============================================================================
--- MODULE: Atomic-Write Stage Ownership (Linux)
--- DESCRIPTION:
--- Names each atomic-write staging file after the process that writes it and
--- removes, at start, the stages a dead Ergopti process left behind (CFD-1,
--- decided by the maintainer on 2026-11-11), as Windows names its stages per
--- process and reaps them (toml_helpers.ahk _TOML_ReapStaleTemps).
---
--- FEATURES & RATIONALE:
--- 1. A per-process name: `<file>.ergopti-<pid>-<start>.tmp` (the infix is
---    identifiers.json's linux_stage.infix), where <start> is
---    the kernel start tick of the process (/proc/<pid>/stat field 22), so a
---    reused pid never passes for the stage's owner. A stage left by a kill or
---    a power cut therefore never blocks this process's exclusive creation.
--- 2. A stage is reaped only with both proofs: its name is ours and its owner
---    is gone (no such process, a zombie, or another start tick), and it is
---    older than the shared [adapters] stale_temp_age_ms, as on Windows.
--- 3. A foreign stage is never touched: a file that does not carry our name
---    pattern stays, and its exclusive creation still refuses to overwrite it
---    (memory project-linux-json-store-publication).
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Identifiers = require("core.text.engine.identifiers")

local LOG = "infra.stage_owner"

-- The word every stage name carries after the destination's own name
-- (_shared/core/text/data/identifiers.json linux_stage.infix).
local INFIX = Identifiers.linux_stage.infix

-- This process's identity; nil until first read.
local _identity = nil

-- Test seam: the /proc reader.
local _read = nil




-- ====================================
-- ====================================
-- ======= 1/ Process identity ========
-- ====================================
-- ====================================

--- Reads a small kernel file.
--- @param path string
--- @return string|nil text
local function read_file(path)
	if _read then return _read(path) end
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local ok, text = pcall(fh.read, fh, "*a")
	local closed = fh:close()
	if not ok or type(text) ~= "string" or not closed then return nil end
	return text
end

--- Parses /proc/<pid>/stat: the state and the start tick, past the process
--- name, which sits between the first `(` and the last `)` and may hold spaces.
--- @param stat string|nil
--- @return string|nil state
--- @return string|nil start_tick Exact decimal kernel value.
local function parse_stat(stat)
	if type(stat) ~= "string" then return nil end
	local closing = stat:match("^.*()%) ")
	if not closing then return nil end
	local index, state = 0, nil
	for field in stat:sub(closing + 2):gmatch("%S+") do
		index = index + 1
		if index == 1 then state = field end
		if index == 20 then return state, field:match("^%d+$") and field or nil end
	end
	return nil
end

--- This process's pid and start tick, read once.
--- @return string pid
--- @return string start
function M.identity()
	if _identity then return _identity.pid, _identity.start end
	local stat = read_file("/proc/self/stat")
	local pid = type(stat) == "string" and stat:match("^(%d+) ") or nil
	local _, start = parse_stat(stat)
	if not pid or not start then error("stage_owner: /proc/self/stat gives no pid and start tick") end
	_identity = { pid = pid, start = start }
	return pid, start
end

--- The staging path this process uses for one destination.
--- @param path string Destination path.
--- @return string stage
function M.stage_path(path)
	local pid, start = M.identity()
	return string.format("%s.%s-%s-%s.tmp", path, INFIX, pid, start)
end

--- Whether the process a stage name records is gone.
--- @param pid string
--- @param start string
--- @return boolean gone
function M.owner_gone(pid, start)
	local own_pid, own_start = M.identity()
	if pid == own_pid and start == own_start then return false end
	local stat = read_file("/proc/" .. pid .. "/stat")
	if stat == nil then return true end
	local state, live_start = parse_stat(stat)
	if state == nil then return false end
	return state == "Z" or live_start ~= start
end




-- =================================
-- =================================
-- ======= 2/ Reaping ==============
-- =================================
-- =================================

--- Removes the stages a dead Ergopti process left in one directory.
--- @param directory string
--- @param opts table|nil { now = seconds, max_age_ms = number, directory = native_directory }
--- @return number removed
--- @return number kept Stages of ours whose owner lives or that are too young.
function M.reap(directory, opts)
	opts = opts or {}
	local Directory = opts.directory or require("core.fs.engine.native_directory")
	local max_age_ms = opts.max_age_ms or require("infra.timings").ms("adapters", "stale_temp_age_ms")
	local now = opts.now or os.time()
	local entries, message, code = Directory.entries(directory)
	if entries == nil then
		if code ~= "ENOENT" then
			Logger.warn(LOG, "Stale stages in %s were not checked: %s.", directory, tostring(message))
		end
		return 0, 0
	end
	local removed, kept = 0, 0
	-- The suffix stage_path writes, as a pattern: <file>.<infix>-<pid>-<start>.tmp.
	local suffix = "%." .. INFIX:gsub("%p", "%%%0") .. "%-(%d+)%-(%d+)%.tmp$"
	for _, entry in ipairs(entries) do
		local pid, start = entry.name:match(suffix)
		if pid then
			local path = Directory.join(directory, entry.name)
			local stat = Directory.stat(path)
			local old = stat and stat.kind == "file" and type(stat.modified) == "number"
				and (now - stat.modified) * 1000 >= max_age_ms
			if old and M.owner_gone(pid, start) then
				local ok, err = os.remove(path)
				if ok then
					removed = removed + 1
					Logger.info(LOG, "Removed a stage left by stopped process %s: %s.", pid, entry.name)
				else
					kept = kept + 1
					Logger.warn(LOG, "A stale stage could not be removed: %s (%s).", entry.name, tostring(err))
				end
			else
				kept = kept + 1
			end
		end
	end
	return removed, kept
end

--- Removes the dead processes' stages beside the settings: the folder of
--- config.toml and the folder of storage.json (the default configuration
--- folder, which a ConfigDirPath override does not move).
--- @return number removed
function M.reap_settings()
	local folders, seen, removed = {}, {}, 0
	for _, file in ipairs({ require("infra.config_paths").config("config.toml"), require("core.fs.adapters.storage").path() }) do
		local folder = type(file) == "string" and require("core.fs.engine.native_path").dirname(file) or nil
		if folder and folder ~= "" and not seen[folder] then
			seen[folder] = true
			folders[#folders + 1] = folder
		end
	end
	for _, folder in ipairs(folders) do removed = removed + M.reap(folder) end
	return removed
end

-- Read once at load, before any caller can replace io.open around a write.
M.identity()

--- Test seam: replaces the /proc reader and forgets the cached identity.
--- @param reader function|nil path -> text|nil
function M._set_reader_for_test(reader)
	_read, _identity = reader, nil
	if reader == nil then M.identity() end
end

return M
