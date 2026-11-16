--- adapters/runtime_owner_ports.lua

--- ==============================================================================
--- MODULE: Owned Runtime Ports (Hammerspoon)
--- DESCRIPTION:
--- The real Mac side of platform/remap/runtime_owner.lua: file existence,
--- read-only launchd and system extension queries, the detection and the consented
--- closing of another Karabiner, the pinned artifact, the physical capture and a
--- timer. Only required when the user opts in to the owned runtime.
---
--- FEATURES & RATIONALE:
--- 1. Read-Only Observation: launchd is only ever asked to print a job and the
---    system extension tool only to list; the privileged jobs belong to the
---    installer.
--- 2. One Place Acts On Stock Karabiner: coexistence is adapters/karabiner_coexistence.lua,
---    which runs Karabiner's own quit steps and only when the owner holds the
---    user's consent.
--- 3. No Process Here: the Console is owned by the launcher's installed-source
---    role behind the capture port, so this module spawns nothing.
--- 4. Artifact From The Manifest: the pinned artifact is whatever
---    vendor/remap-runtime/manifest.json pins completely; an unpinned manifest is a
---    named refusal, never a guessed driver version.
--- 5. One Command Runner: bounded commands reuse the field check's runner.
--- 6. Fetched Into Ergopti's Folder: the first admission downloads and verifies
---    the pinned artifact through platform/remap/runtime_artifact_fetch.lua,
---    then every later one reuses that copy without the network.
--- 7. Driver-Only Update On Request: the pinned VirtualHIDDevice replaces an
---    incompatible one only through platform/remap/runtime_vhid_update.lua,
---    which the Tap-Holds row starts after the user's confirmation.
--- 8. First Install On Request: the runtime is installed only through
---    platform/remap/runtime_install.lua, which the « not installed » row
---    starts after the user's confirmation.
--- ==============================================================================

local M = {}

local FileSystem = require("core.fs.adapters.file_system")
local FieldCheckPorts = require("adapters.field_check_ports")
local NativePath = require("core.fs.engine.native_path")

-- Seconds an observation may take before it is a failure rather than an answer.
local COMMAND_TIMEOUT = 5
-- launchctl's exit status for a service that is not loaded.
local UNKNOWN_SERVICE_STATUS = 113

-- The runtime manifest, relative to this module's directory.
local MANIFEST_RELATIVE = "../vendor/remap-runtime/manifest.lua"

--- Reads the shipped runtime manifest.
--- @return table|nil manifest Nil when it cannot be read.
local function load_manifest()
	local directory = NativePath.directory_prefix(debug.getinfo(1, "S").source:sub(2)) or "./"
	local loaded, manifest = pcall(dofile, directory .. MANIFEST_RELATIVE)
	if not loaded or type(manifest) ~= "table" then return nil end
	return manifest
end

--- Reads and judges the shipped runtime manifest.
--- @return table|nil pinned The owner's pinned facts.
--- @return string|nil reason Why there are none.
local function pinned_artifact()
	local manifest = load_manifest()
	if not manifest then return nil, "the runtime manifest could not be read" end
	return require("platform.remap.runtime_manifest").pinned(manifest)
end

--- How many pin fields of the shipped runtime manifest are still unpinned.
--- @return integer|nil count Nil when the manifest cannot be read.
function M.unpinned_count()
	local manifest = load_manifest()
	if not manifest then return nil end
	return #require("platform.remap.runtime_manifest").unpinned(manifest)
end

--- The VirtualHIDDevice package version the shipped manifest pins.
--- @return string|nil version Nil when unreadable or not pinned.
function M.virtual_hid_version()
	local manifest = load_manifest()
	if not manifest then return nil end
	return require("platform.remap.runtime_manifest").virtual_hid_version(manifest)
end

--- The driver extension version the pinned package installs, the one the
--- system extension listing reports and runtime_vhid.assess compares.
--- @return string|nil version Nil when unreadable or not pinned.
function M.virtual_hid_extension_version()
	local manifest = load_manifest()
	if not manifest then return nil end
	return require("platform.remap.runtime_manifest").virtual_hid_extension_version(manifest)
end

--- Whether the pinned artifact was downloaded and verified: its receipt names
--- the pinned digest (the same test as OwnedRuntimeDownloadedHelper.swift).
--- @return string state `fetched:<version>`, `absent`, `mismatch` or `unpinned`.
function M.artifact_receipt_state()
	local manifest = load_manifest()
	local runtime = manifest and manifest.runtime
	if type(runtime) ~= "table" or type(runtime.version) ~= "string" or type(runtime.sha256) ~= "string" then
		return "unpinned"
	end
	local receipt = FileSystem.expand_path(require("platform.remap.ke_paths").OWNED.ARTIFACT_HOME
		.. "/" .. runtime.version .. "/receipt")
	if FileSystem.exists(receipt) ~= true then return "absent" end
	return FileSystem.read(receipt) == runtime.sha256 .. "\n" and ("fetched:" .. runtime.version) or "mismatch"
