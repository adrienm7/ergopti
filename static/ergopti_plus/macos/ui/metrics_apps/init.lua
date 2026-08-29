--- ui/metrics_apps/init.lua

--- ==============================================================================
--- MODULE: Apps Time Dashboard UI
--- DESCRIPTION:
--- Hosts the WebView for the per-app time dashboard. Reads from the new
--- `db.sqlite` cache via `modules.keylogger.sqlite_reader` and projects the
--- result into the JSON shape consumed by the (unchanged) frontend JS.
---
--- FEATURES & RATIONALE:
--- 1. SQLite-only data path: no openssl decrypt, no manifest.json, no
---    encrypted SQLite — every value originates from `db.sqlite`, which is
---    rebuildable from `data.sql` (canonical text source of truth).
--- 2. Cross-device aggregation: the projection sums by (date, app) across
---    every row in `devices`, so the UI shows a single global stat.
--- 3. Two-stage paint: the dashboard pre-fills from a disk-cached snapshot
---    within milliseconds; the SQLite read runs in the background and
---    overwrites the cache once ready.
--- 4. Format-stable: emits the legacy manifest shape so the frontend JS
---    keeps working without rewrite.
--- ==============================================================================

local M = {}

local hs         = hs
local fs         = require("hs.fs")
local json       = require("hs.json")
local ui_builder = require("ui.ui_builder")
local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local dialog     = require("infra.dialog_util")
local i18n       = require("infra.i18n")
local FileSystem = require("adapters.file_system")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "metrics_apps"

local BRIDGE_DEFER_DELAY_SEC = 0
local FRESH_WITH_CACHE_DELAY_SEC = 0.40
local FRESH_WITHOUT_CACHE_DELAY_SEC = 0.05
local MANIFEST_RETRY_DELAY_SEC = 0.15
local MANIFEST_RETRY_LIMIT = 60
local PREFILL_RETRY_DELAY_SEC = 0.10
local PREFILL_RETRY_LIMIT = 50
local STARTUP_FOCUS_STEPS = {
	{ delay = 0.05, above_everything = true },
	{ delay = 0.15, above_everything = true },
	{ delay = 0.35, above_everything = true },
	{ delay = 0.70, above_everything = false },
}

M._wv             = nil
M._app_icon_cache = {}
--- True once the dashboard has subscribed to completed ingest cycles.
M._ingest_listener_registered = false
local _log_manager = nil
local _generation = 0
local _continuation_timers = {}
local _chooser_owners = {}
local _next_chooser_id = 0

--- Presents one chooser behind a strong owner until its completion callback.
--- @param label string Stable diagnostic label.
--- @param completion function Chooser completion callback.
--- @param configure function Applies choices and presentation options.
--- @return boolean committed
local function present_owned_chooser(label, completion, configure)
	local owner_id = nil
	local created, chooser_or_err = xpcall(function()
		return hs.chooser.new(function(choice)
			if owner_id then _chooser_owners[owner_id] = nil end
			local ok, err = xpcall(function() completion(choice) end, debug.traceback)
			if not ok then
				Logger.error(LOG, "%s completion failed: %s.", label, tostring(err))
			end
		end)
	end, debug.traceback)
	if not created or chooser_or_err == nil or chooser_or_err == false then
		Logger.error(LOG, "%s construction failed: %s.", label, tostring(chooser_or_err))
		return false
	end

	_next_chooser_id = _next_chooser_id + 1
	owner_id = _next_chooser_id
	_chooser_owners[owner_id] = chooser_or_err
	local configured, configure_err = xpcall(function()
		configure(chooser_or_err)
		return chooser_or_err:show()
	end, debug.traceback)
	if not configured or configure_err ~= chooser_or_err then
		Logger.error(LOG, "%s presentation failed: %s.", label, tostring(configure_err))
		local delete_ok, delete_err = xpcall(function()
			return chooser_or_err:delete()
		end, debug.traceback)
		if delete_ok then
			_chooser_owners[owner_id] = nil
		else
			Logger.error(LOG, "%s rollback failed; exact owner retained: %s.",
				label, tostring(delete_err))
		end
		return false
	end
	return true
end

--- Deletes every chooser still owned by the dashboard lifecycle.
--- @return boolean settled
local function delete_owned_choosers()
	local settled = true
	for owner_id, chooser in pairs(_chooser_owners) do
		local ok, err = xpcall(function() return chooser:delete() end, debug.traceback)
		if ok then
			_chooser_owners[owner_id] = nil
		else
			settled = false
			Logger.error(LOG, "Apps dashboard chooser cleanup failed; exact owner retained: %s.",
				tostring(err))
		end
	end
	return settled
end

