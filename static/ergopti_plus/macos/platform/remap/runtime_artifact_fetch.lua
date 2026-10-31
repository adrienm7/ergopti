--- platform/remap/runtime_artifact_fetch.lua

--- ==============================================================================
--- MODULE: Owned Runtime Artifact Fetch
--- DESCRIPTION:
--- Gets the pinned owned Karabiner runtime artifact (ADR 011, WP5) onto this Mac
--- the first time it is needed, verifies it, and keeps it in Ergopti's own folder
--- so that every later start uses that same copy without the network. It never
--- writes to /Applications or to the user's Karabiner folders, and it installs
--- nothing privileged: the verified payload is what the installer publishes.
---
--- FEATURES & RATIONALE:
--- 1. Pinned Or Nothing: only the `runtime` group of a complete manifest pin is
---    fetched. An unpinned manifest is the named refusal `artifact_unpinned`.
--- 2. Verified Before Use: the download must have the pinned size and SHA-256,
---    and its member list must be closed (only directories and regular files,
---    all under `Runtime/`, no absolute path or `..`) before it is extracted.
--- 3. Then Always That One: a receipt naming the digest is written last, after
---    the payload is complete. A receipt that matches the pin and a payload
---    with every product means no network at all on later starts.
--- 4. One Fetch At A Time: callers that ask while a fetch runs wait for it.
--- 5. Ports Only: every effect goes through the ports given to `new`, so the
---    whole sequence is tested with fakes.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local KePaths = require("platform.remap.ke_paths")
local NativePath = require("native_path")

local LOG = "remap.runtime_artifact_fetch"

--- Seconds the download may take.
M.DOWNLOAD_TIMEOUT_SEC = 600
--- Seconds any other step may take.
M.STEP_TIMEOUT_SEC = 60

--- The products a payload must hold, relative to the payload root.
M.PRODUCTS = {
	"Runtime/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
	"Runtime/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",
	"Runtime/bin/ergoptiplus_remap_cli",
}

--- Stable reasons of a refused fetch.
M.REASON = {
	UNPINNED = "artifact_unpinned",
	DOWNLOAD = "artifact_download_failed",
	SIZE = "artifact_size_mismatch",
	DIGEST = "artifact_digest_mismatch",
	MEMBERS = "artifact_members_refused",
	EXTRACT = "artifact_extract_failed",
	STORE = "artifact_store_failed",
}
local REASON = M.REASON

local PIN_KEYS = { "version", "file_name", "source_url", "sha256", "size" }

--- Checks the runtime group of a pin.
--- @param pin any Candidate `runtime` group of the manifest.
--- @return boolean complete
local function complete_pin(pin)
	if type(pin) ~= "table" then return false end
	for _, key in ipairs(PIN_KEYS) do
		if pin[key] == nil then return false end
	end
	return type(pin.version) == "string" and pin.version:match("^[%w%.%-+]+$") ~= nil
		and type(pin.file_name) == "string" and pin.file_name:match("^[%w][%w%._%-]*$") ~= nil
		and type(pin.source_url) == "string" and pin.source_url:match("^https://[^%s]+/" .. pin.file_name:gsub("%p", "%%%0") .. "$") ~= nil
		and type(pin.sha256) == "string" and #pin.sha256 == 64 and pin.sha256:match("^%x+$") ~= nil
		and math.type(pin.size) == "integer" and pin.size >= 1
end

--- The folder a runtime version is kept in, as a tilde path.
--- @param version string Pinned runtime version.
--- @return string path
function M.home_for(version)
	return KePaths.OWNED.ARTIFACT_HOME .. "/" .. version
end

--- Judges a `tar -tvzf` listing and its `tar -tzf` names.
--- @param verbose string Verbose listing.
--- @param names string Name listing.
--- @return boolean closed
--- @return string|nil offending The first refused line.
function M.closed_listing(verbose, names)
	local count = 0
	for line in tostring(verbose):gmatch("[^\n]+") do
		count = count + 1
		local kind = line:sub(1, 1)
		if kind ~= "d" and kind ~= "-" then return false, line end
	end
	local name_count, seen = 0, {}
	for name in tostring(names):gmatch("[^\n]+") do
		name_count = name_count + 1
		if name:sub(1, 1) == "/" or name:find("%.%.") or not (name == "Runtime/" or name:find("^Runtime/")) then
			return false, name
		end
		seen[name] = true
	end
	if count == 0 or count ~= name_count then return false, "listing counts differ" end
	for _, product in ipairs(M.PRODUCTS) do
		if not seen[product] then return false, "missing " .. product end
	end
	return true
end

