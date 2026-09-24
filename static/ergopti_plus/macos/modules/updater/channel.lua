--- modules/updater/channel.lua

--- ==============================================================================
--- MODULE: Update Channel Owner (macOS)
--- DESCRIPTION:
--- The one owner of the update channel the user subscribes to on macOS. It
--- reads and writes config.toml [updater] channel through the menu's
--- preferences transaction, resolves the persisted value through the shared
--- registry, and once a change is durable tells the packaged launcher which
--- Sparkle feed to read, then its subscribers (the menu, the Versions window).
---
--- FEATURES & RATIONALE:
--- 1. One writer: the About menu and the Versions window both call set(), so
---    the two surfaces cannot disagree on the channel.
--- 2. Durable first: subscribers hear of a change only after the preferences
---    transaction committed; a refused save leaves the previous channel live.
--- 3. Explicit ownership: the menu session constructs the owner over its own
---    state and transactional save and hands it to its builders; there is no
---    process-wide singleton for a second menu session to inherit.
--- 4. Registry vocabulary: an alias persisted by hand ("stable") reads as its
---    channel; an unknown value is logged once and the installed build's
---    channel is followed.
--- ==============================================================================

local M = {}

local Logger  = require("infra.logger")
local Updater = require("modules.updater")
local UpdateLauncher = require("adapters.update_launcher")

local LOG = "updater.channel"

-- The flat preference key mapped to config.toml [updater] channel by
-- infra/preferences.lua.
M.STATE_KEY = "update_channel"

--- Creates the channel owner of one menu session.
--- @param opts table { state = table, save = function(): boolean }
--- @return table owner { get, set, subscribe }
function M.new(opts)
	if type(opts) ~= "table" or type(opts.state) ~= "table" or type(opts.save) ~= "function" then
		error("the update channel owner needs the menu state and its transactional save", 2)
	end
	local state, save = opts.state, opts.save
	local listeners = {}
	local warned_values = {}
	local owner = {}

	--- Registers one subscriber under a key; a second registration replaces it.
	--- @param key string Subscriber identity.
	--- @param fn function Receives the new channel id after a durable change.
	function owner.subscribe(key, fn)
		if type(key) ~= "string" or key == "" or type(fn) ~= "function" then
			error("an update channel subscriber needs a key and a function", 2)
		end
		for _, entry in ipairs(listeners) do
			if entry.key == key then
				entry.fn = fn
				return
			end
		end
		listeners[#listeners + 1] = { key = key, fn = fn }
	end

	--- Returns the subscribed channel: the persisted one, else the installed build's.
	--- @return string id Registry channel id.
	function owner.get()
		local persisted = state[M.STATE_KEY]
		if persisted ~= nil then
			local id = Updater.channels().resolve(persisted)
			if id then return id end
			if not warned_values[tostring(persisted)] then
				warned_values[tostring(persisted)] = true
				Logger.warn(LOG, "config.toml names an unknown update channel '%s'; following the installed channel.",
					tostring(persisted))
			end
		end
		return Updater.installed_channel()
	end

	--- Subscribes to one channel of the registry and persists the choice. A
	--- choice equal to the default is still written: the user picked it.
	--- @param id any Channel id (exact; aliases are resolved only when reading).
	--- @return boolean committed True once the channel is durable and published.
	function owner.set(id)
		if type(id) ~= "string" or Updater.channels().channel(id) == nil then
			Logger.error(LOG, "Update channel change refused: '%s' is not a registry channel.", tostring(id))
			return false
		end
		if state[M.STATE_KEY] == id then return true end
		local previous = state[M.STATE_KEY]
		state[M.STATE_KEY] = id
		local ok, committed = pcall(save)
		if not ok or committed ~= true then
			-- The transaction restores the state on refusal; a raised save is
			-- restored here so the live value never claims an uncommitted channel.
			if state[M.STATE_KEY] == id then state[M.STATE_KEY] = previous end
			Logger.error(LOG, "Update channel '%s' could not be saved; keeping '%s' (%s).", id, owner.get(),
				ok and "save refused" or tostring(committed))
			return false
		end
		Logger.info(LOG, "Update channel set to '%s'.", id)
		-- Sparkle's checks read the launcher's selection; a source run has no
		-- launcher to tell.
		if not Updater.is_local_source() then UpdateLauncher.select_channel(id) end
		for _, entry in ipairs(listeners) do
			local notified, err = pcall(entry.fn, id)
			if not notified then
				Logger.error(LOG, "Update channel subscriber '%s' raised: %s.", entry.key, tostring(err))
			end
		end
		return true
	end

	return owner
end

return M