--- Tests whether one callback still belongs to the exact live window.
--- @param generation integer Captured dashboard generation.
--- @param webview table Captured dashboard webview.
--- @return boolean current True only for the published exact owner.
local function is_current_window(generation, webview)
	return generation == _generation and webview ~= nil and M._wv == webview
end

--- Wraps one external async completion in identity and file-log guards.
--- @param generation integer Captured dashboard generation.
--- @param webview table Captured dashboard webview.
--- @param label string Diagnostic label.
--- @param callback function Completion body.
--- @return function guarded Callback safe for an external runloop.
local function owned_async_callback(generation, webview, label, callback)
	return function(...)
		if not is_current_window(generation, webview) then return end
		local args = table.pack(...)
		local ok, err = xpcall(function()
			callback(table.unpack(args, 1, args.n))
		end, debug.traceback)
		if not ok then
			Logger.error(LOG, "%s callback raised: %s.", label, tostring(err))
		end
	end
end

--- Allows direct public category calls while fencing window-owned callbacks.
--- @param generation integer|nil Optional captured dashboard generation.
--- @param webview table|nil Optional captured dashboard webview.
--- @return boolean current True when unowned or owned by the live window.
local function owner_is_current(generation, webview)
	if generation == nil and webview == nil then return true end
	return is_current_window(generation, webview)
end

--- Cancels one exact scheduler handle without dropping refused cleanup debt.
--- @param handle table|nil Scheduler handle.
--- @return boolean settled True only when no native timer remains owned.
local function cancel_timer(handle)
	if type(handle) ~= "table" then return true end
	local ok, settled_or_err = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if not ok or settled_or_err ~= true then
		Logger.error(LOG, "Apps dashboard timer cleanup failed; exact handle retained: %s.",
			tostring(ok and settled_or_err or settled_or_err))
		return false
	end
	return true
end

--- Cancels every delayed continuation independently and retains refusals.
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

--- Schedules one exact generation-owned continuation.
--- @param delay number Delay in seconds.
--- @param generation integer Captured dashboard generation.
--- @param webview table Captured dashboard webview.
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
				Logger.error(LOG, "%s retained timer cleanup debt.", label)
			elseif handle then
				_continuation_timers[handle] = nil
			end
			if not is_current_window(generation, webview) then return end
			callback()
		end)
	end, debug.traceback)
	handle = candidate
	if type(handle) == "table" then _continuation_timers[handle] = true end
	if not ok or type(handle) ~= "table" or committed ~= true then
		if type(handle) == "table" and cancel_timer(handle) then
			_continuation_timers[handle] = nil
		end
		Logger.error(LOG, "%s timer was not committed: %s.", label,
			tostring(ok and committed or candidate))
		return false
	end
	timer_committed = true
	return true
end

--- Invalidates and tears down one published exact window generation.
--- @param generation integer Captured dashboard generation.
--- @param webview table Captured dashboard webview.
--- @param delete_window boolean Whether to delete the native webview.
--- @param reason string Diagnostic reason.
--- @return boolean settled True only when timers and requested delete settled.
local function close_window_generation(generation, webview, delete_window, reason)
	if not is_current_window(generation, webview) then return true end
	_generation = _generation + 1
	M._wv = nil
	local timers_settled = cancel_continuations()
	local choosers_settled = delete_owned_choosers()
	local window_settled = true
	if delete_window then
		local delete_ok, delete_result = xpcall(function()
			return webview:delete()
		end, debug.traceback)
		window_settled = delete_ok and delete_result ~= false
		if not window_settled then
			Logger.error(LOG, "Apps dashboard window delete failed during %s: %s.",
				reason, tostring(delete_result))
		end
	end
	if not timers_settled then
		Logger.error(LOG, "Apps dashboard %s retained timer cleanup debt.", reason)
	end
	return timers_settled and choosers_settled and window_settled
end

--- Rolls back an unpublished window candidate and every acquired timer.
--- @param generation integer Candidate generation.
--- @param webview table|nil Exact candidate webview.
--- @param reason string Diagnostic reason.
--- @return boolean Always false because startup did not commit.
local function rollback_window_candidate(generation, webview, reason)
	if generation == _generation then _generation = _generation + 1 end
	local timers_settled = cancel_continuations()
	local choosers_settled = delete_owned_choosers()
	local window_settled = true
	if webview then
		local delete_ok, delete_result = xpcall(function()
			return webview:delete()
		end, debug.traceback)
		window_settled = delete_ok and delete_result ~= false
		if not window_settled then
			Logger.error(LOG, "Apps dashboard candidate delete failed during %s: %s.",
				reason, tostring(delete_result))
		end
	end
	if not timers_settled then
		Logger.error(LOG, "Apps dashboard startup rollback retained timer cleanup debt.")
	end
	if not choosers_settled then
		Logger.error(LOG, "Apps dashboard startup rollback retained chooser cleanup debt.")
	end
	Logger.error(LOG, "Apps metrics dashboard startup failed during %s.", reason)
	return false
