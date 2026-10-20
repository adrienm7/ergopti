-- tools/diagnostics/macos_metrics_apps_page.lua
-- Actual MetricsApps assets in the real factory and WKWebView. No host, SQLite,
-- native chooser, transport, canvas or input API is substituted by this probe.
local M = {}

local SNAPSHOT = [=[
 const rows = [...document.querySelectorAll('#apps-tbody tr')].filter(row => row.querySelector('.app-name-cell'));
 const aggregate = getAggregatedData();
 const pie = Chart.getChart(document.getElementById('category_pie_chart'));
 if (!pie) throw new Error('Actual category Chart instance unavailable');
 const snapshot = {
  row_count: rows.length,
  rows: Object.fromEntries(rows.map(row => [row.querySelector('.app-name-cell').textContent.trim(), {
   category: row.querySelector('.app-cat-cell').textContent.replace(/\s*✎\s*$/, '').trim(),
   duration: row.querySelector('.app-time-cell').textContent
  }])),
  times: Object.fromEntries(Object.entries(aggregate.apps).map(([name, app]) => [name, app.time_ms])),
  categories: Object.fromEntries(['Editor', 'Browser'].map(name => [name, getAppCategory(name)])),
  by_category: Object.fromEntries(Object.entries(aggregate.rich.by_category).map(([name, app]) => [name, app.time_ms])),
  pie_labels: [...pie.data.labels],
  pie_hours: [...pie.data.datasets[0].data],
  filter_buttons: Object.fromEntries([...document.querySelectorAll('#category-filter-buttons button[data-cat]')]
   .map(button => [button.getAttribute('data-cat'), button.classList.contains('active')])),
  filter_selection: currentCategoryFilter === null ? null : [...currentCategoryFilter].sort(),
  render_error: document.getElementById('render-error-banner') !== null,
  script_errors: window.__ergoptiMetricsPageObservation.errors.length,
  same_publishers: window.__ergoptiMetricsPageObservation.data === window.publishMetricsAppsData &&
   window.__ergoptiMetricsPageObservation.categories === window.publishMetricsAppsCategories,
  chart_version: Chart.version
 };
 return JSON.stringify({applied, snapshot});
]=]

