--- modules/keymap/managed_python.lua

--- ==============================================================================
--- MODULE: Ergopti's Own Python (Linux)
--- DESCRIPTION:
--- The Python that runs the user XKB installer: the python-build-standalone
--- build of the shared managed Python release, pinned in the runtime manifest
--- (_shared/data/linux_native_runtime.json, projected into
--- _generated/native_runtime.lua) and downloaded once, on consent, into the
--- private data folder. The host's python3 is never run (owned runtimes, PIN).
---
--- FEATURES & RATIONALE:
--- 1. Consent first: the archive is about 30 MB, so the user is asked before
---    the first download, as the owned Ollama is; a declined question installs
---    nothing and the layout install reports why.
--- 2. Verified before it exists: the archive is fetched through the managed
---    HTTP client (the desktop proxy policy applies), its size and SHA-256 are
---    checked against the pin, it is unpacked into a private staging folder, and
---    only a complete tree is renamed into its versioned folder. A versioned
---    folder therefore never holds an unverified interpreter.
--- 3. One install at a time: callers that ask while it runs wait for the same
---    outcome instead of starting a second download.
--- 4. Every effect is a dependency, so the suite replays the whole transaction
---    without network, archive or dialog.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "keymap.managed_python"

--- Failure codes the layout registry reports.
M.FAILURE_DECLINED = "python_declined"
M.FAILURE_UNSUPPORTED = "python_unsupported_platform"
M.FAILURE_DOWNLOAD = "python_download_failed"
M.FAILURE_CHECKSUM = "python_checksum_mismatch"
M.FAILURE_UNPACK = "python_unpack_failed"
M.FAILURE_PUBLISH = "python_publish_failed"

--- The interpreter inside an unpacked archive.
M.INTERPRETER = "python/bin/python3"

-- The musl loaders whose presence marks a musl system, per machine.
local MUSL_LOADERS = {
	x86_64 = "/lib/ld-musl-x86_64.so.1",
	aarch64 = "/lib/ld-musl-aarch64.so.1",
}

-- Waiters of the install in flight, nil when none runs.
local _waiters = nil




-- =====================================
-- =====================================
-- ======= 1/ Pin and location =========
-- =====================================
-- =====================================

--- The archive key of this machine: <machine>-<gnu|musl>, or nil.
--- @param deps table { machine, exists }
--- @return string|nil key
function M.platform(deps)
	local machine = deps.machine()
	if MUSL_LOADERS[machine] == nil then return nil end
	return machine .. "-" .. (deps.exists(MUSL_LOADERS[machine]) and "musl" or "gnu")
end

--- The versioned folder this machine's Python lives in once installed.
--- @param deps table { pin, data_dir }
--- @param key string Archive key.
--- @return string
function M.root(deps, key)
	return deps.data_dir .. "/runtime/python/cpython-" .. deps.pin.version .. "+" .. deps.pin.build .. "-" .. key
end

--- The installed interpreter, or nil when it is not installed.
--- @param deps table
--- @return string|nil path
function M.installed(deps)
	local key = M.platform(deps)
	if not key or not deps.pin.archives[key] then return nil end
	local interpreter = M.root(deps, key) .. "/" .. M.INTERPRETER
	return deps.exists(interpreter) and interpreter or nil
end




-- ================================
-- ================================
-- ======= 2/ Installation ========
-- ================================
-- ================================

--- Settles every waiter of the install in flight once.
--- @param ok boolean
--- @param value string Interpreter path, or a failure code.
--- @param detail string|nil
local function settle(ok, value, detail)
	local waiters = _waiters
	_waiters = nil
	if not ok then Logger.error(LOG, "Ergopti's Python is not installed: %s (%s).", tostring(value), tostring(detail)) end
	for _, waiter in ipairs(waiters or {}) do
		local delivered = pcall(waiter, ok, value, detail)
		if not delivered then Logger.error(LOG, "A Python installation completion callback failed.") end
	end
end

