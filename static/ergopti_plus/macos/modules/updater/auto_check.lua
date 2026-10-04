--- modules/updater/auto_check.lua

--- ==============================================================================
--- MODULE: Automatic Update Checks (macOS)
--- DESCRIPTION:
--- Owns the automatic update-check cadence and the check itself on macOS. The
--- launcher's Sparkle controller only downloads and installs, when the user asks
--- (ergoptiplus://updater/check/<channel>); Sparkle's own scheduler is off
--- (SUEnableAutomaticChecks is false in the launcher's Info.plist).
---
--- FEATURES & RATIONALE:
--- 1. One schedule on every driver: _shared/lua/updater/schedule.lua decides
---    from the wall clock and the persisted check record (Storage port, shared
---    key), so every menu preset works (Sparkle refuses intervals under an
---    hour), a restart mid-interval does not check at boot, and a Mac that was
---    off past its due time catches up once the boot delay has passed.
--- 2. One release list: the check reads update_check.releases_url with an ETag
---    and keeps the channel's latest release through the shared registry and
---    offer rule; a 304 reuses the list this session holds, and a session that
---    holds none sends a full request.
--- 3. Never on the typing path: evaluations run from timers and the wake
---    watcher, and the request is asynchronous.
--- 4. Paused: nothing is dispatched and the record is left as it is. A wake
---    restarts the boot delay and re-evaluates at once.
--- 5. Never installs: a new release is announced once (last_notified_tag) and
---    offered by the About row; Sparkle installs only on that click.
--- 6. One interval owner: the frequency rows persist config.toml [updater]
---    check_interval_seconds through the menu's preferences transaction; a
---    value outside the presets snaps to the nearest one.
--- 7. A manual check (check_now) reads the same list with the same ETag, is
---    recorded like an automatic one and answers the update-check window with
---    the shared result (updater.check_result): the release it offers is the
---    one the About row names, and it is not announced again afterwards.
--- ==============================================================================

local M = {}

local Logger    = require("infra.logger")
local Paths     = require("infra.paths")
local FileSystem = require("adapters.file_system")
local JsonCodec = require("adapters.json_codec")
local Schedule  = require("updater.schedule")
local Parser    = require("updater.release_parser")
local CheckResult = require("updater.check_result")
local Updater   = require("modules.updater")
local UpdateLauncher = require("adapters.update_launcher")
local notifications = require("infra.notifications")
local i18n      = require("infra.i18n")

local LOG = "updater.auto_check"

-- The flat preference key mapped to config.toml [updater] check_interval_seconds
-- by infra/preferences.lua.
M.STATE_KEY = "update_check_interval_seconds"

local USER_AGENT = "ErgoptiPlus-Updater-macOS/1.0"
local MS_PER_SEC = 1000





-- ==================================
-- ==================================
-- ======= 1/ Shared Defaults =======
-- ==================================
-- ==================================

--- Loads the automatic-check contract from the shared updater defaults. It has
--- no fallback: a guessed cadence or URL would check the wrong list or never.
--- @return table config { timing, state_key, releases_url, timeout_sec }
function M.load_config()
	local path = Paths.shared("modules/updater/defaults.json")
	local raw = type(path) == "string" and path ~= "" and FileSystem.read(path) or nil
	if type(raw) ~= "string" then error("the shared updater defaults are unreadable", 0) end
	local decoded, decode_err = JsonCodec.decode(raw)
	if decode_err or type(decoded) ~= "table" then
		error("the shared updater defaults are not JSON: " .. tostring(decode_err), 0)
	end
	local ok, err = Schedule.validate_timing(decoded.timing)
	if not ok then error("the shared updater timing is invalid: " .. tostring(err), 0) end
	local state_key = type(decoded.check_state) == "table" and decoded.check_state.storage_key or nil
	local template = type(decoded.update_check) == "table" and decoded.update_check.releases_url or nil
	local sources = decoded.release_sources
	local timeout_sec = type(sources) == "table" and sources.source_timeout_sec or nil
	if type(state_key) ~= "string" or state_key == "" then
		error("the shared updater defaults declare no check_state.storage_key", 0)
	end
	if type(template) ~= "string" or not template:find("{owner}/{repo}", 1, true) then
		error("the shared updater defaults declare no update_check.releases_url", 0)
	end
	if type(timeout_sec) ~= "number" or timeout_sec <= 0 then
		error("the shared updater defaults declare no release_sources.source_timeout_sec", 0)
	end
	local url = template:gsub("{owner}", function() return Updater.GH_OWNER end)
		:gsub("{repo}", function() return Updater.GH_REPO end)
	return { timing = decoded.timing, state_key = state_key, releases_url = url, timeout_sec = timeout_sec }
end

--- Reads a header case-insensitively (HTTP/2 lowercases names, Foundation
--- capitalises them).
--- @param headers table|nil
--- @param wanted string Lowercase header name.
--- @return string|nil
local function header_value(headers, wanted)
	if type(headers) ~= "table" then return nil end
	for key, value in pairs(headers) do
		if type(key) == "string" and key:lower() == wanted and type(value) == "string" and value ~= "" then
			return value
		end
	end
	return nil
end





-- ============================
-- ============================
-- ======= 2/ The Owner =======
-- ============================
-- ============================

--- The interval a menu state stores, snapped to a preset; the default one
--- when it stores none or an invalid one.
--- @param state table Menu state (holds update_check_interval_seconds).
--- @param timing table The shared timing.
--- @return number seconds
local function stored_interval(state, timing)
	local raw = state[M.STATE_KEY]
	if raw == nil then return timing.default_check_interval_sec end
	if type(raw) ~= "number" or raw < 0 or raw ~= math.floor(raw) then
		Logger.warn(LOG, "config.toml check_interval_seconds '%s' is not a whole number of seconds.", tostring(raw))
		return timing.default_check_interval_sec
	end
	local seconds = Schedule.snap_interval(raw, timing)
	return seconds
end

--- Exposes the existing snapped preference for source-run menu captions.
--- @param state table Menu state holding update_check_interval_seconds.
--- @param config table|nil Existing load_config() result.
--- @return number seconds The effective preset interval.
function M.stored_interval(state, config)
	if type(state) ~= "table" then error("the stored check interval needs the menu state", 2) end
	return stored_interval(state, (config or M.load_config()).timing)
end

--- The preset code of the interval a menu state stores, for a driver that
--- starts no owner: a local version names the preset on its greyed row.
--- @param state table Menu state (holds update_check_interval_seconds).
--- @param config table|nil load_config() result (tests pass one).
--- @return string code The preset's menu label key suffix.
function M.stored_interval_code(state, config)
	if type(state) ~= "table" then error("the stored check interval needs the menu state", 2) end
	local timing = (config or M.load_config()).timing
	local _, code = Schedule.snap_interval(stored_interval(state, timing), timing)
	return code
end

--- Creates the automatic-check owner of one menu session.
--- @param opts table
---   state table Menu state (holds update_check_interval_seconds).
---   save function(): boolean Transactional preferences save.
---   channel function(): string The subscribed channel.
---   is_paused function(): boolean The driver's pause.
---   on_available function(release) A new release { tag, channel } was found.
---   config table|nil load_config() result (tests pass one).
---   timer table { after(sec, fn) -> handle, committed; cancel(handle) -> boolean }
---   storage table { get(key, default), set(key, value) -> boolean }
---   http table { get(url, headers, callback(result)) -> boolean }
---   now function(): number Wall clock in epoch seconds.
---   current_version function(): string|nil, installed_channel function(): string|nil
--- @return table owner
function M.new(opts)
	if type(opts) ~= "table" or type(opts.state) ~= "table" or type(opts.save) ~= "function"
		or type(opts.channel) ~= "function" or type(opts.is_paused) ~= "function"
		or type(opts.on_available) ~= "function" or type(opts.timer) ~= "table"
		or type(opts.storage) ~= "table" or type(opts.http) ~= "table" or type(opts.now) ~= "function" then
		error("the automatic update-check owner needs its state, save, channel, pause, callback and ports", 2)
	end
	local config = opts.config or M.load_config()
	local timing = config.timing
	local current_version = opts.current_version or Updater.current_version
	local installed_channel = opts.installed_channel or Updater.installed_channel
	local owner = {}

	local timer_handle = nil
	local record = nil
	local started_at = nil
	local list_cache = nil     -- { body, etag } of the last 200 this session read
	local in_flight = false
	local latest = nil         -- { tag, channel } offered by the last check
	local active = false
	local generation = 0

	--- The check record, loaded once; a missing install seed is created.
	local function load_record()
		if record then return record end
		local state, dropped = Schedule.sanitize_state(opts.storage.get(config.state_key, nil))
		for _, field in ipairs(dropped) do
			Logger.warn(LOG, "Dropped the invalid '%s' of the stored update-check record.", field)
		end
		record = state
		if state.seed == nil then
			-- Spread, not secrecy: installs first run at different times.
			state.seed = string.format("%08x%08x", opts.now() % 4294967296,
				math.floor(os.clock() * 1000000) % 4294967296)
			if opts.storage.set(config.state_key, state) ~= true then
				Logger.error(LOG, "The new update-check record could not be saved.")
			end
		end
		return record
	end

	--- Saves the record; a refused write still advances this session's copy.
	local function save_record(state)
		record = state
		if opts.storage.set(config.state_key, state) == true then return true end
		Logger.error(LOG, "The update-check record could not be saved; this session keeps its copy.")
		return false
	end

	--- The interval in force: the persisted preference snapped to a preset.
	function owner.interval()
		return stored_interval(opts.state, timing)
	end

	--- The preset code of the interval in force (its menu label key suffix).
	function owner.interval_code()
		local _, code = Schedule.snap_interval(owner.interval(), timing)
		return code
	end

	--- The presets, in menu order.
	function owner.presets()
		return timing.check_interval_presets
	end

	--- The release the last check offered, or nil.
	function owner.latest()
		return latest
	end

	local evaluate

	--- Arms the one schedule timer.
	local function arm(delay_sec)
		local handle, committed
		handle, committed = opts.timer.after(delay_sec, function()
			if not active or handle == nil or timer_handle ~= handle then return end
			timer_handle = nil
			evaluate()
		end)
		timer_handle = handle
		if committed ~= true or handle == nil then
			active = false
			Logger.error(LOG, "The update-check timer could not be armed.")
			if handle ~= nil then
				if opts.timer.cancel(handle) == true then
					timer_handle = nil
				else
					Logger.error(LOG, "The refused update-check timer remains owned pending cleanup.")
				end
			end
			return false
		end
		return true
	end

	--- Records one completed check and announces a new release once.
	local function complete(ok, release)
		in_flight = false
		local state = Schedule.record_check(load_record(), opts.now(), ok)
		save_record(state)
		Logger.info(LOG, "Background check recorded: %s (consecutive failures: %d).",
			ok and "success" or "failure", state.failures)
		if not release then
			latest = nil
			return
		end
		latest = release
		if state.last_notified_tag == release.tag then
			Logger.info(LOG, "Background check result: %s available, already notified.", release.tag)
			return
		end
		local notified = {}
		for field, value in pairs(state) do notified[field] = value end
		Logger.info(LOG, "New release available: %s (channel %s).", release.tag, release.channel)
		local ok_notify, accepted = pcall(opts.on_available, release)
		if not ok_notify or accepted ~= true then
			Logger.error(LOG, "Update notification was not accepted: %s.", tostring(accepted))
			return
		end
		notified.last_notified_tag = release.tag
		save_record(notified)
	end

	--- Interprets one release list for the subscribed channel.
	local function read_list(body, channel)
		local registry = Updater.channels()
		local chunks = Parser.split_releases_array(body)
		local tags = {}
		for index, chunk in ipairs(chunks) do tags[index] = Parser.parse_tag(chunk) end
		local best = registry.pick_latest(tags, channel)
		if not best then
			Logger.info(LOG, "Background check result: no release on channel '%s' yet.", channel)
			return nil
		end
		local tag = tags[best]
		local current = current_version()
		if not registry.should_offer(tag, current, channel, installed_channel()) then
			Logger.info(LOG, "Background check result: up to date (current %s, latest %s, channel %s).",
				tostring(current), tag, channel)
			return nil
		end
		return { tag = tag, channel = channel }
	end

	--- The headers of one list request, conditional on this session's copy.
	local function list_headers()
		local headers = { Accept = "application/vnd.github+json", ["User-Agent"] = USER_AGENT }
		if list_cache then headers["If-None-Match"] = list_cache.etag end
		return headers
	end

	--- Reads one list response: the usable body, or nil with the failure reason
	--- (an updater.check_result reason name) and its English cause.
	--- @param result table|nil The HTTP port's result.
	--- @return string|nil body
	--- @return string|nil reason
	--- @return string|nil detail
	local function read_response(result)
		local status = type(result) == "table" and tonumber(result.status) or 0
		if status == 304 and list_cache then
			Logger.debug(LOG, "Release list unchanged (304); reusing this session's copy.")
			return list_cache.body
		end
		if type(result) == "table" and result.ok == true and type(result.body) == "string"
			and result.body:match("^%s*%[") then
			local decoded, decode_error = JsonCodec.decode(result.body)
			if decode_error or type(decoded) ~= "table" then
				return nil, "parse_failed", "a malformed release list: " .. tostring(decode_error)
			end
			for _, entry in pairs(decoded) do
				if type(entry) ~= "table" or type(entry.tag_name) ~= "string" or entry.tag_name == "" then
					return nil, "parse_failed", "a release without a tag"
				end
			end
			local etag = header_value(result.headers, "etag")
			list_cache = etag and { body = result.body, etag = etag } or nil
			return result.body
		end
		return nil, "no_connection",
			tostring(type(result) == "table" and (result.error or ("HTTP " .. tostring(status))) or "no result")
	end

	--- Sends one conditional request for the release list.
	local function dispatch(channel)
		in_flight = true
		local request_generation = generation
		local completed = false
		local ok_dispatch, sent = pcall(opts.http.get, config.releases_url, list_headers(), function(result)
			if completed or not active or request_generation ~= generation then return end
			completed = true
			if channel ~= opts.channel() then
				in_flight = false
				Logger.info(LOG, "Discarded a completed check for the previous channel '%s'.", channel)
				return
			end
			local body, reason, detail = read_response(result)
			if not body then
				if reason == "parse_failed" then
					Logger.warn(LOG, "Background check returned %s.", detail)
				else
					Logger.warn(LOG, "Background check failed: %s.", detail)
				end
				complete(false, nil)
				return
			end
			complete(true, read_list(body, channel))
		end)
		if (not ok_dispatch or sent ~= true) and not completed and active and request_generation == generation then
			completed = true
			Logger.error(LOG, "The update-check request was not dispatched: %s.", tostring(sent))
			complete(false, nil)
		end
	end

	--- One evaluation: re-reads the wall clock, re-arms, and dispatches a due
	--- check unless the driver is paused.
	evaluate = function()
		if not active then return false end
		local now = opts.now()
		local due_at, reason = Schedule.next_due({
			now = now, started_at = started_at, interval = owner.interval(),
			state = load_record(), timing = timing,
		})
		if due_at == nil then
			Logger.debug(LOG, "Automatic update checks are off.")
			return true
		end
		if due_at > now then
			return arm(Schedule.delay_until(due_at, now, timing))
		end
		if not arm(timing.reevaluate_sec) then return false end
		if opts.is_paused() == true then
			Logger.debug(LOG, "Update check due (%s) but the driver is paused; the record is left as it is.", reason)
			return true
		end
		if in_flight then
			Logger.info(LOG, "Update check due (%s) while the previous one is in flight.", reason)
			return true
		end
		local channel = opts.channel()
		Logger.info(LOG, "Background update check due (%s, channel %s).", reason, channel)
		dispatch(channel)
		return true
	end

	owner._evaluate = function() evaluate() end

	--- Runs one check the user asked for, now, whatever the schedule or the
	--- pause, and answers with the shared result (updater.check_result). The
	--- check is recorded like an automatic one; a release it offers becomes the
	--- one the About row names, and a later automatic check does not announce
	--- it again: the window already showed it.
	--- @param channel string Registry channel id to check.
	--- @param on_result function(result) Receives the check result, exactly once.
	--- @return boolean dispatched
	function owner.check_now(channel, on_result)
		local base = { channel = channel, current = current_version() }
		local answered = false
		local function answer(result)
			if answered then return end
			answered = true
			local ok, err = pcall(on_result, result)
			if not ok then Logger.error(LOG, "The manual check's answer raised: %s.", tostring(err)) end
		end
		local function fail(reason, detail)
			save_record(Schedule.record_check(load_record(), opts.now(), false))
			Logger.warn(LOG, "Manual update check failed on channel '%s': %s.", tostring(channel), tostring(detail))
			answer(CheckResult.failure(base, reason, detail))
		end
		Logger.start(LOG, "Manual update check (channel %s)…", tostring(channel))
		if type(channel) ~= "string" or Updater.channels().channel(channel) == nil then
			Logger.error(LOG, "Manual update check refused: '%s' is not a registry channel.", tostring(channel))
			answer(CheckResult.failure(base, "unexpected", "not a registry channel"))
			return false
		end
		local ok_dispatch, sent = pcall(opts.http.get, config.releases_url, list_headers(), function(response)
			if answered then return end
			local body, reason, detail = read_response(response)
			if not body then return fail(reason, detail) end
			local result = CheckResult.classify(body, {
				registry = Updater.channels(), channel = channel,
				current = base.current, installed = installed_channel(),
			})
			local state = Schedule.record_check(load_record(), opts.now(), true)
			-- A channel switched while the request ran leaves the About row to the
			-- new channel, as dispatch() does: the window still gets its answer
			if channel ~= opts.channel() then
				Logger.info(LOG, "The manual check of '%s' leaves the About row to the new channel.", channel)
			elseif result.state == "available" then
				latest = { tag = result.latest, channel = channel }
				state.last_notified_tag = result.latest
			else
				latest = nil
			end
			save_record(state)
			Logger.success(LOG, "Manual update check answered: %s (channel %s, latest %s, %d other channel(s)).",
				result.state, channel, tostring(result.latest), #result.others)
			answer(result)
		end)
		if not ok_dispatch or sent ~= true then
			if not answered then fail("no_connection", ok_dispatch and "the request was refused" or tostring(sent)) end
			return false
		end
		return true
	end

	--- Cancels the armed timer.
	local function disarm()
		if timer_handle == nil then return true end
		if opts.timer.cancel(timer_handle) ~= true then
			Logger.error(LOG, "The update-check timer could not be released.")
			return false
		end
		timer_handle = nil
		return true
	end

	--- Starts the schedule from the persisted record.
	--- @return boolean started
	function owner.start()
		Logger.start(LOG, "Starting automatic update checks…")
		started_at = started_at or opts.now()
		load_record()
		if not disarm() then
			active = false
			Logger.error(LOG, "Automatic update checks could not start: a previous timer is still armed.")
			return false
		end
		generation = generation + 1
		in_flight = false
		active = true
		if not evaluate() then
			Logger.error(LOG, "Automatic update checks could not start: timer admission was refused.")
			return false
		end
		Logger.success(LOG, "Automatic update checks started (every %ds).", owner.interval())
		return true
	end

	--- Stops the schedule; a completion still in flight is discarded.
	--- @return boolean stopped
	function owner.stop()
		active = false
		generation = generation + 1
		in_flight = false
		return disarm()
	end

	--- Revokes pending results when the durable channel owner publishes a change.
	function owner.on_channel_changed()
		generation = generation + 1
		in_flight = false
		latest = nil
		if active and disarm() then return evaluate() end
		return not active
	end

	--- Restarts the boot delay at a wake and re-evaluates at once.
	function owner.on_wake()
		if not active then return end
		started_at = opts.now()
		Logger.info(LOG, "Wake: the update-check schedule is re-evaluated.")
		if disarm() then evaluate() end
	end

	--- Persists a new interval through the preferences transaction, then
	--- re-evaluates the schedule.
	--- @param seconds number A preset's seconds.
	--- @return boolean committed
	function owner.set_interval(seconds)
		if Schedule.preset_for(seconds, timing) == nil then
			Logger.error(LOG, "Check interval change refused: %s s is not a preset.", tostring(seconds))
			return false
		end
		if opts.state[M.STATE_KEY] == seconds then return true end
		local previous = opts.state[M.STATE_KEY]
		opts.state[M.STATE_KEY] = seconds
		local ok, committed = pcall(opts.save)
		if not ok or committed ~= true then
			if opts.state[M.STATE_KEY] == seconds then opts.state[M.STATE_KEY] = previous end
			Logger.error(LOG, "Check interval %ds could not be saved (%s).", seconds,
				ok and "save refused" or tostring(committed))
			return false
		end
		Logger.info(LOG, "Check interval set to %ds.", seconds)
		if active and disarm() then evaluate() end
		return true
	end

	return owner
end

--- Announces a release the automatic check found. A click asks Sparkle for it,
--- and Sparkle shows its own install dialog: nothing installs without the user.
--- @param release table { tag, channel }
--- @return boolean notified
function M.announce(release)
	-- Plain substitution: a tag is outside data, and a "%" in it would be read as
	-- a capture reference in a gsub replacement.
	local body = i18n.get("updater.tray_new_version_body")
	local at = body:find("{1}", 1, true)
	if at then
		body = body:sub(1, at - 1) .. release.tag .. body:sub(at + 3)
	else
		body = body .. " " .. release.tag
	end
	local notified, err = notifications.notify(i18n.get("updater.tray_new_version_title"), body, "info",
		function() UpdateLauncher.request_check(release.channel) end)
	if notified ~= true then
		Logger.error(LOG, "The new-release notification was refused: %s.", tostring(err))
		return false
	end
	return true
end

--- Builds the owner of one menu session over the production ports, then starts
--- it with a wake watcher. owner.stop() also stops the watcher.
--- @param opts table { state, save, channel, is_paused, on_available } as for new().
--- @return table owner The started owner.
function M.start_session(opts)
	local config = M.load_config()
	local owner = M.new({
		state = opts.state,
		save = opts.save,
		channel = opts.channel,
		is_paused = opts.is_paused,
		on_available = opts.on_available,
		config = config,
		timer = require("adapters.timer_scheduler"),
		storage = require("adapters.storage"),
		http = require("adapters.http_client").new({ timeout_ms = config.timeout_sec * MS_PER_SEC }),
		now = os.time,
	})
	local watcher = require("adapters.wake_watcher").new(owner.on_wake)
	if not watcher.start() then
		Logger.error(LOG, "The wake watcher did not start; a wake is caught at the next bounded re-evaluation.")
	end
	local stop_owner = owner.stop
	function owner.stop()
		local watcher_stopped = watcher.stop()
		return stop_owner() == true and watcher_stopped == true
	end
	if not owner.start() then
		owner.stop()
		error("the automatic update checks could not start", 0)
	end
	return owner
end

return M