end

--- Acquires the lifetime ingest subscription before a window can be
--- published. A missing subscriber makes an open dashboard silently stale.
--- @return boolean registered
local function ensure_ingest_listener()
	if M._ingest_listener_registered then return true end
	local ok, registered_or_err = xpcall(function()
		_log_manager = _log_manager or require("modules.keylogger.log_manager")
		if type(_log_manager) ~= "table" or type(_log_manager.on_ingest_done) ~= "function" then
			error("LogManager.on_ingest_done is unavailable")
		end
		return _log_manager.on_ingest_done(function()
			M.push_live_update()
		end)
	end, debug.traceback)
	if not ok or registered_or_err ~= true then
		Logger.error(LOG, "Apps metrics ingest-listener acquisition failed: %s.",
			tostring(ok and registered_or_err or registered_or_err))
		return false
	end
	M._ingest_listener_registered = true
	Logger.debug(LOG, "Post-ingest live-update listener registered.")
	return true
end

--- Cached projection — invalidated when the SQLite `meta.rev` advances.
M._manifest_cache  = nil
M._manifest_rev    = -1




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

local MAX_ICON_LOOKUPS_PER_OPEN = 30

local CONFIG_DIR      = hs.configdir .. "/data"
local CATEGORIES_FILE = CONFIG_DIR .. "/app_categories.json"
--- Fallback category assigned to an uncategorised app on first edit.
---
--- A FUNCTION rather than a module-level constant, and it reads the same i18n key
--- list_existing_categories() reads. Collapsing the two duplicated literals into a
--- constant left the constant itself French, so the file ended up with two SOURCES
--- for one value: on any non-French locale the key returned "General"/"Allgemein"/…
--- while the constant still returned the French spelling, the category picker's
--- current-selection tick matched nothing, and every unclassified app was stored
--- under a name no locale displays. A constant cannot fix it either - this module is
--- required before the locale is settled, so the value has to resolve at call time.
--- @return string The localised default category name.
local function default_app_category()
	return i18n.get("metrics_apps.general_category")
end

--- On-disk snapshot of the last successful render (instant pre-fill).
local UI_TMP_DIR    = (os.getenv("TMPDIR") or "/tmp/"):gsub("/?$", "/")
local UI_CACHE_FILE = UI_TMP_DIR .. "ergopti_metrics_apps_cache.json"





-- ============================
-- ============================
-- ======= 1/ App Icons =======
-- ============================
-- ============================

--- Resolve a base64 data URL for an app's icon, or nil when unavailable.
local function get_app_icon(app_name)
	local app = hs.application.find(app_name)
	if app and type(app.bundleID) == "function" then
		local bid = app:bundleID()
		if bid then
			local ok, img = pcall(hs.image.imageFromAppBundle, bid)
			if ok and img then
				pcall(function() img:setSize({ w = 64, h = 64 }) end)
				local ok2, encoded = pcall(function() return img:encodeAsURLString() end)
				if ok2 and encoded then return encoded end
			end
		end
	end
	return nil
end





-- ==========================================
-- ==========================================
-- ======= 2/ User category overrides =======
-- ==========================================
-- ==========================================

local function load_categories()
	local read_ok, content, read_status, read_detail = pcall(FileSystem.read_with_status, CATEGORIES_FILE)
	if not read_ok or read_status == "error" then
		Logger.error(LOG, "App categories read did not commit; edit refused — %s.",
			tostring(read_ok and read_detail or content))
		return nil, "failed"
	end
	if read_status == "absent" then return {}, "absent", { status = "absent" } end
	if read_status ~= "ok" or type(content) ~= "string" then
		Logger.error(LOG, "App categories returned an invalid read status; edit refused — %s.",
			tostring(read_status))
		return nil, "failed"
	end

	local decode_ok, data = pcall(json.decode, content)
	if not decode_ok or type(data) ~= "table" then
		Logger.error(LOG, "App categories contain invalid JSON; edit refused.")
		return nil, "failed"
	end
	return data, "ok", { status = "ok", content = content }
end

local function save_categories(data, source_snapshot)
	if type(source_snapshot) ~= "table" then
		Logger.error(LOG, "App categories save refused without an exact source snapshot.")
		return false
	end
	local encode_ok, encoded = pcall(json.encode, data)
	if not encode_ok or type(encoded) ~= "string" then
		Logger.error(LOG, "App categories encode failed; changes were not saved.")
		return false
	end

	local write_ok, committed = pcall(
		FileSystem.write_if_unchanged,
		CATEGORIES_FILE,
		encoded,
		source_snapshot
	)
	if not write_ok or committed ~= true then
		Logger.error(LOG, "App-categories atomic publication did not commit; changes were not saved.")
		return false
	end
	return true
