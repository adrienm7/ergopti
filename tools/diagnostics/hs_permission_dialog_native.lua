-- tools/diagnostics/hs_permission_dialog_native.lua
-- Actual hosted WebKit/UI/timer acceptance; guardian and settings endpoints are modeled.

return function(config)
	local Logger = require("infra.logger")
	local LogFiles = require("app_dirs").files
	assert(hs.fs.mkdir(config.root .. "/logs"))
	local old_log = config.root .. "/logs/" .. LogFiles.unified_prefix .. "1980-01-01" .. LogFiles.extension
	local old_file = assert(io.open(old_log, "wb"))
	assert(old_file:write("owned deferred purge witness\n")); assert(old_file:close())
	assert(hs.fs.attributes(old_log).mode == "file")
	assert(Logger.init_log_path(config.root .. "/logs") == true)
	local Locale = require("infra.locale")
	local I18n = require("infra.i18n")
	I18n.set_locale_injector(function(code) Locale.set_locale(code) end)
	I18n.init()
	local UI = require("ui.ui_builder")
	local Scheduler = require("adapters.timer_scheduler")
	local Dialog = require("ui.permission_dialog")
	local Guide = require("ui.permission_dialog.login_items_guide")
	local Json = require("adapters.json_codec")
	local WebViewResult = require("adapters.webview_result")
	local original_show = UI.show_webview
	local observations, results = {}, {}
	local state, enabled, settings_calls, unknown_reads = "requires_approval", false, 0, 0
	local observer, busy, failure, stage, current = nil, false, nil, 1, nil
	local started = hs.timer.absoluteTime()
	local deadline = started + 10 * 1000000000
	local later_done, open_done, unknown_at = false, false, nil
	local ids = {}
	local remap = {
		guardian_state = function()
			if state == "unknown" then unknown_reads = unknown_reads + 1 end
			return state
		end,
		get_tap_holds_enabled = function() return enabled end,
		open_login_items = function(on_done)
			settings_calls = settings_calls + 1
			on_done(true)
			return true
		end,
	}
	local function check(condition, message)
		if not condition then error(message, 0) end
	end
	local function record(id)
		results[#results + 1] = { id = id, passed = true }
	end
	-- Observe the real production result, preserving argument/return slots and errors.
	local forwarder = function(...)
		local returned = table.pack(original_show(...))
		if returned[1] ~= nil then observations[#observations + 1] = returned[1] end
		return table.unpack(returned, 1, returned.n)
	end
	UI.show_webview = forwarder
	local function remember_window(view)
		check(type(view) == "userdata", "Actual native view missing")
		if view:isVisible() ~= true then return nil end
		local window = view:hswindow()
		if window == nil then return nil end -- Bounded readiness only; no substituted AX handle.
		local id = window:id()
		check(math.type(id) == "integer" and id > 0, "Actual native window ID unavailable")
		ids[#ids + 1] = id
		return id
	end
	local function no_window(view, id)
		-- Native _delete closes NSWindow before userdata_gc removes this metatable.
		-- AX enumeration absence alone is insufficient evidence of deletion.
		return getmetatable(view) == nil and hs.window.windowForID(id) == nil
	end
	local function javascript(view, source, receive)
		check(not busy, "Overlapping native JavaScript operation")
		busy = true
		view:evaluateJavaScript(source, function(value, err)
			-- Assertions are evaluated by the outer driver, never swallowed by WebKit's pcall.
			busy = false
			if WebViewResult.is_error(err) then failure = "Actual WK evaluation failed"; return end
			local ok, detail = xpcall(receive, debug.traceback, value)
			if not ok then failure = detail end
		end)
	end
	local function finish()
		check(UI.show_webview == forwarder, "Production factory observer changed")
		UI.show_webview = original_show
		if observer ~= nil then
			observer:stop()
			check(observer:running() == false, "Actual observer timer did not retire")
			observer = nil
		end
		local packet = {
			schema = 1, status = failure == nil and "ok" or "error",
			runtime = "native Hammerspoon", pid = hs.processInfo.processID,
			nonce = config.nonce, version = hs.processInfo.version,
			case_results = results, window_ids = ids, settings_calls = settings_calls,
			guide_active = Guide.is_active(), dialog_open = Dialog.is_open(),
			active_timers = Scheduler.activeCount(), factory_restored = UI.show_webview == original_show,
			retired_views = (function()
				local count = 0
				for _, view in ipairs(observations) do
					if getmetatable(view) == nil then count = count + 1 end
				end
				return count
			end)(),
			action_kind = "synthetic DOM actions through native WK usercontent",
			authority = { guardian = "modeled", settings_opener = "modeled", physical_click = false,
				permission_granted = false, system_settings_opened = false, activation = false },
			failure = failure or "",
		}
		local encoded, err = Json.encode(packet)
		check(type(encoded) == "string" and err == nil, "Native receipt encoding failed")
		local file = assert(io.open(config.root .. "/result.pending", "wb"))
		assert(file:write(encoded)); assert(file:close())
		assert(os.rename(config.root .. "/result.pending", config.root .. "/result.json"))
	end
	local function tick()
		if failure ~= nil then finish(); return end
		check(hs.timer.absoluteTime() < deadline, "Actual UI probe deadline exceeded")
		if busy then return end
		if stage == 1 then
			check(Guide.POLL_SECONDS == 1 and Guide.DEADLINE_SECONDS == 600, "Production guide budgets changed")
			check(Guide.offer(remap) == false and not Guide.is_active() and #observations == 0
				and Scheduler.activeCount() == 0, "Disabled tap-holds created guide resources")
			record("tap_holds_off_keeps_banner")
			check(Dialog.show({ kind = "accessibility", bundle_path = config.bundle,
				open_settings = function() error("Accessibility settings must not be requested") end }) == true,
				"Actual accessibility dialog refused")
			stage = 1.5
		elseif stage == 1.5 then
			if remember_window(observations[1]) == nil then return end
			enabled = true
			check(Guide.offer(remap) == true and #observations == 1 and Dialog.is_open("accessibility")
				and Guide.is_active() and Scheduler.activeCount() == 1, "Login Items did not queue behind Accessibility")
			record("accessibility_precedes_login_items")
			stage = 2
		elseif stage == 2 then
			javascript(observations[1], "Boolean(document.getElementById('later'))", function(ready)
				if ready ~= true then return end
				stage = 3
			end)
		elseif stage == 3 then
			stage = 4
			javascript(observations[1], "document.getElementById('later').click(); true", function(value)
				check(value == true, "Accessibility DOM action refused"); later_done = true
			end)
		elseif stage == 4 then
			if not later_done or #observations < 2 or not Dialog.is_open("login_items") then return end
			check(#observations == 2 and not Dialog.is_open("accessibility"), "Queued Login Items duplicated views")
			check(no_window(observations[1], ids[1]), "Accessibility native window survived Later")
			current = observations[2]
			if remember_window(current) == nil then return end
			record("accessibility_later_native_bridge")
			check(not rawequal(observations[2], observations[1]), "Queued native view reused prior object")
			stage = 5
		elseif stage == 5 then
			javascript(current, "document.querySelector('h1') && document.getElementById('open') && document.getElementById('later') ? ({title:document.querySelector('h1').textContent, steps:document.querySelectorAll('ol li').length, open:document.getElementById('open').textContent, later:document.getElementById('later').textContent, lang:document.documentElement.lang}) : null", function(value)
				if type(value) ~= "table" then return end
				check(value.steps == 3 and type(value.title) == "string" and value.title ~= ""
					and type(value.open) == "string" and value.open ~= "" and type(value.later) == "string"
					and value.later ~= "" and value.title:match("^permission_dialog%.") == nil
					and value.open ~= "permission_dialog.open_settings" and value.later ~= "common.later"
					and value.lang == I18n.get_locale(), "Actual Login Items DOM incomplete")
				local geometry = UI.get_app_geometry("permission_dialog")
				local frame = current:frame()
				check(geometry.width == 560 and geometry.height == 520 and frame.w == 560 and frame.h == 520,
					"Actual view did not consume shared geometry")
				record("login_items_native_dom_and_window")
				state = "unknown"; unknown_at = unknown_reads; stage = 6
			end)
		elseif stage == 6 then
			if unknown_reads <= unknown_at then return end
			check(Dialog.is_open("login_items") and Guide.is_active() and #observations == 2
				and settings_calls == 0 and current:isVisible(), "Unknown status dismissed actual guide")
			record("unknown_status_keeps_steps")
			stage = 7
			javascript(current, "document.getElementById('open').click(); true", function(value)
				check(value == true, "Settings DOM action refused"); open_done = true
			end)
		elseif stage == 7 then
			if not open_done or settings_calls < 1 then return end
			check(settings_calls == 1 and Dialog.is_open("login_items") and Guide.is_active()
				and #observations == 2, "Native settings message changed guide ownership")
			record("open_settings_native_bridge")
			later_done = false; stage = 8
			javascript(current, "document.getElementById('later').click(); true", function(value)
				check(value == true, "Login Items DOM action refused"); later_done = true
			end)
		elseif stage == 8 then
			if not later_done or Dialog.is_open("login_items") then return end
			check(not Guide.is_active() and Scheduler.activeCount() == 0 and no_window(observations[2], ids[2]),
				"Later left production window/poll debt")
			state = "requires_approval"
			check(Guide.offer(remap) == false and #observations == 2, "Automatic offer was not spent")
			record("later_dismisses_and_spends_offer")
			check(Guide.reopen(remap) == true and #observations == 3 and Guide.is_active(), "Explicit reopen refused")
			current = observations[3]; stage = 8.5
		elseif stage == 8.5 then
			if remember_window(current) == nil then return end
			check(not rawequal(current, observations[2]), "Explicit reopen reused prior view")
			record("explicit_reopen_creates_new_view")
			current:delete(); stage = 9
		elseif stage == 9 then
			if Dialog.is_open("login_items") or Guide.is_active() then return end
			check(Scheduler.activeCount() == 0 and no_window(observations[3], ids[3]), "Native close left production poll/window debt")
			record("native_delete_reports_close")
			check(Guide.reopen(remap) == true and #observations == 4, "Approval reopen refused")
			current = observations[4]; stage = 9.5
		elseif stage == 9.5 then
			if remember_window(current) == nil then return end
			state = "ready"; stage = 10
		elseif stage == 10 then
			if Guide.is_active() or Dialog.is_open() then return end
			check(no_window(observations[4], ids[4]) and Scheduler.activeCount() == 0, "Approval left native window/poll debt")
			-- Observe the real Logger purge effect; elapsed time alone is not settlement.
			if hs.fs.attributes(old_log) ~= nil then return end
			check(settings_calls == 1 and #observations == 4, "Unexpected settings/view action")
			record("observed_ready_auto_closes")
			finish()
		end
	end
	observer = hs.timer.new(0.02, function()
		local ok, detail = xpcall(tick, debug.traceback)
		if not ok then
			failure = detail
			pcall(function() Dialog.close() end)
			-- Cleanup stays native; an incomplete guide may retain debt until owned-child retirement.
			local finished, err = pcall(finish)
			if not finished then Logger.error("permission_fixture", "%s", tostring(err)) end
		end
	end)
	assert(observer:start())
end
