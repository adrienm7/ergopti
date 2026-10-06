--- tests/unit/ui/test_permission_ui_geometry_decision.lua
--- Executes the actual probe with explicitly modeled native/IO endpoints.
--- These controls cannot qualify WebKit, screens, permission, installation or input.

local helpers = require("tests.helpers")
local Json = require("json")
local PREFIX = "ERGOPTI_PERMISSION_UI_GEOMETRY "
local PROBE = helpers.driver_root() .. "../../../tools/diagnostics/hs_permission_dialog_native.lua"
local MODULES = {
	"infra.logger", "app_dirs", "infra.locale", "infra.i18n", "ui.ui_builder",
	"adapters.timer_scheduler", "ui.permission_dialog", "ui.permission_dialog.login_items_guide",
	"adapters.json_codec", "adapters.webview_result",
}
local CASES = {
	"tap_holds_off_keeps_banner", "accessibility_precedes_login_items", "accessibility_later_native_bridge",
	"login_items_native_dom_and_window", "unknown_status_keeps_steps", "open_settings_native_bridge",
	"later_dismisses_and_spends_offer", "explicit_reopen_creates_new_view", "native_delete_reports_close",
	"observed_ready_auto_closes",
}

local function modeled_probe(options)
	return helpers.with_fresh_modules(MODULES, function()
		local prior = { hs = _G.hs, type = _G.type, open = io.open, stderr = io.stderr, rename = os.rename }
		local files, lines, views, native_windows = {}, {}, {}, {}
		local remap, observer, current, kind, active, spent, purge = nil, nil, nil, nil, false, false, false
		local frame_reads, observer_starts, factory_calls, original_slots = 0, 0, 0, 0
		local observed_frame
		local root = "/modeled/private/permission-geometry"
		local UI, Dialog, Guide = {}, {}, { POLL_SECONDS = 1, DEADLINE_SECONDS = 600 }
		local function close()
			if current then native_windows[current.window.id()] = nil; setmetatable(current, nil) end
			current, kind, active = nil, nil, false
		end
		UI.show_webview = function(...)
			local supplied = table.pack(...)
			assert(supplied.n == 4 and supplied[2] == nil and supplied[3] == "modeled original slot" and supplied[4] == nil)
			factory_calls = factory_calls + 1
			local view = setmetatable({}, {})
			view.window = { id = function() return factory_calls end }
			native_windows[factory_calls] = view.window
			views[view] = true
			function view.isVisible() return true end
			function view.hswindow() return view.window end
			function view.frame()
				frame_reads = frame_reads + 1
				observed_frame = { w = options.actual_width == nil and 560 or options.actual_width,
					h = options.actual_height == nil and 520 or options.actual_height,
					x = "PRIVATE coordinate", y = "PRIVATE coordinate" }
				return observed_frame
			end
			function view.delete() close() end
			function view.evaluateJavaScript(_, source, receive)
				if source:find("Boolean(", 1, true) then receive(true)
				elseif source:find("querySelector", 1, true) then
					receive({ title = options.bad_dom and "" or "Modeled title", steps = 3,
						open = "Modeled open", later = "Modeled later", lang = "fr" })
				elseif source:find("'later'", 1, true) then
					local previous_kind = kind; close()
					if previous_kind == "accessibility" then
						Dialog.show({ kind = "login_items" }); active = true
					else spent = true end
					receive(true)
				elseif source:find("'open'", 1, true) then
					remap.open_login_items(function() end); receive(true)
				else error("Unexpected modeled JavaScript action") end
			end
			return view, nil, false, nil
		end
		function UI.get_app_geometry() return { width = 560, height = 520 } end
		function Dialog.show(spec)
			kind = spec.kind
			local returned = table.pack(UI.show_webview({ frame = {
				w = options.creation_width == nil and 560 or options.creation_width,
				h = options.creation_height == nil and 520 or options.creation_height,
				x = "PRIVATE coordinate", y = "PRIVATE coordinate" }, title = "PRIVATE title" },
				nil, "modeled original slot", nil))
			assert(returned.n == 4 and returned[2] == nil and returned[3] == false and returned[4] == nil)
			original_slots = original_slots + 1; current = returned[1]; return true
		end
		function Dialog.is_open(wanted) return kind ~= nil and (wanted == nil or kind == wanted) end
		Dialog.close = close
		function Guide.is_active() return active end
		function Guide.offer(value)
			remap = value
			if not remap.get_tap_holds_enabled() or spent then return false end
			active = true; return true
		end
		function Guide.reopen(value) remap = value; Dialog.show({ kind = "login_items" }); active = true; return true end
		package.loaded["infra.logger"] = { init_log_path = function() return true end, error = function() end }
		package.loaded["app_dirs"] = { files = { unified_prefix = "owned-", extension = ".log" } }
		package.loaded["infra.locale"] = { set_locale = function() end }
		package.loaded["infra.i18n"] = { init = function() end, set_locale_injector = function() end,
			get_locale = function() return "fr" end }
		package.loaded["ui.ui_builder"], package.loaded["ui.permission_dialog"] = UI, Dialog
		package.loaded["ui.permission_dialog.login_items_guide"] = Guide
		package.loaded["adapters.timer_scheduler"] = { activeCount = function() return active and 1 or 0 end }
		package.loaded["adapters.webview_result"] = { is_error = function(err) return err ~= nil end }
		package.loaded["adapters.json_codec"] = { encode = function(value)
			if value.kind == "permission_ui_geometry_failure_observation" then
				if options.encoder_changes_frame then observed_frame.w = 560 end
				if options.encoder_throws then error("PRIVATE encode failure") end
				if options.encoder_oversized then return string.rep("X", 1025), nil end
			end
			return Json.encode(value), nil
		end }
		io.open = function(path, mode)
			assert(mode == "wb", "Unexpected modeled file operation")
			return { write = function(_, bytes) files[path] = (files[path] or "") .. bytes; return true end,
				close = function() return true end }
		end
		io.stderr = { write = function(_, bytes)
			if options.writer_changes_frame then observed_frame.w = 560 end
			if options.stderr_throws then error("PRIVATE write failure") end
			lines[#lines + 1] = bytes; return true
		end }
		os.rename = function(source, destination) files[destination], files[source] = files[source], nil; return true end
		_G.type = function(value) if views[value] then return "userdata" end; return prior.type(value) end
		_G.hs = {
			fs = { mkdir = function() return true end, attributes = function(path)
				if purge and path:find("/logs/", 1, true) then return nil end
				if files[path] then return { mode = "file" } end
			end },
			processInfo = { processID = 41, version = "1.1.1" },
			window = { windowForID = function(id) return native_windows[id] end },
			timer = { absoluteTime = function() return 1 end, new = function(interval, callback)
				assert(interval == 0.02, "Original observer delay changed")
				observer = { running_value = false, callback = callback,
					start = function(self) observer_starts = observer_starts + 1; self.running_value = true; return true end,
					stop = function(self) self.running_value = false end,
					running = function(self) return self.running_value end }; return observer
			end },
		}
		local outcome = table.pack(xpcall(function()
			assert(loadfile(PROBE))()({ root = root, nonce = string.rep("1", 32), bundle = "modeled private bundle" })
			for _ = 1, 40 do
				if not observer.running_value then break end
				if active and remap then
					if remap.guardian_state() == "ready" then close(); purge = true end
				end
				observer.callback()
			end
			assert(observer.running_value == false, "Modeled original probe failed to settle")
			local packet = assert(Json.decode(assert(files[root .. "/result.json"])))
			return { packet = packet, lines = lines, frame_reads = frame_reads,
				observer_starts = observer_starts, factory_calls = factory_calls, original_slots = original_slots }
		end, debug.traceback))
		_G.hs, _G.type, io.open, io.stderr, os.rename = prior.hs, prior.type, prior.open, prior.stderr, prior.rename
		if not outcome[1] then error(outcome[2], 0) end
		return outcome[2]
	end)
end

local function check_failure(result)
	helpers.assert_eq(result.packet.status, "error")
	helpers.assert_eq(result.packet.failure:match("^[^\n]+"), "Actual view did not consume shared geometry")
	helpers.assert_eq(#result.packet.case_results, 3)
	for index = 1, 3 do helpers.assert_eq(result.packet.case_results[index].id, CASES[index]) end
	helpers.assert_eq(result.frame_reads, 1, "diagnostic must reuse the original frame")
	helpers.assert_eq(result.observer_starts, 1, "diagnostic must add no timer")
	helpers.assert_eq(result.original_slots, 2, "both original factory calls preserve slots")
	helpers.assert_eq(result.packet.factory_restored, true)
end

local function diagnostic(result)
	helpers.assert_eq(#result.lines, 1, "one closed failure-only line")
	local line = result.lines[1]
	helpers.assert_true(#line <= 1024 and line:sub(-1) == "\n")
	helpers.assert_eq(line:sub(1, #PREFIX), PREFIX)
	helpers.assert_true(line:find("PRIVATE", 1, true) == nil)
	local value = assert(Json.decode(line:sub(#PREFIX + 1)))
	local expected_keys = { "schema", "kind", "authority", "native_verdict", "expected_width", "expected_height",
		"geometry_width", "geometry_height", "creation_width", "creation_height", "actual_width", "actual_height" }
	local keys = {}; for key in pairs(value) do keys[#keys + 1] = key end
	helpers.assert_eq(#keys, #expected_keys)
	for _, key in ipairs(expected_keys) do helpers.assert_true(value[key] ~= nil, "closed key " .. key) end
	helpers.assert_eq(value.schema, 1)
	helpers.assert_eq(value.kind, "permission_ui_geometry_failure_observation")
	helpers.assert_eq(value.authority, false)
	helpers.assert_eq(value.native_verdict, "unchanged")
	helpers.assert_eq(value.expected_width, 560); helpers.assert_eq(value.expected_height, 520)
	helpers.assert_eq(value.geometry_width, 560); helpers.assert_eq(value.geometry_height, 520)
	return value
end

helpers.describe("Independent geometry verdict conservation", function()
	helpers.it("diagnostic IO cannot alter refusal through encoder", function()
		local result = modeled_probe({ actual_width = 559, encoder_changes_frame = true })
		print("INDEPENDENT encoder resulting status=" .. result.packet.status .. " completed_cases=" .. #result.packet.case_results)
		check_failure(result)
	end)
	helpers.it("diagnostic IO cannot alter refusal through stderr", function()
		local result = modeled_probe({ actual_width = 559, writer_changes_frame = true })
		print("INDEPENDENT writer resulting status=" .. result.packet.status .. " completed_cases=" .. #result.packet.case_results)
		check_failure(result)
	end)
end)

helpers.describe("Independent nonscalar geometry filtering", function()
	helpers.it("diagnostic scalar filter rejects a raw real userdata dimension", function()
		local result = modeled_probe({ actual_width = io.stdout }); check_failure(result)
		helpers.assert_eq(diagnostic(result).actual_width, "unavailable")
	end)
	helpers.it("diagnostic scalar filter rejects a table without formatting it", function()
		local value = setmetatable({}, { __tostring = function() error("PRIVATE table formatting occurred") end })
		local result = modeled_probe({ actual_width = value }); check_failure(result)
		helpers.assert_eq(diagnostic(result).actual_width, "unavailable")
	end)
	helpers.it("diagnostic scalar filter rejects a function without invoking it", function()
		local result = modeled_probe({ actual_width = function() error("PRIVATE function invoked") end }); check_failure(result)
		helpers.assert_eq(diagnostic(result).actual_width, "unavailable")
	end)
end)
