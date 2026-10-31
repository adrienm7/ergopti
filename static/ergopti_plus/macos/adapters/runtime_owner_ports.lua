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
--- ==============================================================================

local M = {}

local FileSystem = require("adapters.file_system")
local FieldCheckPorts = require("adapters.field_check_ports")
local NativePath = require("native_path")

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

--- The VirtualHIDDevice version the shipped manifest pins.
--- @return string|nil version Nil when unreadable or not pinned.
function M.virtual_hid_version()
	local manifest = load_manifest()
	if not manifest then return nil end
	return require("platform.remap.runtime_manifest").virtual_hid_version(manifest)
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
		exists = FileSystem.exists,
		read = FileSystem.read,
		write = function(path, content) return FileSystem.write(path, content) == true end,
		expand = FileSystem.expand_path,
	})
	fetcher.ensure(manifest.runtime, callback)
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

--- The ports of the activation rule (platform/remap/runtime_activation.lua).
--- @param owner table The bound runtime owner module.
--- @param close_other_instances function fn() -> boolean, the user's consent.
--- @return table ports
function M.activation(owner, close_other_instances)
	return {
		owner = owner,
		restore = require("adapters.karabiner_coexistence").new().restore,
		marker = M.marker(),
		close_other_instances = close_other_instances,
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
			close = require("platform.remap.runtime_activation").remembering_close(Coexistence.close, M.marker()),
		},
		artifact = {
			pinned = pinned_artifact,
			fetch = M.fetch_artifact,
		},
		capture = require("adapters.runtime_capture_port").new(),
		timer = require("adapters.timer_scheduler"),
	}
end

return M