end

local fetcher

--- Downloads and verifies the pinned artifact the first time, then reuses it.
--- One fetcher serves admission and the field run, so they share one fetch.
--- @param callback function fn(ok, payload|reason, explanation).
function M.fetch_artifact(callback)
	local manifest = load_manifest()
	if not manifest then
		return callback(false, "artifact_unpinned", "the runtime manifest could not be read")
	end
	fetcher = fetcher or require("platform.remap.runtime_artifact_fetch").new({
		exec = FieldCheckPorts.exec,
		network_command = function(curl_args)
			return require("platform.remap.network_download").command("REMAP-RUNTIME", curl_args)
		end,
		exists = FileSystem.exists,
		read = FileSystem.read,
		write = function(path, content) return FileSystem.write(path, content) == true end,
		expand = FileSystem.expand_path,
	})
	fetcher.ensure(manifest.runtime, callback)
end

local vhid_updater

--- Replaces the installed VirtualHIDDevice with the pinned driver, once the
--- user confirmed it (platform/remap/runtime_vhid_update.lua).
--- @param callback function fn(ok, reason|nil, explanation|nil).
function M.update_virtual_hid(callback)
	local Update = require("platform.remap.runtime_vhid_update")
	local manifest = load_manifest()
	if not manifest then
		return callback(false, Update.REASON.UNPINNED, "the runtime manifest could not be read")
	end
	vhid_updater = vhid_updater or Update.new({
		exec = FieldCheckPorts.exec,
		expand = FileSystem.expand_path,
	})
	vhid_updater.update(manifest.virtual_hid_device, callback)
end

local runtime_installer

--- The one owned runtime installer, created on first use.
--- @return table installer { install, repair } (platform/remap/runtime_install.lua).
local function installer()
	runtime_installer = runtime_installer or require("platform.remap.runtime_install").new({
		launcher = function() return require("platform.remap.lease_helper").resolve() end,
		exec = FieldCheckPorts.exec,
		exists = FileSystem.exists,
		fetch_driver = function(fetched)
			local Update = require("platform.remap.runtime_vhid_update")
			local manifest = load_manifest()
			if not manifest then return fetched(false, Update.REASON.UNPINNED, "the runtime manifest could not be read") end
			vhid_updater = vhid_updater or Update.new({ exec = FieldCheckPorts.exec, expand = FileSystem.expand_path,
				network_command = function(curl_args)
					return require("platform.remap.network_download").command("VIRTUAL-HID", curl_args)
				end })
			vhid_updater.fetch(manifest.virtual_hid_device, fetched)
		end,
	})
	return runtime_installer
end

--- Installs the owned runtime through the signed launcher's install role, once
--- the user confirmed it (platform/remap/runtime_install.lua).
--- @param callback function fn(ok, reason|nil, detail|nil).
function M.install_runtime(callback)
	installer().install(callback)
end

--- Repairs the service of an already installed owned runtime through the
--- signed launcher's repair role, once the user confirmed it (MRT-004).
--- @param callback function fn(ok, reason|nil, detail|nil).
function M.repair_runtime(callback)
	installer().repair(callback)
end

--- The persisted record that Ergopti closed the user's own Karabiner.
--- @return table marker { get, set, clear }.
function M.marker()
	local path = FileSystem.expand_path(require("platform.remap.ke_paths").OWNED.CLOSED_OTHER_MARKER)
	return {
		get = function() return FileSystem.exists(path) == true end,
		set = function()
			return FileSystem.prepare_parent_for_create(path) == true and FileSystem.write(path, "closed\n") == true
		end,
		clear = function() return FileSystem.delete(path) == true end,
	}
end

--- Tells the user that Ergopti closed their Karabiner and when it comes back.
local function announce_closed()
	local i18n = require("core.i18n.engine.i18n")
	require("core.ui.engine.notifications").notify(i18n.get("notify.karabiner.user_closed"), nil, "info")
end

