--- platform/remap/runtime_vhid_update.lua

--- ==============================================================================
--- MODULE: Owned Runtime VirtualHIDDevice Driver-Only Update
--- DESCRIPTION:
--- Replaces the one Karabiner-DriverKit-VirtualHIDDevice installed on this Mac
--- with the version the owned runtime is built against (ADR 011, "driver-only
--- update"), after the user confirmed it. Only the driver changes: no
--- Karabiner-Elements application, no configuration and no launchd job of the
--- user's own Karabiner is touched.
---
--- FEATURES & RATIONALE:
--- 1. Pinned Or Nothing: the package is the `virtual_hid_device` group of the
---    runtime manifest (pqrs' signed release, its URL, size and SHA-256). An
---    incomplete group is the named refusal `vhid_update_unpinned`.
--- 2. Verified Twice: the download must have the pinned size and digest before
---    the administrator prompt appears, and the privileged shell checks the
---    digest and the pqrs Developer ID Installer signature again on its own
---    root-owned copy, so a file swapped in the user's folder after the first
---    check never reaches /usr/sbin/installer.
--- 3. Then Activation: installing a DriverKit package only stages it; pqrs'
---    manager asks macOS to replace the active extension, which macOS may hold
---    until the user allows it in System Settings. That last state is the
---    existing `virtual_hid_not_active` block, not a failure of this update.
--- 4. Named Refusals: every step that can fail has its own reason, and a
---    cancelled administrator prompt is `vhid_update_cancelled`, not an error.
--- 5. One Update At A Time: callers that ask while an update runs wait for it.
--- 6. Ports Only: every effect goes through the ports given to `new`.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local KePaths = require("platform.remap.ke_paths")
local Fetch = require("platform.remap.runtime_artifact_fetch")
local NativePath = require("core.fs.engine.native_path")
local text_utils = require("core.text.engine.utils")

local LOG = "remap.runtime_vhid_update"

-- The download and local-step deadlines are the owned runtime fetch's own:
-- both pull a pinned archive of the same kind through the same steps.
local DOWNLOAD_TIMEOUT_SEC = Fetch.DOWNLOAD_TIMEOUT_SEC
local STEP_TIMEOUT_SEC = Fetch.STEP_TIMEOUT_SEC
--- Seconds the administrator prompt and the installer may take together.
M.INSTALL_TIMEOUT_SEC = 900

--- The manager pqrs' package installs; `forceActivate` replaces the active
--- driver even when another version holds the slot.
M.MANAGER = "/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"

--- Exit statuses of the privileged shell's own checks.
M.EXIT_DIGEST = 78
M.EXIT_SIGNATURE = 79

-- AppleScript's error number for a prompt the user cancelled.
local USER_CANCELLED = -128

--- Stable reasons of a refused update.
M.REASON = {
	UNPINNED = "vhid_update_unpinned",
	STORE = "vhid_update_store_failed",
	DOWNLOAD = "vhid_update_download_failed",
	SIZE = "vhid_update_size_mismatch",
	DIGEST = "vhid_update_digest_mismatch",
	SIGNATURE = "vhid_update_signature_refused",
	CANCELLED = "vhid_update_cancelled",
	INSTALL = "vhid_update_install_failed",
	ACTIVATE = "vhid_update_activation_failed",
	-- The facade refused to start: no incompatible driver blocks the owned runtime.
	NOT_OFFERED = "vhid_update_not_offered",
}
local REASON = M.REASON





-- ===================================
-- ===================================
-- ======= 1/ Pin And Commands =======
-- ===================================
-- ===================================

--- Checks the `virtual_hid_device` group of a manifest.
--- @param pin any Candidate group.
--- @return boolean complete
function M.complete_pin(pin)
	if type(pin) ~= "table" then return false end
	return type(pin.version) == "string" and pin.version:match("^%d+%.%d+%.%d+$") ~= nil
		and type(pin.team_identifier) == "string" and pin.team_identifier:match("^%u[%u%d]+$") ~= nil
		and #pin.team_identifier == 10
		and type(pin.file_name) == "string" and pin.file_name:match("^[%w][%w%._%-]*%.pkg$") ~= nil
		and type(pin.source_url) == "string"
		and pin.source_url:match("^https://[^%s'\"\\]+/" .. pin.file_name:gsub("%p", "%%%0") .. "$") ~= nil
		and type(pin.sha256) == "string" and #pin.sha256 == 64 and pin.sha256:match("^%x+$") ~= nil
		and pin.sha256 == pin.sha256:lower()
		and math.type(pin.size) == "integer" and pin.size >= 1
end

--- The folder a driver version is downloaded to, as a tilde path.
--- @param version string Pinned driver version.
--- @return string path
function M.home_for(version)
	return KePaths.OWNED.ARTIFACT_HOME .. "/VirtualHIDDevice/" .. version
end

--- The shell the administrator prompt runs. It copies the package into a
--- root-owned folder, checks the pinned digest and pqrs' installer signature
--- on that copy, and only then installs it.
--- @param package_path string Absolute path of the verified download.
--- @param pin table Complete `virtual_hid_device` group.
--- @return string script One line of /bin/sh.
function M.root_script(package_path, pin)
	assert(M.complete_pin(pin), "a complete VirtualHIDDevice pin is required")
	assert(type(package_path) == "string" and package_path:sub(1, 1) == "/", "an absolute package path is required")
	local copy = '"$work/driver.pkg"'
	return table.concat({
		"set -eu",
		"work=$(/usr/bin/mktemp -d /private/tmp/ergoptiplus-vhid.XXXXXX)",
		"trap '/bin/rm -rf \"$work\"' EXIT",
		"/bin/cp -X " .. text_utils.shell_quote(package_path) .. " " .. copy,
		"digest=$(/usr/bin/shasum -a 256 " .. copy .. " | /usr/bin/cut -d' ' -f1)",
		"[ \"$digest\" = " .. pin.sha256 .. " ] || exit " .. M.EXIT_DIGEST,
		"signature=$(/usr/sbin/pkgutil --check-signature " .. copy .. ") || exit " .. M.EXIT_SIGNATURE,
		"printf '%s\\n' \"$signature\" | /usr/bin/grep -q '^ *Status: signed by a developer certificate issued by Apple'"
			.. " || exit " .. M.EXIT_SIGNATURE,
		"printf '%s\\n' \"$signature\" | /usr/bin/grep -Eq '^ *1\\. Developer ID Installer: .*\\("
			.. pin.team_identifier .. "\\)$' || exit " .. M.EXIT_SIGNATURE,
		"/usr/sbin/installer -pkg " .. copy .. " -target /",
	}, "; ")
end

--- The osascript arguments that run the root script behind the native
--- administrator prompt.
--- @param package_path string Absolute path of the verified download.
--- @param pin table Complete `virtual_hid_device` group.
--- @return table args
function M.install_args(package_path, pin)
	return { "-e", text_utils.applescript_format('do shell script "%s" with administrator privileges',
		M.root_script(package_path, pin)) }
end

--- Reads the status osascript reports for a failed `do shell script`: its
--- error message ends with the number in parentheses.
--- @param stderr any osascript's standard error.
--- @return integer|nil status
function M.script_status(stderr)
	if type(stderr) ~= "string" then return nil end
	local status = stderr:match("%((%-?%d+)%)%s*$")
	return status and math.tointeger(tonumber(status)) or nil
end

--- Names a failed privileged install.
--- @param stderr any osascript's standard error.
--- @return string reason
function M.install_reason(stderr)
	local status = M.script_status(stderr)
	if status == USER_CANCELLED then return REASON.CANCELLED end
	if status == M.EXIT_DIGEST then return REASON.DIGEST end
	if status == M.EXIT_SIGNATURE then return REASON.SIGNATURE end
	return REASON.INSTALL
end





-- =============================
-- =============================
-- ======= 2/ Update Run =======
-- =============================
-- =============================

--- Creates an updater bound to its ports.
--- Port contracts:
---   exec(executable, args, timeout, fn(code|nil, stdout, stderr)) runs one command;
---   expand(path) -> absolute path;
---   network_command(curl_args) -> executable, args, describe(code, stderr) | nil, err
---     wraps the download behind the system network route (NET-001).
--- @param ports table exec, expand, network_command.
--- @return table updater { update }.
function M.new(ports)
	assert(type(ports) == "table", "Missing VirtualHIDDevice update ports")
	for _, name in ipairs({ "exec", "expand", "network_command" }) do
		assert(type(ports[name]) == "function", "Missing VirtualHIDDevice update port: " .. name)
	end
	local updater = {}
	local waiters

	--- Settles every waiter of the running update once.
	local function settle(ok, reason, detail, kind)
		local pending = waiters
		waiters = nil
		if ok and kind == "fetched" then
			Logger.success(LOG, "VirtualHIDDevice driver downloaded and verified for the first install.")
		elseif ok then
			Logger.success(LOG, "VirtualHIDDevice driver update installed and activation requested.")
		elseif reason == REASON.CANCELLED then
			Logger.info(LOG, "VirtualHIDDevice driver update cancelled at the administrator prompt.")
		else
			Logger.error(LOG, "VirtualHIDDevice driver update refused (%s): %s", tostring(reason), tostring(detail))
		end
		for _, waiter in ipairs(pending or {}) do
			local called, failure = pcall(waiter, ok, reason, detail)
			if not called then Logger.error(LOG, "Driver update callback failed: %s.", tostring(failure)) end
		end
	end

	--- Describes a failed command for the log.
	local function failure(executable, code, stderr)
		return NativePath.basename(executable) .. " status " .. tostring(code)
			.. ((type(stderr) == "string" and stderr ~= "") and (": " .. stderr:gsub("%s+$", "")) or "")
	end

	-- The failure describer of a wrapped command, keyed by its exact argv table.
	local describers = setmetatable({}, { __mode = "k" })

	--- Runs one step and continues only on exit 0.
	local function step(executable, args, timeout, reason, detail, continue)
		local describe = describers[args]
		ports.exec(executable, args, timeout, function(code, stdout, stderr)
			if code ~= 0 then
				local named = describe and describe(code, stderr)
				return settle(false, reason, detail .. " (" .. (named or failure(executable, code, stderr)) .. ")")
			end
			continue(stdout or "")
		end)
	end

	--- Downloads and verifies the pinned driver into Ergopti's folder, then continues.
	--- @param pin table Complete `virtual_hid_device` group.
	--- @param continue function fn(package_path) once the verified package is kept.
	local function download(pin, continue)
		local home = ports.expand(M.home_for(pin.version))
		local package = home .. "/" .. pin.file_name
		local partial = home .. "/." .. pin.file_name .. ".partial"
		step("/bin/rm", { "-f", partial, package }, STEP_TIMEOUT_SEC, REASON.STORE,
			"the driver folder could not be cleared", function()
		step("/bin/mkdir", { "-p", home }, STEP_TIMEOUT_SEC, REASON.STORE,
			"the driver folder could not be created", function()
		-- Behind the system network route, as every remap download (NET-001).
		local download, download_args, describe = ports.network_command({ "-L", "--fail", "--silent",
			"--show-error", "--proto", "=https", "--max-filesize", tostring(pin.size), "--output", partial, pin.source_url })
		if not download then
			return settle(false, REASON.DOWNLOAD, "the network route is unavailable: " .. tostring(download_args))
		end
		describers[download_args] = describe
		step(download, download_args,
			DOWNLOAD_TIMEOUT_SEC, REASON.DOWNLOAD, "the driver could not be downloaded from " .. pin.source_url,
			function()
		step("/usr/bin/stat", { "-f", "%z", partial }, STEP_TIMEOUT_SEC, REASON.SIZE,
			"the download size could not be read", function(size)
			if tonumber(size:match("%d+")) ~= pin.size then
				return settle(false, REASON.SIZE, "the download has " .. tostring(size:match("%d+"))
					.. " bytes, the pin says " .. tostring(pin.size))
			end
		step("/usr/bin/shasum", { "-a", "256", partial }, STEP_TIMEOUT_SEC, REASON.DIGEST,
			"the download digest could not be computed", function(digest)
			local actual = digest:match("^\\?(%x+)")
			if actual == nil or actual:lower() ~= pin.sha256 then
				return settle(false, REASON.DIGEST, "the download digest " .. tostring(actual)
					.. " is not the pinned " .. pin.sha256)
			end
		step("/bin/mv", { partial, package }, STEP_TIMEOUT_SEC, REASON.STORE,
			"the verified driver could not be kept", function()
			continue(package)
		end) end) end) end) end) end)
	end

	--- Starts one run, or queues the callback behind the running one.
	--- @return boolean started False when the pin is incomplete or a run already runs.
	local function begin(pin, callback)
		assert(type(callback) == "function", "Missing driver update callback")
		if not M.complete_pin(pin) then
			callback(false, REASON.UNPINNED, "the VirtualHIDDevice driver is not pinned in the manifest")
			return false
		end
		if waiters then
			waiters[#waiters + 1] = callback
			return false
		end
		waiters = { callback }
		return true
	end

	--- Downloads, verifies, installs and activates the pinned driver.
	--- @param pin table The manifest's `virtual_hid_device` group.
	--- @param callback function fn(ok, reason|nil, explanation|nil) called once.
	function updater.update(pin, callback)
		if not begin(pin, callback) then return end
		Logger.start(LOG, "Updating the VirtualHIDDevice driver to %s on the user's request…", pin.version)
		download(pin, function(package)
		ports.exec("/usr/bin/osascript", M.install_args(package, pin), M.INSTALL_TIMEOUT_SEC,
			function(code, _, stderr)
			if code ~= 0 then
				return settle(false, M.install_reason(stderr),
					"the privileged install did not complete (" .. failure("/usr/bin/osascript", code, stderr) .. ")")
			end
		step(M.MANAGER, { "forceActivate" }, STEP_TIMEOUT_SEC, REASON.ACTIVATE,
			"macOS was not asked to activate the new driver", function()
			settle(true)
		end) end) end)
	end

	--- Downloads and verifies the pinned driver only, for the owned runtime's first
	--- install, whose administrator shell installs it (OwnedRuntimeInstallMainOperation.swift).
	--- @param pin table The manifest's `virtual_hid_device` group.
	--- @param callback function fn(ok, reason|nil, explanation|nil) called once.
	function updater.fetch(pin, callback)
		if not begin(pin, callback) then return end
		Logger.start(LOG, "Downloading the VirtualHIDDevice driver %s for the first install…", pin.version)
		download(pin, function() settle(true, nil, nil, "fetched") end)
	end

	return updater
end

return M
