--- ui/menu/click_gate.lua

--- ==============================================================================
--- MODULE: Menubar Click Gate
--- DESCRIPTION:
--- Every menubar row runs through this gate, so a click that lands while a
--- reload is in flight or on a stale tree is held, handed to the reloaded
--- menu or resolved on the current tree, never refused or dropped.
---
--- FEATURES & RATIONALE:
--- 1. Reload in flight: the static menu stays clickable through the whole
---    controlled reload (lease fence, input drain, teardown), and every save
---    is refused there (run_exclusive "terminal quiescence was not proved"),
---    so a toggle reached the log only, half applied in RAM. The gate holds
---    the click instead. A completed reload hands the held clicks to its
---    successor through the settings store at teardown; a reload that never
---    happened (refused fence) runs them in place, and one still pending past
---    a bounded wait reports them lost.
--- 2. Requested state: a check-row click asks for the opposite of the
---    checkmark the user saw (menu.click_intent). A late click whose row
---    already shows that state is skipped and logged, as on Windows (replay
---    schema v3), so two clicks, one of them delayed, never cancel out.
--- 3. Stale tree: the cached static menu lags a state change by the refresh
---    coalescing delay, longer when a native push was refused. A click on a
---    dirty tree is resolved on a freshly built one by its row path.
--- 4. A Reload click made while a reload is already in flight joins that reload:
---    it is logged and dropped, never held and replayed by the successor as a
---    second reload (the Linux tray follows the same rule).
--- 5. The successor consumes the hand-off once at boot, rejecting a malformed
---    or expired record, and reports a row it cannot match once with a
---    localized notice.
--- ==============================================================================

local M = {}

local ClickIntent = require("menu.click_intent")
local Logger = require("infra.logger")
local json = require("json")

local LOG = "menu.click_gate"

--- Settings key of the reload hand-off; read once and deleted by the successor.
M.REPLAY_KEY = "menu_reload_replay"

--- Version of the persisted hand-off record.
local REPLAY_SCHEMA = 1

--- A reload replaces the Lua state in seconds. A record older than this was
--- left by a reload that never booted a successor and must not replay later.
local REPLAY_TTL_SEC = 60

-- Held clicks are a handful at most: the menu closes on every activation.
local MAX_HELD_CLICKS = 8

--- How often a held click checks whether the reload went away without
--- replacing this Lua state (a refused or failed lease fence).
local ABORT_POLL_SEC = 0.25

--- Bounded wait for a reload that neither completes nor aborts.
local ABORT_WAIT_SEC = 30





-- ===================================
-- ===================================
-- ======= 1/ Gate Factory ===========
-- ===================================
-- ===================================

