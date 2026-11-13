--- modules/keymap/pending_layout_activation.lua

--- ==============================================================================
--- MODULE: Pending Layout Activation (macOS)
--- DESCRIPTION:
--- Remembers the installed layouts macOS has not turned on yet: the fallback
--- of the install. Writing the enabled input-source preference normally turns
--- a layout on at once, as a fresh process sees it (probe v5, P5); when that
--- fresh read still finds it off, the install reports « pending », and at the
--- next boot of the driver (after a login, P10) this module checks whether
--- macOS turned the layout on and, when the user asked to use it, selects it.
---
--- FEATURES & RATIONALE:
--- 1. Honest states: a pending layout is never called enabled. At boot each one
---    is either confirmed on (and forgotten) or logged as still off, with the
---    time it was installed, so a logout that did not help is visible.
--- 2. Explicit ownership: init() takes every collaborator once and refuses a
---    second call; every other entry point refuses to run before it.
--- 3. Stored as one JSON record in the driver's settings, so it survives a
---    reload, a logout and a reboot.
--- ==============================================================================

local Logger = require("infra.logger")
local TableUtil = require("core.text.engine.table_util")

local M = {}

local LOG = "keymap.pending_layout_activation"

--- Logical settings key of the pending record.
M.STORAGE_KEY = "pending_layout_activation"

-- The collaborators init() received; nil until then.
local _deps = nil
local _revisions = {}
local _selecting = {}

local function changed(id)
	_revisions[id] = (_revisions[id] or 0) + 1
end

--- Refuses a call before init().
--- @param name string Entry point name.
local function require_init(name)
	if _deps == nil then error("pending_layout_activation." .. name .. " called before init()", 3) end
end

--- Whether a timestamp can be rendered by this host's UTC date formatter.
--- @param value any Candidate Unix timestamp.
--- @return boolean valid
local function valid_timestamp(value)
	if type(value) ~= "number" or value ~= value or value % 1 ~= 0 then return false end
	local ok, rendered = pcall(os.date, "!%Y-%m-%dT%H:%M:%SZ", value)
	return ok and type(rendered) == "string"
end

--- The stored entries, keyed by layout id: { keyboard_name, select, recorded_at }.
--- @return table|nil entries
--- @return string|nil error
local function read_entries()
	local read_ok, raw = _deps.storage.read_exact(M.STORAGE_KEY)
	if read_ok ~= true then return nil, "the stored record could not be read" end
	if raw == nil then return {}, nil end
	if type(raw) ~= "string" then return nil, "the stored record is not a JSON string" end
	local ok, decoded = pcall(_deps.decode_json, raw)
	if not ok or type(decoded) ~= "table" or decoded.schema ~= 1 or type(decoded.layouts) ~= "table" then
		return nil, "the stored record is not a pending-layout record"
	end
	for id, entry in pairs(decoded.layouts) do
		if type(id) ~= "string" or id == "" or type(entry) ~= "table"
			or type(entry.keyboard_name) ~= "string" or entry.keyboard_name == ""
			or type(entry.select) ~= "boolean" or not valid_timestamp(entry.recorded_at) then
			return nil, "the stored record contains an invalid layout entry"
		end
	end
	return decoded.layouts, nil
end

--- Stores the entries, or removes the record when none is left.
--- @param entries table
--- @return boolean written
local function write_entries(entries)
	local expected = nil
	local written
	if next(entries) == nil then
		written = _deps.storage.delete(M.STORAGE_KEY)
	else
		expected = _deps.encode_json({ schema = 1, layouts = entries })
		if type(expected) ~= "string" then
			Logger.error(LOG, "The pending-layout record could not be encoded.")
			return false
		end
		written = _deps.storage.set(M.STORAGE_KEY, expected)
	end
	local read_ok, actual = _deps.storage.read_exact(M.STORAGE_KEY)
	if written ~= true or read_ok ~= true or actual ~= expected then
		Logger.error(LOG, "The pending-layout record did not reach its requested state.")
		return false
	end
	return true
end

--- Takes the collaborators. Called once, at boot.
--- @param deps table { storage = { read_exact, set, delete }, is_live(keyboard_name) ->
---   boolean|nil, err, select(id, on_done(ok, code, detail)), encode_json,
---   decode_json, now() -> number, reason (the closed reason a layout still off
---   is logged with) }.
function M.init(deps)
	if _deps ~= nil then error("pending_layout_activation.init called twice", 2) end
	assert(type(deps) == "table", "pending_layout_activation.init needs its collaborators")
	assert(type(deps.storage) == "table" and type(deps.storage.read_exact) == "function"
		and type(deps.storage.set) == "function" and type(deps.storage.delete) == "function",
		"pending_layout_activation.init needs storage read_exact, set and delete")
	for _, name in ipairs({ "is_live", "select", "encode_json", "decode_json", "now" }) do
		assert(type(deps[name]) == "function", "pending_layout_activation.init needs " .. name)
	end
	assert(type(deps.reason) == "string" and deps.reason ~= "", "pending_layout_activation.init needs the reason it logs")
	_deps = deps
	Logger.debug(LOG, "Pending layout activation initialized.")
end

--- Whether init() ran.
--- @return boolean
function M.is_initialized() return _deps ~= nil end