function M.run(config, done)
	assert(type(config) == "table" and type(done) == "function")
	local root = assert(config.production_root)
	assert(config.expected_version == hs.processInfo.version)
	assert(config.readiness_query == "typeof window.publishMetricsAppsData")
	package.path = root .. "/macos/?.lua;" .. root .. "/macos/?/init.lua;"
		.. root .. "/_shared/lua/?.lua;" .. root .. "/_shared/lua/?/init.lua;" .. package.path
	local Logger, UI = require("infra.logger"), require("ui.ui_builder")
	local Scheduler, Result = require("adapters.timer_scheduler"), require("adapters.webview_result")
	local json = require("hs.json")
	local policy = assert(io.open(root .. "/_shared/modules/diagnostics/redaction.json", "rb"))
	local raw_policy = assert(policy:read("*a")); assert(policy:close())
	Logger.initialize_privacy(raw_policy)
	require("infra.i18n").init()
	require("infra.i18n").set_locale_no_reload("fr")
	assert(rawequal(require("hs.webview"), hs.webview) and hs.screen.mainScreen())
	local methods, ucc_methods = hs.getObjectMetatable("hs.webview"), hs.getObjectMetatable("hs.webview.usercontent")
	local native = { new = hs.webview.new, controller = hs.webview.usercontent.new, callback = ucc_methods.setCallback }
	assert(debug.getinfo(native.new, "S").what == "C" and debug.getinfo(native.controller, "S").what == "C")
	assert(debug.getinfo(UI.show_webview, "S").source == "@" .. root .. "/macos/ui/ui_builder.lua")
	for _, name in ipairs({ "evaluateJavaScript", "delete", "hide", "windowCallback", "deleteOnClose", "allowNewWindows" }) do
		native[name] = assert(methods[name])
	end
	local state = { timers = {}, evaluations = {}, steps = {}, errors = {}, phase = "opening",
		navigation_completed = false, pending = false, finishing = false, finished = false }
	local baseline, started = Scheduler.activeCount(), hs.timer.absoluteTime()
	local view, controller, finish, later, publish_receipt
	local function count_timers()
		local count = 0; for _ in pairs(state.timers) do count = count + 1 end; return count
	end
	local function failure(detail)
		state.errors[#state.errors + 1] = tostring(detail)
	end
	local function retire_timer(timer)
		local ok = pcall(function()
			assert(rawequal(timer:stop(), timer) and timer:running() == false)
		end)
		if ok then state.timers[timer] = nil end
		return ok
	end
	local function stop_timers()
		for timer in pairs(state.timers) do
			if not retire_timer(timer) then failure("probe timer retirement refused") end
		end
	end
	local function guarded(body)
		if state.finished then return end
		local ok, detail = xpcall(function()
			assert(not state.failure, state.failure)
			assert((hs.timer.absoluteTime() - started) / 1e9 < 40, "MetricsApps native deadline exceeded")
			body()
		end, debug.traceback)
		if not ok then finish(detail) end
	end
	later = function(body)
		local timer
		timer = assert(hs.timer.doAfter(0.05, function()
			local ok, detail = xpcall(function()
				assert(retire_timer(timer), "probe delivery did not retire its exact timer")
				if not state.finished then body() end
			end, debug.traceback)
			if not ok then
				if state.finishing then failure(detail); publish_receipt() else finish(detail) end
			end
		end))
		state.timers[timer] = true
	end
	publish_receipt = function()
		if state.finished then return end
		state.finished = true
		stop_timers()
		if state.failure then failure(state.failure) end
		local unchanged = rawequal(hs.webview.new, native.new) and rawequal(hs.webview.usercontent.new, native.controller)
			and rawequal(ucc_methods.setCallback, native.callback)
		for _, name in ipairs({ "evaluateJavaScript", "delete", "hide", "windowCallback", "deleteOnClose", "allowNewWindows" }) do
			if not rawequal(methods[name], native[name]) then unchanged = false end
		end
		local receipt = { schema_version = 1, contract = "native.metrics-apps-page",
			scope = "actual UiBuilder and MetricsApps page; Host.show, SQLite and native choosers unmeasured",
			native_input = "not attempted; JavaScript DOM click only", ucc_userdata_gc = "unmeasured",
			nonce = config.nonce, source_revision = config.source_revision, source_manifest_digest = config.source_manifest_digest,
			pid = hs.processInfo.processID, version = hs.processInfo.version, arch = hs.processInfo.arch,
			status = #state.errors == 0 and "ok" or "error", errors = state.errors, phase = state.phase,
			navigation_completed = state.navigation_completed, native_apis_unmodified = unchanged,
			readiness = state.readiness, steps = state.steps, native_message = state.message,
			cleanup = { callback_detached = state.detached == true, window_consumed = view ~= nil and getmetatable(view) == nil,
				product_timer_baseline = baseline, product_timer_final = Scheduler.activeCount(),
				probe_timers_final = count_timers(), evaluation_pending = state.pending },
			filter_scope = "category rename and DOM filter with non-null selection; Host.show and persistence unmeasured" }
		done(receipt, state.evaluations, state.raw_message)
	end
	finish = function(detail)
		if state.finished then return end
		if detail then failure(detail) end
		if state.finishing then return end
		state.finishing = true
		stop_timers()
		if controller then
			local ok, ack = pcall(function() return controller:setCallback(nil) end)
			state.detached = ok and rawequal(ack, controller)
			if not state.detached then failure("native callback detach refused") end
		end
		if view and getmetatable(view) ~= nil then
			local ok, err = xpcall(function()
				assert(view:hide() == view and view:isVisible() == false, "owned native hide refused")
				view:delete()
			end, debug.traceback)
			if not ok then failure(err) end
		end
		local cleanup_started = hs.timer.absoluteTime()
		local function observe_cleanup()
			if view and getmetatable(view) == nil and Scheduler.activeCount() == baseline then
				publish_receipt()
			elseif (hs.timer.absoluteTime() - cleanup_started) / 1e9 >= 5 then
				failure("native window or product timer retirement incomplete"); publish_receipt()
			else later(observe_cleanup) end
		end
		observe_cleanup()
	end
	local function evaluate(name, code, after)
		assert(not state.pending and view and getmetatable(view) ~= nil, "evaluation owner unavailable")
		state.pending = true
		local delivered = false
		local ack = view:evaluateJavaScript(code, function(value, native_error)
			guarded(function()
				assert(not delivered, "duplicate native evaluation completion")
				delivered, state.pending = true, false
				state.evaluations[#state.evaluations + 1] = { name = name, result_type = type(value),
					result = type(value) == "string" and value or hs.inspect(value), error_observation = hs.inspect(native_error) }
				assert(not Result.is_error(native_error) and type(value) == "string", "native JavaScript completion refused")
				local decoded = assert(json.decode(value), "native JSON result unavailable")
			after(decoded, value)
			end)
		end)
		assert(rawequal(ack, view), "native JavaScript submission not acknowledged")
	end
	local manifest = { ["2026-10-20"] = {
		Editor = { app_time_ms = 60000, chars = 10, category = "Productivity", hourly = { ["12"] = { c = 10, time_ms = 60000 } } },
		Browser = { app_time_ms = 120000, chars = 20, category = "Utilities", hourly = { ["13"] = { c = 20, time_ms = 120000 } } } } }
	local categories = { Editor = { type = "constructor", score = 0 }, Browser = { type = "toString", score = 0 } }
	local edited = { Editor = { type = "Mon équipe", score = 1 }, Browser = { type = "toString", score = 0 } }
	local function encoded(value) return assert(json.encode(value)) end
	local function payload(data, cats, mr, cr)
		return "window.publishMetricsAppsData(" .. encoded(data) .. "," .. encoded(cats)
			.. ",{}, {manifest_revision:" .. mr .. ",categories_revision:" .. cr .. "})"
	end
	local operations = {
		{ "initial", "const applied=" .. payload(manifest, categories, 1, 1) .. ";" },
		{ "filter", "const button=[...document.querySelectorAll('button[data-cat]')].find(b=>b.getAttribute('data-cat')==='toString');"
			.. "if(!button)throw new Error('Initial filter unavailable');button.click();const applied=true;" },
		{ "filter_reset", "const button=[...document.querySelectorAll('button[data-cat]')].find(b=>b.getAttribute('data-cat')==='toString');"
			.. "if(!button)throw new Error('Initial filter reset unavailable');button.click();const applied=true;" },
		{ "category_edit", "const applied=window.publishMetricsAppsCategories(" .. encoded(edited) .. ",2);" },
	}
	manifest["2026-10-20"].Editor.app_time_ms, manifest["2026-10-20"].Browser.app_time_ms = 120000, 240000
	operations[#operations + 1] = { "newer_manifest", "const applied=" .. payload(manifest, categories, 2, 1) .. ";" }
	operations[#operations + 1] = { "stale", "const applied=" .. payload({}, categories, 1, 1) .. ";" }
	operations[#operations + 1] = { "newer_categories", "const applied=" .. payload({}, categories, 1, 3) .. ";" }
	operations[#operations + 1] = { "select_before_rename", "const button=[...document.querySelectorAll('#category-filter-buttons button[data-cat]')].find(b=>b.getAttribute('data-cat')==='toString');"
		.. "if(!button)throw new Error('Filter before rename unavailable');button.click();const applied=true;" }
	operations[#operations + 1] = { "rename_selected", "const applied=window.publishMetricsAppsCategories(" .. encoded(edited) .. ",4);" }
	operations[#operations + 1] = { "include_renamed", "const button=[...document.querySelectorAll('#category-filter-buttons button[data-cat]')].find(b=>b.getAttribute('data-cat')==='Mon équipe');"
		.. "if(!button)throw new Error('Renamed filter unavailable');button.click();const applied=true;" }
	operations[#operations + 1] = { "include_remaining", "const button=[...document.querySelectorAll('#category-filter-buttons button[data-cat]')].find(b=>b.getAttribute('data-cat')==='toString');"
		.. "if(!button)throw new Error('Remaining filter unavailable');button.click();const applied=true;" }
	operations[#operations + 1] = { "restore_categories", "const applied=window.publishMetricsAppsCategories(" .. encoded(categories) .. ",5);" }
	local function run_step(index)
		local operation = operations[index]
		if not operation then
			state.phase = "native_message"
			evaluate("click", "(()=>{const row=[...document.querySelectorAll('#apps-tbody tr')].find(r=>r.querySelector('.app-name-cell')?.textContent.trim()==='Editor');"
				.. "if(!row)throw new Error('Editor row unavailable');row.querySelector('.app-cat-cell').click();return JSON.stringify({clicked:true});})()",
				function(result)
					assert(result.clicked == true)
					local function wait_message()
						guarded(function()
							if state.message then state.phase = "complete"; finish() else later(wait_message) end
						end)
					end
					wait_message()
				end)
			return
		end
		state.phase = operation[1]
		evaluate(operation[1], "(()=>{" .. operation[2] .. SNAPSHOT .. "})()", function(result, raw_json)
			assert(type(result.applied) == "boolean" and type(result.snapshot) == "table")
			-- Preserve WK's empty objects and null selection without a Lua JSON round trip.
			state.steps[operation[1]] = raw_json
			later(function() guarded(function() run_step(index + 1) end) end)
		end)
	end
	local function ready()
		guarded(function()
			if not state.navigation_completed then later(ready); return end
			evaluate("readiness", "(()=>{return JSON.stringify({data:" .. config.readiness_query
				.. ",categories:typeof window.publishMetricsAppsCategories,ready_state:document.readyState,"
				.. "dependencies:[typeof initDashboard,typeof renderDashboard,typeof renderHourWeekdayHeatmap,typeof openAppDrilldown],"
				.. "private_owner_exposed:Object.prototype.hasOwnProperty.call(window,'metricsAppsPublications'),chart_version:Chart.version});})()",
				function(result)
					if result.data ~= "function" or result.categories ~= "function" then later(ready); return end
					state.readiness = result
					evaluate("observer", "(()=>{const errors=[];window.__ergoptiMetricsPageObservation={errors,data:window.publishMetricsAppsData,categories:window.publishMetricsAppsCategories};"
						.. "window.addEventListener('error',e=>errors.push(String(e.message)));window.addEventListener('unhandledrejection',e=>errors.push(String(e.reason)));"
						.. "return JSON.stringify({installed:true});})()", function(result2)
						assert(result2.installed == true); run_step(1)
					end)
				end)
		end)
	end
	guarded(function()
		local deadline = assert(hs.timer.doAfter(40, function() finish("MetricsApps native deadline exceeded") end))
		state.timers[deadline] = true
		controller = assert(hs.webview.usercontent.new("metrics_apps_bridge"))
		assert(controller:setCallback(function(message)
			state.raw_message = hs.inspect(message)
			local ok, detail = xpcall(function()
				assert(not state.message and not state.finishing and type(message) == "table", "unexpected native page message")
				assert(message.name == "metrics_apps_bridge" and rawequal(message.webView, view), "native page identity differs")
				assert(type(message.frameInfo) == "table" and message.frameInfo.mainFrame == true, "native main frame missing")
				assert(type(message.body) == "table" and message.body.action == "edit" and message.body.app == "Editor"
					and message.body.cat == "constructor" and message.body.score == 0, "native category message differs")
				state.message = { name = message.name, webview_type = type(message.webView), webview_exact = true,
					main_frame = message.frameInfo.mainFrame, body = message.body }
			end, debug.traceback)
			if not ok then state.failure = detail end
		end) == controller)
		local screen = hs.screen.mainScreen():frame()
		local created = UI.show_webview({ assets_dir = root .. "/_shared/ui/metrics_apps/", title = "MetricsApps native page qualification",
			frame = { x = screen.x + 40, y = screen.y + 40, w = math.min(1100, screen.w - 80), h = math.min(800, screen.h - 80) },
			focus = false, delete_on_close = false, usercontent = controller,
			on_webview_created = function(candidate) view = candidate; return true end,
			on_close = function() if not state.finishing then state.failure = "owned page closed unexpectedly" end end,
			on_navigation = function(action, candidate)
				if action == "didFinishNavigation" and rawequal(candidate, view) then state.navigation_completed = true end
				if action == "didFailNavigation" or action == "didFailProvisionalNavigation" then state.failure = action end
				return true
			end })
		assert(created and rawequal(created, view) and type(view) == "userdata", "actual factory view unavailable")
		assert(view:deleteOnClose() == false and view:allowNewWindows() == false, "native policy differs")
		later(ready)
	end)
	return state
end

return M