--- Creates a fetcher bound to its ports.
--- Port contracts:
---   exec(executable, args, timeout, fn(code|nil, stdout, stderr)) runs one command;
---   exists(path) -> boolean; read(path) -> string|nil; write(path, content) -> boolean;
---   expand(path) -> absolute path.
--- @param ports table exec, exists, read, write, expand.
--- @return table fetcher { ensure, payload_for }.
function M.new(ports)
	assert(type(ports) == "table", "Missing artifact fetch ports")
	for _, name in ipairs({ "exec", "exists", "read", "write", "expand" }) do
		assert(type(ports[name]) == "function", "Missing artifact fetch port: " .. name)
	end
	local fetcher = {}
	local waiters

	--- Settles every waiter of the running fetch once.
	local function settle(ok, value, detail)
		local pending = waiters
		waiters = nil
		if ok then
			Logger.success(LOG, "Owned runtime artifact ready at %s.", tostring(value))
		else
			Logger.error(LOG, "Owned runtime artifact refused (%s): %s", tostring(value), tostring(detail))
		end
		for _, waiter in ipairs(pending or {}) do
			local called, failure = pcall(waiter, ok, value, detail)
			if not called then Logger.error(LOG, "Artifact fetch callback failed: %s.", tostring(failure)) end
		end
	end

	--- Runs one step and continues only on exit 0.
	local function step(executable, args, timeout, reason, detail, continue)
		ports.exec(executable, args, timeout, function(code, stdout, stderr)
			if code ~= 0 then
				return settle(false, reason, detail .. " (" .. NativePath.basename(executable) .. " status "
					.. tostring(code) .. (stderr and stderr ~= "" and (": " .. stderr:gsub("%s+$", "")) or "") .. ")")
			end
			continue(stdout or "")
		end)
	end

	--- Whether a complete payload of this pin is already kept.
	--- @param home string Absolute version folder.
	--- @param pin table Runtime pin.
	--- @return boolean kept
	local function kept(home, pin)
		local receipt = ports.read(home .. "/receipt")
		if type(receipt) ~= "string" or receipt:match("^(%x+)") ~= pin.sha256 then return false end
		for _, product in ipairs(M.PRODUCTS) do
			if ports.exists(home .. "/payload/" .. product) ~= true then return false end
		end
		return true
	end

	--- The kept payload root of a pin, or nil when it is not kept.
	--- @param pin table Runtime pin.
	--- @return string|nil payload Absolute path of the folder holding Runtime/.
	function fetcher.payload_for(pin)
		if not complete_pin(pin) then return nil end
		local home = ports.expand(M.home_for(pin.version))
		if kept(home, pin) then return home .. "/payload" end
		return nil
	end

	--- Makes sure the pinned artifact is downloaded, verified and extracted.
	--- @param pin table The manifest's `runtime` group.
	--- @param callback function fn(ok, payload_or_reason, explanation) called once.
	function fetcher.ensure(pin, callback)
		assert(type(callback) == "function", "Missing artifact fetch callback")
		if not complete_pin(pin) then
			return callback(false, REASON.UNPINNED, "the runtime artifact is not pinned in the manifest")
		end
		if waiters then
			waiters[#waiters + 1] = callback
			return
		end
		waiters = { callback }
		local home = ports.expand(M.home_for(pin.version))
		if kept(home, pin) then
			Logger.info(LOG, "Owned runtime artifact %s already verified; no download.", pin.version)
			return settle(true, home .. "/payload")
		end
		local archive = home .. "/" .. pin.file_name
		local partial = home .. "/." .. pin.file_name .. ".partial"
		local staging = home .. "/.payload-staging"
		Logger.start(LOG, "Fetching the owned runtime artifact %s…", pin.version)
		step("/bin/rm", { "-rf", partial, staging, home .. "/payload", home .. "/receipt" }, M.STEP_TIMEOUT_SEC,
			REASON.STORE, "the artifact folder could not be cleared", function()
		step("/bin/mkdir", { "-p", staging }, M.STEP_TIMEOUT_SEC, REASON.STORE,
			"the artifact folder could not be created", function()
		step("/usr/bin/curl", { "-L", "--fail", "--silent", "--show-error", "--proto", "=https",
			"--max-filesize", tostring(pin.size), "--output", partial, pin.source_url },
			M.DOWNLOAD_TIMEOUT_SEC, REASON.DOWNLOAD, "the artifact could not be downloaded from " .. pin.source_url,
			function()
		step("/usr/bin/stat", { "-f", "%z", partial }, M.STEP_TIMEOUT_SEC, REASON.SIZE,
			"the download size could not be read", function(size)
			if tonumber(size:match("%d+")) ~= pin.size then
				return settle(false, REASON.SIZE, "the download has " .. tostring(size:match("%d+"))
					.. " bytes, the pin says " .. tostring(pin.size))
			end
		step("/usr/bin/shasum", { "-a", "256", partial }, M.STEP_TIMEOUT_SEC, REASON.DIGEST,
			"the download digest could not be computed", function(digest)
			local actual = digest:match("^\\?(%x+)")
			if actual == nil or actual:lower() ~= pin.sha256 then
				return settle(false, REASON.DIGEST, "the download digest " .. tostring(actual)
					.. " is not the pinned " .. pin.sha256)
			end
		step("/usr/bin/tar", { "-tvzf", partial }, M.STEP_TIMEOUT_SEC, REASON.MEMBERS,
			"the artifact could not be listed", function(verbose)
		step("/usr/bin/tar", { "-tzf", partial }, M.STEP_TIMEOUT_SEC, REASON.MEMBERS,
			"the artifact could not be listed", function(names)
			local closed, offending = M.closed_listing(verbose, names)
			if not closed then
				return settle(false, REASON.MEMBERS, "the artifact holds a refused member: " .. tostring(offending))
			end
		step("/usr/bin/tar", { "-xzf", partial, "-C", staging }, M.STEP_TIMEOUT_SEC, REASON.EXTRACT,
			"the artifact could not be extracted", function()
			for _, product in ipairs(M.PRODUCTS) do
				if ports.exists(staging .. "/" .. product) ~= true then
					return settle(false, REASON.EXTRACT, "the extracted payload lacks " .. product)
				end
			end
		step("/bin/mv", { staging, home .. "/payload" }, M.STEP_TIMEOUT_SEC, REASON.STORE,
			"the payload could not be put in place", function()
		step("/bin/mv", { partial, archive }, M.STEP_TIMEOUT_SEC, REASON.STORE,
			"the verified artifact could not be kept", function()
			-- The receipt is written last: without it the payload is never trusted.
			if ports.write(home .. "/receipt", pin.sha256 .. "\n") ~= true then
				return settle(false, REASON.STORE, "the artifact receipt could not be written")
			end
			settle(true, home .. "/payload")
		end) end) end) end) end) end) end) end) end) end)
	end

	return fetcher
end

return M