end

local function push_categories_to_ui(generation, webview)
	webview = webview or M._wv
	generation = generation or _generation
	if not is_current_window(generation, webview) then return false end
	local categories = load_categories()
	if not categories then return false end
	if not is_current_window(generation, webview) then return false end
	local ok, result_or_err = xpcall(function()
		return webview:evaluateJavaScript(string.format(
			"window.updateUserCategories(%s);", json.encode(categories)))
	end, debug.traceback)
	if not ok or result_or_err == false then
		Logger.error(LOG, "App categories injection failed: %s.", tostring(result_or_err))
		return false
	end
	return is_current_window(generation, webview)
end

local function list_existing_categories()
	local cats = load_categories()
	if not cats then return nil end
	local general = i18n.get("metrics_apps.general_category")
	local seen = { [general] = true }
	local result = { general }
	for _, entry in pairs(cats) do
		local t = type(entry) == "table" and entry.type or nil
		if type(t) == "string" and t ~= "" and not seen[t] then
			seen[t] = true
			table.insert(result, t)
		end
	end
	table.sort(result, function(a, b) return a:lower() < b:lower() end)
	return result
end

local function prompt_score_then_save(app_name, chosen_cat, default_score, generation, webview)
	if not owner_is_current(generation, webview) then return false end
	local btn, score_str = dialog.text_prompt(
		i18n.get("metrics_apps.score_title"),
		string.format(i18n.get("metrics_apps.score_prompt"), app_name),
		tostring(default_score or 0), i18n.get("button.ok"), i18n.get("common.cancel"))
	if not owner_is_current(generation, webview) then return false end
	if btn ~= i18n.get("button.ok") then return end
	local score = tonumber(score_str)
	if not score or score < -2 or score > 2 then
		dialog.alert(i18n.get("common.warning"), i18n.get("metrics_apps.score_error"), i18n.get("button.ok"))
		return
	end
	local cats, _, source_snapshot = load_categories()
	if not cats then return false end
	cats[app_name] = { type = chosen_cat, score = score }
	if not save_categories(cats, source_snapshot) then return false end
	if generation ~= nil then
		push_categories_to_ui(generation, webview)
	elseif M._wv then
		push_categories_to_ui(_generation, M._wv)
	end
	return true
end

function M.prompt_category(app_name, default_cat, default_score, generation, webview)
	if not owner_is_current(generation, webview) then return false end
	local existing = list_existing_categories()
	if not existing then return false end
	local choices  = {}

	table.insert(choices, { text = i18n.get("metrics_apps.new_category_item"), subText = i18n.get("metrics_apps.new_category_create_subtext"), _kind = "new" })
	table.insert(choices, { text = i18n.get("metrics_apps.rename_item"), subText = i18n.get("metrics_apps.rename_subtext"), _kind = "rename" })
	for _, cat in ipairs(existing) do
		local marker = (cat == default_cat) and "  ✓" or ""
		table.insert(choices, { text = cat .. marker, subText = i18n.get("metrics_apps.use_category_subtext"), _kind = "pick", _value = cat })
	end

	return present_owned_chooser("Category chooser", function(choice)
		if not owner_is_current(generation, webview) then return end
		if not choice then return end
		if choice._kind == "pick" then
			prompt_score_then_save(app_name, choice._value, default_score, generation, webview)
		elseif choice._kind == "new" then
			local btn, new_cat = dialog.text_prompt(i18n.get("metrics_apps.new_category_title"),
				string.format(i18n.get("metrics_apps.new_category_prompt"), app_name),
				"", i18n.get("button.ok"), i18n.get("common.cancel"))
			if not owner_is_current(generation, webview) then return end
			if btn == i18n.get("button.ok") and new_cat and new_cat ~= "" then
				prompt_score_then_save(app_name, new_cat, default_score, generation, webview)
			end
		elseif choice._kind == "rename" then
			local rename_choices = {}
			for _, cat in ipairs(existing) do
				table.insert(rename_choices, { text = cat, subText = i18n.get("metrics_apps.rename_title") })
			end
			present_owned_chooser("Category rename chooser", function(c2)
				if not owner_is_current(generation, webview) then return end
				if not c2 then return end
				local btn, new_name = dialog.text_prompt(i18n.get("metrics_apps.rename_title"),
					string.format(i18n.get("metrics_apps.rename_prompt"), c2.text),
					c2.text, i18n.get("button.ok"), i18n.get("common.cancel"))
				if not owner_is_current(generation, webview) then return end
				if btn == i18n.get("button.ok") and new_name and new_name ~= "" and new_name ~= c2.text then
					local cats, _, source_snapshot = load_categories()
					if not cats then return end
					for _, entry in pairs(cats) do
						if type(entry) == "table" and entry.type == c2.text then
							entry.type = new_name
						end
					end
					if save_categories(cats, source_snapshot) then
						if generation ~= nil then
							push_categories_to_ui(generation, webview)
						elseif M._wv then
							push_categories_to_ui(_generation, M._wv)
						end
					end
				end
			end, function(sub)
				sub:placeholderText(i18n.get("metrics_apps.rename_chooser_placeholder"))
				sub:choices(rename_choices)
			end)
		end
	end, function(chooser)
		chooser:placeholderText(string.format(i18n.get("metrics_apps.chooser_placeholder"), app_name))
		chooser:choices(choices)
	end)
