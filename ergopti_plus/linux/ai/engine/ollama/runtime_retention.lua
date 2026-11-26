--- ai/engine/ollama/runtime_retention.lua

--- ==============================================================================
--- MODULE: Managed Ollama Runtime Retention (Linux)
--- DESCRIPTION:
--- Removes the release folders a runtime update left behind under
--- runtimes/ollama/, once the pinned release is verified and its daemon answers,
--- as macOS exchanges its earlier install for the new one: each update used to
--- leave about 1.4 GB on disk.
---
--- FEATURES & RATIONALE:
--- 1. Only Ergopti's own release folders are candidates: a direct child of the
---    resolver's runtimes/ollama folder named <version>-<asset>-<sha256>, a real
---    folder (never a link) owned by the user. The pinned release, which the
---    running daemon uses, is never one.
--- 2. The removal is a shell-free `rm -r --one-file-system` child under the
---    finite process port, off the event loop, so a large tree never stalls
---    input; rm never follows a link.
--- 3. A failed removal is logged and left in place; the next start lists the
---    folder again and retries it, so a refusal is never hidden.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")

local available, native = pcall(require, "luv")
if not available then native = nil end

local LOG = "ai.engine.ollama.runtime_retention"

--- Whether a folder name is a release folder of install_policy.posix_plan.
--- @param name string
--- @return boolean
local function release_name(name)
	local digest = type(name) == "string" and name:match("^%d+%.%d+%.%d+%-[a-z0-9%-]+%-([0-9a-f]+)$")
	return digest ~= nil and #digest == 64
end

--- Lists the release folders other than the pinned one.
--- @param plan table Resolver plan { runtime, parent, uid }.
--- @param fs table|nil { fs_scandir, fs_scandir_next, fs_lstat } (tests); luv otherwise.
--- @return table|nil paths Absolute folders to remove, sorted.
--- @return string|nil reason
function M.stale(plan, fs)
	fs = fs or native
	if type(plan) ~= "table" or type(plan.runtime) ~= "string" or type(plan.parent) ~= "string"
		or type(plan.uid) ~= "number" then return nil, "runtime_retention_plan_unavailable" end
	if type(fs) ~= "table" then return nil, "runtime_retention_native_unavailable" end
	local ok, iterator = pcall(fs.fs_scandir, plan.runtime)
	if not ok or not iterator then return nil, "runtime_retention_scan_refused" end
	local paths = {}
	while true do
		local listed, name = pcall(fs.fs_scandir_next, iterator)
		if not listed then return nil, "runtime_retention_scan_refused" end
		if name == nil then break end
		local path = plan.runtime .. "/" .. name
		if path ~= plan.parent and release_name(name) then
			local stat_ok, value = pcall(fs.fs_lstat, path)
			if stat_ok and type(value) == "table" and value.type == "directory" and value.uid == plan.uid then
				paths[#paths + 1] = path
			end
		end
	end
	table.sort(paths)
	return paths
end

--- Removes release folders through the finite process port.
--- @param paths table Folders from M.stale or the unverified pinned release.
--- @param process table { start } finite process port.
--- @param timeout_ms number The removal's ceiling.
--- @param label string What is removed, for the log.
--- @param done function|nil Receives true once removed, false when kept.
--- @return table|nil operation The retained process operation.
function M.remove(paths, process, timeout_ms, label, done)
	if type(paths) ~= "table" or #paths == 0 then return nil end
	local args = { "-r", "--one-file-system", "--" }
	for _, path in ipairs(paths) do args[#args + 1] = path end
	Logger.info(LOG, "Removing %s: %s…", label, table.concat(paths, ", "))
	return process.start("rm", args, { owner = "ollama-runtime-retention", timeout_ms = timeout_ms }, function(result)
		local removed = type(result) == "table" and result.ok == true and result.exit_code == 0
		if removed then
			Logger.info(LOG, "Removed %s.", label)
		else
			Logger.warn(LOG, "Could not remove %s (%s); kept until the next start retries.", label,
				tostring(type(result) == "table" and (result.error or result.stderr or result.exit_code) or "no receipt"))
		end
		if type(done) == "function" then pcall(done, removed) end
	end)
end

return M
