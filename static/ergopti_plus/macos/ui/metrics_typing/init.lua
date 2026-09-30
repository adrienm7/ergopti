--- ui/metrics_typing/init.lua

--- ==============================================================================
--- MODULE: Typing Metrics Dashboard UI
--- DESCRIPTION:
--- Hosts the typing-metrics WebView. Reads from `db.sqlite` (the tmpdir cache
--- rebuildable from `data.sql`) via `modules.keylogger.sqlite_reader` and
--- projects the result into the JSON shape consumed by the (unchanged)
--- frontend JS.
---
--- FEATURES & RATIONALE:
--- 1. Instant first paint: the last complete publication is persisted by
---    `ui.metrics_typing.snapshot` and painted as soon as the page is ready,
---    labelled with its date, before any aggregation has run.
--- 2. Paced refresh: every projection (open, live update, filter request)
---    runs as an `infra.paced_job` in bounded main-thread slices, one job at a
---    time, and updates the page in place when it completes. Nothing reads
---    SQLite synchronously on the open path or in the request poller.
--- 3. Incremental projection: `ui.metrics_typing.projection` reuses past days
---    while their fingerprint is unchanged, so a refresh reads only new days.
--- 4. Filter requests: the JS frontend pushes `(start_date, end_date, apps)`
---    via `window._lua_request`; the poll timer reads it, queues the paced
---    projection (latest request wins), and pushes back the result.
--- ==============================================================================

local M = {}
local WebviewResult = require("adapters.webview_result")

local hs         = hs
local fs         = require("hs.fs")
local json       = require("hs.json")
local FileSystem = require("adapters.file_system")
local ui_builder = require("ui.ui_builder")
local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local i18n       = require("infra.i18n")
local TimerScheduler = require("adapters.timer_scheduler")
local PacedJob   = require("infra.paced_job")
local PacedJson  = require("infra.paced_json")
local Projection = require("ui.metrics_typing.projection")
local Snapshot   = require("ui.metrics_typing.snapshot")

local LOG = "metrics_typing"

-- Lazy-loaded to avoid circular require; populated on first open().
local _log_manager = nil
local function _get_log_manager()
	if not _log_manager then
		_log_manager = require("modules.keylogger.log_manager")
	end
	return _log_manager
end

--- Acquires the module-lifetime ingest subscription before any window is
--- published. A dashboard without this owner would silently stop refreshing,
--- so subscription failure is a startup refusal rather than optional telemetry.
--- @return boolean registered
local function ensure_ingest_listener()
	if M and M._ingest_listener_registered then return true end
	local ok, registered_or_err = xpcall(function()
		local manager = _get_log_manager()
		if type(manager) ~= "table" or type(manager.on_ingest_done) ~= "function" then
			error("LogManager.on_ingest_done is unavailable")
		end
		return manager.on_ingest_done(function()
			M.push_live_update()
		end)
	end, debug.traceback)
	if not ok or registered_or_err ~= true then
		Logger.error(LOG, "Typing metrics ingest-listener acquisition failed: %s.",
			tostring(ok and registered_or_err or registered_or_err))
		return false
	end
	M._ingest_listener_registered = true
	Logger.debug(LOG, "Post-ingest live-update listener registered.")
	return true
end

local JS_MAX_SAFE_INTEGER = 2 ^ 53 - 1

M._wv             = nil
M._timer          = nil
M._startup_webview = nil
M._app_icon_cache = {}
--- True once we have registered our on_ingest_done listener.
--- The listener is registered once for the module lifetime; subsequent
--- opens reuse it (the dashboard state is on M which is always live).
M._ingest_listener_registered = false
local _generation = 0
local _publication_revision = 0
local _pending_live_publication = nil
local _cache_reset_owner = nil
local _continuation_timers = {}
local _closing_webview = nil
local _delivery_errors = {}
local _delivery_generation = nil
--- Running paced projection, if any; one job at a time per window.
M._job = nil
--- Work waiting for the running job: a full refresh, a live manifest refresh,
--- and the latest range request (older ones are superseded by the frontend).
local _pending_work = { full = false, live = false, range = nil }
--- Snapshot timestamp painted in this window, shown again if the refresh fails.
local _painted_snapshot_at = nil

local function delivery_is_current(generation, webview)
	return generation == _generation and M._wv == webview
