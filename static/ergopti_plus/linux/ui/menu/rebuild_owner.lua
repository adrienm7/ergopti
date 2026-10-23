--- ui/menu/rebuild_owner.lua

--- ==============================================================================
--- MODULE: Coalesced Native Tray Publication
--- DESCRIPTION:
--- Retires old action authority on a refresh request and publishes at most one
--- current tree per pump. Native GTK objects and their IDs remain tray-owned.
---
--- FEATURES & RATIONALE:
--- 1. A retired row never runs its own action: its closure captured a context
---    the refresh has already replaced.
--- 2. A click on a retired row is not dropped either. The desktop shell keeps
---    showing the published tree while a refresh is pending (a toggle, a file
---    reload, the Reload row itself), so a click made then is held under its
---    row path and replayed once against the next published tree.
--- 3. The click carries the state it asks for, the opposite of the checkmark
---    the user saw. A replayed row that already shows that state is skipped
---    and logged: running it would toggle the row back.
--- 4. A click on the Reload row that arrives after a reload already ran since
---    the clicked tree was built joins that reload: it is logged and dropped,
---    never replayed as a second reload (macOS and Linux share this rule).
--- 5. A held click whose row the next tree no longer has is logged and
---    reported once with a localized notice; a click dropped at shutdown or
---    past the hold limit is logged. None is ever silent.
--- ==============================================================================

local M = {}

local ClickIntent = require("menu.click_intent")
local Logger = require("logger.shim")

local LOG = "ui.menu.rebuild_owner"

-- Held clicks are a handful at most: the menu closes on every activation.
local MAX_HELD_CLICKS = 8

--- Shows the notice for held clicks the refreshed tree could not match.
--- @return boolean admitted
local function notify_lost()
	local I18n = require("infra.i18n")
	-- A notification, not a menu row: named first so the menu-row census of
	-- ui/menu/ does not read `title = I18n.get(...)` as a row built here.
	local title = I18n.get("menu.reload_replay.lost_title")
	return require("adapters.notifier").send(I18n.get("menu.reload_replay.lost"), {
		title = title, level = "warning",
	})
end