end

local function prompt_pick_app(generation, webview)
	if not is_current_window(generation, webview) then return false end
	local ok_mod, app_picker = pcall(require, "infra.app_picker")
	if not ok_mod then
		Logger.error(LOG, "lib.app_picker module unavailable.")
		return
	end
	-- Discovery is asynchronous: it shells out to `find` across two application
	-- trees, and doing that synchronously froze the runloop — and the keyboard tap
	-- with it — for the whole scan. Everything that needs the result moves into the
	-- continuation.
	app_picker.discover_apps(function(choices)
		if not is_current_window(generation, webview) then return end
		if type(choices) ~= "table" or #choices == 0 then
			dialog.alert(i18n.get("common.warning"), i18n.get("metrics_apps.no_app_detected"), i18n.get("button.ok"))
			return
		end
		present_owned_chooser("Application metrics chooser", function(choice)
			if not is_current_window(generation, webview) then return end
			if not choice then return end
			local cats    = load_categories()
			if not cats then return end
			local current = cats[choice.text] or { type = default_app_category(), score = 0 }
			M.prompt_category(choice.text, current.type, current.score, generation, webview)
		end, function(chooser)
			chooser:placeholderText(i18n.get("metrics_apps.pick_app_placeholder"))
			chooser:choices(choices)
			chooser:searchSubText(true)
		end)
	end)
	return true
end

local function handle_bridge_message(msg, generation, webview)
	if not is_current_window(generation, webview) then return false end
	if type(msg) ~= "table" then return end
	local body = msg.body
	if type(body) ~= "table" then return end

	local act = body.action
	if act == "edit" then
		local app_name = tostring(body.app or "")
		local cat      = tostring(body.cat or default_app_category())
		local score    = tonumber(body.score) or 0
		return schedule_continuation(BRIDGE_DEFER_DELAY_SEC, generation, webview,
			function() M.prompt_category(app_name, cat, score, generation, webview) end,
			"Apps category prompt")
	elseif act == "pick" then
		return schedule_continuation(BRIDGE_DEFER_DELAY_SEC, generation, webview,
			function() prompt_pick_app(generation, webview) end,
			"Apps picker prompt")
	else
		Logger.warn(LOG, "Unknown bridge action received: %s.", tostring(act))
	end
	return false
end





-- ================================
-- ================================
-- ======= 3/ Disk pre-fill =======
-- ================================
-- ================================

local function save_disk_cache(payload)
	local ok_enc, body = pcall(json.encode, payload)
	if not ok_enc then return end
	local f = io.open(UI_CACHE_FILE, "w")
	if f then f:write(body); f:close() end
end

local function load_disk_cache()
	local f = io.open(UI_CACHE_FILE, "r")
	if not f then return nil end
	local content = f:read("*a"); f:close()
	local ok, data = pcall(json.decode, content)
	if not ok or type(data) ~= "table" then return nil end
	return data
end

--- Returns a shallow manifest copy augmented with the still-open foreground
--- interval. Persisted aggregates close intervals on focus changes; mutating the
--- cached projection here would add the same elapsed time again on every refresh.
--- @param manifest table SQLite projection keyed by date then application.
--- @return table Projection safe to send to the dashboard.
local function with_live_active_app_duration(manifest)
	local ok_tracker, tracker = pcall(require, "modules.keylogger.context_tracker")
	if not ok_tracker or type(tracker.get_active_app_snapshot) ~= "function" then return manifest end
	local ok_snapshot, snapshot = pcall(tracker.get_active_app_snapshot)
	if not ok_snapshot or type(snapshot) ~= "table"
		or type(snapshot.app) ~= "string" or type(snapshot.duration_ms) ~= "number"
		or snapshot.duration_ms <= 0
	then
		return manifest
	end

	local date_str = os.date("%Y-%m-%d")
	local projected = {}
	for date_key, day_data in pairs(manifest) do projected[date_key] = day_data end
	local original_day = manifest[date_str] or {}
	local day_copy = {}
	for app_name, app_data in pairs(original_day) do day_copy[app_name] = app_data end
	projected[date_str] = day_copy

	local original_app = original_day[snapshot.app] or {}
	local app_copy = {}
	for key, value in pairs(original_app) do app_copy[key] = value end
	app_copy.app_time_ms = (tonumber(app_copy.app_time_ms) or 0) + snapshot.duration_ms
	day_copy[snapshot.app] = app_copy
	return projected