end

local function delivery_failure(generation, webview, site, category)
	if not delivery_is_current(generation, webview) then return end
	if _delivery_generation ~= generation then
		_delivery_generation = generation
		_delivery_errors = {}
	end
	local key = site .. ":" .. category
	if _delivery_errors[key] then return end
	_delivery_errors[key] = true
	Logger.error(LOG, "Typing metrics JavaScript delivery failed (%s; %s; content withheld; repeats suppressed).", site, category)
end

local function submit_javascript(generation, webview, site, code, callback, on_failure)
	if not delivery_is_current(generation, webview) then return false end
	local admitted, completed, pending, failed = nil, false, nil, false
	local function complete(result, execution_error)
		if completed or not delivery_is_current(generation, webview) then return end
		if admitted == nil then pending = pending or { result, execution_error }; return end
		completed = true
		if not admitted then return end
		if WebviewResult.is_error(execution_error) then
			failed = true
			if on_failure then on_failure() end
			delivery_failure(generation, webview, site, "execution")
			return
		end
		if callback then
			local ok = pcall(callback, result)
			if not ok then
				failed = true
				if on_failure then on_failure() end
				delivery_failure(generation, webview, site, "callback")
			end
		end
	end
	local ok, result = pcall(webview.evaluateJavaScript, webview, code, complete)
	admitted = ok and result == webview
	if not admitted then
		completed = true
		if on_failure then on_failure() end
		delivery_failure(generation, webview, site, "submission")
		return false
	end
	if pending then complete(pending[1], pending[2]) end
	return not failed and delivery_is_current(generation, webview)
end

local function encode_delivery(generation, webview, site, value)
	if not delivery_is_current(generation, webview) then return nil end
	local ok, encoded = pcall(json.encode, value)
	if not delivery_is_current(generation, webview) then return nil end
	if not ok or type(encoded) ~= "string" or encoded == "" then
		delivery_failure(generation, webview, site, "encoding")
		return nil
	end
	return encoded
end

--- Cancels the running projection job and forgets queued work.
--- @return boolean settled True once no job timer remains owned.
local function cancel_job()
	_pending_work = { full = false, live = false, range = nil }
	local job = M._job
	if not job then return true end
	M._job = nil
	local settled = job.cancel()
	if not settled then Logger.error(LOG, "Typing metrics projection job retained timer cleanup debt.") end
	return settled
end

local _cache_reset_failure_generation = nil

local request_work

--- Forgets every cached projection, on disk and in memory, once the disk
--- snapshot is gone. The running job is cancelled in the same turn, so it can
--- neither republish nor re-save what was cleared, and a full projection is
--- queued again so the page leaves its refreshing state.
--- @return boolean removed True only when the disk snapshot is gone.
local function reset_caches(generation, webview)
	if not delivery_is_current(generation, webview) then return false end
	local removed = Snapshot.remove()
	if not delivery_is_current(generation, webview) then return false end
	if removed then
		cancel_job()
		Projection.reset()
		request_work(generation, webview, "full")
		return true
	end
	if _cache_reset_failure_generation ~= generation then
		_cache_reset_failure_generation = generation
		Logger.error(LOG, "Typing metrics cache reset failed (disk deletion; content withheld; repeats suppressed).")
	end
	return false
end

local function clear_cache(generation, webview, reset_id)
	if not delivery_is_current(generation, webview) then return end
	if type(reset_id) ~= "number" or reset_id <= 0 or reset_id % 1 ~= 0 or reset_id > JS_MAX_SAFE_INTEGER then
		delivery_failure(generation, webview, "cache reset", "invalid reset owner")
		return
	end
	local owner = _cache_reset_owner
	if owner and owner.generation == generation and reset_id < owner.id then return end
	if not owner or owner.generation ~= generation or reset_id > owner.id then
		owner = { generation = generation, id = reset_id, settled = false }
		_cache_reset_owner = owner
		local removed = reset_caches(generation, webview)
		if not delivery_is_current(generation, webview) or _cache_reset_owner ~= owner then return end
		owner.result = removed
		owner.settled = true
		if removed then Logger.info(LOG, "Caches cleared by user reset.") end
	end
	if not owner.settled or not delivery_is_current(generation, webview) or _cache_reset_owner ~= owner then return end
	submit_javascript(generation, webview, "cache reset completion", string.format(
		"window.complete_cache_reset(%d,%s);", reset_id, tostring(owner.result)), function(applied)
		if _cache_reset_owner ~= owner then return end
		if applied ~= true and applied ~= false then
			delivery_failure(generation, webview, "cache reset completion", "invalid acknowledgement")
		end
	end)