--- Builds the owner's state observer: the first block of a launch the user can
--- act on (runtime_owner.lua USER_BLOCKS) raises one notice; the Tap-Holds menu
--- says which one. Without it an owned boot with the runtime missing
--- or a user Karabiner left running had the tap-holds off silently, since the
--- official-application wizard no longer runs and the explanation sits in a submenu.
--- @param notify function fn(text) showing a notice.
--- @return function observer fn(state, reason).
function M.block_notice(notify)
	assert(type(notify) == "function", "Missing notifier")
	local shown = false
	local blocks = require("platform.remap.runtime_owner").USER_BLOCKS
	return function(state, reason)
		if shown or (state ~= "unavailable" and state ~= "failed") or not blocks[reason] then return end
		shown = true
		notify(require("core.i18n.engine.i18n").get("notify.karabiner.owned_blocked"))
	end
end

local approval_watch

--- The one approval watch of this launch (platform/remap/runtime_approval_watch.lua).
--- @return table watch
local function approval()
	approval_watch = approval_watch or require("platform.remap.runtime_approval_watch").new({
		listing = function(callback)
			FieldCheckPorts.exec("/usr/bin/systemextensionsctl", { "list" }, COMMAND_TIMEOUT, function(code, output)
				callback(code == 0 and output or nil)
			end)
		end,
		now = function() return hs.timer.absoluteTime() / 1e9 end,
		after = function(seconds, fn) return require("core.events.timer_scheduler").after(seconds, fn) end,
		cancel = function(handle) return require("core.events.timer_scheduler").cancel(handle) end,
		open_settings = function(url) return hs.urlevent.openURL(url) end,
		reload = function() hs.reload() end,
		version = M.virtual_hid_extension_version,
	})
	return approval_watch
end

--- Builds the owner's state observer with the automatic steps of the first
--- install (WP8): a missing runtime offers the install once by itself (one
--- confirmation, then the macOS administrator prompt), and a driver waiting
--- for approval opens its System Settings pane and reloads once it is allowed.
--- Every other block keeps the one notice of M.block_notice.
--- @param notify function fn(text) showing a notice.
--- @return function observer fn(state, reason).
function M.automatic_observer(notify)
	local notice = M.block_notice(notify)
	local offered = false
	-- A field run drives the install itself (infra/field_check_owned_activation.lua
	-- install): a modal offer would hold the run, and the watch's reload would cut it.
	local field_run = os.getenv(require("core.text.engine.identifiers").field_report.environment) ~= nil
		or require("core.lifecycle.engine.dev_source").is_active()
	return function(state, reason)
		if field_run then return notice(state, reason) end
		if state == "unavailable" and not offered
			and require("platform.remap").OWNED_INSTALL_REASONS[reason] == true then
			offered = true
			local committed = require("core.timing.engine.deferred_work").after(0, function()
				require("ai.ui.owned_runtime_install").open(require("platform.remap"))
			end, "owned_runtime_install.offer")
			if committed == true then return end
		elseif state == "unavailable" and reason == require("platform.remap.runtime_vhid").REASON_NOT_ACTIVE then
			approval().start()
		end
		notice(state, reason)
	end
end

--- The ports of the activation rule (platform/remap/runtime_activation.lua).
--- @param owner table The bound runtime owner module.
--- @param close_other_instances function fn() -> boolean, the user's consent.
--- @param reload function fn() asking for a driver reload.
--- @return table ports
function M.activation(owner, close_other_instances, reload)
	return {
		owner = owner,
		close_other_instances = close_other_instances,
		restore = require("adapters.karabiner_coexistence").new().restore,
		marker = M.marker(),
		reload = reload,
	}
end

--- The ports of the real Mac.
--- @return table ports For platform.remap.runtime_owner.init.
function M.new()
	local exec = FieldCheckPorts.exec
	local Coexistence = require("adapters.karabiner_coexistence").new()
	return {
		fs = {
			exists = FileSystem.exists,
			expand = FileSystem.expand_path,
		},
		launchd = {
			loaded = function(label, callback)
				exec("/bin/launchctl", { "print", "system/" .. label }, COMMAND_TIMEOUT, function(code)
					if code == 0 then return callback(true) end
					if code == UNKNOWN_SERVICE_STATUS then return callback(false) end
					callback(nil)
				end)
			end,
		},
		system_extensions = {
			listing = function(callback)
				exec("/usr/bin/systemextensionsctl", { "list" }, COMMAND_TIMEOUT, function(code, output)
					callback(code == 0 and output or nil)
				end)
			end,
		},
		coexistence = {
			detect = Coexistence.detect,
			close = require("platform.remap.runtime_activation").remembering_close(Coexistence.close, M.marker(),
				announce_closed),
		},
		artifact = {
			pinned = pinned_artifact,
			fetch = M.fetch_artifact,
		},
		capture = require("adapters.runtime_capture_port").new(),
		timer = require("core.events.timer_scheduler"),
		observer = M.automatic_observer(function(text)
			require("core.ui.engine.notifications").notify(text, nil, "warning")
		end),
	}
end

return M