end

local function raise_now(wv, above_everything)
	if not wv then return end
	pcall(function() wv:show() end)
	pcall(function() wv:bringToFront(above_everything) end)
	pcall(hs.focus)
	local ok, win = pcall(function() return wv:hswindow() end)
	if ok and win then
		pcall(function() win:raise() end)
		pcall(function() win:focus() end)
	end
end





-- ===============================
-- ===============================
-- ======= 4/ Data refresh =======
-- ===============================
-- ===============================

--- Read the current manifest from db.sqlite and inject it into the WebView.
--- Cached on `meta.rev` so consecutive opens within the same revision skip
--- the SQL pass entirely.
local function load_and_inject(generation, webview)
	if not is_current_window(generation, webview) then return false end

	local log_manager   = require("modules.keylogger.log_manager")
	local sqlite_reader = require("modules.keylogger.sqlite_reader")
	local sqlite_path   = log_manager.get_sqlite_path()
	if not sqlite_path or not fs.attributes(sqlite_path) then
		Logger.warn(LOG, "db.sqlite not available — dashboard will display empty.")
		return false
	end

	local rev = log_manager.get_db_rev()
	local manifest
	if M._manifest_cache and M._manifest_rev == rev then
		Logger.done(LOG, "Manifest cache hit (rev %d).", rev)
		manifest = M._manifest_cache
	else
		Logger.trace(LOG, "Manifest cache miss (rev %d) — querying SQLite…", rev)
		manifest = sqlite_reader.read_manifest(sqlite_path)
		M._manifest_cache = manifest
		M._manifest_rev   = rev
		Logger.done(LOG, "Manifest cached (rev %d).", rev)
	end
	if not is_current_window(generation, webview) then return false end

	local user_cats = load_categories()
	if not user_cats then
		Logger.warn(LOG, "Apps dashboard refresh refused because categories are unreadable.")
		return false
	end
	if not is_current_window(generation, webview) then return false end

	-- App icon collection (capped to keep first paint fast).
	local app_icons    = {}
	local icon_lookups = 0
	local seen_apps    = {}
	for _, day_data in pairs(manifest) do
		for app_name, _ in pairs(day_data) do
			if not seen_apps[app_name] then
				seen_apps[app_name] = true
				local cached = M._app_icon_cache[app_name]
				if cached ~= nil then
					if cached then app_icons[app_name] = cached end
				elseif icon_lookups < MAX_ICON_LOOKUPS_PER_OPEN then
					local icon = get_app_icon(app_name)
					M._app_icon_cache[app_name] = icon or false
					if icon then app_icons[app_name] = icon end
					icon_lookups = icon_lookups + 1
				end
			end
		end
	end

	local cached_manifest_json = json.encode(manifest)
	local manifest_json        = json.encode(with_live_active_app_duration(manifest))
	local user_cats_json = json.encode(user_cats)
	local app_icons_json = json.encode(app_icons)

	save_disk_cache({ manifest = cached_manifest_json, user_cats = user_cats_json, app_icons = app_icons_json })
	if not is_current_window(generation, webview) then return false end

	local function try_inject(remaining)
		if not is_current_window(generation, webview) then return end
		local probe_ok, probe_result = xpcall(function()
			return webview:evaluateJavaScript("typeof window.bootstrapMetricsAppsData",
				owned_async_callback(generation, webview, "Apps dashboard bootstrap probe", function(t)
			if t == "function" then
				local js = string.format("window.bootstrapMetricsAppsData(%s,%s,%s);",
					manifest_json, user_cats_json, app_icons_json)
				local inject_ok, inject_result = xpcall(function()
					return webview:evaluateJavaScript(js)
				end, debug.traceback)
				if not inject_ok or inject_result == false then
					Logger.error(LOG, "Apps dashboard manifest injection failed: %s.",
						tostring(inject_result))
					return
				end
				Logger.success(LOG, "Apps dashboard manifest injected.")
			elseif t == "undefined" then
				webview:evaluateJavaScript("typeof window.initDashboard",
					owned_async_callback(generation, webview,
						"Apps dashboard legacy bootstrap probe", function(t2)
					if t2 == "function" then
						local js = string.format(
							"window.ManifestData=%s;window.UserCategories=%s;window.AppIcons=%s;window.initDashboard();",
							manifest_json, user_cats_json, app_icons_json)
						local inject_ok, inject_result = xpcall(function()
							return webview:evaluateJavaScript(js)
						end, debug.traceback)
						if not inject_ok or inject_result == false then
							Logger.error(LOG, "Apps dashboard legacy injection failed: %s.",
								tostring(inject_result))
							return
						end
						Logger.success(LOG, "Apps dashboard manifest injected (legacy path).")
					elseif remaining > 0 then
						if not schedule_continuation(MANIFEST_RETRY_DELAY_SEC,
							generation, webview, function() try_inject(remaining - 1) end,
							"Apps dashboard legacy bootstrap retry")
						then
							close_window_generation(generation, webview, true,
								"legacy bootstrap retry refusal")
						end
					else
						Logger.error(LOG, "load_and_inject(): bootstrap not available.")
					end
				end))
			elseif remaining > 0 then
				if not schedule_continuation(MANIFEST_RETRY_DELAY_SEC,
					generation, webview, function() try_inject(remaining - 1) end,
					"Apps dashboard bootstrap retry")
				then
					close_window_generation(generation, webview, true,
						"bootstrap retry refusal")
				end
			else
				Logger.error(LOG, "load_and_inject(): apps dashboard JS not available.")
			end
		end))
		end, debug.traceback)
		if not probe_ok or probe_result == false then
			Logger.error(LOG, "Apps dashboard bootstrap probe failed: %s.",
				tostring(probe_result))
		end
	end
	try_inject(MANIFEST_RETRY_LIMIT)
	return true