--- Runs the verified download, unpack and publication of one archive.
--- @param deps table
--- @param key string Archive key.
--- @param archive table { url, sha256, bytes }
local function install(deps, key, archive)
	local root = M.root(deps, key)
	local acquired, stage, stage_current = pcall(deps.create_stage, root)
	if not acquired or type(stage) ~= "string" or type(stage_current) ~= "function" then
		settle(false, M.FAILURE_PUBLISH, "a private staging folder could not be reserved")
		return
	end
	local download = stage .. "/archive.tar.gz"
	local function current()
		local checked, retained = pcall(stage_current)
		return checked and retained == true
	end
	local function fail(code, detail)
		if not current() then settle(false, code, detail); return end
		deps.remove_tree(stage, function() settle(false, code, detail) end)
	end
	do
		Logger.start(LOG, "Downloading Ergopti's Python (%d bytes) for %s…", archive.bytes, key)
		local function downloaded(result)
			if not current() then fail(M.FAILURE_PUBLISH, "the staging folder changed"); return end
			if type(result) ~= "table" or result.ok ~= true or result.status ~= 200 then
				fail(M.FAILURE_DOWNLOAD, type(result) == "table" and tostring(result.error or result.status) or "no result")
				return
			end
			if deps.size(download) ~= archive.bytes then
				fail(M.FAILURE_DOWNLOAD, "the archive is not " .. archive.bytes .. " bytes")
				return
			end
			deps.sha256(download, function(digest, err)
				if not current() then fail(M.FAILURE_PUBLISH, "the staging folder changed"); return end
				if digest ~= archive.sha256 then
					fail(M.FAILURE_CHECKSUM, tostring(err or digest))
					return
				end
				deps.unpack(download, stage, function(unpacked, unpack_err)
					if not current() then fail(M.FAILURE_PUBLISH, "the staging folder changed"); return end
					if not unpacked or not deps.exists(stage .. "/" .. M.INTERPRETER) then
						fail(M.FAILURE_UNPACK, tostring(unpack_err or "no interpreter in the archive"))
						return
					end
					if not deps.delete(download) then
						fail(M.FAILURE_PUBLISH, "the downloaded archive cannot be removed")
						return
					end
					if not current() then fail(M.FAILURE_PUBLISH, "the staging folder changed"); return end
					local renamed, rename_err = deps.rename(stage, root)
					if not renamed then
						fail(M.FAILURE_PUBLISH, tostring(rename_err))
						return
					end
					Logger.success(LOG, "Ergopti's Python %s installed in %s.", deps.pin.version, root)
					settle(true, root .. "/" .. M.INTERPRETER, nil)
				end)
			end)
		end
		-- The boolean alone cannot prove that a refused or completed transfer
		-- has released its process, pipes and destination. Wait for its exact
		-- physical receipt before reading or removing the staging directory.
		local called, started, operation = pcall(deps.download, archive.url, download, archive.bytes, function() end)
		if not called or type(started) ~= "boolean" or type(operation) ~= "table"
			or operation.started ~= started or type(operation.is_settled) ~= "function"
			or type(operation.on_settled) ~= "function" or type(operation.settled_result) ~= "function" then
			Logger.error(LOG, "Python download ownership is unknown; staging remains reserved.")
			return
		end
		local attaching, delivered, subscribed = true, false, false
		local function settled()
			if attaching or not subscribed or delivered then return end
			local observed, closed = pcall(operation.is_settled, operation)
			if not observed or closed ~= true then return end
			local read, result = pcall(operation.settled_result, operation)
			delivered = true
			if not started or not read or type(result) ~= "table" then
				fail(M.FAILURE_DOWNLOAD, "the download was not admitted or did not return a settled result")
			else
				downloaded(result)
			end
		end
		local registered, accepted = pcall(operation.on_settled, operation, settled)
		subscribed = registered and accepted == true
		attaching = false
		if not subscribed then
			Logger.error(LOG, "Python download settlement registration failed; staging remains reserved.")
			return
		end
		settled()
	end
end

--- Calls on_done(true, interpreter) with Ergopti's Python, installing it first
--- when the user agrees, or on_done(false, failure_code, detail).
--- @param deps table { pin, data_dir, machine, exists, confirm, download, size,
---   sha256, unpack, create_stage, remove_tree, delete, rename }
--- @param on_done function
function M.ensure(deps, on_done)
	local installed = M.installed(deps)
	if installed then on_done(true, installed) return end
	if _waiters then _waiters[#_waiters + 1] = on_done return end
	local key = M.platform(deps)
	local archive = key and deps.pin.archives[key]
	if not archive then
		on_done(false, M.FAILURE_UNSUPPORTED, "no Ergopti Python build for " .. tostring(deps.machine()))
		return
	end
	_waiters = { on_done }
	-- Asked before anything is written: a declined offer leaves no trace.
	if deps.confirm(archive.bytes) ~= true then
		settle(false, M.FAILURE_DECLINED, "the download was not accepted")
		return
	end
	install(deps, key, archive)
end

--- Forgets the install in flight; for tests only.
function M._reset_for_test()
	_waiters = nil
end

return M