--- Records a layout the preference lists but macOS has not turned on.
--- @param id string Layout id.
--- @param keyboard_name string Its KeyboardLayout Name.
--- @return boolean recorded
function M.record(id, keyboard_name)
	require_init("record")
	if type(id) ~= "string" or id == "" or type(keyboard_name) ~= "string" or keyboard_name == "" then
		Logger.error(LOG, "Cannot record a pending layout with an invalid identity.")
		return false
	end
	local entries, err = read_entries()
	if not entries then
		Logger.error(LOG, "The '%s' layout could not be recorded as pending: %s.", tostring(id), tostring(err))
		return false
	end
	local previous = entries[id]
	local recorded_at = _deps.now()
	if not valid_timestamp(recorded_at) then
		Logger.error(LOG, "Cannot record a pending layout with an invalid timestamp.")
		return false
	end
	entries[id] = {
		keyboard_name = keyboard_name,
		select = previous ~= nil and previous.select == true,
		recorded_at = recorded_at,
	}
	-- Fence an earlier selection before storage can re-enter or return an
	-- unreadable receipt: the write may have committed even when proof failed.
	changed(id)
	local written = write_entries(entries)
	if written then
		Logger.info(LOG, "The '%s' layout waits for the next login: macOS turns it on then.", tostring(id))
	end
	return written
end

--- Asks for a pending layout to be selected once macOS turns it on.
--- @param id string Layout id, already recorded.
--- @return boolean recorded
function M.request_select(id)
	require_init("request_select")
	local entries, err = read_entries()
	if not entries or entries[id] == nil then
		Logger.error(LOG, "Cannot select the '%s' layout after the login: %s.", tostring(id),
			tostring(err or "it is not pending"))
		return false
	end
	entries[id].select = true
	changed(id)
	local written = write_entries(entries)
	if written then
		Logger.info(LOG, "The '%s' layout will be selected after the next login.", tostring(id))
	end
	return written
end

--- Forgets a layout (uninstalled, or turned on).
--- @param id string Layout id.
--- @return boolean forgotten True also when it was not pending.
function M.forget(id)
	require_init("forget")
	local entries, err = read_entries()
	if not entries then
		Logger.error(LOG, "The '%s' layout could not be forgotten: %s.", tostring(id), tostring(err))
		return false
	end
	if entries[id] == nil then return true end
	entries[id] = nil
	changed(id)
	local written = write_entries(entries)
	if written then
		Logger.debug(LOG, "The '%s' layout is no longer pending.", tostring(id))
	end
	return written
end

--- The pending entry of a layout, or nil.
--- @param id string Layout id.
--- @return table|nil entry
function M.pending(id)
	require_init("pending")
	local entries = read_entries()
	return entries and entries[id] or nil
end

--- Retains the durable request until its exact asynchronous selection settles.
--- @param id string Layout id.
local function select_pending(id)
	if _selecting[id] then return end
	local revision = _revisions[id] or 0
	local owner = {}
	_selecting[id] = owner
	local started, start_error = pcall(_deps.select, id, function(ok, code, detail)
		if _selecting[id] ~= owner then return end
		_selecting[id] = nil
		if ok then
			if (_revisions[id] or 0) == revision then M.forget(id) end
			Logger.info(LOG, "Selected the '%s' layout, as asked before the login.", id)
		else
			Logger.warn(LOG, "The '%s' layout is on but could not be selected (%s): %s.", id,
				tostring(code), tostring(detail))
		end
	end)
	if not started or start_error == false then
		if _selecting[id] == owner then _selecting[id] = nil end
		Logger.error(LOG, "Selection of the '%s' layout could not start: %s.", id, tostring(start_error))
	end
end

--- At boot: confirms each pending layout macOS turned on (selecting it when
--- asked) and logs each one still off.
--- @return table summary { confirmed = n, waiting = n, unreadable = n }.
function M.resume()
	require_init("resume")
	local summary = { confirmed = 0, waiting = 0, unreadable = 0 }
	local entries, err = read_entries()
	if not entries then
		Logger.error(LOG, "The pending layouts cannot be read: %s.", tostring(err))
		summary.unreadable = 1
		return summary
	end
	for _, id in ipairs(TableUtil.sorted_keys(entries)) do
		local entry = entries[id]
		local live, live_err = _deps.is_live(entry.keyboard_name)
		if live == nil then
			Logger.error(LOG, "Whether macOS turned on the '%s' layout cannot be read: %s.", id, tostring(live_err))
			summary.unreadable = summary.unreadable + 1
		elseif live then
			summary.confirmed = summary.confirmed + 1
			Logger.info(LOG, "macOS turned on the '%s' layout installed at %s.", id, os.date("!%Y-%m-%dT%H:%M:%SZ",
				tonumber(entry.recorded_at) or 0))
			if entry.select == true then
				select_pending(id)
			else
				M.forget(id)
			end
		else
			summary.waiting = summary.waiting + 1
			Logger.warn(LOG, "macOS has not turned on the '%s' layout installed at %s (reason=not_enabled:%s); it is checked again at the next boot.",
				id, os.date("!%Y-%m-%dT%H:%M:%SZ", tonumber(entry.recorded_at) or 0), _deps.reason)
		end
	end
	return summary
end

--- The production collaborators.
--- @return table deps
function M.production_deps()
	local Json = require("core.text.engine.json")
	local Storage = require("adapters.storage")
	return {
		storage = { read_exact = Storage.read_exact, set = Storage.set, delete = Storage.delete },
		is_live = function(keyboard_name)
			return require("modules.keymap.input_sources").is_live_enabled(keyboard_name)
		end,
		select = function(id, on_done) return require("modules.keymap.layout_registry").select(id, on_done) end,
		reason = require("modules.keymap.layout_registry").REASON_REQUIRES_LOGOUT,
		encode_json = Json.encode,
		decode_json = Json.decode,
		now = os.time,
	}
end

--- Test seam: forgets the collaborators.
function M._reset() _deps = nil; _revisions = {}; _selecting = {} end

return M