end

local function prefill_from_disk_cache(generation, webview)
	if not is_current_window(generation, webview) then return false end
	local cached = load_disk_cache()
	if not cached or type(cached.manifest) ~= "string" then return false end
	local icons_json = cached.app_icons or "{}"
	local function try_inject_cache(remaining)
		if not is_current_window(generation, webview) then return end
		local probe_ok, probe_result = xpcall(function()
			return webview:evaluateJavaScript("typeof window.bootstrapMetricsAppsData",
				owned_async_callback(generation, webview, "Apps dashboard cache probe", function(t)
			if t == "function" then
				local js = string.format("window.bootstrapMetricsAppsData(%s,%s,%s);",
					cached.manifest, cached.user_cats or "{}", icons_json)
				local inject_ok, inject_result = xpcall(function()
					return webview:evaluateJavaScript(js)
				end, debug.traceback)
				if not inject_ok or inject_result == false then
					Logger.error(LOG, "Apps dashboard cache injection failed: %s.",
						tostring(inject_result))
					return
				end
				Logger.success(LOG, "Apps dashboard pre-filled from disk cache.")
			elseif t == "undefined" then
				webview:evaluateJavaScript("typeof window.initDashboard",
					owned_async_callback(generation, webview,
						"Apps dashboard legacy cache probe", function(t2)
					if t2 == "function" then
						local js = string.format(
							"window.ManifestData=%s;window.UserCategories=%s;window.AppIcons=%s;window.initDashboard();",
							cached.manifest, cached.user_cats or "{}", icons_json)
						local inject_ok, inject_result = xpcall(function()
							return webview:evaluateJavaScript(js)
						end, debug.traceback)
						if not inject_ok or inject_result == false then
							Logger.error(LOG, "Apps dashboard legacy cache injection failed: %s.",
								tostring(inject_result))
						end
					elseif remaining > 0 then
						if not schedule_continuation(PREFILL_RETRY_DELAY_SEC,
							generation, webview, function() try_inject_cache(remaining - 1) end,
							"Apps dashboard legacy cache retry")
						then
							close_window_generation(generation, webview, true,
								"legacy cache retry refusal")
						end
					end
				end))
			elseif remaining > 0 then
				if not schedule_continuation(PREFILL_RETRY_DELAY_SEC,
					generation, webview, function() try_inject_cache(remaining - 1) end,
					"Apps dashboard cache retry")
				then
					close_window_generation(generation, webview, true,
						"cache retry refusal")
				end
			end
		end))
		end, debug.traceback)
		if not probe_ok or probe_result == false then
			Logger.error(LOG, "Apps dashboard cache probe failed: %s.",
				tostring(probe_result))
		end
	end
	try_inject_cache(PREFILL_RETRY_LIMIT)
	return true
end





-- =============================
-- =============================
-- ======= 5/ Public API =======
-- =============================
-- =============================

