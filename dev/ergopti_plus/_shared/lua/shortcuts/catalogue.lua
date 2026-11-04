--- _shared/lua/shortcuts/catalogue.lua

--- ==============================================================================
--- MODULE: Shortcut Catalogues (Shared)
--- DESCRIPTION:
--- The parts of the shortcut owners that the macOS and Linux drivers run
--- identically: the number-row tap-key list read from
--- _shared/modules/actions/tap_keys.json with the identity it publishes to the
--- binding registry, and the lookup of the action catalogue that decides which
--- ids a shortcut slot may hold.
---
--- FEATURES & RATIONALE:
--- 1. A factory for the tap-key list: each driver passes how it reads the
---    file, which keycode field its entries must carry, and its owner module,
---    so the validation, the detached identity and the "published only while
---    the source is the acknowledged one" rule exist once.
--- 2. Fail fast: a missing, unreadable or malformed list raises, because the
---    menu would otherwise show no tap key and nothing would say why.
--- 3. The action catalogue is looked up lazily and logged when unavailable, so
---    a caller can keep every stored slot rather than prove one outdated
---    without it.
--- ==============================================================================

local BindingPublication = require("config_binding_publication")
local BindingIdentity = require("config_binding_identity")

local M = {}

-- The binding prefix a tap key dispatches under and stores its parameter under.
M.TAP_BINDING_PREFIX = "tap_key__"

-- The registry owner name and module the tap keys publish under.
M.TAP_OWNER = "tap"
M.TAP_MODULE = "modules.shortcuts.tap_keys"

local ACTION_CATALOGUE_MODULE = "modules.gestures.manager"




-- =============================================
-- =============================================
-- ======= 1/ Tap-key list =====================
-- =============================================
-- =============================================

--- Builds one driver's tap-key list owner.
--- @param ports table {
---   keys_rel_path = string path of the list under _shared/,
---   resolve_path = function(rel) -> string|nil: absolute path of a shared file,
---   read = function(path) -> string: the file text; raises its own error when
---     the file cannot be read completely,
---   decode = function(text) -> table|nil: nil when the text is not valid JSON,
---   valid_entry = function(entry) -> boolean: whether an entry carries its id
---     and this platform's keycodes,
---   invalid_entry_message = string: the reason raised for an invalid entry,
---   owner = table: the driver's tap_keys module, registered by the caller. }
--- @return table list { keys, loaded_keys, published_binding_catalogue, binding_id, reset }
function M.new_tap_keys(ports)
	assert(type(ports) == "table", "a tap-key list needs its ports")
	for _, name in ipairs({ "resolve_path", "read", "decode", "valid_entry" }) do
		assert(type(ports[name]) == "function", "a tap-key list needs the port " .. name)
	end
	assert(type(ports.keys_rel_path) == "string" and type(ports.invalid_entry_message) == "string"
		and type(ports.owner) == "table", "a tap-key list needs its path, entry message and owner")
	local list = {}
	local keys, binding_source, binding_catalogue = nil, nil, nil

	--- The shared key list, read once.
	--- @return table Array of entries.
	function list.keys()
		if keys then return keys end
		local path = ports.resolve_path(ports.keys_rel_path)
		local decoded = ports.decode(ports.read(path))
		if type(decoded) ~= "table" or type(decoded.keys) ~= "table" or #decoded.keys == 0 then
			error("tap_keys: " .. tostring(path) .. " is malformed")
		end
		for _, entry in ipairs(decoded.keys) do
			if not ports.valid_entry(entry) then
				error("tap_keys: an entry of " .. tostring(path) .. " " .. ports.invalid_entry_message)
			end
		end
		-- The identity first: a list it refuses must not stay cached as loaded.
		local identity = BindingIdentity.tap_binding_catalogue(decoded.keys)
		keys, binding_source, binding_catalogue = decoded.keys, decoded.keys, identity
		return keys
	end

	--- Returns only the detached identity of the acknowledged current native
	--- source. A changed source withdraws publication; this accessor performs no IO.
	--- @return table|nil catalogue
	function list.published_binding_catalogue()
		if not BindingPublication.owner_is_current(M.TAP_OWNER, M.TAP_MODULE, ports.owner) then return nil end
		if binding_catalogue == nil or not rawequal(keys, binding_source) then return nil end
		local current = BindingIdentity.tap_binding_catalogue(keys)
		for id in pairs(current.slots) do
			if binding_catalogue.slots[id] ~= true then return nil end
		end
		for id in pairs(binding_catalogue.slots) do
			if current.slots[id] ~= true then return nil end
		end
		return current
	end

	--- The binding a tap key dispatches under.
	--- @param id string
	--- @return string
	function list.binding_id(id)
		return M.TAP_BINDING_PREFIX .. tostring(id)
	end

	--- The list as already loaded, without reading the file; nil before the first
	--- keys(). Dispatch guards compare it by identity to prove the list is unchanged.
	--- @return table|nil
	function list.loaded_keys() return keys end

	--- Forgets the list and its published identity (test seam of the driver).
	function list.reset()
		keys, binding_source, binding_catalogue = nil, nil, nil
	end

	return list
end




-- =============================================
-- =============================================
-- ======= 2/ Action catalogue lookup ==========
-- =============================================
-- =============================================

--- The gestures manager, whose catalogue decides which ids a slot may hold.
--- Required lazily because the daemon loads it after the shortcut owners.
--- @param logger table Central logger.
--- @param log string Log namespace of the caller.
--- @return table|nil manager nil (logged) when its catalogue is unavailable.
function M.action_catalogue(logger, log)
	local ok, Gestures = pcall(require, ACTION_CATALOGUE_MODULE)
	if not ok or type(Gestures) ~= "table" or type(Gestures.is_assignable) ~= "function" then
		logger.error(log, "The action catalogue is unavailable: %s", tostring(Gestures))
		return nil
	end
	return Gestures
end

return M