end

--- Cancels one exact scheduler handle without dropping refused cleanup debt.
--- @param handle table|nil Scheduler handle.
--- @return boolean settled True only when no native timer remains owned.
local function cancel_timer(handle)
	if type(handle) ~= "table" then return true end
	local ok, settled = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if not ok or settled ~= true then
		Logger.error(LOG, "Dashboard timer cleanup failed; exact handle retained: %s.",
			tostring(ok and settled or settled))
		return false
	end
	return true
end

--- Cancels the JS request poller while retaining a refused exact handle.
--- @return boolean settled True only when the poller was released.
local function cancel_poller()
	if not M._timer then return true end
	local handle = M._timer
	if not cancel_timer(handle) then return false end
	if M._timer == handle then M._timer = nil end
	return true
end

--- Cancels every delayed dashboard continuation independently.
--- @return boolean settled True only when all exact handles were released.
local function cancel_continuations()
	local snapshot = {}
	for handle in pairs(_continuation_timers) do snapshot[#snapshot + 1] = handle end
	local settled = true
	for _, handle in ipairs(snapshot) do
		if cancel_timer(handle) then
			_continuation_timers[handle] = nil
		else
			settled = false
		end
	end
	return settled
end

--- Invalidates callbacks and releases every timer owned by the current window.
--- @return boolean settled True only when all exact timers were released.
local function stop_runtime()
	_generation = _generation + 1
	_pending_live_publication = nil
	_cache_reset_owner = nil
	_painted_snapshot_at = nil
	M._pending_full_refresh = false
	local job_stopped = cancel_job()
	local poller_stopped = cancel_poller()
	local continuations_stopped = cancel_continuations()
	return job_stopped and poller_stopped and continuations_stopped
end

--- Retries deletion of an unpublished WebView retained by startup rollback.
--- @return boolean settled True only when no startup window remains owned.
local function settle_startup_webview()
	local owned = M._startup_webview
	if not owned then return true end
	if type(owned.delete) ~= "function" then
		Logger.error(LOG, "Typing metrics startup cleanup refused; WebView has no delete method.")
		return false
	end
	_closing_webview = owned
	local ok, err = xpcall(function() owned:delete() end, debug.traceback)
	if _closing_webview == owned then _closing_webview = nil end
	if not ok then
		Logger.error(LOG, "Typing metrics startup cleanup did not commit; exact WebView retained: %s.",
			tostring(err))
		return false
	end
	if M._startup_webview == owned then M._startup_webview = nil end
	return true
end

--- Fences a failed startup and retains any refused native cleanup capability.
--- @param webview table Exact unpublished WebView.
--- @param reason string Diagnostic failure reason.
--- @return boolean Always false because startup did not commit.
local function rollback_startup_webview(webview, reason)
	if M._wv == webview then M._wv = nil end
	M._startup_webview = webview
	local runtime_settled = stop_runtime()
	local window_settled = settle_startup_webview()
	if not runtime_settled then
		Logger.error(LOG, "Typing metrics startup rollback retained timer cleanup debt.")
	end
	if not window_settled then
		Logger.error(LOG, "Typing metrics startup rollback retained WebView cleanup debt.")
	end
	Logger.error(LOG, "Typing metrics dashboard startup failed: %s.", reason)
	return false
end

--- Schedules one generation-owned delayed continuation.
--- @param delay number Delay in seconds.
--- @param generation integer Dashboard generation.
--- @param webview table Exact webview owner.
--- @param callback function Continuation body.
--- @param label string Diagnostic label.
--- @return boolean committed True only when the timer was armed.
local function schedule_continuation(delay, generation, webview, callback, label)
	local handle
	local timer_committed = false
	local ok, candidate, committed = xpcall(function()
		return TimerScheduler.after(delay, function()
			if timer_committed ~= true then return end
			if handle and handle.timer ~= nil then
				-- TimerScheduler fences one-shot user delivery before attempting stop;
				-- cleanup debt is retained globally and locally, but must not turn a
				-- committed first paint into a permanently blank dashboard.
				Logger.error(LOG, "%s continuation retained timer cleanup debt.", label)
			else
				if handle then _continuation_timers[handle] = nil end
			end
			if generation ~= _generation or M._wv ~= webview then return end
			callback()
		end)
	end, debug.traceback)
	handle = candidate
	if type(handle) == "table" then _continuation_timers[handle] = true end
	if not ok or type(handle) ~= "table" or committed ~= true then
		if type(handle) == "table" and cancel_timer(handle) then
			_continuation_timers[handle] = nil
		end
		Logger.error(LOG, "%s continuation timer was not committed: %s.", label,
			tostring(ok and committed or candidate))
		return false
	end
	timer_committed = true
	return true
end



--- Resolves the path to shared UI assets (fail-fast).
--- Priority: module-relative > upward search > ERROR
--- @param subdir string Subdirectory name under static/ergopti_plus/_shared/ui/.
--- @return string|nil Absolute path if found, nil if missing (ERROR logged).
local function resolve_ui_assets_dir(subdir)
	-- Resolved through the single shared-tree resolver (Paths.shared). The
	-- trailing slash is preserved because callers concatenate asset filenames
	-- directly onto the returned directory path.
	local base = Paths.shared("ui/" .. subdir)
	if base and fs.dir(base) then
		Logger.debug(LOG, "resolve_ui_assets_dir('%s'): resolved via Paths.shared.", subdir)
		return base .. "/"
	end

	Logger.error(LOG, "resolve_ui_assets_dir('%s'): directory not found after all attempts.", subdir)
	return nil
end

--- Coalesces one full manifest refresh per completed ingest cycle.
M._pending_full_refresh = false





-- ============================
-- ============================
-- ======= 1/ App icons =======
-- ============================
-- ============================

local MAX_ICON_LOOKUPS_PER_OPEN = 24

--- Pseudo-apps the frontend never selects by default (data.js process_manifest).
local EXCLUDED_APPS = { Unknown = true, _sys = true, _system = true }

local function get_app_icon(app_name)
	local app = hs.application.find(app_name)
	if app and type(app.bundleID) == "function" then
		local ok, img = pcall(hs.image.imageFromAppBundle, app:bundleID())
		if ok and img then
			img:setSize({ w = 32, h = 32 })
			return img:encodeAsURLString()
		end
	end
	return nil
end





-- ====================================
-- ====================================
-- ======= 2/ Paced projections =======
-- ====================================
-- ====================================

--- Returns the readable db.sqlite path, or nil when no store exists yet.
--- @return string|nil sqlite_path
local function readable_sqlite_path()
	local sqlite_path = _get_log_manager().get_sqlite_path()
	if not sqlite_path or not fs.attributes(sqlite_path) then return nil end
	return sqlite_path
end

--- Computes the complete first-paint publication: manifest, app icons, the
--- all-time n-gram prefetch, and the keycode layout.
--- @param pacer table Pacer from `infra.paced_job`.
--- @return table result { payload = string, generated_at = epoch seconds }.
local function compute_full(pacer)
	local generated_at = os.time()
	local today = os.date("%Y-%m-%d")
	local manifest, manifest_json = {}, "{}"
	local session = nil
	local sqlite_path = readable_sqlite_path()
	if sqlite_path then
		session = Projection.session(require("modules.keylogger.sqlite_reader"), sqlite_path, today, pacer)
		manifest, manifest_json = session.manifest()
	end

	-- App icons + apps list + first_date computed from manifest. The apps list
	-- excludes the same pseudo-apps as the frontend's default selection, so the
	-- prefetch and the page's first range request share one cached history.
	local app_icons      = {}
	local icon_lookups   = 0
	local first_date     = nil
	local all_apps_set   = {}
	local all_apps_list  = {}
	for date_str, day_data in pairs(manifest) do
		if first_date == nil or date_str < first_date then first_date = date_str end
		for app_name, _ in pairs(day_data) do
			if not EXCLUDED_APPS[app_name] and not all_apps_set[app_name] then
				all_apps_set[app_name] = true
				table.insert(all_apps_list, app_name)
			end
			if app_name ~= "Unknown" and app_icons[app_name] == nil then
				local cached = M._app_icon_cache[app_name]
				if cached ~= nil then
					if cached then app_icons[app_name] = cached end
				elseif icon_lookups < MAX_ICON_LOOKUPS_PER_OPEN then
					-- Each lookup enumerates running applications natively
					pacer.pause()
					local icon = get_app_icon(app_name)
					M._app_icon_cache[app_name] = icon or false
					if icon then app_icons[app_name] = icon end
					icon_lookups = icon_lookups + 1
				end
			end
		end
	end
	table.sort(all_apps_list)

	-- Build keycode layout (numeric kc → character) for the keyboard heatmap.
	local kc_layout = {}
	local ok_kc, raw_kc_map = pcall(function() return hs.keycodes.map end)
	if ok_kc and type(raw_kc_map) == "table" then
		for k, v in pairs(raw_kc_map) do
			if type(k) == "number" then kc_layout[tostring(k)] = tostring(v) end
		end
	end

	-- Initial range pre-fetch (first_date → today).
	local initial_data_json = "null"
	if session and first_date then
		initial_data_json = session.range(first_date, today, all_apps_list)
	end

	return {
		generated_at = generated_at,
		payload = string.format('{"manifest":%s,"app_icons":%s,"initial_data":%s,"kc_layout":%s}',
			manifest_json, PacedJson.encode(app_icons, pacer), initial_data_json,
			PacedJson.encode(kc_layout, pacer)),
	}
end

--- Computes the manifest alone after an ingest; the frontend then replays its
--- active range request.
--- @param pacer table Pacer from `infra.paced_job`.
--- @return string payload Publication object text.
local function compute_live(pacer)
	local sqlite_path = readable_sqlite_path()
	if not sqlite_path then return '{"manifest":{}}' end
	local session = Projection.session(require("modules.keylogger.sqlite_reader"), sqlite_path,
		os.date("%Y-%m-%d"), pacer)
	local _, manifest_json = session.manifest()
	return '{"manifest":' .. manifest_json .. "}"
end

--- Computes one range request's { historical, today } payload.
--- @param query table Decoded frontend request.
--- @param pacer table Pacer from `infra.paced_job`.
--- @return string payload Encoded range data.
local function compute_range(query, pacer)
	local sqlite_path = readable_sqlite_path()
	if not sqlite_path then return '{"historical":[],"today":[]}' end
	local apps = type(query.apps) == "table" and query.apps or nil
	local session = Projection.session(require("modules.keylogger.sqlite_reader"), sqlite_path,
		os.date("%Y-%m-%d"), pacer)
	return session.range(query.start_date, query.end_date, apps)
end





-- ===================================
-- ===================================
-- ======= 3/ Page publication =======
-- ===================================
-- ===================================

--- Probes a frontend capability until it exists, then runs `on_ready`.
--- @param generation integer Dashboard generation.
--- @param webview table Exact webview owner.
--- @param site string Diagnostic site.
--- @param capability string Global function name the page must define.
--- @param on_ready function Continuation once the capability exists.
--- @param on_abandon function Called when delivery is given up.
--- @return boolean admitted
local function when_ready(generation, webview, site, capability, on_ready, on_abandon)
	local retry_delay = site == "cache" and 0.10 or 0.15
	local retry_count = site == "cache" and 50 or 60
	local function attempt(remaining)
		local admitted = submit_javascript(generation, webview, site .. " readiness", "typeof window." .. capability, function(kind)
			if kind == "function" then
				on_ready()
			elseif remaining > 0 then
				if not schedule_continuation(retry_delay, generation, webview,
					function() attempt(remaining - 1) end, "Typing metrics publication readiness")
				then on_abandon() end
			else
				on_abandon()
				delivery_failure(generation, webview, site, "publication capability unavailable")
			end
		end, on_abandon)
		if not admitted then on_abandon() end
		return admitted
	end
	return attempt(retry_count)
end

--- Encodes the freshness banner state for the page.
--- @param state string "stale", "loading", "fresh" or "failed".
--- @param generated_at number|nil Epoch seconds of the data shown.
--- @return string json
local function freshness_json(state, generated_at)
	if generated_at then
		return string.format('{"state":"%s","generated_at":%d}', state, math.floor(generated_at * 1000))
	end
	return string.format('{"state":"%s"}', state)
end

local function publish_data(generation, webview, site, payload, revision, with_assets, freshness)
	local metadata = string.format('{"manifest_revision":%d%s%s}', revision,
		with_assets and string.format(',"assets_revision":%d', revision) or "",
		freshness and (',"freshness":' .. freshness) or "")
	local code = "window.publishTypingMetricsData(" .. payload .. "," .. metadata .. ");"
	local publication = { code = code, generation = generation, revision = revision }
	if site == "live manifest" then
		if _pending_live_publication and _pending_live_publication.generation == generation then
			if revision > _pending_live_publication.revision then
				_pending_live_publication.code = code
				_pending_live_publication.revision = revision
			end
			return true
		end
		_pending_live_publication = publication
	end
	local function release_pending()
		if _pending_live_publication == publication then _pending_live_publication = nil end
	end
	return when_ready(generation, webview, site, "publishTypingMetricsData", function()
		release_pending()
		submit_javascript(generation, webview, site, publication.code, function(applied)
			if applied == true then
				if site == "live manifest" then
					Logger.debug(LOG, "Typing metrics live publication applied.")
				else
					Logger.success(LOG, "Typing metrics publication applied (%s).", site)
				end
			elseif applied == false then
				Logger.debug(LOG, "Typing metrics stale publication discarded (%s).", site)
			else
				delivery_failure(generation, webview, site, "invalid publication acknowledgement")
			end
		end)
	end, release_pending)
end

--- Shows a freshness state that carries no data (loading, failed refresh).
--- @param generation integer Dashboard generation.
--- @param webview table Exact webview owner.
--- @param freshness string Encoded freshness state.
--- @param revision integer Ordering against data publications.
--- @return boolean admitted
local function publish_freshness(generation, webview, freshness, revision)
	local code = string.format("window.setTypingMetricsFreshness(%s,%d);", freshness, revision)
	return when_ready(generation, webview, "freshness", "setTypingMetricsFreshness", function()
		submit_javascript(generation, webview, "freshness", code)
	end, function() end)
end

--- Paints the persisted snapshot, or the loading state when there is none.
--- Reads one file and hands its payload to the page verbatim.
local function prefill_from_disk_cache(generation, webview)
	if generation ~= _generation or M._wv ~= webview then return false end
	local snapshot = Snapshot.load()
	if not snapshot then
		publish_freshness(generation, webview, freshness_json("loading"), 0)
		return false
	end
	_painted_snapshot_at = snapshot.generated_at
	return publish_data(generation, webview, "cache", snapshot.payload, 0, true,
		freshness_json("stale", snapshot.generated_at))
end

--- Publishes one completed job's result.
local function deliver_work(generation, webview, work, ok, result)
	if not delivery_is_current(generation, webview) then return end
	if work.kind == "full" then
		_publication_revision = _publication_revision + 1
		if not ok then
			publish_freshness(generation, webview, freshness_json("failed", _painted_snapshot_at),
				_publication_revision)
			return
		end
		Snapshot.save(result.payload, result.generated_at)
		publish_data(generation, webview, "manifest", result.payload, _publication_revision, true,
			freshness_json("fresh"))
	elseif work.kind == "live" then
		if not ok then return end
		_publication_revision = _publication_revision + 1
		publish_data(generation, webview, "live manifest", result, _publication_revision, false)
	else
		local request_id = work.request_id
		local encoded = ok and result or "null"
		local js_cmd
		if request_id then
			js_cmd = string.format("window.receive_range_data(%s,%d)", encoded, request_id)
		else
			-- Backward compatibility for a cached dashboard loaded before the
			-- request-id protocol was introduced
			js_cmd = string.format("window.receive_range_data(%s)", encoded)
		end
		submit_javascript(generation, webview, "range", js_cmd)
	end
end

--- Starts the next queued job when none is running.
--- @param generation integer Dashboard generation.
--- @param webview table Exact webview owner.
--- @return boolean accepted
local function run_next_work(generation, webview)
	if not delivery_is_current(generation, webview) then return false end
	if M._job then return true end
	local work
	if _pending_work.full then
		_pending_work.full = false
		-- A full refresh publishes the manifest too, so it absorbs a live one
		_pending_work.live = false
		work = { kind = "full" }
	elseif _pending_work.live then
		_pending_work.live = false
		work = { kind = "live" }
	elseif _pending_work.range then
		work = _pending_work.range
		_pending_work.range = nil
	else
		return true
	end
	local job
	job = PacedJob.start({
		label = "Typing metrics " .. work.kind .. " projection",
		body = function(pacer)
			if work.kind == "full" then return compute_full(pacer) end
			if work.kind == "live" then return compute_live(pacer) end
			return compute_range(work.query, pacer)
		end,
		on_done = function(ok, result)
			if M._job ~= job then return end
			M._job = nil
			deliver_work(generation, webview, work, ok, result)
			run_next_work(generation, webview)
		end,
	})
	if not job then
		deliver_work(generation, webview, work, false, "projection job refused")
		return false
	end
	M._job = job
	return true
end

--- Queues projection work for the current window.
--- @param generation integer Dashboard generation.
--- @param webview table Exact webview owner.
--- @param kind string "full", "live" or "range".
--- @param work table|nil Range work { kind, query, request_id }.
--- @return boolean accepted
request_work = function(generation, webview, kind, work)
	if not delivery_is_current(generation, webview) then return false end
	if kind == "full" then
		_pending_work.full = true
	elseif kind == "live" then
		_pending_work.live = true
	else
		-- The frontend supersedes older requests itself; only the latest is served
		_pending_work.range = work
	end
	return run_next_work(generation, webview)
end

--- Refresh just the manifest-backed UI state after an ingest. `process_manifest`
--- preserves the current filters and requests their n-gram range again, so the
--- all-app prefetch is not recomputed on every live update.
local function refresh_live_manifest(generation, webview)
	return request_work(generation, webview, "live")
end





-- =============================
-- =============================
-- ======= 5/ Public API =======
-- =============================
-- =============================

--- Closes the typing metrics dashboard without losing an ambiguous native owner.
--- @return boolean committed
function M.close()
	if not settle_startup_webview() then return false end
	if not M._wv then return stop_runtime() end
	local owned = M._wv
	if type(owned.delete) ~= "function" then
		Logger.error(LOG, "Typing metrics close refused; owned WebView has no delete method.")
		return false
	end
	_closing_webview = owned
	local ok, err = xpcall(function() owned:delete() end, debug.traceback)
	if _closing_webview == owned then _closing_webview = nil end
	if not ok then
		Logger.error(LOG, "Typing metrics close did not commit; exact WebView retained: %s.",
			tostring(err))
		return false
	end
	if M._wv == owned then M._wv = nil end
	local stopped = stop_runtime()
	if not stopped then Logger.error(LOG, "Typing metrics close retained timer cleanup debt.") end
	Logger.info(LOG, "Typing metrics dashboard closed.")
	return stopped
end

function M.show()
	if not settle_startup_webview() then
		Logger.error(LOG, "Typing metrics dashboard startup refused: prior WebView cleanup remains pending.")
		return false
	end
	if M._wv then
		local generation, webview = _generation, M._wv
		local already_focused = false
		pcall(function()
			local win     = webview:hswindow()
			if win then
				local focused   = hs.window.focusedWindow()
				already_focused = focused and focused:id() == win:id()
			end
		end)
		if not delivery_is_current(generation, webview) then return false end
		if already_focused then
			Logger.debug(LOG, "Dashboard already focused — closing.")
			if not delivery_is_current(generation, webview) then return false end
			return M.close()
		end
		Logger.debug(LOG, "Dashboard already open, bringing to front…")
		if not delivery_is_current(generation, webview) then return false end
		ui_builder.force_focus(webview, false, { is_current = function()
			return delivery_is_current(generation, webview)
		end })
		return submit_javascript(generation, webview, "reopen", "window.apply_date_app_filters();")
	end

	Logger.start(LOG, "Opening typing metrics dashboard…")

	local sf    = hs.screen.mainScreen():frame()
	local frame = { x = sf.x + 50, y = sf.y + 50, w = sf.w - 100, h = sf.h - 100 }

	local assets_dir = resolve_ui_assets_dir("metrics_typing")
	if not assets_dir then
		Logger.error(LOG, "Cannot open dashboard — shared UI assets not found.")
		return false
	end
	if not ensure_ingest_listener() then return false end

	_generation = _generation + 1
	local generation = _generation
	_publication_revision = 0
	_pending_live_publication = nil
	_cache_reset_owner = nil
	local webview
	M._wv = ui_builder.show_webview({
		frame       = frame,
		title       = i18n.get("metrics_apps.title"),
		style_masks = 15,
		assets_dir = assets_dir,
		on_close   = function()
			if generation ~= _generation then return end
			if _closing_webview == webview then return end
			_generation = _generation + 1
			M._wv = nil
			_painted_snapshot_at = nil
			local job_stopped = cancel_job()
			local poller_stopped = cancel_poller()
			local continuations_stopped = cancel_continuations()
			if not job_stopped or not poller_stopped or not continuations_stopped then
				Logger.error(LOG, "Typing metrics close retained timer cleanup debt.")
			end
			Logger.info(LOG, "Typing metrics dashboard closed.")
		end,
	})
	webview = M._wv
	if not webview then
		Logger.error(LOG, "Typing metrics dashboard webview creation failed.")
		return false
	end

	-- The snapshot paint reads one file; the aggregation is a paced job whose
	-- first slice runs on a later timer turn, never on this open path.
	local bootstrap_committed = schedule_continuation(0.05, generation, webview, function()
		prefill_from_disk_cache(generation, webview)
		if not request_work(generation, webview, "full") then
			Logger.error(LOG, "Dashboard fresh-data load could not be scheduled.")
		end
	end, "Dashboard bootstrap")
	if not bootstrap_committed then
		return rollback_startup_webview(webview, "bootstrap timer unavailable")
	end

	-- JS-side filter request poller.
	if not cancel_poller() then
		return rollback_startup_webview(webview, "prior poller cleanup remains pending")
	end
	local poll_ok, poll_candidate, poll_committed = xpcall(function()
		return TimerScheduler.every(0.3, function()
		if generation ~= _generation or M._wv ~= webview then return end
		pcall(function()
			submit_javascript(generation, webview, "request poll", "window._lua_request", function(req)
				if generation ~= _generation or M._wv ~= webview then return end
				if req and type(req) == "string" and req ~= "" and req ~= "null" then
					local expected = encode_delivery(generation, webview, "request reset", req)
					if not expected then return end
					local reset = "(function(){if(window._lua_request!==" .. expected
						.. "){return false;}window._lua_request=null;return true;})()"
					submit_javascript(generation, webview, "request reset", reset, function(applied)
						if applied == false then return end
						if applied ~= true then
							delivery_failure(generation, webview, "request reset", "invalid acknowledgement")
							return
						end
						local ok, query = pcall(json.decode, req)
						if ok and query then
							if query.action == "clear_cache" then
								clear_cache(generation, webview, query.reset_id)
							else
								local request_id = tonumber(query.request_id)
								if not (request_id and request_id > 0 and request_id % 1 == 0) then
									request_id = nil
								end
								request_work(generation, webview, "range",
									{ kind = "range", query = query, request_id = request_id })
							end
						end
					end)
				end
			end)
		end)
		end)
	end, debug.traceback)
	if type(poll_candidate) == "table" then M._timer = poll_candidate end
	if not poll_ok or type(poll_candidate) ~= "table" or poll_committed ~= true then
		return rollback_startup_webview(webview,
			"request poller unavailable: " .. tostring(poll_ok and poll_committed or poll_candidate))
	end

	Logger.success(LOG, "Typing metrics dashboard window opened.")
	return true
end

--- Signals that a fresh ingest cycle just completed. Both the n-gram tables
--- and the manifest-backed KPIs change, so refresh the manifest and replay the
--- active range without recomputing the global all-app prefetch.
function M.push_live_update(_unused)
	if M._wv and not M._pending_full_refresh then
		local generation = _generation
		local webview = M._wv
		M._pending_full_refresh = true
		if not schedule_continuation(0, generation, webview, function()
			M._pending_full_refresh = false
			refresh_live_manifest(generation, webview)
		end, "Live metrics manifest refresh") then
			M._pending_full_refresh = false
			return false
		end
		Logger.debug(LOG, "push_live_update: scheduled full manifest refresh.")
		return true
	end
	return false
end

return M