function M.show()
	if M._wv then
		Logger.debug(LOG, "Dashboard already open, bringing to front…")
		local webview = M._wv
		local generation = _generation
		local focus_ok, focus_result = xpcall(function()
			return ui_builder.force_focus(webview)
		end, debug.traceback)
		if not focus_ok or focus_result == false
			or not is_current_window(generation, webview)
		then
			Logger.error(LOG, "Apps metrics dashboard focus failed: %s.",
				tostring(focus_result))
			return false
		end
		return true
	end

	Logger.start(LOG, "Opening apps time dashboard…")

	local sf    = hs.screen.mainScreen():frame()
	local frame = { x = sf.x + 50, y = sf.y + 50, w = sf.w - 100, h = sf.h - 100 }

	local assets_dir = resolve_ui_assets_dir("metrics_apps")
	if not assets_dir then
		Logger.error(LOG, "Cannot open dashboard — shared UI assets not found.")
		return false
	end
	if not ensure_ingest_listener() then return false end

	_generation = _generation + 1
	local generation = _generation
	if not cancel_continuations() then
		Logger.error(LOG, "Apps metrics dashboard startup refused: prior timer cleanup remains pending.")
		return false
	end
	if not delete_owned_choosers() then
		Logger.error(LOG, "Apps metrics dashboard startup refused: prior chooser cleanup remains pending.")
		return false
	end

	local webview
	local closed_during_create = false
	local creation_in_progress = true
	local ucc_ok, ucc_or_err = xpcall(function()
		local candidate = hs.webview.usercontent.new("metrics_apps_bridge")
		if not candidate or type(candidate.setCallback) ~= "function" then
			error("usercontent candidate unavailable")
		end
		local callback_result = candidate:setCallback(function(msg)
			if not is_current_window(generation, webview) then return end
			handle_bridge_message(msg, generation, webview)
		end)
		if not callback_result then error("usercontent callback registration refused") end
		return candidate
	end, debug.traceback)
	if not ucc_ok or not ucc_or_err then
		creation_in_progress = false
		return rollback_window_candidate(generation, nil,
			"usercontent bridge acquisition: " .. tostring(ucc_or_err))
	end

	local ok_webview, webview_or_err = xpcall(function()
		webview = ui_builder.show_webview({
		frame       = frame,
		title       = i18n.get("metrics_apps.window_title"),
		style_masks = 15,
		assets_dir  = assets_dir,
		usercontent = ucc_or_err,
		on_close    = function()
			if creation_in_progress then
				closed_during_create = true
				return
			end
			if not is_current_window(generation, webview) then return end
			close_window_generation(generation, webview, false, "native close")
			Logger.info(LOG, "Apps time dashboard closed.")
		end,
	})
		return webview
	end, debug.traceback)
	creation_in_progress = false
	if not ok_webview or not webview_or_err or closed_during_create then
		return rollback_window_candidate(generation, webview,
			closed_during_create and "reentrant native close"
				or ("webview acquisition: " .. tostring(webview_or_err)))
	end

	for index, step in ipairs(STARTUP_FOCUS_STEPS) do
		if not schedule_continuation(step.delay, generation, webview,
			function() raise_now(webview, step.above_everything) end,
			string.format("Apps dashboard focus step %d", index))
		then
			return rollback_window_candidate(generation, webview,
				string.format("focus timer %d acquisition", index))
		end
	end

	if not schedule_continuation(FRESH_WITHOUT_CACHE_DELAY_SEC, generation, webview, function()
		local had_cache = prefill_from_disk_cache(generation, webview)
		local refresh_delay = had_cache
			and FRESH_WITH_CACHE_DELAY_SEC or FRESH_WITHOUT_CACHE_DELAY_SEC
		if not schedule_continuation(refresh_delay, generation, webview,
			function() load_and_inject(generation, webview) end,
			"Apps dashboard fresh-data load")
		then
			close_window_generation(generation, webview, true,
				"fresh-data timer refusal")
		end
	end, "Apps dashboard bootstrap") then
		return rollback_window_candidate(generation, webview,
			"bootstrap timer acquisition")
	end

	M._wv = webview
	raise_now(webview, true)
	if not is_current_window(generation, webview) then
		Logger.error(LOG, "Apps metrics dashboard closed during final publication.")
		return false
	end

	Logger.success(LOG, "Apps time dashboard window opened.")
	return true
end

--- Live-refresh hook. Today's manifest entry is rebuilt on each ingest tick;
--- callers (kept for API compatibility) just trigger a fresh load.
function M.push_live_update(_unused)
	local generation = _generation
	local webview = M._wv
	if not is_current_window(generation, webview) then return false end
	return schedule_continuation(BRIDGE_DEFER_DELAY_SEC, generation, webview,
		function() load_and_inject(generation, webview) end,
		"Apps dashboard live refresh")
end

return M