--- Creates the gate for one menubar.
--- @param deps table terminal_pending, is_reloading, stale, refresh, current_items,
---   store {get, set, delete}, schedule(sec, fn), notify_lost and now functions.
--- @return table gate
function M.new(deps)
	assert(type(deps) == "table", "click gate dependencies are required")
	for _, name in ipairs({ "terminal_pending", "is_reloading", "stale", "refresh", "current_items",
		"schedule", "notify_lost", "now" }) do
		assert(type(deps[name]) == "function", "click gate port missing: " .. name)
	end
	local store = deps.store
	assert(type(store) == "table" and type(store.get) == "function" and type(store.set) == "function"
		and type(store.delete) == "function", "click gate store port is required")

	local gate = {}
	-- Gate function -> the row action it guards. Weak: a replaced tree is collected.
	local raws = setmetatable({}, { __mode = "k" })
	local held = {}
	local held_since = nil
	local poll_armed = false
	local handed_off = false
	local inherited = nil

	local function pending()
		local ok, result = pcall(deps.terminal_pending)
		if not ok then
			Logger.error(LOG, "Terminal state could not be read: %s; the click is held.", tostring(result))
			return true
		end
		return result == true
	end

	local function report_lost(labels)
		if #labels == 0 then return end
		Logger.warn(LOG, "Menu click(s) on %s not applied: the current menu has no such row.",
			table.concat(labels, ", "))
		local ok, err = pcall(deps.notify_lost)
		if not ok then Logger.error(LOG, "Lost menu click notice failed: %s.", tostring(err)) end
	end

	local function run(label, action, args)
		local ok, err = xpcall(function()
			return action((table.unpack or unpack)(args, 1, args.n))
		end, debug.traceback)
		if not ok then Logger.error(LOG, "Menu action '%s' raised: %s", label, tostring(err)) end
	end

	--- Runs a click on the current tree by its path; returns false when lost.
	local function resolve(click, items, origin)
		local label = ClickIntent.describe(click.path)
		local row = ClickIntent.find(items, click.path)
		local action = row and raws[row.fn]
		if type(action) ~= "function" then return false end
		if ClickIntent.already_applied(row, click.desired) then
			Logger.info(LOG, "%s menu click on '%s' skipped: the row is already %s, the state its click asked for.",
				origin, label, click.desired and "checked" or "unchecked")
			return true
		end
		Logger.info(LOG, "%s menu click on '%s' runs on the current menu.", origin, label)
		run(label, action, click.args)
		return true
	end

	local poll
	local hand

	local function arm_poll()
		if poll_armed then return end
		local ok, committed = pcall(deps.schedule, ABORT_POLL_SEC, poll)
		if ok and committed ~= false then
			poll_armed = true
			return
		end
		Logger.error(LOG, "Held menu clicks cannot wait for the reload: its timer did not commit.")
		local labels = {}
		for _, click in ipairs(held) do labels[#labels + 1] = ClickIntent.describe(click.path) end
		held, held_since = {}, nil
		report_lost(labels)
	end

	--- Releases held clicks once no reload owns the process any more.
	poll = function()
		poll_armed = false
		if #held == 0 then return end
		if pending() then
			if deps.now() - held_since <= ABORT_WAIT_SEC then arm_poll(); return end
			local labels = {}
			for _, click in ipairs(held) do labels[#labels + 1] = ClickIntent.describe(click.path) end
			held, held_since = {}, nil
			Logger.warn(LOG, "The reload is still pending after %d s; %d held menu click(s) dropped.",
				ABORT_WAIT_SEC, #labels)
			report_lost(labels)
			return
		end
		local clicks = held
		held, held_since = {}, nil
		Logger.info(LOG, "The reload ended without replacing the driver; %d held menu click(s) run in place.",
			#clicks)
		gate.replay(clicks, "Held")
	end

	local function hold(click)
		local label = ClickIntent.describe(click.path)
		if handed_off then
			Logger.info(LOG, "Menu click on '%s' held after the reload hand-off.", label)
			hand({ click })
			return
		end
		if #held >= MAX_HELD_CLICKS then
			Logger.warn(LOG, "Menu click on '%s' dropped: %d clicks already wait for the reload.",
				label, MAX_HELD_CLICKS)
			report_lost({ label })
			return
		end
		held[#held + 1] = click
		held_since = held_since or deps.now()
		Logger.info(LOG, "Menu click on '%s' held: a reload is in progress; it runs once the reload ends.", label)
		arm_poll()
	end

	--- Dispatches one click made on a gated row.
	local function dispatch(path, checked, action, joins_reload, ...)
		local click = { path = path, desired = ClickIntent.desired(checked),
			args = { n = select("#", ...), ... } }
		if pending() then
			if joins_reload then
				Logger.info(LOG, "Menu click on '%s' joined the reload in flight; no second reload.",
					ClickIntent.describe(path))
				return nil
			end
			hold(click)
			return nil
		end
		local stale_ok, stale = pcall(deps.stale)
		if stale_ok and stale == true then
			local refreshed, items = pcall(deps.refresh)
			if refreshed and type(items) == "table" then
				if not resolve(click, items, "Stale") then report_lost({ ClickIntent.describe(path) }) end
				return nil
			end
			Logger.warn(LOG, "Menu tree could not be refreshed for a click on '%s'; it runs as clicked.",
				ClickIntent.describe(path))
		end
		return action(...)
	end

	--- Puts every row action of a generated tree behind the gate, in place.
	--- A subtree a builder cache reuses keeps the gate it already has.
	--- @param items table Generated menubar tree.
	--- @return table items The same tree.
	function gate.wrap(items)
		local function walk(rows, prefix, seen)
			if type(rows) ~= "table" or seen[rows] then return end
			seen[rows] = true
			for _, row in ipairs(rows) do
				if type(row) == "table" then
					local path = ClickIntent.child_path(prefix, row.title)
					local action = row.fn
					if type(action) == "function" and raws[action] == nil then
						local checked, joins_reload = row.checked, row.joins_reload == true
						local guarded
						guarded = function(...) return dispatch(path, checked, action, joins_reload, ...) end
						raws[guarded] = action
						row.fn = guarded
					end
					walk(row.menu, path, seen)
				end
			end
		end
		walk(items, {}, {})
		return items
	end

	--- Runs clicks once on the current tree, holding them again while a
	--- reload is pending.
	--- @param clicks table Click records { path, desired, args }.
	--- @param origin string Log prefix ("Held", "Replayed").
	function gate.replay(clicks, origin)
		local labels = {}
		for _, click in ipairs(clicks) do
			if pending() then
				hold(click)
			else
				local stale_ok, stale = pcall(deps.stale)
				local items
				if stale_ok and stale == true then
					local refreshed, fresh = pcall(deps.refresh)
					items = refreshed and fresh or nil
				end
				if type(items) ~= "table" then items = deps.current_items() end
				if not resolve(click, items, origin) then labels[#labels + 1] = ClickIntent.describe(click.path) end
			end
		end
		report_lost(labels)
	end

	--- Writes clicks into the hand-off record, after any already written.
	local function persist(clicks)
		local record = { schema = REPLAY_SCHEMA, at = deps.now(), clicks = {} }
		local read, previous = pcall(store.get, M.REPLAY_KEY, nil)
		if read and type(previous) == "string" then
			local decoded, earlier = pcall(json.decode, previous)
			if decoded and type(earlier) == "table" and type(earlier.clicks) == "table" then
				for _, click in ipairs(earlier.clicks) do record.clicks[#record.clicks + 1] = click end
			end
		end
		for _, click in ipairs(clicks) do
			record.clicks[#record.clicks + 1] = { path = click.path, desired = click.desired }
		end
		local encoded, text = pcall(json.encode, record)
		local stored, committed = false, nil
		if encoded then stored, committed = pcall(store.set, M.REPLAY_KEY, text) end
		if stored and committed == true then
			Logger.info(LOG, "%d held menu click(s) handed to the reloaded menu.", #clicks)
			return
		end
		Logger.error(LOG, "%d held menu click(s) could not be handed to the reloaded menu: %s.",
			#clicks, tostring(encoded and committed or text))
	end

	--- Hands clicks to the successor of a reload, or reports them dropped on a quit.
	hand = function(clicks)
		local reloading_ok, reloading = pcall(deps.is_reloading)
		if reloading_ok and reloading == true then persist(clicks); return end
		for _, click in ipairs(clicks) do
			Logger.warn(LOG, "Held menu click on %s dropped: the driver is quitting.",
				ClickIntent.describe(click.path))
		end
	end

	--- Teardown step: hands held clicks to the reload successor, or reports
	--- them dropped when the driver quits. A click made after this step, while
	--- the logger drains, is handed over at once.
	--- @return boolean true Teardown never retains this step.
	function gate.handoff()
		handed_off = true
		if #held == 0 then return true end
		local clicks = held
		held, held_since = {}, nil
		hand(clicks)
		return true
	end

	--- Boot: consumes the previous generation's hand-off once.
	--- @return integer count Valid clicks inherited for replay.
	function gate.inherit()
		if inherited ~= nil then
			Logger.error(LOG, "The reload hand-off was already consumed; duplicate inherit refused.")
			return 0
		end
		inherited = {}
		local read, text = pcall(store.get, M.REPLAY_KEY, nil)
		if not read then
			Logger.error(LOG, "The reload hand-off could not be read: %s.", tostring(text))
			return 0
		end
		if text == nil then return 0 end
		local deleted, removed = pcall(store.delete, M.REPLAY_KEY)
		if not deleted or removed == false then
			Logger.error(LOG, "The reload hand-off could not be deleted; it is not replayed.")
			return 0
		end
		local decoded, record = pcall(json.decode, text)
		if not decoded or type(record) ~= "table" or record.schema ~= REPLAY_SCHEMA
			or type(record.at) ~= "number" or type(record.clicks) ~= "table" then
			Logger.warn(LOG, "The reload hand-off is malformed; it is rejected.")
			return 0
		end
		local age = deps.now() - record.at
		if age < 0 or age > REPLAY_TTL_SEC then
			Logger.warn(LOG, "The reload hand-off is %.0f s old; it is rejected.", age)
			return 0
		end
		for _, click in ipairs(record.clicks) do
			if type(click) ~= "table" or not ClickIntent.valid_path(click.path)
				or (click.desired ~= nil and type(click.desired) ~= "boolean") then
				Logger.warn(LOG, "The reload hand-off holds a malformed click; it is rejected.")
				inherited = {}
				return 0
			end
			inherited[#inherited + 1] = { path = click.path, desired = click.desired, args = { n = 0 } }
		end
		Logger.info(LOG, "%d menu click(s) inherited from the previous reload.", #inherited)
		return #inherited
	end

	--- Boot, once the menu tree exists: replays the inherited clicks.
	function gate.replay_inherited()
		if type(inherited) ~= "table" or #inherited == 0 then return end
		local clicks = inherited
		inherited = {}
		gate.replay(clicks, "Replayed")
	end

	return gate
end

return M