--- Creates a pure-RAM owner; callers pump after physical input admission.
--- @param options table Pinned build, publish, current and optional appearance,
---   error and lost-click notice callbacks.
--- @return table owner
function M.new(options)
	assert(type(options) == "table", "menu rebuild options are required")
	local build, publish, current = options.build, options.publish, options.current
	local appearance, on_error = options.appearance, options.on_error
	local notify = options.notify_lost or notify_lost
	assert(type(build) == "function" and type(publish) == "function"
		and type(current) == "function", "menu rebuild ports are required")
	assert(appearance == nil or type(appearance) == "function", "menu appearance port must be callable")
	assert(on_error == nil or type(on_error) == "function", "menu error port must be callable")
	assert(type(notify) == "function", "menu lost-click notice port must be callable")
	local generation, published, dirty, stopped, pumping = 0, nil, false, false, false
	local published_rows = nil
	local held = {}
	local reloads = 0
	local reported_generation, reported_reason
	local owner = {}

	local function live(epoch)
		if stopped or generation ~= epoch then return false end
		local ok, accepted = pcall(current)
		return ok and accepted == true and not stopped and generation == epoch
	end

	local function report(epoch, reason)
		if reported_generation == epoch and reported_reason == reason then return end
		reported_generation, reported_reason = epoch, reason
		if on_error then pcall(on_error, reason) end
	end

	local replay

	--- Holds a click that reached a retired or not yet acknowledged row.
	--- @param path table Row titles from the root.
	--- @param checked boolean|nil The checkmark the clicked row showed.
	--- @return boolean false The click has not run yet.
	local function hold(path, checked, ...)
		local label = ClickIntent.describe(path)
		local called, accepted = pcall(current)
		if stopped or not called or accepted ~= true then
			Logger.warn(LOG, "Menu click on '%s' dropped: the tray menu is stopped.", label)
			return false
		end
		if #held >= MAX_HELD_CLICKS then
			Logger.warn(LOG, "Menu click on '%s' dropped: %d clicks already wait for the refreshed menu.",
				label, MAX_HELD_CLICKS)
			return false
		end
		held[#held + 1] = { path = path, desired = ClickIntent.desired(checked), args = { n = select("#", ...), ... } }
		Logger.info(LOG, "Menu click on '%s' held while the menu refreshes; it runs on the refreshed menu.", label)
		-- A stale reference to an older row: the successor is already live.
		if not pumping and not dirty and published == generation and live(generation) then replay() end
		return false
	end

	--- Runs each held click once against the acknowledged tree.
	replay = function()
		local lost = {}
		while #held > 0 do
			local epoch = published
			if pumping or dirty or epoch ~= generation or not live(epoch) then break end
			local click = table.remove(held, 1)
			local label = ClickIntent.describe(click.path)
			local row = ClickIntent.find(published_rows, click.path)
			if not row or type(row.fn) ~= "function" then
				lost[#lost + 1] = label
			elseif ClickIntent.already_applied(row, click.desired) then
				Logger.info(LOG, "Held menu click on '%s' skipped: the row is already %s, the state its click asked for.",
					label, click.desired and "checked" or "unchecked")
			else
				Logger.info(LOG, "Held menu click on '%s' replayed on the refreshed menu.", label)
				local ok, err = pcall(row.fn, (table.unpack or unpack)(click.args, 1, click.args.n))
				if not ok then Logger.error(LOG, "Held menu click on '%s' failed: %s.", label, tostring(err)) end
			end
		end
		if #lost > 0 then
			Logger.warn(LOG, "Held menu click(s) on %s not replayed: the refreshed menu has no such row.",
				table.concat(lost, ", "))
			local ok, err = pcall(notify)
			if not ok then Logger.error(LOG, "Lost menu click notice failed: %s.", tostring(err)) end
		end
	end

	--- Copies newly built rows; an old native ID never gains a successor action.
	--- A click on a retired row is held under its title path instead.
	local function bind(items, epoch, ancestors, prefix)
		assert(type(items) == "table" and not ancestors[items], "menu tree must be acyclic")
		ancestors[items] = true
		local rows = {}
		for index, item in ipairs(items) do
			assert(type(item) == "table", "menu rows must be tables")
			local row = {}
			for key, value in pairs(item) do row[key] = value end
			local path = ClickIntent.child_path(prefix, row.title)
			if type(row.menu) == "table" then row.menu = bind(row.menu, epoch, ancestors, path) end
			local action, checked = row.fn, row.checked
			local joins_reload, reloads_seen = row.joins_reload == true, reloads
			if type(action) == "function" then
				row.fn = function(...)
					if pumping or published ~= epoch or not live(epoch) then
						if joins_reload and reloads > reloads_seen then
							Logger.info(LOG, "Menu click on '%s' joined the reload that already ran; no second reload.",
								ClickIntent.describe(path))
							return false
						end
						return hold(path, checked, ...)
					end
					return action(...)
				end
			end
			rows[index] = row
		end
		ancestors[items] = nil
		return rows
	end

	--- Revokes existing callbacks immediately without entering GTK or the builder.
	--- @return boolean accepted Refresh request, never a publication receipt.
	function owner.request()
		if stopped then return false end
		generation, dirty = generation + 1, true
		return true
	end

	--- Publishes one latest generation; refusals remain dirty for the next pump.
	--- Clicks held meanwhile replay once against the acknowledged tree.
	--- @return boolean acknowledged Current menu accepted by the native publisher.
	--- @return string|nil reason Idle, retired generation or contained refusal.
	function owner.pump()
		if stopped then return false, "stopped" end
		if pumping then return false, "busy" end
		if not dirty then return false, "idle" end
		local epoch = generation
		pumping = true
		if not live(epoch) then pumping = false; return false, "retired" end
		local ok, items, state = pcall(build)
		if ok and live(epoch) then ok, items = pcall(bind, items, epoch, {}, {}) end
		if not live(epoch) then pumping = false; return false, "retired" end
		if not ok then
			report(epoch, "build-refused"); pumping = false; return false, "build-refused"
		end
		local called, accepted = pcall(publish, items)
		if not live(epoch) then pumping = false; return false, "retired" end
		if not called or accepted ~= true then
			report(epoch, "publication-refused"); pumping = false; return false, "publication-refused"
		end
		published, published_rows, dirty = epoch, items, false
		if appearance and live(epoch) then
			local applied, result = pcall(appearance, state)
			if not applied or result == false then report(epoch, "appearance-refused") end
		end
		local retained = live(epoch)
		pumping = false
		if not retained then return false, "retired" end
		if #held > 0 then replay() end
		return true
	end

	--- Records that a reload ran, so a Reload click made on an older tree joins it.
	function owner.note_reload()
		reloads = reloads + 1
	end

	--- Permanently retires queued work and every action without touching GTK.
	--- @return boolean acknowledged No resource is acquired by this owner.
	function owner.stop()
		if not stopped then generation = generation + 1 end
		stopped, dirty, published, published_rows = true, false, nil, nil
		for _, click in ipairs(held) do
			Logger.warn(LOG, "Held menu click on '%s' dropped: the tray menu stopped before it could run.",
				ClickIntent.describe(click.path))
		end
		held = {}
		return true
	end

	return owner
end

return M
